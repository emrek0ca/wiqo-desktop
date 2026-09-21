import CryptoKit
import Foundation

/// A single step of an AI-generated plan, already translated into the exact same
/// `CommandType`/`CommandPayload` pair the manual UI buttons send. The backend is the only
/// place that talks to Groq and holds the shared API key; the app never sees it.
struct PlannedCommand: Identifiable {
    let id: UUID
    let type: CommandType
    let payload: CommandPayload
    let summary: String
    let isDestructive: Bool
    let requiresUserPresence: Bool

    init(id: UUID = UUID(), type: CommandType, payload: CommandPayload, summary: String, isDestructive: Bool, requiresUserPresence: Bool) {
        self.id = id
        self.type = type
        self.payload = payload
        self.summary = summary
        self.isDestructive = isDestructive
        self.requiresUserPresence = requiresUserPresence
    }
}

/// Where the app's copilot/auth requests go. Fixed - there is exactly one Rova backend, and it
/// is not meant to be user-configurable in the shipped app.
enum RovaBackendConfig {
    static let baseURL = URL(string: "https://api.wiqoai.com")!
}

enum RovaBackendError: Error, LocalizedError {
    case notAuthenticated
    case network(String)
    case invalidResponse
    case declined(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Önce Wiqo hesabına giriş yap."
        case .network(let message): return message
        case .invalidResponse: return "Sunucudan geçersiz bir yanıt alındı. Lütfen tekrar dene."
        case .declined(let reason): return reason
        }
    }
}

/// Talks to Rova's own backend (see the `rova-backend` project) instead of any third-party AI
/// API directly. The backend owns the shared Groq key server-side and gates access behind a
/// login; this app only ever carries its own session token, stored in Keychain like the Mac
/// pairing token already is. This is the single integration point for both account handling and
/// the AI copilot feature.
enum RovaBackendClient {
    private static let tokenAccount = "rova-backend-token"
    static let apnsBundleID = "com.wiqo.ios"

    #if DEBUG
    static let apnsEnvironment = "development"
    #else
    static let apnsEnvironment = "production"
    #endif

    static var isAuthenticated: Bool { token != nil }

    static var token: String? {
        guard let data = try? RovaKeychainStore.load(account: tokenAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func mobileReadCacheKey(_ path: String) -> String {
        "\(currentUserID ?? currentUserEmail ?? "anonymous"):\(path)"
    }

    /// Stable per-account key for namespacing anything cached locally (conversation history,
    /// etc.) so one signed-in account can never read another account's data on a shared device.
    /// Read from the session JWT's own payload - not re-verified here, only used as a local
    /// storage key, exactly like the token itself is already trusted for that JWT's lifetime.
    static var currentUserID: String? {
        guard let id = tokenPayload?["userId"] else { return nil }
        if let value = id as? Int { return String(value) }
        return id as? String
    }

    static var currentUserEmail: String? { tokenPayload?["email"] as? String }

    private static var tokenPayload: [String: Any]? {
        guard let token else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func signOut() {
        try? RovaKeychainStore.delete(account: tokenAccount)
        WiqoMobileReadCache.shared.removeAll()
    }

    static func registerAPNsToken(_ token: String) async throws {
        struct Response: Decodable { let ok: Bool }
        _ = try await authorizedPost(
            "notifications/apns-token",
            body: [
                "token": token,
                "environment": apnsEnvironment,
                "bundleId": apnsBundleID
            ],
            as: Response.self
        )
    }

    static func revokeAPNsToken(_ token: String? = nil) async throws {
        struct Response: Decodable { let ok: Bool }
        var body: [String: Any] = [:]
        if let token { body["token"] = token }
        _ = try await authorizedPost("notifications/apns-token/revoke", body: body, as: Response.self)
    }

    @discardableResult
    static func register(email: String, password: String, inviteCode: String? = nil) async throws -> String {
        try await authenticate(path: "auth/register", email: email, password: password, inviteCode: inviteCode)
    }

    @discardableResult
    static func login(email: String, password: String) async throws -> String {
        try await authenticate(path: "auth/login", email: email, password: password)
    }

    /// The backend returns a natural-language error for unknown accounts and delivery failures;
    /// keeping the response decoding here means every auth surface presents the same message.
    static func forgotPassword(email: String) async throws {
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent("auth/forgot-password"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines)])
        let (data, response) = try await send(request)
        struct Response: Decodable { let ok: Bool; let message: String? }
        let decoded = try decode(Response.self, from: data, response: response)
        guard decoded.ok else {
            throw RovaBackendError.declined(nonEmptyMessage(decoded.message, fallback: "Şifre sıfırlama isteği tamamlanamadı."))
        }
    }

    @discardableResult
    static func resetPassword(email: String, code: String, newPassword: String) async throws -> String {
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent("auth/reset-password"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "code": code, "newPassword": newPassword])
        let (data, response) = try await send(request)
        struct AuthResponse: Decodable { let token: String }
        let decoded = try decode(AuthResponse.self, from: data, response: response)
        try RovaKeychainStore.save(Data(decoded.token.utf8), account: tokenAccount)
        return decoded.token
    }

