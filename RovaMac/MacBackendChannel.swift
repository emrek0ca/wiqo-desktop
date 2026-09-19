import Foundation

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
    private static let endpoint = URL(string: "wss://84-247-172-213.sslip.io/device/socket")!
    private static let apiBaseURL = URL(string: "https://84-247-172-213.sslip.io")!
    private static let tokenAccount = "rova-backend-token"

    private let engine: MacCommandEngine
    private let runtimeStatus: () -> String
    private let deviceInfo: () -> DeviceInfo
    private let pairedDeviceToken: () -> String?
    private var task: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var currentToken: String?

    init(engine: MacCommandEngine, runtimeStatus: @escaping () -> String, deviceInfo: @escaping () -> DeviceInfo, pairedDeviceToken: @escaping () -> String?) {
        self.engine = engine
        self.runtimeStatus = runtimeStatus
        self.deviceInfo = deviceInfo
        self.pairedDeviceToken = pairedDeviceToken
    }

    /// Reconnects with a stored token, if any - call once at app launch.
    func connectWithStoredTokenIfAvailable() {
        guard let data = try? RovaKeychainStore.load(account: Self.tokenAccount),
              let token = String(data: data, encoding: .utf8) else { return }
        connect(token: token)
    }

    func connect(token: String) {
        guard token != currentToken || task == nil else { return }
        try? RovaKeychainStore.save(Data(token.utf8), account: Self.tokenAccount)
        currentToken = token
        reconnectAttempt = 0
        open(token: token)
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        currentToken = nil
        try? RovaKeychainStore.delete(account: Self.tokenAccount)
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
        guard let token = currentToken ?? storedBackendToken() else {
            throw MacBackendChannelError.notAuthenticated
        }
        var request = URLRequest(url: Self.apiBaseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func storedBackendToken() -> String? {
        guard let data = try? RovaKeychainStore.load(account: Self.tokenAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func open(token: String) {
        task?.cancel(with: .goingAway, reason: nil)
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default)
        let newTask = session.webSocketTask(with: request)
        task = newTask
        newTask.resume()
        sendRegistration(on: newTask)
        receiveNext(on: newTask)
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
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            guard error == nil else { return }
            Task { @MainActor [weak self] in
                guard let self, self.task === task else { return }
                self.sendAutomationReceipts(on: task)
            }
        }
    }

    private func receiveNext(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.task === task else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handleIncoming(text, on: task) }
                    self.reconnectAttempt = 0
                    self.receiveNext(on: task)
                case .failure:
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handleIncoming(_ text: String, on task: URLSessionWebSocketTask) {
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = envelope["type"] as? String else { return }
        switch type {
        case "automationStep":
            guard let payload = try? JSONDecoder().decode(AutomationStepPayload.self, from: data) else { return }
            sendAutomationStepAck(payload, on: task)
            executeAutomationStep(payload, on: task)
        case "automationRun":
            guard let payload = try? JSONDecoder().decode(AutomationRunPayload.self, from: data) else { return }
            executeLegacyAutomation(payload)
        case "automationComplete":
            // The Mac does not need to act on the final checkpoint; iPhone/UI clients consume it.
            break
        case "interactiveCommand":
            guard let payload = try? Self.iso8601Decoder.decode(InteractiveCommandPayload.self, from: data) else { return }
            executeInteractiveCommand(payload, on: task)
        default:
            break
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
            for step in payload.steps where Self.canRunUnattended(step) {
                let id = step.id.flatMap(UUID.init) ?? UUID()
                let request = CommandRequest(id: id, type: step.type, payload: step.payload)
                _ = await engine.execute(request, runtimeStatus: runtimeStatus())
            }
        }
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
        guard let currentToken else { return }
        reconnectTask?.cancel()
        let delays: [UInt64] = [1, 2, 4, 8, 16, 30]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.open(token: currentToken)
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

private struct AutomationRunPayload: Decodable {
    let type: String
    let runId: Int
    let reply: String?
    let steps: [AutomationStep]
}

private struct AutomationStep: Decodable {
    let id: String?
    let type: CommandType
    let payload: CommandPayload
    let summary: String
    let isDestructive: Bool
    // Optional so queued runs written by an older backend remain deliverable.
    let requiresUserPresence: Bool?
}

private struct AutomationStepPayload: Decodable {
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

private struct InteractiveCommandPayload: Decodable {
    let type: String
    let commandId: String
    let request: CommandRequest
}

private struct InteractiveCommandResultPayload: Encodable {
    let type = "interactiveCommandResult"
    let commandId: String
    let result: CommandResult
}
