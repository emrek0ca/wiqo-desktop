import CryptoKit
import CoreLocation
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

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
    case copilotPayloadTooLarge

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Önce Wiqo hesabına giriş yap."
        case .network(let message): return message
        case .invalidResponse: return "Sunucudan geçersiz bir yanıt alındı. Lütfen tekrar dene."
        case .declined(let reason): return reason
        case .copilotPayloadTooLarge: return "Eklerin toplam boyutu çok büyük. Daha az dosya veya görsel ekleyip tekrar dene."
        }
    }
}

private actor CopilotLocationPromptLedger {
    static let shared = CopilotLocationPromptLedger()
    private var claimed: Set<String> = []

    func claim(_ requestID: String) -> Bool {
        guard !claimed.contains(requestID) else { return false }
        claimed.insert(requestID)
        if claimed.count > 256 { claimed.removeAll(keepingCapacity: true) }
        return true
    }
}

/// Talks to Rova's own backend (see the `rova-backend` project) instead of any third-party AI
/// API directly. The backend owns the shared Groq key server-side and gates access behind a
/// login; this app only ever carries its own session token, stored in Keychain like the Mac
/// pairing token already is. This is the single integration point for both account handling and
/// the AI copilot feature.
enum RovaBackendClient {
    private static let tokenAccount = "rova-backend-token"
    /// Mirrors rova-backend's chat file-content contract and leaves room under express.json's 20 MB cap.
    private static let maxFileContentsPayloadBytes = 6_000_000
    private static let maxAttachmentContentsPayloadBytes = 19_000_000
    private static let maxCopilotRequestBodyBytes = 19_500_000
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
    /// One line of the thinking timeline (see ThinkingTrace). `state` is running, done or failed.
    struct ActivityUpdate: Decodable, Equatable, Sendable {
        let id: String
        let phase: String
        let label: String
        let state: String
        /// general / research / developer / execution: the sub-agent doing this line (mascot).
        let persona: String?
    }

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
        /// The reply is only a "doing it now" line; replace it with the verified outcome once the
        /// steps finish (see DeviceOutcomeNarrator).
        var replyIsProgress = false
        /// Safe PC steps queued because the PC was offline; they run once it reconnects.
        var deferredTask: DeferredTask? = nil
        /// A website, long document, presentation or image set Wiqo now builds step by step in
        /// the background (backend src/projects/); the chat shows its live card.
        var projectTask: ProjectTask? = nil
        /// A background agent task this turn started or answered (backend src/agent/tasks.ts).
        var agentTask: AgentTaskRef? = nil
        var widgets: [CopilotResultWidget] = []
    }

    struct CopilotResultWidget: Codable, Hashable, Sendable {
        enum Kind: String, Codable { case created_resource, weather, sources }
        enum ResourceType: String, Codable { case agent, automation }

        struct Source: Codable, Hashable, Sendable, Identifiable {
            let title: String?
            let url: String
            let published: String?

            var id: String { url }
        }

        struct WeatherCurrent: Codable, Hashable, Sendable {
            let observedAt: String?
            let temperatureC: Double?
            let feelsLikeC: Double?
            let humidityPercent: Double?
            let windKmh: Double?
            let condition: String
            let weatherCode: Int?
        }

        struct WeatherHour: Codable, Hashable, Sendable {
            let time: String
            let temperatureC: Double?
            let rainChancePercent: Double?
            let weatherCode: Int?
        }

        struct WeatherDay: Codable, Hashable, Sendable {
            let date: String
            let condition: String
            let weatherCode: Int?
            let minC: Double?
            let maxC: Double?
            let rainChancePercent: Double?
            let rainMm: Double?
        }

        let type: Kind
        let resourceType: ResourceType?
        let id: Int?
        let title: String?
        let detail: String?
        let scheduleLabel: String?
        let schedule: String?
        let timezone: String?
        let nextRunAt: String?
        let status: String?
        let persona: String?
        let presentation: String?
        let location: String?
        let source: String?
        let current: WeatherCurrent?
        let hourly: [WeatherHour]?
        let days: [WeatherDay]?
        let sources: [Source]?
    }

    /// The handle a chat reply carries for a background agent task; the card polls the detail.
    struct AgentTaskRef: Codable, Hashable, Sendable {
        let id: Int
        let title: String
        /// general / research / developer / execution - which mascot to show (WiqoAgentMascot).
        let persona: String?
    }

    /// Live state of a background agent task (GET /agent-tasks/:id).
    struct AgentTaskDetail: Decodable, Equatable, Sendable {
        struct Step: Decodable, Equatable, Hashable, Sendable {
            let id: String
            let title: String
            let status: String
            let seconds: Int?
            /// What the step found (sources included) - the evidence behind the answer.
            let brief: String?
        }
        struct Waiting: Decodable, Equatable, Sendable {
            let reason: String
            let confirmationId: String?
            let question: String?
        }
        struct Usage: Decodable, Equatable, Sendable {
            let modelCalls: Int
            let inputTokens: Int
            let outputTokens: Int
            let budget: Int
        }
        struct Verification: Decodable, Equatable, Sendable {
            let checked: Bool
            let unsupported: [String]
        }
        let id: Int
        let title: String
        let persona: String?
        let status: String
        let progress: String?
        let steps: [Step]
        let waiting: Waiting?
        let usage: Usage
        let verification: Verification?
        let revisions: Int
        let error: String?
        let estimatedSeconds: Int?
        let conversationId: String?

        var isActive: Bool { status == "running" }
    }

    static func fetchAgentTasks() async throws -> [AgentTaskDetail] {
        struct Response: Decodable { let tasks: [AgentTaskDetail] }
        return try await authorizedGet("agent-tasks", as: Response.self).tasks
    }

    static func steerAgentTask(id: Int, note: String) async throws {
        _ = try await authorizedPost("agent-tasks/\(id)/steer", body: ["note": note], as: AgentTaskDetail.self)
    }

    /// A named standing agent (backend agent/agents.ts), with what it remembers.
    struct NamedAgent: Decodable, Identifiable, Sendable {
        let id: Int
        let name: String
        let role: String
        let persona: String?
        let cron: String?
        let nextRunAt: String?
        let lastRunAt: String?
        let memory: String
    }

    static func fetchAgents() async throws -> [NamedAgent] {
        struct Response: Decodable { let agents: [NamedAgent] }
        return try await authorizedGet("agents", as: Response.self).agents
    }

    static func forgetAgentMemory(id: Int) async throws {
        struct Response: Decodable { let ok: Bool }
        _ = try await authorizedPost("agents/\(id)/forget", body: [:], as: Response.self)
    }

    static func deleteAgent(id: Int) async throws {
        _ = try await authorizedMutate("agents/\(id)", method: "DELETE")
    }

    static func fetchAgentTask(id: Int) async throws -> AgentTaskDetail {
        try await authorizedGet("agent-tasks/\(id)", as: AgentTaskDetail.self)
    }

    /// The handle a chat reply carries for a background project.
    struct ProjectTask: Codable, Hashable, Sendable {
        let id: Int
        let kind: String
        let title: String
        let status: String
    }

    /// Full state of a background project (`GET projects/:id`): the plan as a checklist, the live
    /// progress line, the verification results and - once done - the delivered files.
    struct ProjectDetail: Decodable, Equatable, Sendable {
        struct Step: Decodable, Equatable, Hashable, Sendable {
            let id: String
            let title: String
            let status: String
            let detail: String?
        }
        struct Check: Decodable, Equatable, Hashable, Sendable {
            let label: String
            let passed: Bool
            let detail: String?
        }
        /// One real event of the live feed: a plan decision, a file written, a check result, a fix.
        struct Event: Decodable, Equatable, Hashable, Sendable {
            let at: String
            let kind: String
            let text: String
            let stepId: String?
        }
        let id: Int
        let kind: String
        let title: String
        let status: String
        let phase: String
        let progress: String?
        let steps: [Step]
        let checks: [Check]
        let summary: String?
        let error: String?
        let artifacts: [ArtifactDescriptor]
        let artifactsExpired: Bool?
        // Optional so a card keeps working against a backend that predates the live feed.
        let events: [Event]?
        let preview: ArtifactDescriptor?
        let stepStartedAt: String?
        let serverTime: String?
        let updatedAt: String?

        var isActive: Bool { status == "running" }
    }

    /// Work Wiqo will do the next time the PC comes online (backend automation/deferred.ts).
    struct DeferredTask: Codable, Hashable, Sendable {
        let id: Int
        let summary: String
        let status: String
        let createdAt: String
        let expiresAt: String
    }

    struct DeferredCancellationResponse: Decodable, Sendable {
        let cancelled: Bool?
        let outcomeUnknown: Bool?
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
        let widgets: [CopilotResultWidget]?
        let locationRequired: LocationRequiredInfo?
        let backendConfirmations: [BackendConfirmation]?
        let replyIsProgress: Bool?
        let deferredTask: DeferredTask?
        let projectTask: ProjectTask?
        let agentTask: AgentTaskRef?
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

    private struct LocationRequiredInfo: Decodable {
        let requestId: String
        let prompt: String
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
        /// Content read on this phone (FileContentExtractor); the files themselves are never sent.
        files: [FileContent] = [],
        createAgent: Bool = false,
        // Awaited on the main actor in stream order - separate `Task { @MainActor }` hops per event
        // are not guaranteed to run in order, which would scramble streamed text.
        onStatus: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onDelta: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onReset: @escaping @MainActor @Sendable () -> Void = {},
        onConfirmationNeeded: @escaping @MainActor @Sendable ([PlannedCommand], [BackendConfirmation]) -> Void = { _, _ in },
        onStepUpdate: @escaping @MainActor @Sendable (ExecutionStepUpdate) -> Void = { _ in },
        onActivity: @escaping @MainActor @Sendable (ActivityUpdate) -> Void = { _ in },
        onLocationRequired: @escaping @MainActor @Sendable (String) async -> Void = { _ in },
        /// Today's message count as the server has just counted it (used, limit).
        onUsage: @escaping @MainActor @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> ConverseResult {
        let requestLocationOnce: @MainActor @Sendable (String) async -> Void = { locationRequestID in
            guard await CopilotLocationPromptLedger.shared.claim(locationRequestID) else { return }
            await onLocationRequired(locationRequestID)
        }
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
                if let fileBase64 = result.fileBase64 { value["fileBase64"] = fileBase64 }
                if let artifactID = result.artifactID { value["artifactId"] = artifactID }
                if let fileName = result.fileName { value["fileName"] = fileName }
                if let mimeType = result.mimeType { value["mimeType"] = mimeType }
                return value
            }
        ]
        var requestBody = body
        if createAgent { requestBody["composerIntent"] = "create_agent" }
        let encoder = JSONEncoder()
        var filePayloadBytes = files.isEmpty ? 0 : 2 // JSON array brackets
        for (index, file) in files.enumerated() {
            filePayloadBytes += try encoder.encode(file).count + (index == 0 ? 0 : 1)
            guard filePayloadBytes <= Self.maxFileContentsPayloadBytes else {
                throw RovaBackendError.copilotPayloadTooLarge
            }
        }
        if !files.isEmpty {
            let encoded = try encoder.encode(files)
            guard encoded.count <= Self.maxFileContentsPayloadBytes,
                  let object = try? JSONSerialization.jsonObject(with: encoded) else {
                throw RovaBackendError.copilotPayloadTooLarge
            }
            requestBody["files"] = object
        }
        let imagePayloadBytes = attachments.reduce(0) { $0 + $1.dataBase64.utf8.count }
        guard imagePayloadBytes <= 18_000_000,
              filePayloadBytes + imagePayloadBytes <= Self.maxAttachmentContentsPayloadBytes else {
            throw RovaBackendError.copilotPayloadTooLarge
        }
        if let deviceID { requestBody["deviceId"] = deviceID.uuidString }
        if let turnCount { requestBody["turnCount"] = turnCount }
        if !createAgent, deviceResults.isEmpty, files.isEmpty, attachments.isEmpty,
           let lastUser = messages.last(where: { $0.role == "user" })?.content,
           let hint = await WiqoOnDeviceRouter.hint(for: lastUser),
           let object = try? JSONSerialization.jsonObject(with: hint) {
            requestBody["intentHint"] = object
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [.fragmentsAllowed])
        guard (request.httpBody?.count ?? 0) <= Self.maxCopilotRequestBodyBytes else {
            throw RovaBackendError.copilotPayloadTooLarge
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            return try await waitForCopilotRequest(requestID: requestID, onStatus: onStatus, onLocationRequired: requestLocationOnce)
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
            let widgets: [CopilotResultWidget]?
            let backendConfirmations: [BackendConfirmation]?
            let replyIsProgress: Bool?
            let deferredTask: DeferredTask?
            let projectTask: ProjectTask?
            let agentTask: AgentTaskRef?
        }
        struct ConfirmationNeededEvent: Decodable {
            let steps: [CopilotStepResponse]
            let backendConfirmations: [BackendConfirmation]?
        }
        struct StepUpdateEvent: Decodable {
            let step: ExecutionStepUpdate
        }
        struct ActivityEvent: Decodable {
            let activity: ActivityUpdate
        }
        struct LocationRequiredEvent: Decodable {
            let requestId: String
            let prompt: String?
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
                case "activity":
                    if let event = try? decoder.decode(ActivityEvent.self, from: json) {
                        await onActivity(event.activity)
                    }
                case "location_required":
                    if let event = try? decoder.decode(LocationRequiredEvent.self, from: json) {
                        await onStatus(event.prompt ?? "Hava durumu için konum izni bekleniyor…")
                        await requestLocationOnce(event.requestId)
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
                        widgets: event.widgets ?? [],
                        backendConfirmations: event.backendConfirmations ?? [],
                        replyIsProgress: event.replyIsProgress ?? false,
                        deferredTask: event.deferredTask,
                        projectTask: event.projectTask,
                        agentTask: event.agentTask
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
            return try await waitForCopilotRequest(requestID: requestID, onStatus: onStatus, onLocationRequired: requestLocationOnce)
        }
        return try await waitForCopilotRequest(requestID: requestID, onStatus: onStatus, onLocationRequired: requestLocationOnce)
    }

    static func continueCopilotWeatherLocation(requestID: String, city: String?) async throws {
        struct Response: Decodable { let requestId: String; let status: String }
        var body: [String: Any] = ["city": NSNull()]
        if let city { body["city"] = city }
        _ = try await authorizedPost("copilot/requests/\(requestID)/location", body: body, as: Response.self)
    }

    static func requestAndContinueCopilotWeatherLocation(requestID: String) async {
        let city = await OneShotCityLocator.currentCity()
        try? await continueCopilotWeatherLocation(requestID: requestID, city: city)
    }

    static func resolveBackendConfirmation(id: UUID, approved: Bool, terminalGrant: (grantId: String, signature: String)? = nil, terminalGrantExpiresAt: Int? = nil, terminalGrantScope: String = "task") async throws -> BackendConfirmationResponse {
        var body: [String: Any] = [
            "confirmationId": id.uuidString,
            "approved": approved
        ]
        if let terminalGrant {
            var grant: [String: Any] = ["grantId": terminalGrant.grantId, "signature": terminalGrant.signature, "scope": terminalGrantScope]
            // A session expiry is signed by the paired phone; task/folder scope is enforced by the backend.
            if let terminalGrantExpiresAt { grant["expiresAt"] = terminalGrantExpiresAt }
            body["terminalGrant"] = grant
        }
        defer { reconcileLocalReminders() }
        return try await authorizedPost("copilot/confirm", body: body, as: BackendConfirmationResponse.self)
    }

    private static func makeConverseResult(
        reply: String,
        steps: [CopilotStepResponse],
        executionState: String?,
        artifacts: [ArtifactDescriptor],
        widgets: [CopilotResultWidget] = [],
        backendConfirmations: [BackendConfirmation],
        replyIsProgress: Bool = false,
        deferredTask: DeferredTask? = nil,
        projectTask: ProjectTask? = nil,
        agentTask: AgentTaskRef? = nil
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
            backendConfirmations: backendConfirmations,
            replyIsProgress: replyIsProgress,
            deferredTask: deferredTask,
            projectTask: projectTask,
            agentTask: agentTask,
            widgets: widgets
        )
    }

    private static func waitForCopilotRequest(
        requestID: UUID,
        onStatus: @escaping @MainActor @Sendable (String) -> Void,
        onLocationRequired: @escaping @MainActor @Sendable (String) async -> Void
    ) async throws -> ConverseResult {
        await onStatus("Bağlantı koptu; Wiqo işlemin sonucunu koruyor…")
        let deadline = Date().addingTimeInterval(150)
        var missingCount = 0
        var locationRequestHandled = false
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
                        widgets: response.widgets ?? [],
                        backendConfirmations: response.backendConfirmations ?? [],
                        replyIsProgress: response.replyIsProgress ?? false,
                        deferredTask: response.deferredTask,
                        projectTask: response.projectTask,
                        agentTask: response.agentTask
                    )
                case "failed":
                    throw RovaBackendError.declined(nonEmptyMessage(state.error?.message, fallback: "İşlem tamamlanamadı."))
                case "awaiting_weather_location":
                    if !locationRequestHandled, let required = state.response?.locationRequired {
                        locationRequestHandled = true
                        await onLocationRequired(required.requestId)
                    } else {
                        await onStatus("Hava durumu isteği devam ediyor…")
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
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
        /// Bytes of a file the user asked to receive; the backend turns them into a downloadable
        /// artifact and never shows them to the model. Set only for a "Telefona gönder" step.
        let fileBase64: String?
        let artifactID: String?
        let fileName: String?
        let mimeType: String?

        init(stepID: UUID, type: CommandType, summary: String? = nil, status: CommandStatus, message: String, error: RovaError?, dataText: String? = nil, imageBase64: String? = nil, fileBase64: String? = nil, artifactID: String? = nil, fileName: String? = nil, mimeType: String? = nil) {
            self.stepID = stepID
            self.type = type
            self.summary = summary
            self.status = status
            self.message = message
            self.error = error
            self.dataText = dataText
            self.imageBase64 = imageBase64
            self.fileBase64 = fileBase64
            self.artifactID = artifactID
            self.fileName = fileName
            self.mimeType = mimeType
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

    struct ActivityItem: Decodable, Identifiable {
        struct Reference: Decodable { let type: String; let id: String }
        let id: String
        let state: String
        let source: String
        let title: String
        let detail: String?
        let at: String
        let ref: Reference?
        /// Sub-agent mascot for agent tasks and automations.
        let persona: String?
        /// Safe, user-facing approval payload used when a notification opens Activity directly.
        let confirmation: BackendConfirmation?
    }

    struct ActivityFeed: Decodable {
        let needsAttention: [ActivityItem]
        let upcoming: [ActivityItem]
        let recent: [ActivityItem]
    }

    static func fetchActivity() async throws -> ActivityFeed {
        try await authorizedGet("activity", as: ActivityFeed.self)
    }

    struct TerminalJobCancellationResponse: Decodable {
        let ok: Bool
        let state: String
        let errorCode: String?
    }

    struct TerminalGrantRevocationResponse: Decodable {
        let revoked: Bool
        let unknownJobCount: Int
    }

    static func cancelTerminalJob(id: String) async throws -> TerminalJobCancellationResponse {
        try await authorizedPost("terminal-jobs/\(id)/cancel", body: [:], as: TerminalJobCancellationResponse.self)
    }

    static func revokeTerminalGrant(id: String) async throws -> TerminalGrantRevocationResponse {
        try await authorizedPost("terminal-grants/\(id)/revoke", body: [:], as: TerminalGrantRevocationResponse.self)
    }

    struct StoredMemory: Decodable, Identifiable {
        let id: Int
        let kind: String
        let content: String
        let createdAt: String
        let updatedAt: String
    }

    static func fetchStoredMemories() async throws -> [StoredMemory] {
        struct Response: Decodable { let memories: [StoredMemory] }
        return try await authorizedGet("memory/items", as: Response.self).memories
    }

    static func deleteStoredMemory(id: Int) async throws {
        _ = try await authorizedMutate("memory/items/\(id)", method: "DELETE")
    }

    static func deleteAllStoredMemories() async throws {
        _ = try await authorizedMutate("memory/items", method: "DELETE")
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
        let widgets: [CopilotResultWidget]?
    }

    static func fetchConversations() async throws -> [RemoteConversationSummary] {
        struct Response: Decodable { let conversations: [RemoteConversationSummary] }
        return try await authorizedGet("conversations", as: Response.self).conversations
    }

    /// A saved request the user re-runs with one tap (backend: agent/skills.ts).
    struct UserSkill: Decodable, Identifiable, Sendable {
        let id: Int
        let name: String
        let prompt: String
    }

    static func fetchSkills() async throws -> [UserSkill] {
        struct Response: Decodable { let skills: [UserSkill] }
        return try await authorizedGet("skills", as: Response.self).skills
    }

    static func saveSkill(name: String, prompt: String) async throws {
        struct Response: Decodable { let id: Int }
        _ = try await authorizedPost("skills", body: ["name": name, "prompt": prompt], as: Response.self)
    }

    static func deleteSkill(id: Int) async throws {
        _ = try await authorizedMutate("skills/\(id)", method: "DELETE")
    }

    /// Turns an automation run into a conversation ("run-<id>") and returns its id.
    static func conversationFromRun(automationID: Int, runID: Int) async throws -> String {
        struct Response: Decodable { let conversationId: String }
        return try await authorizedPost("automations/\(automationID)/runs/\(runID)/conversation", body: [:], as: Response.self).conversationId
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

    static func registerFileTransfer(commandID: UUID, deviceID: UUID) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["commandId": commandID.uuidString, "deviceId": deviceID.uuidString])
        _ = try await authorizedJSON("file-transfers/intents", method: "POST", body: body)
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
        let accessLevel: String?
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

    static func setOAuthAccessLevel(provider: String, level: String) async throws {
        guard level == "read" || level == "write", provider == "google" || provider == "notion" else { throw RovaBackendError.invalidResponse }
        _ = try await authorizedPut("oauth/\(provider)/access", body: ["accessLevel": level])
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
    /// specific paired PC. Callers must never select an arbitrary online PC.
    static func sendDeviceCommand(_ request: CommandRequest, deviceId: String) async throws -> CommandResult {
        let body = try Self.iso8601Encoder.encode(request)
        let path = "devices/\(deviceId)/command"
        let timeout: TimeInterval = switch RovaOperationManifest.entry(for: request.type).timeoutClass {
        case .short, .medium: 35
        case .long: request.type == .sendFileToPhone ? 130 : 75
        }
        let data = try await authorizedJSON(path, method: "POST", body: body, timeout: timeout)
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
        /// "Her gün 14:35" - the backend's plain reading of the schedule.
        let scheduleLabel: String?
        /// "phone" when this phone delivers it itself, "server" when the backend pushes it.
        let delivery: String?

        private enum CodingKeys: String, CodingKey {
            case id, prompt, cron, isActive, lastRunAt, nextRunAt, lifecycleStatus, targetDeviceId, scheduleLabel, delivery
        }

        init(
            id: Int,
            prompt: String,
            cron: String,
            isActive: Bool,
            lastRunAt: String? = nil,
            nextRunAt: String? = nil,
            lifecycleStatus: String? = nil,
            targetDeviceId: String? = nil,
            scheduleLabel: String? = nil,
            delivery: String? = nil
        ) {
            self.id = id
            self.prompt = prompt
            self.cron = cron
            self.isActive = isActive
            self.lastRunAt = lastRunAt
            self.nextRunAt = nextRunAt
            self.lifecycleStatus = lifecycleStatus
            self.targetDeviceId = targetDeviceId
            self.scheduleLabel = scheduleLabel
            self.delivery = delivery
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
            scheduleLabel = try values.decodeIfPresent(String.self, forKey: .scheduleLabel)
            delivery = try values.decodeIfPresent(String.self, forKey: .delivery)
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

    struct RovaGoal: Decodable, Identifiable {
        let id: Int
        let title: String
        let createdAt: String
        let total: Int
        let done: Int
    }

    static func fetchGoals() async throws -> [RovaGoal] {
        struct Response: Decodable { let goals: [RovaGoal] }
        return try await authorizedGet("tasks/goals", as: Response.self).goals
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
        defer { reconcileLocalReminders() }
        return try await authorizedPost("automations/\(id)/pause", body: [:], as: AutomationActionResponse.self)
    }

    static func resumeAutomation(id: Int) async throws -> AutomationActionResponse {
        defer { reconcileLocalReminders() }
        return try await authorizedPost("automations/\(id)/resume", body: [:], as: AutomationActionResponse.self)
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
        reconcileLocalReminders()
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

    static func fetchProject(id: Int) async throws -> ProjectDetail {
        try await authorizedGet("projects/\(id)", as: ProjectDetail.self)
    }

    static func cancelAgentTask(id: Int) async throws {
        struct Response: Decodable { let ok: Bool }
        _ = try await authorizedPost("agent-tasks/\(id)/cancel", body: [:], as: Response.self)
    }

    static func cancelProject(id: Int) async throws -> ProjectDetail {
        try await authorizedPost("projects/\(id)/cancel", body: [:], as: ProjectDetail.self)
    }

    static func retryProject(id: Int) async throws -> ProjectDetail {
        try await authorizedPost("projects/\(id)/retry", body: [:], as: ProjectDetail.self)
    }

    static func cancelDeferredTask(id: Int) async throws -> DeferredCancellationResponse {
        let data = try await authorizedMutate("devices/pending-tasks/\(id)", method: "DELETE")
        return try JSONDecoder().decode(DeferredCancellationResponse.self, from: data)
    }

    static func cancelAutomation(id: Int) async throws {
        _ = try await authorizedMutate("automations/\(id)", method: "DELETE")
        reconcileLocalReminders()
    }

    // MARK: - On-device reminders

    /// A notification-only automation the phone schedules itself (backend: automation/localDelivery.ts).
    struct LocalNotification: Decodable, Sendable {
        let automationId: Int
        let specHash: String?
        let title: String
        let body: String
        let hour: Int
        let minute: Int
        /// 0 = Sunday ... 6 = Saturday, like cron; nil = every day.
        let weekdays: [Int]?
        let timezone: String
    }

    /// A single-moment reminder ("yarın 9'da", "10 dakika sonra").
    struct LocalOnceNotification: Decodable, Sendable {
        let automationId: Int
        let title: String
        let body: String
        /// ISO 8601 instant.
        let at: String
    }

    struct LocalNotificationPlan: Decodable, Sendable {
        let notifications: [LocalNotification]
        let once: [LocalOnceNotification]?
    }

    static func fetchLocalNotifications() async throws -> LocalNotificationPlan {
        try await authorizedGet("automations/local-notifications", as: LocalNotificationPlan.self)
    }

    static func leaseLocalDelivery(_ automationIDs: [Int]) async throws -> [Int] {
        struct Response: Decodable { let leased: [Int] }
        return try await authorizedPost("automations/local-delivery", body: ["automationIds": automationIDs], as: Response.self).leased
    }

    /// Automations can change from chat approvals or the detail screen; the phone's own schedule follows.
    static func reconcileLocalReminders() {
        Task { @MainActor in WiqoLocalReminders.shared.reconcile() }
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

    private static func authorizedPut(_ path: String, body: [String: Any]) async throws -> Data {
        guard let token else { throw RovaBackendError.notAuthenticated }
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent(path))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await send(request)
        if response.statusCode == 401 { signOut(); throw RovaBackendError.notAuthenticated }
        guard (200..<300).contains(response.statusCode) else {
            throw RovaBackendError.network(serverErrorMessage(from: data) ?? userFacingHTTPMessage(for: response.statusCode))
        }
        return data
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

    private static func authorizedJSON(_ path: String, method: String, body: Data, timeout: TimeInterval = 60) async throws -> Data {
        guard let token else { throw RovaBackendError.notAuthenticated }
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
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


/// Requests one location fix and resolves it locally to a city name; raw coordinates never leave iOS.
@MainActor
private final class OneShotCityLocator: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var continuation: CheckedContinuation<String?, Never>?
    private var didRequestLocation = false

    static func currentCity() async -> String? {
        await OneShotCityLocator().locate()
    }

    private func locate() async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyKilometer
            guard CLLocationManager.locationServicesEnabled() else {
                finish(nil)
                return
            }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                requestLocationOnce()
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            default:
                finish(nil)
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.finish(nil)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            requestLocationOnce()
        case .denied, .restricted:
            finish(nil)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { finish(nil); return }
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            Task { @MainActor in
                let city = placemarks?.first?.locality
                    ?? placemarks?.first?.subAdministrativeArea
                    ?? placemarks?.first?.subLocality
                self?.finish(city?.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }

    private func requestLocationOnce() {
        guard !didRequestLocation else { return }
        didRequestLocation = true
        manager.requestLocation()
    }

    private func finish(_ city: String?) {
        guard let continuation else { return }
        self.continuation = nil
        manager.stopUpdatingLocation()
        let normalized = city?.trimmingCharacters(in: .whitespacesAndNewlines)
        continuation.resume(returning: normalized?.isEmpty == false ? normalized : nil)
    }
}

/// Edge routing: when Apple's on-device model is available, the phone guesses the request's route
/// itself and sends it as `intentHint`, so the backend can skip its paid 20b router call. It is only
/// a hint - the backend validates it exactly like its own router's output, keeps every policy check,
/// and never lets it ask the user a question. Returns JSON in route_intent's shape, or nil.
enum WiqoOnDeviceRouter {
    private static let timeout: Duration = .milliseconds(1_000)

    static func hint(for message: String) async -> Data? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4, text.count <= 1_200 else { return nil }
        #if canImport(FoundationModels)
        // iPhone 13/14 and other devices without Apple Intelligence (or with it turned off) stop
        // here at no cost: no hint is sent and the backend routes the request as before.
        if #available(iOS 26.0, *), WiqoOnDeviceIntentModel.isUsable {
            return await withTaskGroup(of: Data?.self) { group in
                group.addTask { await WiqoOnDeviceIntentModel.route(text) }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
enum WiqoOnDeviceIntentModel {
    @Generable
    enum IntentClass: String {
        case conversation, information, research, cloud_read, cloud_write, pc_action, terminal_action, document_project, automation_setup, automation_manage, clarification, other_task
    }

    @Generable
    enum Target: String {
        case chat, cloud_tool, pc, project, automation, research, clarification
    }

    @Generable
    enum Freshness: String {
        case none, current
    }

    @Generable
    enum SideEffect: String {
        case none, read, write, device
    }

    @Generable
    enum ToolGroup: String {
        case cloud, documents, images, code, automation, tasks, browser, research
    }

    @Generable
    enum ProjectKind: String {
        case website, document, presentation, images, none
    }

    @Generable
    struct Decision {
        @Guide(description: "İsteğin türü. Tekrarlı zamanlama veya hatırlatma automation_setup'tır; belge adı bunu değiştirmez.")
        let intentClass: IntentClass
        @Guide(description: "İşin yürütüleceği yer.")
        let target: Target
        @Guide(description: "Güncel/canlı bilgi gerekiyorsa current.")
        let freshness: Freshness
        let sideEffect: SideEffect
        @Guide(description: "Gerekli araç grupları; en az olanı seç.", .maximumCount(4))
        let candidateToolGroups: [ToolGroup]
        @Guide(description: "Çok uzun belge, sunum, web sitesi veya görsel seti ise türü; değilse none.")
        let projectKind: ProjectKind
        @Guide(description: "Karardan ne kadar eminsin.", .range(0.0...1.0))
        let confidence: Double
    }

    private static let instructions = """
    Wiqo asistanına gelen bir isteği yalnızca sınıflandırırsın; işi yapmaz, araç çağırmaz, yetki vermezsin. \
    Kullanıcının kendi PC/dosya kapsamı güncellik gerektirmez. Olumsuz istek ("gönderme") sohbettir. \
    Emin değilsen düşük confidence ver.
    """

    /// Checked on every request (cheap): the user can turn Apple Intelligence on or off at any time.
    static var isUsable: Bool {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return false }
        return model.supportsLocale(Locale(identifier: "tr_TR"))
    }

    static func route(_ message: String) async -> Data? {
        let model = SystemLanguageModel.default
        guard isUsable else { return nil }
        do {
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(
                to: message,
                generating: Decision.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 160)
            )
            let decision = response.content
            let value: [String: Any] = [
                "intentClass": decision.intentClass.rawValue,
                "target": decision.target.rawValue,
                "freshness": decision.freshness.rawValue,
                "sideEffect": decision.sideEffect.rawValue,
                "clarificationQuestion": "",
                "candidateToolGroups": decision.candidateToolGroups.map(\.rawValue),
                "reason": "model_classification",
                "confidence": decision.confidence,
                "projectKind": decision.projectKind.rawValue,
                "projectTitle": ""
            ]
            return try JSONSerialization.data(withJSONObject: value)
        } catch {
            return nil
        }
    }
}
#endif
