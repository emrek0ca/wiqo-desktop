import Foundation

private actor BackendTokenStore {
    private let account: String

    init(account: String) {
        self.account = account
    }

    func load() -> String? {
        guard let data = try? RovaKeychainStore.load(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) throws {
        try RovaKeychainStore.save(Data(token.utf8), account: account)
    }

    func delete() throws {
        try RovaKeychainStore.delete(account: account)
    }
}

/// Persistent connection from this Mac to Rova's backend, so a scheduled automation (something
/// the user set up conversationally, e.g. "her sabah 9'da...") can reach this Mac even when no
/// iPhone is around to ask for anything. Authenticates with the same login JWT the iPhone used
/// to sign in to the Rova backend - handed over once via WireMessage.backendToken on the existing
/// local pairing connection, so this needs no separate Mac-side login screen.
///
/// Only ever receives already-vetted, non-destructive steps (the backend filters out anything
/// destructive before it reaches here - see rova-backend/src/automation/scheduler.ts) and runs
/// them through the exact same MacCommandEngine every other command already goes through.
@MainActor
final class MacBackendChannel: NSObject {
    // Keep the relay on the canonical hostname. The old sslip.io hostname followed one server IP;
    // a VPS/IP change made every already-installed Mac reconnect forever to a stale endpoint.
    static let endpoint = URL(string: "wss://api.wiqoai.com/device/socket")!
    static let apiBaseURL = URL(string: "https://api.wiqoai.com")!
    private static let heartbeatInterval: UInt64 = 20
    private static let openTimeout: UInt64 = 12

    private let engine: MacCommandEngine
    private let tokenStore = BackendTokenStore(account: MacStorage.backendTokenAccount)
    private let runtimeStatus: () -> String
    private let deviceInfo: () -> DeviceInfo
    private let pairedDeviceToken: () -> String?
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var openTimeoutTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var currentToken: String?
    private var registrationSent = false
    private let onConnectionStateChange: (Bool) -> Void

    init(
        engine: MacCommandEngine,
        runtimeStatus: @escaping () -> String,
        deviceInfo: @escaping () -> DeviceInfo,
        pairedDeviceToken: @escaping () -> String?,
        onConnectionStateChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.engine = engine
        self.runtimeStatus = runtimeStatus
        self.deviceInfo = deviceInfo
        self.pairedDeviceToken = pairedDeviceToken
        self.onConnectionStateChange = onConnectionStateChange
    }

    /// Reconnects with a stored token, if any - call once at app launch.
    @discardableResult
    func connectWithStoredTokenIfAvailable() async -> Bool {
        let token = await tokenStore.load()
        guard let token, !token.isEmpty else { return false }
        guard currentToken == nil || !registrationSent else { return registrationSent }
        await connect(token: token)
        return registrationSent && currentToken == token
    }

    func connect(token: String) async {
        guard !token.isEmpty else { return }
        if token == currentToken, registrationSent { return }
        if token == currentToken, task != nil { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        registrationSent = false
        publishConnectionState()
        currentToken = token
        reconnectAttempt = 0
        do {
            try await tokenStore.save(token)
        } catch {
            // Keep the live connection attempt possible, but do not pretend the token was
            // persisted. The next launch will require the phone to hand the token over again.
        }
        guard currentToken == token else { return }
        open(token: token)
    }

    func disconnect() async {
        stopConnection()
        reconnectTask?.cancel()
        reconnectTask = nil
        currentToken = nil
        do { try await tokenStore.delete() } catch { }
    }

    /// Stops the socket while retaining the backend token for the next app launch.
    func stopConnection() {
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        registrationSent = false
        publishConnectionState()
    }

    func fetchAutomations() async throws -> [MacAutomation] {
        let request = try authenticatedRequest(path: "automations")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MacBackendChannelError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw MacBackendChannelError.requestFailed
        }
        return try JSONDecoder().decode(MacAutomationResponse.self, from: data).automations
    }

    func cancelAutomation(id: Int) async throws {
        var request = try authenticatedRequest(path: "automations/\(id)")
        request.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MacBackendChannelError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            _ = data
            throw MacBackendChannelError.requestFailed
        }
    }

    private func authenticatedRequest(path: String) throws -> URLRequest {
        guard let token = currentToken else {
            throw MacBackendChannelError.notAuthenticated
        }
        var request = URLRequest(url: Self.apiBaseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func open(token: String) {
        guard currentToken == token else { return }
        task?.cancel(with: .goingAway, reason: nil)
        heartbeatTask?.cancel()
        heartbeatTask = nil
        openTimeoutTask?.cancel()
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        let newTask = session.webSocketTask(with: request)
        self.session = session
        task = newTask
        registrationSent = false
        publishConnectionState()
        newTask.resume()
        sendRegistration(on: newTask)
        receiveNext(on: newTask)
        openTimeoutTask = Task { @MainActor [weak self, weak newTask] in
            do {
                try await Task.sleep(nanoseconds: Self.openTimeout * 1_000_000_000)
            } catch {
                return
            }
            guard let self, let newTask, self.task === newTask, !self.registrationSent else { return }
            self.handleSocketFailure(newTask)
        }
    }

    private func sendRegistration(on task: URLSessionWebSocketTask) {
        let info = deviceInfo()
        let value: [String: Any] = [
            "type": "register",
            "protocolVersion": 2,
            "deviceId": info.id.uuidString,
            "displayName": info.displayName,
            "platform": info.platform,
            "capabilities": info.capabilities,
            "applicationTargets": info.applicationTargets.map { target in
                [
                    "name": target.name,
                    "bundleIdentifier": target.bundleIdentifier ?? "",
                    "isRunning": target.isRunning,
                    "supportedActions": target.supportedActions.map(\.rawValue)
                ] as [String: Any]
            },
            "authorities": info.authorities.map { authority in
                [
                    "capability": authority.capability,
                    "displayName": authority.displayName,
                    "access": authority.access.rawValue,
                    "requiredPermissions": authority.requiredPermissions,
                    "message": authority.message ?? ""
                ] as [String: Any]
            }
        ]
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) else {
            handleSocketFailure(task)
            return
        }
        task.send(.string(text)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.task === task else { return }
                guard error == nil else {
                    self.handleSocketFailure(task)
                    return
                }
                self.registrationSent = true
                self.reconnectAttempt = 0
                self.openTimeoutTask?.cancel()
                self.openTimeoutTask = nil
                self.publishConnectionState()
                self.startHeartbeat(on: task)
                self.sendAutomationReceipts(on: task)
            }
        }
    }

    private func receiveNext(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            switch result {
            case .success(.string(let text)):
                guard let data = text.data(using: .utf8) else {
                    Task { @MainActor [weak self] in self?.receiveNext(on: task) }
                    return
                }
                let parseTask = Task.detached(priority: .utility) {
                    Self.parseIncoming(data)
                }
                Task { @MainActor [weak self] in
                    guard let self, self.task === task else { return }
                    if let message = await parseTask.value {
                        self.handleIncoming(message, on: task)
                    }
                    self.receiveNext(on: task)
                }
            case .success:
                Task { @MainActor [weak self] in self?.receiveNext(on: task) }
            case .failure:
                Task { @MainActor [weak self] in
                    guard let self, self.task === task else { return }
                    self.handleSocketFailure(task)
                }
            }
        }
    }

    private func startHeartbeat(on task: URLSessionWebSocketTask) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self, weak task] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.heartbeatInterval * 1_000_000_000)
                } catch {
                    return
                }
                guard let self, let task, self.task === task, self.registrationSent else { return }
                task.sendPing { [weak self, weak task] error in
                    Task { @MainActor [weak self, weak task] in
                        guard let self, let task, self.task === task else { return }
                        if error != nil { self.handleSocketFailure(task) }
                    }
                }
            }
        }
    }

    private func handleSocketFailure(_ task: URLSessionWebSocketTask) {
        guard self.task === task else { return }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        task.cancel(with: .abnormalClosure, reason: nil)
        self.task = nil
        session?.invalidateAndCancel()
        session = nil
        registrationSent = false
        publishConnectionState()
        scheduleReconnect()
    }

    private func publishConnectionState() {
        onConnectionStateChange(registrationSent)
    }

    private func handleIncoming(_ message: ParsedBackendMessage, on task: URLSessionWebSocketTask) {
        switch message {
        case .automationStep(let payload):
            sendAutomationStepAck(payload, on: task)
            executeAutomationStep(payload, on: task)
        case .automationRun(let payload):
            executeLegacyAutomation(payload)
        case .automationComplete:
            // The Mac does not need to act on the final checkpoint; iPhone/UI clients consume it.
            break
        case .interactiveCommand(let payload):
            executeInteractiveCommand(payload, on: task)
        }
    }

    private nonisolated static func parseIncoming(_ data: Data) -> ParsedBackendMessage? {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = envelope["type"] as? String else { return nil }
        let decoder = JSONDecoder()
        switch type {
        case "automationStep":
            guard let payload = try? decoder.decode(AutomationStepPayload.self, from: data) else { return nil }
            return .automationStep(payload)
        case "automationRun":
            guard let payload = try? decoder.decode(AutomationRunPayload.self, from: data) else { return nil }
            return .automationRun(payload)
        case "automationComplete":
            return .automationComplete
        case "interactiveCommand":
            decoder.dateDecodingStrategy = .iso8601
            guard let payload = try? decoder.decode(InteractiveCommandPayload.self, from: data) else { return nil }
            return .interactiveCommand(payload)
        default:
            return nil
        }
    }

    /// A confirmed chat command relayed through the backend instead of the direct local
    /// connection - same request shape, same MacCommandEngine, no unattended-execution
    /// restriction, because the phone already gated this exactly as it would for the direct path.
    /// Still requires the same per-command signature the direct path requires (see MacRuntime's
    /// `.command` handling) - the backend relay only proves "a signed-in account," not "the device
    /// that holds this Mac's pairing token," so skipping this check here would have let anyone
    /// signed in to the account (or the backend itself, if it were ever compromised) run commands
    /// this Mac never actually paired to accept unsigned.
    private func executeInteractiveCommand(_ payload: InteractiveCommandPayload, on task: URLSessionWebSocketTask) {
        guard let token = pairedDeviceToken(), RovaValidation.verifyRequestSignature(request: payload.request, token: token) else {
            let now = Date()
            let error = RovaError(code: "INVALID_SIGNATURE", message: "Komut kriptografik imzası geçersiz.")
            let result = CommandResult(commandID: payload.request.id, status: .failed, message: error.message, startedAt: now, finishedAt: now, error: error)
            sendInteractiveCommandResult(commandId: payload.commandId, result: result, on: task)
            return
        }
        Task { @MainActor [weak self, engine, runtimeStatus] in
            let result = await engine.execute(payload.request, runtimeStatus: runtimeStatus())
            self?.sendInteractiveCommandResult(commandId: payload.commandId, result: result, on: task)
        }
    }

    private func sendInteractiveCommandResult(commandId: String, result: CommandResult, on task: URLSessionWebSocketTask) {
        guard self.task === task else { return }
        let payload = InteractiveCommandResultPayload(commandId: commandId, result: result)
        guard let data = try? Self.iso8601Encoder.encode(payload), let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    /// CommandRequest/CommandResult carry Date fields, encoded as ISO-8601 strings everywhere
    /// else in this protocol (see RovaShared/Framing.swift's RovaWireCodec) - this channel's own
    /// JSON needs the same strategy or those fields simply fail to decode.
    private static let iso8601Encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let iso8601Decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func executeAutomationStep(_ payload: AutomationStepPayload, on task: URLSessionWebSocketTask) {
        guard let commandID = UUID(uuidString: payload.commandId) else {
            sendAutomationStepResult(
                runID: payload.runId,
                stepID: payload.stepId,
                commandID: payload.commandId,
                status: .denied,
                message: "Otomasyon komut kimliği geçersiz.",
                error: RovaError(code: "INVALID_COMMAND_ID", message: "Otomasyon komut kimliği geçersiz.", category: "validation"),
                on: task
            )
            return
        }
        guard Self.canRunUnattended(payload.step) else {
            sendAutomationStepResult(
                runID: payload.runId,
                stepID: payload.stepId,
                commandID: payload.commandId,
                status: .denied,
                message: "Bu otomasyon adımı kullanıcı onayı gerektiriyor.",
                error: RovaError(code: "AUTOMATION_STEP_BLOCKED", message: "Bu otomasyon adımı kullanıcı onayı gerektiriyor.", category: "permission"),
                on: task
            )
            return
        }
        let request = CommandRequest(id: commandID, type: payload.step.type, payload: payload.step.payload)
        Task { @MainActor [weak self, engine, runtimeStatus] in
            let result = await engine.execute(request, runtimeStatus: runtimeStatus())
            self?.sendAutomationStepResult(
                runID: payload.runId,
                stepID: payload.stepId,
                commandID: payload.commandId,
                status: result.status,
                message: result.message,
                error: result.error,
                on: task
            )
        }
    }

    private func sendAutomationStepAck(_ payload: AutomationStepPayload, on task: URLSessionWebSocketTask) {
        let value = AutomationStepAckPayload(runId: payload.runId, stepId: payload.stepId, commandId: payload.commandId)
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func sendAutomationReceipts(on task: URLSessionWebSocketTask) {
        Task { @MainActor [weak self, engine] in
            let results = await engine.persistedResults()
            guard let self, self.task === task, !results.isEmpty else { return }
            let receipts = results.prefix(128).map { result in
                AutomationReceiptPayload(
                    commandId: result.commandID.uuidString,
                    status: result.status.rawValue,
                    message: result.message,
                    error: result.error
                )
            }
            let payload = AutomationReceiptsPayload(receipts: Array(receipts))
            guard let data = try? JSONEncoder().encode(payload), let text = String(data: data, encoding: .utf8) else { return }
            task.send(.string(text)) { _ in }
        }
    }

    private func executeLegacyAutomation(_ payload: AutomationRunPayload) {
        Task { [engine, runtimeStatus] in
            for (index, step) in payload.steps.enumerated() where Self.canRunUnattended(step) {
                // Older automation payloads may not carry a command ID. Derive one from the
                // stable run/step position so reconnect delivery cannot execute the same step
                // again under a fresh UUID.
                let id = step.id.flatMap(UUID.init) ?? Self.stableLegacyCommandID(runID: payload.runId, stepIndex: index)
                let request = CommandRequest(id: id, type: step.type, payload: step.payload)
                _ = await engine.execute(request, runtimeStatus: runtimeStatus())
            }
        }
    }

    private static func stableLegacyCommandID(runID: Int, stepIndex: Int) -> UUID {
        let digest = RovaCrypto.sha256Hex(Data("legacy-automation:\(runID):\(stepIndex)".utf8))
        let uuidText = "\(digest.prefix(8))-\(digest.dropFirst(8).prefix(4))-\(digest.dropFirst(12).prefix(4))-\(digest.dropFirst(16).prefix(4))-\(digest.dropFirst(20).prefix(12))"
        return UUID(uuidString: uuidText)!
    }

    private func sendAutomationStepResult(
        runID: Int,
        stepID: Int,
        commandID: String,
        status: CommandStatus,
        message: String,
        error: RovaError?,
        on task: URLSessionWebSocketTask
    ) {
        let targetTask = self.task === task ? task : self.task
        guard let targetTask else { return }
        let payload = AutomationStepResultPayload(
            runId: runID,
            stepId: stepID,
            commandId: commandID,
            status: status.rawValue,
            message: message,
            error: error
        )
        guard let data = try? JSONEncoder().encode(payload), let text = String(data: data, encoding: .utf8) else { return }
        targetTask.send(.string(text)) { _ in }
    }

    private static func canRunUnattended(_ step: AutomationStep) -> Bool {
        guard !step.isDestructive, step.requiresUserPresence != true else { return false }
        return RovaCommandAuthority.permitsUnattended(type: step.type, payload: step.payload)
    }

    private func scheduleReconnect() {
        guard let currentToken, reconnectTask == nil else { return }
        let delays: [UInt64] = [1, 2, 4, 8, 16, 30]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        let jitter = UInt64.random(in: 0...250)
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000 + jitter * 1_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.open(token: currentToken)
        }
    }
}

