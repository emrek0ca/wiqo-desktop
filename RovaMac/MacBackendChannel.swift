import Foundation

private actor BackendTokenStore {
    private let accessAccount: String
    private let refreshAccount: String
    private let accountAccount: String

    init(accessAccount: String, refreshAccount: String, accountAccount: String) {
        self.accessAccount = accessAccount
        self.refreshAccount = refreshAccount
        self.accountAccount = accountAccount
    }

    func loadAccess() -> String? {
        guard let data = try? RovaKeychainStore.load(account: accessAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func loadRefresh() -> String? {
        guard let data = try? RovaKeychainStore.load(account: refreshAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(accessToken: String, refreshToken: String?, accountToken: String?) throws {
        try RovaKeychainStore.save(Data(accessToken.utf8), account: accessAccount)
        if let refreshToken, !refreshToken.isEmpty {
            try RovaKeychainStore.save(Data(refreshToken.utf8), account: refreshAccount)
        } else {
            try? RovaKeychainStore.delete(account: refreshAccount)
        }
        if let accountToken, !accountToken.isEmpty {
            try RovaKeychainStore.save(Data(accountToken.utf8), account: accountAccount)
        } else {
            try? RovaKeychainStore.delete(account: accountAccount)
        }
    }

    func delete() throws {
        try RovaKeychainStore.delete(account: accessAccount)
        try? RovaKeychainStore.delete(account: refreshAccount)
        try? RovaKeychainStore.delete(account: accountAccount)
    }
}

private struct BackendSessionCredentials: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let accessTokenExpiresIn: Int
    let refreshTokenExpiresAt: String
}

/// Persistent connection from this Mac to Rova's backend, so a scheduled automation (something
/// the user set up conversationally, e.g. "her sabah 9'da...") can reach this Mac even when no
/// iPhone is around to ask for anything. Current clients persist only short-lived, device-scoped
/// access plus rotating refresh credentials. A legacy local account token is used only long enough
/// to bootstrap that scoped session, so this needs no separate Mac-side login screen.
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
    private let tokenStore = BackendTokenStore(
        accessAccount: MacStorage.backendTokenAccount,
        refreshAccount: MacStorage.backendRefreshTokenAccount,
        accountAccount: MacStorage.backendAccountTokenAccount
    )
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
    private var currentRefreshToken: String?
    private final class TerminalJobRecord {
        let id: String
        let grantId: String
        let workingDirectory: String
        var state = "running"
        var processIdentifier: Int32?
        var cancelRequested = false
        var output: ProcessOutputContent?
        var message = "Terminal işi çalışıyor."
        var errorCode: String?
        let startedAt = Date()

        init(id: String, grantId: String, workingDirectory: String) {
            self.id = id
            self.grantId = grantId
            self.workingDirectory = workingDirectory
        }
    }
    private var terminalJobs: [String: TerminalJobRecord] = [:]
    func accessTokenForFileTransfer() async -> String? {
        if let refresh = currentRefreshToken,
           let credentials = await refreshCredentials(refreshToken: refresh),
           currentRefreshToken == refresh {
            currentRefreshToken = credentials.refreshToken
            try? await tokenStore.save(accessToken: credentials.accessToken, refreshToken: credentials.refreshToken, accountToken: nil)
            return credentials.accessToken
        }
        return currentToken
    }
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

    /// Re-sends the current catalog (apps, capabilities, authorities) on the live socket, so a
    /// snapshot the backend already has from a slower or earlier scan does not stay stale for the
    /// rest of the connection. A no-op while there is no open, registered socket.
    func resendRegistration() {
        guard let task, registrationSent else { return }
        sendRegistration(on: task)
    }

    /// Reconnects with a stored token, if any - call once at app launch.
    @discardableResult
    func connectWithStoredTokenIfAvailable() async -> Bool {
        let token = await tokenStore.loadAccess()
        guard let token, !token.isEmpty else { return false }
        guard currentToken == nil || !registrationSent else { return registrationSent }
        let refreshToken = await tokenStore.loadRefresh()
        await connect(token: token, refreshToken: refreshToken)
        return registrationSent && currentToken != nil
    }

    /// Accepts either the legacy account token (from local pairing) or a scoped device access
    /// token. New pairing responses provide the refresh token explicitly; local pairing bootstraps
    /// a scoped session once, keeping the existing Protocol v2 message unchanged.
    func connect(token: String, refreshToken: String? = nil, accountToken: String? = nil) async {
        guard !token.isEmpty else { return }
        if token == currentToken, refreshToken == currentRefreshToken, registrationSent { return }
        if token == currentToken, task != nil { return }
        let credentials: (access: String, refresh: String?)
        if let refreshToken, !refreshToken.isEmpty {
            credentials = (token, refreshToken)
        } else if let bootstrapped = await bootstrapCredentials(accountToken: token) {
            credentials = (bootstrapped.accessToken, bootstrapped.refreshToken)
        } else {
            // Backward compatibility for an older backend. The socket still accepts the account
            // token, but no refresh loop is possible until the next successful bootstrap.
            credentials = (token, nil)
        }
        let legacyAccountToken = credentials.refresh == nil ? (accountToken ?? token) : nil
        await establish(accessToken: credentials.access, refreshToken: credentials.refresh, accountToken: legacyAccountToken)
    }

    private func establish(accessToken: String, refreshToken: String?, accountToken: String?) async {
        guard !accessToken.isEmpty else { return }
        if accessToken == currentToken, refreshToken == currentRefreshToken, registrationSent { return }
        if accessToken == currentToken, task != nil { return }
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
        currentToken = accessToken
        currentRefreshToken = refreshToken
        reconnectAttempt = 0
        do {
            try await tokenStore.save(accessToken: accessToken, refreshToken: refreshToken, accountToken: accountToken)
        } catch {
            // Keep the live connection attempt possible, but do not pretend the token was
            // persisted. The next launch will require the phone to hand the token over again.
        }
        guard currentToken == accessToken else { return }
        open(token: accessToken)
    }

    func disconnect() async {
        stopConnection()
        reconnectTask?.cancel()
        reconnectTask = nil
        currentToken = nil
        currentRefreshToken = nil
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

    private func bootstrapCredentials(accountToken: String) async -> BackendSessionCredentials? {
        guard let body = try? JSONSerialization.data(withJSONObject: ["deviceId": deviceInfo().id.uuidString]) else { return nil }
        var request = URLRequest(url: Self.apiBaseURL.appendingPathComponent("device-sessions/bootstrap"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accountToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(BackendSessionCredentials.self, from: data)
    }

    private func refreshCredentials(refreshToken: String) async -> BackendSessionCredentials? {
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "deviceId": deviceInfo().id.uuidString,
            "refreshToken": refreshToken
        ]) else { return nil }
        var request = URLRequest(url: Self.apiBaseURL.appendingPathComponent("device-sessions/refresh"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let credentials = try? JSONDecoder().decode(BackendSessionCredentials.self, from: data),
              !credentials.accessToken.isEmpty,
              !credentials.refreshToken.isEmpty else { return nil }
        return credentials
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
            // Optional protocol features; an older backend ignores the field.
            "features": CapabilityStore.shared.isEnabled("device.code.execute") ? [RovaTerminalPolicy.feature] : [],
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
        case .terminalCommand(let payload):
            executeTerminalCommand(payload, on: task)
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
        case "terminalCommand":
            guard let payload = try? decoder.decode(TerminalCommandPayload.self, from: data) else { return nil }
            return .terminalCommand(payload)
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
        if payload.request.signatureVersion != 2 {
            let now = Date()
            let error = RovaError(code: "SIGNATURE_VERSION_REQUIRED", message: "Güvenli komut imzası için Wiqo iPhone uygulamasını güncelleyin.", category: "permission")
            let result = CommandResult(commandID: payload.request.id, status: .failed, message: error.message, startedAt: now, finishedAt: now, error: error)
            sendInteractiveCommandResult(commandId: payload.commandId, result: result, on: task)
            return
        }
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

    /// One command of a terminal session the user approved on the phone. The backend only relays:
    /// the grant must carry a valid signature made with this Mac's pairing token (which the backend
    /// never has), must not be expired, the working folder must resolve inside the granted folder,
    /// "read" grants run inspection commands only, and forbidden commands never run. Code execution
    /// turned off in Wiqo's capability settings turns this off too.
    private func executeTerminalCommand(_ payload: TerminalCommandPayload, on task: URLSessionWebSocketTask) {
        let request = payload.request
        pruneTerminalJobs()
        let action = request.action ?? "run"
        if action == "get_job" || action == "cancel_job" {
            handleTerminalJobAction(action, jobId: request.jobId, grant: request.grant, commandId: payload.commandId, on: task)
            return
        }
        guard let grant = request.grant else {
            sendTerminalDenial(payload.commandId, code: "TERMINAL_GRANT_INVALID", message: "Terminal oturum izni eksik.", on: task)
            return
        }
        let deny: (String, String) -> Void = { [weak self] code, message in
            self?.sendTerminalDenial(payload.commandId, code: code, message: message, on: task)
        }
        guard CapabilityStore.shared.isEnabled("device.code.execute") else {
            deny("TERMINAL_DISABLED", "Kod çalıştırma Wiqo Mac ayarlarında kapalı.")
            return
        }
        guard let token = pairedDeviceToken(),
              RovaTerminalPolicy.verifyGrant(grantId: grant.id, rootDirectory: grant.rootDirectory, mode: grant.mode, expiresAt: grant.expiresAt, signature: grant.signature, token: token) else {
            deny("TERMINAL_GRANT_INVALID", "Terminal oturum izni geçersiz ya da süresi dolmuş; telefondan yeniden onay gerekiyor.")
            return
        }
        guard let requestedDirectory = request.workingDirectory,
              let root = RovaTerminalPolicy.resolveDirectory(grant.rootDirectory),
              let directory = RovaTerminalPolicy.resolveDirectory(requestedDirectory),
              RovaTerminalPolicy.isWithin(directory, root: root) else {
            deny("TERMINAL_OUTSIDE_GRANT", "Çalışma klasörü onaylanan klasörün dışında.")
            return
        }
        if action == "apply_patch" {
            guard grant.mode == "full",
                  let rawFilePath = request.filePath,
                  let filePath = RovaTerminalPolicy.resolveExistingFile(rawFilePath, workingDirectory: directory, root: root),
                  let patch = request.patch, patch.utf8.count <= 120_000 else {
                deny("TERMINAL_PATCH_SCOPE", "Yama için tam izin ve onaylı klasördeki mevcut bir dosya gerekiyor.")
                return
            }
            let applied = MacSystem.applyTerminalPatch(filePath: filePath, patch: patch, expectedPatchPath: rawFilePath)
            let now = Date()
            if let error = applied.error {
                let result = CommandResult(commandID: UUID(), status: .failed, message: error.message, startedAt: now, finishedAt: now, error: error)
                sendInteractiveCommandResult(commandId: payload.commandId, result: result, on: task)
                return
            }
            let job = TerminalJobContent(jobId: payload.commandId, status: "completed", diff: applied.diff, applied: true, message: "Yama uygulandı.")
            let result = CommandResult(commandID: UUID(), status: .completed, message: "Yama uygulandı; değişiklik diff'i döndürüldü.", startedAt: now, finishedAt: now, data: .terminalJob(job))
            sendInteractiveCommandResult(commandId: payload.commandId, result: result, on: task)
            return
        }
        guard action == "run" || action == "start_job" else {
            deny("TERMINAL_ACTION_INVALID", "Terminal işlemi desteklenmiyor.")
            return
        }
        let command = request.command ?? ""
        guard !command.isEmpty, command.count <= 4_000, !command.contains("\0") else {
            deny("TERMINAL_COMMAND_INVALID", "Komut geçersiz.")
            return
        }
        if RovaTerminalPolicy.isForbidden(command) {
            deny("TERMINAL_COMMAND_FORBIDDEN", "Bu komut Wiqo terminal oturumlarında çalıştırılmaz.")
            return
        }
        if grant.mode != "full" && !RovaTerminalPolicy.isReadOnly(command) {
            deny("TERMINAL_READ_ONLY", "Bu oturum yalnızca okuma izni veriyor; değiştiren komut için yeni onay gerekiyor.")
            return
        }
        if action == "start_job" {
            guard let jobId = request.jobId, UUID(uuidString: jobId) != nil else {
                deny("TERMINAL_JOB_ID_INVALID", "Arka plan işi kimliği geçersiz.")
                return
            }
            if let existing = terminalJobs[jobId], existing.grantId != grant.id {
                deny("TERMINAL_GRANT_INVALID", "Bu iş farklı bir terminal iznine bağlı.")
                return
            }
            let remainingSeconds = max(1, grant.expiresAt - Int(Date().timeIntervalSince1970))
            startTerminalJob(id: jobId, grantId: grant.id, command: command, directory: directory, timeoutSeconds: max(1, min(1800, min(request.timeoutSeconds ?? 600, remainingSeconds))))
            sendTerminalJobSnapshot(jobId, commandId: payload.commandId, on: task)
            return
        }
        let timeoutSeconds = max(1, min(110, request.timeoutSeconds ?? 60))
        let commandId = payload.commandId
        Task.detached(priority: .userInitiated) { [weak self] in
            let started = Date()
            let outcome = MacSystem.executeTerminalCommand(command, workingDirectory: directory, timeoutSeconds: timeoutSeconds, processStarted: { _ in })
            let finished = Date()
            let status: CommandStatus = outcome.error == nil ? .completed : (outcome.error?.category == "timeout" ? .unknown : .failed)
            let message = outcome.error?.message ?? "Komut tamamlandı."
            let result = CommandResult(commandID: UUID(), status: status, message: message, startedAt: started, finishedAt: finished, data: outcome.data, error: outcome.error)
            await MainActor.run { self?.sendInteractiveCommandResult(commandId: commandId, result: result, on: task) }
        }
    }

    private func sendTerminalDenial(_ commandId: String, code: String, message: String, on task: URLSessionWebSocketTask) {
        let now = Date()
        let error = RovaError(code: code, message: message, category: "permission")
        let result = CommandResult(commandID: UUID(), status: .denied, message: message, startedAt: now, finishedAt: now, error: error)
        sendInteractiveCommandResult(commandId: commandId, result: result, on: task)
    }

    private func handleTerminalJobAction(_ action: String, jobId: String?, grant: TerminalGrantPayload?, commandId: String, on task: URLSessionWebSocketTask) {
        guard let jobId, UUID(uuidString: jobId) != nil, let job = terminalJobs[jobId] else {
            let now = Date()
            let value = TerminalJobContent(jobId: jobId ?? "", status: "unknown", message: "Bu Mac sürecinde iş bulunamadı; yeniden başlatıldıysa sonucu bilinmiyor.", errorCode: "TERMINAL_JOB_UNKNOWN")
            let result = CommandResult(commandID: UUID(), status: .unknown, message: value.message ?? "İşin sonucu bilinmiyor.", startedAt: now, finishedAt: now, data: .terminalJob(value), error: RovaError(code: "TERMINAL_JOB_UNKNOWN", message: value.message ?? "İşin sonucu bilinmiyor.", category: "unknown"))
            sendInteractiveCommandResult(commandId: commandId, result: result, on: task)
            return
        }
        guard let grant, let token = pairedDeviceToken(), grant.id == job.grantId,
              RovaTerminalPolicy.verifyGrant(grantId: grant.id, rootDirectory: grant.rootDirectory, mode: grant.mode, expiresAt: grant.expiresAt, signature: grant.signature, token: token),
              let root = RovaTerminalPolicy.resolveDirectory(grant.rootDirectory),
              RovaTerminalPolicy.isWithin(job.workingDirectory, root: root) else {
            sendTerminalDenial(commandId, code: "TERMINAL_GRANT_INVALID", message: "İşin imzalı terminal izni doğrulanamadı.", on: task)
            return
        }
        if action == "cancel_job", job.state == "running" {
            job.cancelRequested = true
            if let processIdentifier = job.processIdentifier { MacSystem.terminateTerminalProcess(processIdentifier) }
            job.message = "İptal istendi; PC işlemi durduruluyor."
        }
        sendTerminalJobSnapshot(jobId, commandId: commandId, on: task)
    }

    private func startTerminalJob(id: String, grantId: String, command: String, directory: String, timeoutSeconds: Int) {
        guard terminalJobs[id] == nil else { return }
        let job = TerminalJobRecord(id: id, grantId: grantId, workingDirectory: directory)
        terminalJobs[id] = job
        // A weak reference that is itself a `let` can be captured by the process-start callback,
        // which runs on another thread; capturing the detached task's own `self` var cannot.
        weak let owner = self
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = MacSystem.executeTerminalCommand(command, workingDirectory: directory, timeoutSeconds: timeoutSeconds, processStarted: { processIdentifier in
                Task { @MainActor in
                    guard let owner, let current = owner.terminalJobs[id] else { return }
                    current.processIdentifier = processIdentifier
                    if current.cancelRequested { MacSystem.terminateTerminalProcess(processIdentifier) }
                }
            })
            await MainActor.run { [weak self] in
                guard let self, let current = self.terminalJobs[id] else { return }
                if case let .processOutput(output)? = outcome.data { current.output = output }
                if current.cancelRequested {
                    current.state = "cancelled"
                    current.message = "Terminal işi kullanıcı tarafından durduruldu."
                    current.errorCode = nil
                } else if outcome.error?.category == "timeout" {
                    current.state = "unknown"
                    current.message = "Terminal işi zaman aşımına uğradı; sonucu doğrulanamadı."
                    current.errorCode = outcome.error?.code
                } else if let error = outcome.error {
                    current.state = "failed"
                    current.message = error.message
                    current.errorCode = error.code
                } else {
                    current.state = "completed"
                    current.message = "Terminal işi tamamlandı."
                }
                current.processIdentifier = nil
                self.sendTerminalJobStateUpdate(current)
            }
        }
    }

    private func sendTerminalJobStateUpdate(_ job: TerminalJobRecord) {
        guard let task, task.state == .running else { return }
        let value: [String: Any] = [
            "type": "terminalJobUpdate",
            "jobId": job.id,
            "state": job.state,
            "errorCode": job.errorCode.map { $0 as Any } ?? NSNull()
        ]
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func sendTerminalJobSnapshot(_ id: String, commandId: String, on task: URLSessionWebSocketTask) {
        let now = Date()
        guard let job = terminalJobs[id] else { return }
        let value = TerminalJobContent(jobId: job.id, status: job.state, output: job.output, message: job.message, errorCode: job.errorCode)
        let commandStatus: CommandStatus = job.state == "unknown" ? .unknown : job.state == "failed" ? .failed : .completed
        let result = CommandResult(commandID: UUID(uuidString: id) ?? UUID(), status: commandStatus, message: job.message, startedAt: job.startedAt, finishedAt: now, data: .terminalJob(value), error: job.errorCode.map { RovaError(code: $0, message: job.message, category: job.state == "unknown" ? "unknown" : "tool_failure") })
        sendInteractiveCommandResult(commandId: commandId, result: result, on: task)
    }

    private func pruneTerminalJobs() {
        let completed = terminalJobs.values.filter { $0.state != "running" }.sorted { $0.startedAt < $1.startedAt }
        for job in completed where Date().timeIntervalSince(job.startedAt) > 24 * 60 * 60 { terminalJobs.removeValue(forKey: job.id) }
        let remaining = terminalJobs.values.filter { $0.state != "running" }.sorted { $0.startedAt < $1.startedAt }
        for job in remaining.prefix(max(0, remaining.count - 50)) { terminalJobs.removeValue(forKey: job.id) }
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
            if let refreshToken = self.currentRefreshToken,
               let credentials = await self.refreshCredentials(refreshToken: refreshToken) {
                self.currentToken = credentials.accessToken
                self.currentRefreshToken = credentials.refreshToken
                try? await self.tokenStore.save(accessToken: credentials.accessToken, refreshToken: credentials.refreshToken, accountToken: nil)
                self.open(token: credentials.accessToken)
            } else {
                self.open(token: currentToken)
            }
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
    case terminalCommand(TerminalCommandPayload)
}

private struct TerminalGrantPayload: Decodable, Sendable {
    let id: String
    let rootDirectory: String
    let mode: String
    let expiresAt: Int
    let signature: String
}

private struct TerminalCommandRequest: Decodable, Sendable {
    let action: String?
    let grant: TerminalGrantPayload?
    let command: String?
    let workingDirectory: String?
    let timeoutSeconds: Int?
    let jobId: String?
    let filePath: String?
    let patch: String?
}

private struct TerminalCommandPayload: Decodable, Sendable {
    let type: String
    let commandId: String
    let request: TerminalCommandRequest
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