    private static func authenticate(path: String, email: String, password: String, inviteCode: String? = nil) async throws -> String {
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["email": email, "password": password]
        if let inviteCode, !inviteCode.trimmingCharacters(in: .whitespaces).isEmpty { body["inviteCode"] = inviteCode }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request)
        struct AuthResponse: Decodable { let token: String }
        let decoded = try decode(AuthResponse.self, from: data, response: response)
        try RovaKeychainStore.save(Data(decoded.token.utf8), account: tokenAccount)
        return decoded.token
    }

    /// One turn of conversation, in the wire shape `/copilot/chat` expects and returns.
    struct ChatTurn: Codable {
        let role: String
        let content: String
    }

    struct ChatAttachment: Encodable {
        let name: String
        let mimeType: String
        let dataBase64: String
    }

    struct ArtifactDescriptor: Codable, Identifiable, Equatable, Hashable {
        let id: String
        let kind: String
        let filename: String
        let mimeType: String
        let byteCount: Int
        let sha256: String
        let downloadURL: URL
        let expiresAt: String
    }

    struct BackendConfirmation: Codable, Identifiable, Equatable, Hashable {
        let id: UUID
        let kind: String
        let title: String
        let summary: String
        let details: [String: String]
        let isDestructive: Bool
        let requiresUserPresence: Bool
        let expiresAt: String
    }

    struct BackendConfirmationResult: Decodable {
        let ok: Bool
        let text: String
        let artifacts: [ArtifactDescriptor]
    }

    struct BackendConfirmationResponse: Decodable {
        let confirmationId: UUID
        let status: String
        let result: BackendConfirmationResult?
    }

    /// Live execution truth emitted by the backend while a chat turn is still running. The
    /// backend deliberately omits its internal tool name; the client only needs the stable id,
    /// user-facing summary, and lifecycle state to keep the compact execution widget current.
    struct ExecutionStepUpdate: Decodable, Equatable {
        let id: UUID
        let kind: String
        let summary: String
        let requiresConfirmation: Bool
        let requiresUserPresence: Bool
        let status: String
        let confirmationId: UUID?
        let message: String?
        let sequence: Int?
    }

    struct ConverseResult {
        let reply: String
        let steps: [PlannedCommand]
        let executionState: String?
        let artifacts: [ArtifactDescriptor]
        let backendConfirmations: [BackendConfirmation]
    }

    /// Result of running code on the canvas (`/canvas/run`) - the same sandbox run_python uses,
    /// but invoked directly from the composer's canvas sheet rather than through a model turn.
    struct CanvasRunResult: Decodable {
        let exitCode: Int
        let timedOut: Bool
        let truncated: Bool
        let durationMs: Int
        let stdout: String
        let stderr: String
        let artifacts: [ArtifactDescriptor]
    }

    struct QueueTask: Decodable {
        let id: Int
        let kind: String
        let status: String
        let progress: String?
        let result: CanvasRunResult?
        let error: String?
        let retryCount: Int
        let createdAt: String
        let startedAt: String?
        let finishedAt: String?
        let lastHeartbeatAt: String?
        let deadlineAt: String?
    }

    private struct CopilotStepResponse: Decodable {
        let id: UUID?
        let type: CommandType
        let payload: CommandPayload
        let summary: String
        let isDestructive: Bool
        let requiresUserPresence: Bool?
    }

    private struct CopilotServerResponse: Decodable {
        let reply: String
        let steps: [CopilotStepResponse]
        let executionState: String?
        let artifacts: [ArtifactDescriptor]?
        let backendConfirmations: [BackendConfirmation]?
    }

    private struct CopilotErrorResponse: Decodable {
        let code: String?
        let category: String?
        let message: String?
    }

    private struct CopilotStatusResponse: Decodable {
        let requestId: String
        let status: String
        let response: CopilotServerResponse?
        let error: CopilotErrorResponse?
    }

    struct MemoryCandidate: Decodable, Identifiable {
        let id: Int
        let kind: String
        let content: String
        let sourceText: String
        let status: String
        let similarity: Double?
        let createdAt: String
    }

    /// A learned "always allow" - Wiqo stopped asking to confirm this exact action because the
    /// user already approved it once. Only ever created for non-destructive action types; see
    /// the backend's groq/trust.ts for the full list. Revoking one makes Wiqo ask again.
    struct TrustGrant: Decodable, Identifiable {
        let id: Int
        let label: String
        let grantedAt: String
    }

    struct DeviceStatus: Decodable, Identifiable {
        let id: String
        let displayName: String
        let platform: String
        let capabilities: [String]
        let online: Bool
        let lastSeenAt: String?
    }

    struct ProactiveSuggestion: Decodable, Identifiable {
        let id: Int
        let kind: String
        let title: String
        let body: String
        let prompt: String
        let createdAt: String
        let expiresAt: String?
    }

    /// Sends the whole conversation so far (the backend is stateless; the app owns history) and
    /// gets back the model's natural-language reply plus any Mac-bound steps it decided to take.
    ///
    /// The backend streams this as Server-Sent Events - zero or more live status lines ("Wikipedia'da
    /// araştırıyorum…") delivered via `onStatus` as the model works, followed by exactly one
    /// terminal event. This is what replaces a dead spinner with something that actually shows
    /// progress on a long multi-tool request, and it's also why a slow chain (e.g. "research this
    /// and save it") no longer looks hung - the connection stays alive and visibly working instead
    /// of going silent until either an answer or a timeout arrives.
    static func converse(
        messages: [ChatTurn],
        availableApps: [ApplicationID],
        applicationTargets: [DeviceApplicationTarget] = [],
        availableCapabilities: [String] = [],
        authorities: [DeviceCapabilityAuthority] = [],
        deviceID: UUID? = nil,
        conversationID: String = "default",
        turnCount: Int? = nil,
        deviceResults: [DeviceExecutionResult] = [],
        requestID: UUID = UUID(),
        attachments: [ChatAttachment] = [],
        // Awaited on the main actor in stream order - separate `Task { @MainActor }` hops per event
        // are not guaranteed to run in order, which would scramble streamed text.
        onStatus: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onDelta: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onReset: @escaping @MainActor @Sendable () -> Void = {},
        onConfirmationNeeded: @escaping @MainActor @Sendable ([PlannedCommand], [BackendConfirmation]) -> Void = { _, _ in },
        onStepUpdate: @escaping @MainActor @Sendable (ExecutionStepUpdate) -> Void = { _ in },
        /// Today's message count as the server has just counted it (used, limit).
        onUsage: @escaping @MainActor @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> ConverseResult {
        guard let token else { throw RovaBackendError.notAuthenticated }
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent("copilot/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The backend keeps the result in its request ledger; this timeout only bounds the live
        // stream. A dropped stream is resumed through copilot/requests below.
        request.timeoutInterval = 90
        let body: [String: Any] = [
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "availableApps": availableApps.map(\.rawValue),
            "applicationTargets": applicationTargets.map { target in
                [
                    "name": target.name,
                    "bundleIdentifier": target.bundleIdentifier ?? NSNull(),
                    "isRunning": target.isRunning,
                    "supportedActions": target.supportedActions.map(\.rawValue)
                ] as [String: Any]
            },
            "availableCapabilities": availableCapabilities,
            "authorities": authorities.map { authority in
                [
                    "capability": authority.capability,
                    "displayName": authority.displayName,
                    "access": authority.access.rawValue,
                    "requiredPermissions": authority.requiredPermissions,
                    "message": authority.message ?? ""
                ] as [String: Any]
            },
            "conversationId": conversationID,
            "requestId": requestID.uuidString,
            "attachments": attachments.map { [
                "name": $0.name,
                "mimeType": $0.mimeType,
                "dataBase64": $0.dataBase64
            ] },
            "deviceResults": deviceResults.map { result -> [String: Any] in
                var value: [String: Any] = [
                    "stepId": result.stepID.uuidString,
                    "type": result.type.rawValue,
                    "status": result.status.rawValue,
                    "message": result.message
                ]
                if let summary = result.summary { value["summary"] = summary }
                if let error = result.error { value["error"] = error.message }
                if let dataText = result.dataText { value["dataText"] = dataText }
                if let imageBase64 = result.imageBase64 { value["imageBase64"] = imageBase64 }
                return value
            }
        ]
        var requestBody = body
        if let deviceID { requestBody["deviceId"] = deviceID.uuidString }
        if let turnCount { requestBody["turnCount"] = turnCount }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [.fragmentsAllowed])

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            return try await waitForCopilotRequest(requestID: requestID, onStatus: onStatus)
        }
        guard let http = response as? HTTPURLResponse else { throw RovaBackendError.invalidResponse }
        if http.statusCode == 401 {
            signOut()
            throw RovaBackendError.notAuthenticated
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await chunk in bytes { body.append(chunk) }
            let serverMessage = serverErrorMessage(from: body)
            throw RovaBackendError.network(serverMessage ?? userFacingHTTPMessage(for: http.statusCode))
        }

        struct StatusEvent: Decodable { let text: String }
        struct DeltaEvent: Decodable { let text: String }
        struct DoneEvent: Decodable {
            let reply: String
            let steps: [CopilotStepResponse]
            let executionState: String?
            let artifacts: [ArtifactDescriptor]?
            let backendConfirmations: [BackendConfirmation]?
        }
        struct ConfirmationNeededEvent: Decodable {
            let steps: [CopilotStepResponse]
            let backendConfirmations: [BackendConfirmation]?
        }
        struct StepUpdateEvent: Decodable {
            let step: ExecutionStepUpdate
        }
        struct ErrorEvent: Decodable { let message: String; let code: String? }
        struct EventKind: Decodable { let type: String }
        struct UsageEvent: Decodable {
            struct Counter: Decodable { let used: Int; let limit: Int }
            let messages: Counter
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let json = Data(line.dropFirst(6).utf8)
                guard let kind = try? decoder.decode(EventKind.self, from: json) else { continue }
                switch kind.type {
                case "status":
                    if let event = try? decoder.decode(StatusEvent.self, from: json) {
                        await onStatus(event.text)
                    }
                case "delta":
                    if let event = try? decoder.decode(DeltaEvent.self, from: json) {
                        await onDelta(event.text)
                    }
                case "confirmation_needed":
                    // This is the plan/confirmation state so far, not necessarily the final
                    // event. Device steps still use the existing final-plan sheet; backend rows
                    // are safe to act on immediately because the server durably claims each one
                    // atomically when the user taps its own button.
                    if let event = try? decoder.decode(ConfirmationNeededEvent.self, from: json) {
                        let partial = makeConverseResult(
                            reply: "",
                            steps: event.steps,
                            executionState: nil,
                            artifacts: [],
                            backendConfirmations: event.backendConfirmations ?? []
                        )
                        await onConfirmationNeeded(partial.steps, partial.backendConfirmations)
                    }
                case "step_update":
                    if let event = try? decoder.decode(StepUpdateEvent.self, from: json) {
                        await onStepUpdate(event.step)
                    }
                case "usage":
                    if let event = try? decoder.decode(UsageEvent.self, from: json) {
                        await onUsage(event.messages.used, event.messages.limit)
                    }
                case "reset":
                    await onReset()
                case "done":
                    let event = try decoder.decode(DoneEvent.self, from: json)
                    return makeConverseResult(
                        reply: event.reply,
                        steps: event.steps,
                        executionState: event.executionState,
                        artifacts: event.artifacts ?? [],
                        backendConfirmations: event.backendConfirmations ?? []
                    )
                case "error":
                    let event = try? decoder.decode(ErrorEvent.self, from: json)
                    let message = nonEmptyMessage(event?.message, fallback: "İstek anlaşılamadı.")
                    throw RovaBackendError.declined(appendingErrorCode(message, code: event?.code))
                default:
                    continue
                }
            }
        } catch let error as RovaBackendError {
            throw error
        } catch {
            return try await waitForCopilotRequest(requestID: requestID, onStatus: onStatus)
        }
        return try await waitForCopilotRequest(requestID: requestID, onStatus: onStatus)
    }

    static func resolveBackendConfirmation(id: UUID, approved: Bool) async throws -> BackendConfirmationResponse {
        try await authorizedPost(
            "copilot/confirm",
            body: [
                "confirmationId": id.uuidString,
                "approved": approved
            ],
            as: BackendConfirmationResponse.self
        )
    }

    private static func makeConverseResult(
        reply: String,
        steps: [CopilotStepResponse],
        executionState: String?,
        artifacts: [ArtifactDescriptor],
        backendConfirmations: [BackendConfirmation]
    ) -> ConverseResult {
        let planned = steps.map { step in
            let localDestructive = RovaCommandAuthority.isDestructive(type: step.type, payload: step.payload)
            let localPresence = RovaCommandAuthority.requiresUserPresence(type: step.type, payload: step.payload)
            return PlannedCommand(
                id: step.id ?? UUID(),
                type: step.type,
                payload: step.payload,
                summary: step.summary,
                isDestructive: step.isDestructive || localDestructive,
                requiresUserPresence: step.requiresUserPresence == true || step.isDestructive || localDestructive || localPresence
            )
        }
        return ConverseResult(
            reply: reply,
            steps: planned,
            executionState: executionState,
            artifacts: artifacts,
            backendConfirmations: backendConfirmations
        )
    }

    private static func waitForCopilotRequest(
        requestID: UUID,
        onStatus: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ConverseResult {
        await onStatus("Bağlantı koptu; Wiqo işlemin sonucunu koruyor…")
        let deadline = Date().addingTimeInterval(150)
        var missingCount = 0
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            do {
                let state = try await authorizedGet("copilot/requests/\(requestID.uuidString)", as: CopilotStatusResponse.self)
                switch state.status {
                case "done":
                    guard let response = state.response else { throw RovaBackendError.invalidResponse }
                    return makeConverseResult(
                        reply: response.reply,
                        steps: response.steps,
                        executionState: response.executionState,
                        artifacts: response.artifacts ?? [],
                        backendConfirmations: response.backendConfirmations ?? []
                    )
                case "failed":
                    throw RovaBackendError.declined(nonEmptyMessage(state.error?.message, fallback: "İşlem tamamlanamadı."))
                default:
                    await onStatus("İşlem bağlantıdan bağımsız devam ediyor…")
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch RovaBackendError.network(let message) where message == "İşlem bulunamadı." {
                missingCount += 1
                if missingCount >= 3 { throw RovaBackendError.network(message) }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw RovaBackendError.network("İşlem sunucuda devam ediyor olabilir. Sohbete dönüp tekrar kontrol edebilirsin.")
    }

    struct DeviceExecutionResult: Codable {
        let stepID: UUID
        let type: CommandType
        let summary: String?
        let status: CommandStatus
        let message: String
        let error: RovaError?
        let dataText: String?
        let imageBase64: String?

        init(stepID: UUID, type: CommandType, summary: String? = nil, status: CommandStatus, message: String, error: RovaError?, dataText: String? = nil, imageBase64: String? = nil) {
            self.stepID = stepID
            self.type = type
            self.summary = summary
            self.status = status
            self.message = message
            self.error = error
            self.dataText = dataText
            self.imageBase64 = imageBase64
        }
    }

    struct AudioConverseResult {
        let transcript: String
        let reply: String
        let steps: [PlannedCommand]
        let executionState: String?
        let artifacts: [ArtifactDescriptor]
        let audioData: Data?
        let audioError: String?
    }

    static func converseAudio(
        audioData: Data,
        mimeType: String,
        messages: [ChatTurn],
        availableApps: [ApplicationID],
        applicationTargets: [DeviceApplicationTarget] = [],
        availableCapabilities: [String] = [],
        authorities: [DeviceCapabilityAuthority] = [],
        deviceID: UUID? = nil,
        conversationID: String = "default",
        turnCount: Int? = nil,
        requestID: UUID = UUID(),
        respondWithAudio: Bool = true
    ) async throws -> AudioConverseResult {
        guard !audioData.isEmpty, audioData.count <= 12_000_000 else { throw RovaBackendError.declined("Ses dosyası desteklenen boyut sınırını aşıyor.") }
        var body: [String: Any] = [
            "audioBase64": audioData.base64EncodedString(),
            "mimeType": mimeType,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "availableApps": availableApps.map(\.rawValue),
            "applicationTargets": applicationTargets.map { target in
                [
                    "name": target.name,
                    "bundleIdentifier": target.bundleIdentifier ?? NSNull(),
                    "isRunning": target.isRunning,
                    "supportedActions": target.supportedActions.map(\.rawValue)
                ] as [String: Any]
            },
            "availableCapabilities": availableCapabilities,
            "authorities": authorities.map { authority in
                [
                    "capability": authority.capability,
                    "displayName": authority.displayName,
                    "access": authority.access.rawValue,
                    "requiredPermissions": authority.requiredPermissions,
                    "message": authority.message ?? ""
                ] as [String: Any]
            },
            "conversationId": conversationID,
            "requestId": requestID.uuidString,
            "respondWithAudio": respondWithAudio
        ]
        if let deviceID { body["deviceId"] = deviceID.uuidString }
        if let turnCount { body["turnCount"] = turnCount }
        struct StepResponse: Decodable {
            let id: UUID?
            let type: CommandType
            let payload: CommandPayload
            let summary: String
            let isDestructive: Bool
            let requiresUserPresence: Bool?
        }
        struct Response: Decodable {
            let transcript: String
            let reply: String
            let steps: [StepResponse]
            let executionState: String?
            let artifacts: [ArtifactDescriptor]
            let audioBase64: String?
            let audioError: String?
        }
        let response = try await authorizedPost("copilot/audio", body: body, as: Response.self)
        let steps = response.steps.map { step in
            let localDestructive = RovaCommandAuthority.isDestructive(type: step.type, payload: step.payload)
            let localPresence = RovaCommandAuthority.requiresUserPresence(type: step.type, payload: step.payload)
            return PlannedCommand(
                id: step.id ?? UUID(),
                type: step.type,
                payload: step.payload,
                summary: step.summary,
                isDestructive: step.isDestructive || localDestructive,
                requiresUserPresence: step.requiresUserPresence == true || step.isDestructive || localDestructive || localPresence
            )
        }
        let generatedAudio = response.audioBase64.flatMap { Data(base64Encoded: $0) }
        return AudioConverseResult(transcript: response.transcript, reply: response.reply, steps: steps, executionState: response.executionState, artifacts: response.artifacts, audioData: generatedAudio, audioError: response.audioError)
    }

    static func fetchMemoryCandidates() async throws -> [MemoryCandidate] {
        let key = mobileReadCacheKey("memory/candidates")
        if let data = WiqoMobileReadCache.shared.data(for: key, maxAge: 20),
           let cached = try? JSONDecoder().decode([MemoryCandidate].self, from: data) {
            return cached
        }
        struct Response: Decodable { let candidates: [MemoryCandidate] }
        let candidates = try await authorizedGet("memory/candidates", as: Response.self).candidates
        if let data = try? JSONEncoder().encode(candidates) {
            WiqoMobileReadCache.shared.store(data, for: key)
        }
        return candidates
    }

    static func acceptMemoryCandidate(id: Int) async throws {
        _ = try await authorizedMutate("memory/candidates/\(id)/accept", method: "POST")
        WiqoMobileReadCache.shared.invalidate(mobileReadCacheKey("memory/candidates"))
    }

    static func dismissMemoryCandidate(id: Int) async throws {
        _ = try await authorizedMutate("memory/candidates/\(id)/dismiss", method: "POST")
        WiqoMobileReadCache.shared.invalidate(mobileReadCacheKey("memory/candidates"))
    }

    static func fetchTrustGrants() async throws -> [TrustGrant] {
        let key = mobileReadCacheKey("trust-grants")
        if let data = WiqoMobileReadCache.shared.data(for: key, maxAge: 20),
           let cached = try? JSONDecoder().decode([TrustGrant].self, from: data) {
            return cached
        }
        struct Response: Decodable { let grants: [TrustGrant] }
        let grants = try await authorizedGet("trust-grants", as: Response.self).grants
        if let data = try? JSONEncoder().encode(grants) {
            WiqoMobileReadCache.shared.store(data, for: key)
        }
        return grants
    }

    static func revokeTrustGrant(id: Int) async throws {
        _ = try await authorizedMutate("trust-grants/\(id)", method: "DELETE")
        WiqoMobileReadCache.shared.invalidate(mobileReadCacheKey("trust-grants"))
    }

    /// Explicit "always allow" from the confirmation sheet - only ever called right after the
    /// same biometric prompt a one-time confirm already requires. The backend accepts this only
    /// for a small allowlisted set of step types (see USER_GRANTABLE_TRUST_TYPES server-side);
    /// anything else is rejected there rather than silently ignored.
    @discardableResult
    static func grantTrust(type: String, summary: String) async throws -> TrustGrant {
        let result = try await authorizedPost("trust-grants", body: ["type": type, "summary": summary], as: TrustGrant.self)
        WiqoMobileReadCache.shared.invalidate(mobileReadCacheKey("trust-grants"))
        return result
    }

    // MARK: - Profile & account

    static func fetchProfile() async throws -> UserProfile {
        try await authorizedGet("profile", as: UserProfile.self)
    }

    /// `body` is a JSON object of only the fields that changed; `null` clears a field.
    static func updateProfile(body: Data) async throws -> UserProfile {
        let data = try await authorizedJSON("profile", method: "PUT", body: body)
        do { return try JSONDecoder().decode(UserProfile.self, from: data) } catch { throw RovaBackendError.invalidResponse }
    }

    /// Permanently deletes the account and all of its server-side data. The caller signs out
    /// afterwards, once it has cleared the account's local caches.
    static func deleteAccount(password: String) async throws {
        _ = try await authorizedJSON("profile", method: "DELETE", body: try JSONSerialization.data(withJSONObject: ["password": password]))
    }

    // MARK: - Conversation history (server-side backup of chat history)

    struct RemoteConversationSummary: Decodable {
        let id: String
        let title: String
        let preview: String
        let updatedAt: String
        let turnCount: Int
    }

    struct RemoteConversationMessage: Decodable {
        let role: String
        let content: String
        let createdAt: String
        let artifacts: [ArtifactDescriptor]
    }

    static func fetchConversations() async throws -> [RemoteConversationSummary] {
        struct Response: Decodable { let conversations: [RemoteConversationSummary] }
        return try await authorizedGet("conversations", as: Response.self).conversations
    }

    static func fetchConversationMessages(id: String) async throws -> [RemoteConversationMessage] {
        struct Response: Decodable { let messages: [RemoteConversationMessage] }
        return try await authorizedGet("conversations/\(id)/messages", as: Response.self).messages
    }

    static func deleteConversationRemote(id: String) async throws {
        _ = try await authorizedMutate("conversations/\(id)", method: "DELETE")
    }

    // MARK: - Canvas

    static func runCanvasCode(
        language: String,
        code: String,
        timeoutSeconds: Int = 15,
        packages: [String] = [],
        onTaskID: @escaping @MainActor @Sendable (Int) -> Void = { _ in },
        onProgress: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> CanvasRunResult {
        struct Submission: Decodable { let taskId: Int; let status: String; let message: String }
        var body: [String: Any] = ["language": language, "code": code, "timeoutSeconds": timeoutSeconds]
        if !packages.isEmpty { body["packages"] = packages }
        let submission = try await authorizedPost(
            "canvas/run",
            body: body,
            as: Submission.self
        )
        await onTaskID(submission.taskId)
        let deadline = Date().addingTimeInterval(packages.isEmpty ? 120 : 180)
        while Date() < deadline {
            if Task.isCancelled {
                try? await cancelCanvasRun(taskID: submission.taskId)
                throw CancellationError()
            }
            let task = try await fetchQueueTask(id: submission.taskId)
            switch task.status {
            case "done":
                guard let result = task.result else { throw RovaBackendError.invalidResponse }
                return result
            case "failed", "unknown":
                throw RovaBackendError.declined(nonEmptyMessage(task.error, fallback: "Kod çalıştırma tamamlanamadı."))
            case "cancelled":
                throw RovaBackendError.declined("Kod çalıştırma iptal edildi.")
            default:
                if let progress = task.progress, !progress.isEmpty { await onProgress(progress) }
                try await Task.sleep(nanoseconds: 350_000_000)
            }
        }
        throw RovaBackendError.network("Kod çalıştırma beklenenden uzun sürdü. İstersen tekrar deneyebilirsin.")
    }

    private static func fetchQueueTask(id: Int) async throws -> QueueTask {
        try await authorizedGet("queue/\(id)", as: QueueTask.self)
    }

    static func cancelCanvasRun(taskID: Int) async throws {
        _ = try await authorizedMutate("queue/\(taskID)/cancel", method: "POST")
    }

    // MARK: - Billing

    static func fetchSubscription() async throws -> SubscriptionInfo {
        try await authorizedGet("billing/subscription", as: SubscriptionInfo.self)
    }

    /// Forwards a StoreKit transaction's raw JWS to the backend right after a purchase - the
    /// backend independently re-verifies it against Apple's root certificate before granting
    /// anything (see rova-backend/src/billing/subscriptions.ts). The response carries the account's
    /// new plan and usage, so the app can show it at once.
    static func verifyStoreKitTransaction(_ signedTransaction: String) async throws -> SubscriptionInfo? {
        struct Response: Decodable { let ok: Bool; let subscription: SubscriptionInfo? }
        return try await authorizedPost("billing/storekit/verify", body: ["signedTransaction": signedTransaction], as: Response.self).subscription
    }

    static func fetchDevices() async throws -> [DeviceStatus] {
        struct Response: Decodable { let devices: [DeviceStatus] }
        // Presence changes independently of account/device metadata; a cached `online` value
        // must never be presented as current after a disconnect or wake.
        return try await authorizedGet("devices", as: Response.self).devices
    }

    struct DeviceEvent: Decodable {
        let type: String
        let device: DeviceStatus
    }

    static func observeDeviceEvents(_ onEvent: @escaping @MainActor @Sendable (DeviceEvent) -> Void) async throws {
        guard let token else { throw RovaBackendError.notAuthenticated }
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent("devices/events"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw RovaBackendError.invalidResponse }
        if http.statusCode == 401 { throw RovaBackendError.notAuthenticated }
        guard http.statusCode == 200 else { throw RovaBackendError.network("Cihaz bağlantısı izlenemiyor.") }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: "),
                  let data = String(line.dropFirst(6)).data(using: .utf8),
                  let event = try? JSONDecoder().decode(DeviceEvent.self, from: data) else { continue }
            await onEvent(event)
        }
    }

    struct AccountInfo: Decodable {
        let email: String
        let isFoundingMember: Bool
    }

    static func fetchAccountInfo() async throws -> AccountInfo {
        try await authorizedGet("auth/me", as: AccountInfo.self)
    }

    /// A code someone can hand a friend - redeeming one credits both sides a Pro bonus (see
    /// rova-backend's grantReferralBonus). Every account always has a few unused ones; the
    /// backend self-provisions a fresh batch the first time this is read.
    struct InviteCode: Decodable, Identifiable {
        var id: String { code }
        let code: String
        let used: Bool
        let createdAt: String
    }

    static func fetchInviteCodes() async throws -> [InviteCode] {
        struct Response: Decodable { let codes: [InviteCode] }
        return try await authorizedGet("auth/invite-codes", as: Response.self).codes
    }

    /// A real Google/Notion account connection (see rova-backend's routes/oauth.ts) - never the
    /// tokens themselves, just enough to show "bağlı: ___" and let the user disconnect it.
    struct OAuthConnection: Decodable, Identifiable {
        var id: String { provider }
        let provider: String
        let accountLabel: String?
        let connectedAt: String
    }

    static func fetchOAuthConnections() async throws -> [OAuthConnection] {
        struct Response: Decodable { let connections: [OAuthConnection] }
        return try await authorizedGet("oauth", as: Response.self).connections
    }

    /// Returns the provider's own consent URL to open in an ASWebAuthenticationSession - this
    /// request itself carries the real Authorization header (a webview navigation couldn't), and
    /// the state that ties the resulting callback back to this account is embedded server-side.
    static func startOAuth(provider: String) async throws -> URL {
        struct Response: Decodable { let url: String }
        let response = try await authorizedGet("oauth/\(provider)/start", as: Response.self)
        guard let url = URL(string: response.url) else { throw RovaBackendError.invalidResponse }
        return url
    }

    static func disconnectOAuth(provider: String) async throws {
        _ = try await authorizedMutate("oauth/\(provider)", method: "DELETE")
    }

    /// Sets (or, with `nil`/empty, clears) a user-chosen name for one paired PC - lets more than
    /// one paired PC be told apart ("Ofis PC", "Ev PC") instead of both showing the same
    /// hostname-derived name.
    @discardableResult
    static func renameDevice(id: String, name: String?) async throws -> DeviceStatus {
        struct Response: Decodable { let device: DeviceStatus }
        let value: Any = name ?? NSNull()
        let body = try JSONSerialization.data(withJSONObject: ["displayName": value])
        let data = try await authorizedJSON("devices/\(id)", method: "PATCH", body: body)
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw RovaBackendError.invalidResponse }
        WiqoMobileReadCache.shared.invalidate(mobileReadCacheKey("devices"))
        return decoded.device
    }

    /// Removes a PC from this account's "Bağlı cihazlar" list - the backend relay registry only,
    /// not the phone's own direct pairing (see IOSConnectionModel.forgetPairing for that).
    static func deleteDevice(id: String) async throws {
        _ = try await authorizedMutate("devices/\(id)", method: "DELETE")
        WiqoMobileReadCache.shared.invalidate(mobileReadCacheKey("devices"))
    }

    /// The interactive fallback used when the direct local connection to the paired PC isn't
    /// available (different network, PC just woke up, etc.) - relays the same already-confirmed
    /// CommandRequest through the PC's own persistent backend connection (the one automations
    /// already use) and returns the real CommandResult once the PC replies. `deviceId` targets a
    /// specific paired PC when known; omitted, the backend picks the first one online.
    static func sendDeviceCommand(_ request: CommandRequest, deviceId: String?) async throws -> CommandResult {
        let body = try Self.iso8601Encoder.encode(request)
        let path = "devices/\(deviceId ?? "default")/command"
        let data = try await authorizedJSON(path, method: "POST", body: body)
        do {
            return try Self.iso8601Decoder.decode(CommandResult.self, from: data)
        } catch {
            throw RovaBackendError.invalidResponse
        }
    }

    struct RelayPairingClaim: Decodable {
        let deviceId: String
        let displayName: String
        let platform: String
        let pairingToken: String
    }

    /// Claims the short-lived QR bootstrap session. The backend binds the Mac to this signed-in
    /// account; the returned pairing token is only for the existing per-command signature path.
    static func claimRelayPairing(sessionID: String, secret: String) async throws -> RelayPairingClaim {
        let body = try JSONSerialization.data(withJSONObject: ["secret": secret])
        let data = try await authorizedJSON("device-pairing/sessions/\(sessionID)/claim", method: "POST", body: body)
        do { return try JSONDecoder().decode(RelayPairingClaim.self, from: data) }
        catch { throw RovaBackendError.invalidResponse }
    }

    /// CommandRequest/CommandResult carry Date fields encoded as ISO-8601 strings everywhere else
    /// in this protocol (see RovaShared/Framing.swift's RovaWireCodec) - matched here so this
    /// relay path round-trips the same values the direct connection would have produced.
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

    static func refreshProactiveSuggestions() async throws -> [ProactiveSuggestion] {
        struct Response: Decodable { let suggestions: [ProactiveSuggestion] }
        return try await authorizedPost("proactive/refresh", body: [:], as: Response.self).suggestions
    }

    static func updateProactiveSuggestion(id: Int, action: String) async throws {
        guard action == "accept" || action == "dismiss" else { return }
        _ = try await authorizedMutate("proactive/suggestions/\(id)/\(action)", method: "POST")
    }

    // MARK: - Tasks & automations (created conversationally; managed here)

    struct RovaTask: Decodable, Identifiable {
        let id: Int
        let title: String
        let status: String
        let createdAt: String
        let completedAt: String?
    }

    struct RovaAutomation: Decodable, Identifiable {
        let id: Int
        let prompt: String
        let cron: String
        let isActive: Bool
        let lastRunAt: String?
        let nextRunAt: String?
        let lifecycleStatus: String?
        let targetDeviceId: String?

        private enum CodingKeys: String, CodingKey {
            case id, prompt, cron, isActive, lastRunAt, nextRunAt, lifecycleStatus, targetDeviceId
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(Int.self, forKey: .id)
            prompt = try values.decode(String.self, forKey: .prompt)
            cron = try values.decode(String.self, forKey: .cron)
            isActive = try values.decode(Bool.self, forKey: .isActive)
            lastRunAt = try values.decodeIfPresent(String.self, forKey: .lastRunAt)
            nextRunAt = try values.decodeIfPresent(String.self, forKey: .nextRunAt)
            lifecycleStatus = try values.decodeIfPresent(String.self, forKey: .lifecycleStatus)
            targetDeviceId = try values.decodeIfPresent(String.self, forKey: .targetDeviceId)
        }
    }

    struct AutomationReviewItem: Decodable, Identifiable {
        let runId: Int
        let automationId: Int
        let title: String
        let status: String
        let reply: String?
        let error: String?
        let delivered: Bool
        let currentStep: Int
        let waitingReason: String?
        let errorCategory: String?
        let checkpointAt: String?
        let lastProgressAt: String?
        let finishedAt: String?

        var id: Int { runId }
    }

    struct AutomationActionResponse: Decodable {
        let ok: Bool
        let status: String?
        let runId: Int?
        let coalesced: Bool?
        let nextRunAt: String?
    }

    /// One step of a past automation run.
    struct AutomationRunStep: Decodable, Identifiable {
        let id: Int
        let stepIndex: Int
        let kind: String
        let status: String
        let inputSummary: String?
        let outputSummary: String?
        let error: String?
        let attemptCount: Int
        let maxAttempts: Int
        let isDestructive: Bool
        let requiresUserPresence: Bool
        let startedAt: String?
        let finishedAt: String?
        let commandId: String?
        let deliveryState: String?
        let acknowledgedAt: String?
        let lastProgressAt: String?
        let deadlineAt: String?
        let lastErrorCode: String?
        let lastErrorCategory: String?
    }

    struct AutomationRun: Decodable, Identifiable {
        let id: Int
        let status: String
        let reply: String?
        let error: String?
        let delivered: Bool
        let completionDeliveryState: String?
        let pushState: String?
        let pushError: String?
        let currentStep: Int?
        let checkpointAt: String?
        let lastProgressAt: String?
        let deadlineAt: String?
        let startedAt: String
        let finishedAt: String?
        let steps: [AutomationRunStep]
    }

    struct ExecutionJournalEntry: Decodable, Identifiable {
        let id: Int
        let stepId: String?
        let event: String
        let toolName: String?
        let status: String?
        let verified: Bool
        let retryable: Bool
        let sideEffectUncertain: Bool
        let errorCode: String?
        let summary: String
        let durationMs: Int?
        let createdAt: String
    }

    static func fetchAutomationRuns(id: Int) async throws -> [AutomationRun] {
        struct Response: Decodable { let runs: [AutomationRun] }
        return try await authorizedGet("automations/\(id)/runs", as: Response.self).runs
    }

    static func fetchAutomationJournal(automationID: Int, runID: Int) async throws -> [ExecutionJournalEntry] {
        struct Response: Decodable { let entries: [ExecutionJournalEntry] }
        return try await authorizedGet("automations/\(automationID)/runs/\(runID)/journal", as: Response.self).entries
    }

    static func fetchCopilotJournal(requestID: UUID) async throws -> [ExecutionJournalEntry] {
        struct Response: Decodable { let entries: [ExecutionJournalEntry] }
        return try await authorizedGet("copilot/requests/\(requestID.uuidString)/journal", as: Response.self).entries
    }

    static func fetchTasks() async throws -> [RovaTask] {
        struct Response: Decodable { let tasks: [RovaTask] }
        return try await authorizedGet("tasks", as: Response.self).tasks
    }

    static func completeTask(id: Int) async throws {
        _ = try await authorizedMutate("tasks/\(id)/complete", method: "POST")
    }

    static func fetchAutomations() async throws -> [RovaAutomation] {
        struct Response: Decodable { let automations: [RovaAutomation] }
        return try await authorizedGet("automations", as: Response.self).automations
    }

    static func fetchAutomationReview() async throws -> [AutomationReviewItem] {
        struct Response: Decodable { let items: [AutomationReviewItem] }
        return try await authorizedGet("automations/review", as: Response.self).items
    }

    static func pauseAutomation(id: Int) async throws -> AutomationActionResponse {
        try await authorizedPost("automations/\(id)/pause", body: [:], as: AutomationActionResponse.self)
    }

    static func resumeAutomation(id: Int) async throws -> AutomationActionResponse {
        try await authorizedPost("automations/\(id)/resume", body: [:], as: AutomationActionResponse.self)
    }

    static func runAutomationNow(id: Int) async throws -> AutomationActionResponse {
        try await authorizedPost("automations/\(id)/run-now", body: [:], as: AutomationActionResponse.self)
    }

    static func updateAutomation(
        id: Int,
        prompt: String? = nil,
        cron: String? = nil,
        timezone: String? = nil,
        targetDeviceId: String? = nil
    ) async throws {
        var values: [String: Any] = [:]
        if let prompt { values["prompt"] = prompt }
        if let cron { values["cron"] = cron }
        if let timezone { values["timezone"] = timezone }
        if let targetDeviceId { values["targetDeviceId"] = targetDeviceId }
        let data = try JSONSerialization.data(withJSONObject: values)
        _ = try await authorizedJSON("automations/\(id)", method: "PATCH", body: data)
    }

    static func retryAutomationRun(automationID: Int, runID: Int) async throws -> AutomationActionResponse {
        try await authorizedPost("automations/\(automationID)/runs/\(runID)/retry", body: [:], as: AutomationActionResponse.self)
    }

    static func resolveUnknownAutomationRun(
        automationID: Int,
        runID: Int,
        resolution: String
    ) async throws -> AutomationActionResponse {
        try await authorizedPost(
            "automations/\(automationID)/runs/\(runID)/resolve-unknown",
            body: ["resolution": resolution],
            as: AutomationActionResponse.self
        )
    }

    static func cancelAutomation(id: Int) async throws {
        _ = try await authorizedMutate("automations/\(id)", method: "DELETE")
    }

    private static func authorizedGet<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        guard let token else { throw RovaBackendError.notAuthenticated }
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        if response.statusCode == 401 { signOut(); throw RovaBackendError.notAuthenticated }
        return try decode(T.self, from: data, response: response)
    }

    private static func authorizedPost<T: Decodable>(_ path: String, body: [String: Any], as type: T.Type) async throws -> T {
        guard let token else { throw RovaBackendError.notAuthenticated }
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await send(request)
        if response.statusCode == 401 { signOut(); throw RovaBackendError.notAuthenticated }
        return try decode(T.self, from: data, response: response)
    }

    @discardableResult
    private static func authorizedMutate(_ path: String, method: String) async throws -> Data {
        guard let token else { throw RovaBackendError.notAuthenticated }
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        if response.statusCode == 401 { signOut(); throw RovaBackendError.notAuthenticated }
        guard (200..<300).contains(response.statusCode) else {
            let message = serverErrorMessage(from: data)
            throw RovaBackendError.network(message ?? userFacingHTTPMessage(for: response.statusCode))
        }
        return data
    }

    private static func authorizedJSON(_ path: String, method: String, body: Data) async throws -> Data {
        guard let token else { throw RovaBackendError.notAuthenticated }
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let (data, response) = try await send(request)
        if response.statusCode == 401 { signOut(); throw RovaBackendError.notAuthenticated }
        guard (200..<300).contains(response.statusCode) else {
            let message = serverErrorMessage(from: data)
            throw RovaBackendError.network(message ?? userFacingHTTPMessage(for: response.statusCode))
        }
        return data
    }

    // MARK: - Shared plumbing

    /// Downloads a generated document/image into a per-account cache folder so it can be opened
    /// with Quick Look (PDF, Word, Excel, CSV, images...). The backend's artifact URL requires the
    /// session token, which a plain file/web preview could not send. The file is verified against
    /// the artifact's SHA-256 before it is handed to the viewer, and reused if already cached.
    static func downloadArtifact(_ artifact: ArtifactDescriptor) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiqo-artifacts", isDirectory: true)
            .appendingPathComponent(currentUserID ?? "anon", isDirectory: true)
            .appendingPathComponent(artifact.id, isDirectory: true)
        let safeName = artifact.filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let destination = folder.appendingPathComponent(safeName.isEmpty ? "dosya" : safeName)
        if FileManager.default.fileExists(atPath: destination.path),
           let cached = try? Data(contentsOf: destination),
           sha256Hex(cached) == artifact.sha256.lowercased() {
            return destination
        }
        guard let token else { throw RovaBackendError.notAuthenticated }
        var request = URLRequest(url: artifact.downloadURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        if response.statusCode == 401 { signOut(); throw RovaBackendError.notAuthenticated }
        guard (200..<300).contains(response.statusCode) else {
            throw RovaBackendError.network(response.statusCode == 404 ? "Dosyanın süresi dolmuş; yeniden oluşturmamı isteyebilirsin." : "Dosya indirilemedi.")
        }
        guard sha256Hex(data) == artifact.sha256.lowercased() else {
            throw RovaBackendError.network("Dosya bütünlük doğrulamasını geçemedi.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: destination, options: [.atomic])
        return destination
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var retried = false
        while true {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                // A read that failed only because the connection had gone stale (typical right after
                // the app returns from the background) is safe to repeat once. A write is never
                // repeated here: the server could already have acted on it.
                if !retried, isRepeatable(request), isDroppedConnection(error) {
                    retried = true
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                }
                throw RovaBackendError.network(userFacingNetworkMessage(for: error))
            }
            guard let http = response as? HTTPURLResponse else { throw RovaBackendError.invalidResponse }
            return (data, http)
        }
    }

    private static func isRepeatable(_ request: URLRequest) -> Bool {
        (request.httpMethod ?? "GET") == "GET"
    }

    private static func isDroppedConnection(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed: return true
        default: return false
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, response: HTTPURLResponse) throws -> T {
        guard (200..<300).contains(response.statusCode) else {
            let message = serverErrorMessage(from: data)
            if response.statusCode == 422 {
                throw RovaBackendError.declined(message ?? userFacingHTTPMessage(for: response.statusCode))
            }
            throw RovaBackendError.network(message ?? userFacingHTTPMessage(for: response.statusCode))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RovaBackendError.invalidResponse
        }
    }

    private static func userFacingNetworkMessage(for error: Error) -> String {
        guard let urlError = error as? URLError else {
            return "Wiqo sunucusuna ulaşılamadı. Lütfen internet bağlantını kontrol edip tekrar dene."
        }
        switch urlError.code {
        case .notConnectedToInternet:
            return "İnternet bağlantısı yok. Bağlantını kontrol edip tekrar dene."
        case .timedOut:
            return "Wiqo sunucusu zamanında yanıt vermedi. Biraz sonra tekrar dene."
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed:
            return "Wiqo sunucusuna bağlanılamadı. Biraz sonra tekrar dene."
        default:
            return "Wiqo sunucusuna bağlanırken bir sorun oluştu. Lütfen tekrar dene."
        }
    }

    private static func userFacingHTTPMessage(for statusCode: Int) -> String {
        switch statusCode {
        case 400:
            return "Gönderdiğin bilgiler geçersiz. Lütfen kontrol edip tekrar dene."
        case 401:
            return "Oturumun geçersiz veya süresi dolmuş. Lütfen tekrar giriş yap."
        case 403:
            return "Bu işlem için yetkin yok."
        case 404:
            return "İstenen Wiqo kaydı bulunamadı."
        case 409:
            return "Bu istek zaten işleniyor. Biraz sonra tekrar dene."
        case 429:
            return "Çok fazla istek yapıldı. Biraz sonra tekrar dene."
        case 500:
            return "Wiqo sunucusunda beklenmeyen bir hata oluştu. Lütfen tekrar dene."
        case 502, 503, 504:
            return "Wiqo sunucusu şu anda kullanılamıyor. Biraz sonra tekrar dene."
        default:
            return "Wiqo sunucusu isteği tamamlayamadı. Lütfen tekrar dene."
        }
    }

    private static func nonEmptyMessage(_ message: String?, fallback: String) -> String {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func serverErrorMessage(from data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(BackendErrorEnvelope.self, from: data) else { return nil }
        let message = envelope.error?.message ?? envelope.message ?? envelope.result?.text
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return nil }
        return appendingErrorCode(trimmed, code: envelope.error?.code)
    }

    /// Every backend error response already carries a real machine-readable `code`
    /// (`CONFIRMATION_NOT_PENDING`, `QUOTA_EXCEEDED`, ...) - this was being decoded and then
    /// silently dropped before reaching any caller. Appending it here means every existing
    /// `RovaBackendError.network(message)` surface (there is no single shared error view) gets it
    /// for free, without hunting down and touching every place that already displays this string.
    private static func appendingErrorCode(_ message: String, code: String?) -> String {
        guard let code, !code.isEmpty else { return message }
        return "\(message) (kod: \(code))"
    }
}

private struct BackendErrorEnvelope: Decodable {
    struct Detail: Decodable {
        let code: String?
        let message: String?
    }

    struct Result: Decodable {
        let text: String?
    }

    let error: Detail?
    let message: String?
    let result: Result?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        result = try container.decodeIfPresent(Result.self, forKey: .result)
        if let detail = try? container.decode(Detail.self, forKey: .error) {
            error = detail
        } else if let text = try? container.decode(String.self, forKey: .error) {
            error = Detail(code: nil, message: text)
        } else {
            error = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case error
        case message
        case result
    }
}

/// Short-lived cache for repeatable mobile reads. Commands, writes, auth, and live chat never use
/// this cache. Keeping it in the existing client avoids another project-file entry and keeps the
/// read policy next to the requests it protects.
private final class WiqoMobileReadCache: @unchecked Sendable {
    static let shared = WiqoMobileReadCache()

    private struct Entry {
        let data: Data
        let storedAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    private init() {}

    func data(for key: String, maxAge: TimeInterval, now: Date = Date()) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.storedAt) <= maxAge else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.data
    }

    func store(_ data: Data, for key: String, now: Date = Date()) {
        lock.lock()
        entries[key] = Entry(data: data, storedAt: now)
        lock.unlock()
    }

    func invalidate(_ key: String) {
        lock.lock()
        entries.removeValue(forKey: key)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

extension RovaBackendClient.DeviceStatus: Encodable {
    private enum CodingKeys: String, CodingKey {
        case id, displayName, platform, capabilities, online, lastSeenAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(platform, forKey: .platform)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(online, forKey: .online)
        try container.encodeIfPresent(lastSeenAt, forKey: .lastSeenAt)
    }
}

extension RovaBackendClient.TrustGrant: Encodable {
    private enum CodingKeys: String, CodingKey {
        case id, label, grantedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(grantedAt, forKey: .grantedAt)
    }
}

extension RovaBackendClient.MemoryCandidate: Encodable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, content, sourceText, status, similarity, createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(content, forKey: .content)
        try container.encode(sourceText, forKey: .sourceText)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(similarity, forKey: .similarity)
        try container.encode(createdAt, forKey: .createdAt)
    }
}