enum MacBackendChannelError: LocalizedError {
    case notAuthenticated
    case invalidResponse
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Wiqo hesabı iPhone üzerinden bağlanmamış."
        case .invalidResponse, .requestFailed: return "Otomasyonlar alınamadı."
        }
    }
}

struct MacAutomation: Decodable, Identifiable {
    let id: Int
    let prompt: String
    let cron: String
    let isActive: Bool
    let lastRunAt: String?
    let nextRunAt: String?
    let trigger: MacAutomationTrigger?
}

private struct MacAutomationResponse: Decodable {
    let automations: [MacAutomation]
}

struct MacAutomationTrigger: Decodable {
    let type: String
    let intervalSeconds: Int?
    let lastState: Bool?
    let lastError: String?
    let nextCheckAt: String?
}

private enum ParsedBackendMessage: Sendable {
    case automationStep(AutomationStepPayload)
    case automationRun(AutomationRunPayload)
    case automationComplete
    case interactiveCommand(InteractiveCommandPayload)
}

private struct AutomationRunPayload: Decodable, Sendable {
    let type: String
    let runId: Int
    let reply: String?
    let steps: [AutomationStep]
}

private struct AutomationStep: Decodable, Sendable {
    let id: String?
    let type: CommandType
    let payload: CommandPayload
    let summary: String
    let isDestructive: Bool
    // Optional so queued runs written by an older backend remain deliverable.
    let requiresUserPresence: Bool?
}

private struct AutomationStepPayload: Decodable, Sendable {
    let type: String
    let runId: Int
    let stepId: Int
    let commandId: String
    let step: AutomationStep
}

private struct AutomationStepResultPayload: Encodable {
    let type = "automationStepResult"
    let protocolVersion = 2
    let runId: Int
    let stepId: Int
    let commandId: String
    let status: String
    let message: String
    let error: RovaError?
}

private struct AutomationStepAckPayload: Encodable {
    let type = "automationStepAck"
    let protocolVersion = 2
    let runId: Int
    let stepId: Int
    let commandId: String
}

private struct AutomationReceiptPayload: Encodable {
    let commandId: String
    let status: String
    let message: String
    let error: RovaError?
}

private struct AutomationReceiptsPayload: Encodable {
    let type = "automationReceipts"
    let protocolVersion = 2
    let receipts: [AutomationReceiptPayload]
}

private struct InteractiveCommandPayload: Decodable, Sendable {
    let type: String
    let commandId: String
    let request: CommandRequest
}

private struct InteractiveCommandResultPayload: Encodable {
    let type = "interactiveCommandResult"
    let commandId: String
    let result: CommandResult
}
