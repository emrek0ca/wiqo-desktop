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
        case .notAuthenticated: return String(localized: "Önce Wiqo hesabına giriş yap.")
        case .network(let message): return message
        case .invalidResponse: return String(localized: "Sunucudan geçersiz bir yanıt alındı. Lütfen tekrar dene.")
        case .declined(let reason): return reason
        case .copilotPayloadTooLarge: return String(localized: "Eklerin toplam boyutu çok büyük. Daha az dosya veya görsel ekleyip tekrar dene.")
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
    static let tokenAccount = "rova-backend-token"
    /// Mirrors rova-backend's chat file-content contract and leaves room under express.json's 20 MB cap.
    static let maxFileContentsPayloadBytes = 6_000_000
    static let maxAttachmentContentsPayloadBytes = 19_000_000
    static let maxCopilotRequestBodyBytes = 19_500_000
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

    static func mobileReadCacheKey(_ path: String) -> String {
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

    static var tokenPayload: [String: Any]? {
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
            throw RovaBackendError.declined(nonEmptyMessage(decoded.message, fallback: String(localized: "Şifre sıfırlama isteği tamamlanamadı.")))
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

    static func authenticate(path: String, email: String, password: String, inviteCode: String? = nil) async throws -> String {
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
        enum Kind: String, Codable {
            case created_resource, code_change, weather, sources, artifact, task_result, task_plan, approval, clarification, error, list, table, map, card, inline_app, act_handoff, unknown

            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer().decode(String.self)
                self = Kind(rawValue: value) ?? .unknown
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(rawValue)
            }
        }
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

        struct TablePreview: Codable, Hashable, Sendable {
            let columns: [String]
            let rows: [[String]]
            let totalRows: Int
        }

        /// One row of a connector card (mail, event, file, page, person).
        struct ListItem: Codable, Hashable, Sendable {
            let id: String?
            let title: String
            let subtitle: String?
            let detail: String?
            let meta: String?
            let badge: String?
            /// ISO start/end for calendar items; the card groups them by day.
            let start: String?
            let end: String?
            let url: String?
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
        /// Stable backend identity used for deterministic merge/dedup across SSE, polling and
        /// history. These are optional for messages written by older backend versions.
        let widgetId: String?
        let version: Int?
        let state: String?
        let summary: String?
        let current: WeatherCurrent?
        let hourly: [WeatherHour]?
        let days: [WeatherDay]?
        let sources: [Source]?
        let artifactId: String?
        let variant: String?
        let mimeType: String?
        let byteCount: Int?
        let tablePreview: TablePreview?
        let taskId: String?
        /// clarification: a question the running task is waiting on. The answer goes back with `taskId` and `questionId` unchanged.
        let questionId: String?
        let question: String?
        let options: [String]?
        let capability: String?
        struct PlanRow: Codable, Hashable, Sendable, Identifiable {
            let id: String
            let title: String
            let expectedResult: String
            let dependsOn: [String]
            let status: String
            let message: String?
        }
        let planSteps: [PlanRow]?
        let taskStatus: String?
        let completedSteps: Int?
        let totalSteps: Int?
        let confirmationId: String?
        let expiresAt: String?
        let code: String?
        let category: String?
        let message: String?
        let retryable: Bool?
        /// list: which connected service (mail, calendar, drive, notion, contacts) and its rows.
        let domain: String?
        let items: [ListItem]?
        let total: Int?
        /// table: spreadsheet rows.
        let columns: [String]?
        let rows: [[String]]?
        let totalRows: Int?
        /// code_change: the project's version after this change, and whether the change was checked.
        let projectVersion: Int?
        let verified: Bool?
        /// map: what to show (place, route, search, traffic); the phone resolves it with Apple Maps.
        let mode: String?
        let query: String?
        let origin: String?
        let destination: String?
        let transport: String?
        let near: String?
        let traffic: Bool?
        let url: String?
        /// card: one small self-contained card; each kind uses only its own fields.
        let kind: String?
        let subtitle: String?
        let seconds: Double?
        let quotes: [CardQuote]?
        let matches: [CardMatch]?
        let sourceLang: String?
        let targetLang: String?
        let original: String?
        let translated: String?
        let expression: String?
        let result: String?
        let servings: Double?
        let minutes: Double?
        let ingredients: [String]?
        let directions: [CardStep]?
        let tripDays: [CardDay]?
        let service: String?
        let checklist: [String]?
        let contactQuery: String?
        /// inline_app: one self-contained HTML document the phone runs in an isolated sandbox, and its preferred height.
        let html: String?
        let height: Double?
        /// inline_app: JSON handed to the page as `wiqo.data`, the libraries the phone injects, the card this one replaces and the key of its saved state.
        let data: String?
        let libs: [String]?
        let replaces: String?
        let stateKey: String?
        /// act_handoff: what to start in Act (a new project or a change to the open one) and which project it applies to.
        let request: String?
        let operation: String?
        let projectId: String?
        let projectKind: String?
        let projectName: String?
    }

    struct CardQuote: Codable, Hashable, Sendable {
        let symbol: String
        let name: String
        let price: Double
        let changePercent: Double?
        let unit: String?
        let series: [Double]?
    }

    struct CardMatch: Codable, Hashable, Sendable {
        let league: String?
        let home: String
        let away: String
        let homeScore: Int?
        let awayScore: Int?
        let status: String
        let when: String?
    }

    struct CardStep: Codable, Hashable, Sendable {
        let text: String
        let seconds: Double?
    }

    struct CardTripItem: Codable, Hashable, Sendable {
        let time: String?
        let title: String
        let place: String?
        let note: String?
    }

    struct CardDay: Codable, Hashable, Sendable {
        let title: String
        let items: [CardTripItem]
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
        let isPrimary: Bool?
        let cron: String?
        let nextRunAt: String?
        let lastRunAt: String?
        let memory: String
    }

    /// What the primary agent watches (opt-in) and what it noticed (backend agent/events.ts).
    struct WatchSource: Decodable, Identifiable, Sendable {
        let source: String
        let enabled: Bool
        let lastError: String?
        var id: String { source }
    }

    struct AgentEvent: Decodable, Identifiable, Sendable {
        let id: Int
        let source: String
        let title: String
        let status: String
        let summary: String?
    }

    struct AgentBudget: Decodable, Sendable {
        let paused: Bool
        let usedTokens: Int
        let limitTokens: Int
        let tasksToday: Int
    }

    struct AgentAuditEntry: Decodable, Identifiable, Sendable {
        let id: Int
        let kind: String
        let summary: String
        let createdAt: String
    }

    /// The first version of Act kept projects on the server in plaintext. Only what the one-time move to
    /// sealed projects needs is left (see ActModel.migrateLegacyIfNeeded): list, read, delete.
    struct CodeProject: Decodable, Identifiable, Sendable {
        let id: Int
        let name: String
        let kind: String
        let version: Int
        let updatedAt: String
        let fileCount: Int?
    }

    struct CodeProjectSnapshot: Decodable, Sendable {
        struct Header: Decodable, Sendable { let id: Int; let name: String; let kind: String; let version: Int }
        struct File: Decodable, Sendable { let path: String; let content: String }
        let project: Header
        let files: [File]
    }

    static func fetchCodeProjects() async throws -> [CodeProject] {
        struct Response: Decodable { let projects: [CodeProject] }
        return try await authorizedGet("code-projects", as: Response.self).projects
    }

    static func fetchCodeProjectSnapshot(id: Int) async throws -> CodeProjectSnapshot {
        try await authorizedGet("code-projects/\(id)/snapshot", as: CodeProjectSnapshot.self)
    }

    static func deleteCodeProject(id: Int) async throws {
        _ = try await authorizedMutate("code-projects/\(id)", method: "DELETE")
    }

    struct StandingRule: Decodable, Identifiable, Sendable {
        let tool: String
        let label: String
        let enabled: Bool
        var id: String { tool }
    }

    static func fetchStandingRules() async throws -> [StandingRule] {
        struct Response: Decodable { let rules: [StandingRule] }
        return try await authorizedGet("agents/standing", as: Response.self).rules
    }

    static func setStandingRule(_ tool: String, enabled: Bool) async throws -> [StandingRule] {
        struct Response: Decodable { let rules: [StandingRule] }
        let data = try await authorizedPut("agents/standing/\(tool)", body: ["enabled": enabled])
        return try JSONDecoder().decode(Response.self, from: data).rules
    }

    static func sendEventFeedback(id: Int, important: Bool) async throws {
        struct Response: Decodable { let ok: Bool }
        _ = try await authorizedPost("agents/events/\(id)/feedback", body: ["kind": important ? "important" : "unimportant"], as: Response.self)
    }

    static func fetchAgentBudget() async throws -> AgentBudget {
        try await authorizedGet("agents/budget", as: AgentBudget.self)
    }

    static func setAgentPaused(_ paused: Bool) async throws -> AgentBudget {
        let data = try await authorizedPut("agents/pause", body: ["paused": paused])
        return try JSONDecoder().decode(AgentBudget.self, from: data)
    }

    static func fetchAgentAudit() async throws -> [AgentAuditEntry] {
        struct Response: Decodable { let entries: [AgentAuditEntry] }
        return try await authorizedGet("agents/audit", as: Response.self).entries
    }

    static func fetchWatchSources() async throws -> [WatchSource] {
        struct Response: Decodable { let sources: [WatchSource] }
        return try await authorizedGet("agents/watch", as: Response.self).sources
    }

    static func setWatchSource(_ source: String, enabled: Bool) async throws -> [WatchSource] {
        struct Response: Decodable { let sources: [WatchSource] }
        let data = try await authorizedPut("agents/watch/\(source)", body: ["enabled": enabled])
        return try JSONDecoder().decode(Response.self, from: data).sources
    }

    static func fetchAgentEvents() async throws -> [AgentEvent] {
        struct Response: Decodable { let events: [AgentEvent] }
        return try await authorizedGet("agents/events", as: Response.self).events
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

    struct CopilotStepResponse: Decodable {
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

    /// The terminal SSE event and the cached request must decode the same plan. Keeping this
    /// outside `converse` lets the wire contract be exercised without a live account or Mac.
    struct CopilotDoneEvent: Decodable {
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

    static func decodeCopilotDone(_ data: Data) throws -> ConverseResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(CopilotDoneEvent.self, from: data)
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
    }

    static func decodeCompletedCopilotStatus(_ data: Data) throws -> ConverseResult {
        let state = try JSONDecoder().decode(CopilotStatusResponse.self, from: data)
        guard state.status == "done", let response = state.response else { throw RovaBackendError.invalidResponse }
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
        taskID: UUID? = nil,
        /// Set when this message answers a clarification card: the card's own task and question ids go out unchanged.
        clarification: ClarificationAnswer? = nil,
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
        onWidgetUpdate: @escaping @MainActor @Sendable (CopilotResultWidget) -> Void = { _ in },
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
        var body: [String: Any] = [
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
            "clientFeatures": ["artifact-directory-v1"],
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
                if let error = result.error {
                    value["error"] = error.message
                    value["errorCode"] = error.code
                }
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
        Self.applyTaskIdentity(to: &requestBody, taskID: taskID, clarification: clarification)
        // What the person reads (replies, cards, notifications) is written in the phone's language.
        requestBody["locale"] = Locale.preferredLanguages.first ?? "tr"
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
        struct ConfirmationNeededEvent: Decodable {
            let steps: [CopilotStepResponse]
            let backendConfirmations: [BackendConfirmation]?
        }
        struct StepUpdateEvent: Decodable {
            let step: ExecutionStepUpdate
        }
        struct WidgetUpdateEvent: Decodable { let widget: CopilotResultWidget }
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
                case "widget_update":
                    if let event = try? decoder.decode(WidgetUpdateEvent.self, from: json) {
                        await onWidgetUpdate(event.widget)
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
                        await onStatus(event.prompt ?? String(localized: "Hava durumu için konum izni bekleniyor…"))
                        await requestLocationOnce(event.requestId)
                    }
                case "reset":
                    await onReset()
                case "done":
                    return try decodeCopilotDone(json)
                case "error":
                    let event = try? decoder.decode(ErrorEvent.self, from: json)
                    let message = nonEmptyMessage(event?.message, fallback: String(localized: "İstek anlaşılamadı."))
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

    static func makeConverseResult(
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
            let localPresence = RovaCommandAuthority.requiresUserPresence(type: step.type, payload: step.payload, autoReadOwnFolders: WiqoApprovalPreferences.autoReadOwnFolders)
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

    /// The two ids that tie a request to its task. An answer to a clarification card carries the card's ids verbatim (no new task id).
    struct ClarificationAnswer: Equatable, Sendable {
        let taskId: String
        let questionId: String
    }

    static func applyTaskIdentity(to body: inout [String: Any], taskID: UUID?, clarification: ClarificationAnswer?) {
        if let clarification {
            body["taskId"] = clarification.taskId
            body["questionId"] = clarification.questionId
        } else if let taskID {
            body["taskId"] = taskID.uuidString
        }
    }

    static func waitForCopilotRequest(
        requestID: UUID,
        onStatus: @escaping @MainActor @Sendable (String) -> Void,
        onLocationRequired: @escaping @MainActor @Sendable (String) async -> Void
    ) async throws -> ConverseResult {
        await onStatus(String(localized: "Bağlantı koptu; Wiqo işlemin sonucunu koruyor…"))
        let deadline = Date().addingTimeInterval(150)
        var missingCount = 0
        var malformedCount = 0
        var locationRequestHandled = false
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            do {
                let state = try await authorizedGet("copilot/requests/\(requestID.uuidString)", as: CopilotStatusResponse.self)
                if state.status != "done" || state.response != nil { malformedCount = 0 }
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
                    throw RovaBackendError.declined(nonEmptyMessage(state.error?.message, fallback: String(localized: "İşlem tamamlanamadı.")))
                case "awaiting_weather_location":
                    if !locationRequestHandled, let required = state.response?.locationRequired {
                        locationRequestHandled = true
                        await onLocationRequired(required.requestId)
                    } else {
                        await onStatus(String(localized: "Hava durumu isteği devam ediyor…"))
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                default:
                    await onStatus(String(localized: "İşlem bağlantıdan bağımsız devam ediyor…"))
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch RovaBackendError.network(let message) where message == "İşlem bulunamadı." {
                missingCount += 1
                if missingCount >= 3 { throw RovaBackendError.network(message) }
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch RovaBackendError.invalidResponse {
                // A gateway can return a transient non-JSON 200 while the durable result is
                // already committed. Retry only this read; never post the side effect again.
                malformedCount += 1
                if malformedCount >= 3 { throw RovaBackendError.invalidResponse }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw RovaBackendError.network(String(localized: "İşlem sunucuda devam ediyor olabilir. Sohbete dönüp tekrar kontrol edebilirsin."))
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
        guard !audioData.isEmpty, audioData.count <= 12_000_000 else { throw RovaBackendError.declined(String(localized: "Ses dosyası desteklenen boyut sınırını aşıyor.")) }
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
            "clientFeatures": ["artifact-directory-v1"],
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
            let localPresence = RovaCommandAuthority.requiresUserPresence(type: step.type, payload: step.payload, autoReadOwnFolders: WiqoApprovalPreferences.autoReadOwnFolders)
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

    /// A PC task of this conversation that stopped on a failed step, if it is still fresh.
    struct OpenWork: Decodable, Equatable { let goal: String; let detail: String }

    static func fetchOpenWork(conversationID: String) async throws -> OpenWork? {
        struct Response: Decodable { let openWork: OpenWork? }
        return try await authorizedGet("conversations/\(conversationID)/open-work", as: Response.self).openWork
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

    // MARK: - Shared plumbing

    static func authorizedGet<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        guard let token else { throw RovaBackendError.notAuthenticated }
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        if response.statusCode == 401 { signOut(); throw RovaBackendError.notAuthenticated }
        return try decode(T.self, from: data, response: response)
    }

    static func authorizedPost<T: Decodable>(_ path: String, body: [String: Any], as type: T.Type, timeout: TimeInterval? = nil, missingRouteMessage: String? = nil) async throws -> T {
        guard let token else { throw RovaBackendError.notAuthenticated }
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent(path))
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await send(request)
        if response.statusCode == 401 { signOut(); throw RovaBackendError.notAuthenticated }
        if response.statusCode == 404, let missingRouteMessage, serverErrorMessage(from: data) == nil {
            throw RovaBackendError.network(missingRouteMessage)
        }
        return try decode(T.self, from: data, response: response)
    }

    static func authorizedPut(_ path: String, body: [String: Any]) async throws -> Data {
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
    static func authorizedMutate(_ path: String, method: String) async throws -> Data {
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

    static func authorizedJSON(_ path: String, method: String, body: Data, timeout: TimeInterval = 60) async throws -> Data {
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
            throw RovaBackendError.network(response.statusCode == 404 ? String(localized: "Dosyanın süresi dolmuş; yeniden oluşturmamı isteyebilirsin.") : "Dosya indirilemedi.")
        }
        guard sha256Hex(data) == artifact.sha256.lowercased() else {
            throw RovaBackendError.network(String(localized: "Dosya bütünlük doğrulamasını geçemedi."))
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: destination, options: [.atomic])
        return destination
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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

    static func isRepeatable(_ request: URLRequest) -> Bool {
        (request.httpMethod ?? "GET") == "GET"
    }

    static func isDroppedConnection(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed: return true
        default: return false
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, response: HTTPURLResponse) throws -> T {
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

    static func userFacingNetworkMessage(for error: Error) -> String {
        guard let urlError = error as? URLError else {
            return String(localized: "Wiqo sunucusuna ulaşılamadı. Lütfen internet bağlantını kontrol edip tekrar dene.")
        }
        switch urlError.code {
        case .notConnectedToInternet:
            return String(localized: "İnternet bağlantısı yok. Bağlantını kontrol edip tekrar dene.")
        case .timedOut:
            return String(localized: "Wiqo sunucusu zamanında yanıt vermedi. Biraz sonra tekrar dene.")
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed:
            return String(localized: "Wiqo sunucusuna bağlanılamadı. Biraz sonra tekrar dene.")
        default:
            return String(localized: "Wiqo sunucusuna bağlanırken bir sorun oluştu. Lütfen tekrar dene.")
        }
    }

    static func userFacingHTTPMessage(for statusCode: Int) -> String {
        switch statusCode {
        case 400:
            return String(localized: "Gönderdiğin bilgiler geçersiz. Lütfen kontrol edip tekrar dene.")
        case 401:
            return String(localized: "Oturumun geçersiz veya süresi dolmuş. Lütfen tekrar giriş yap.")
        case 403:
            return String(localized: "Bu işlem için yetkin yok.")
        case 404:
            return String(localized: "İstenen Wiqo kaydı bulunamadı.")
        case 409:
            return String(localized: "Bu istek zaten işleniyor. Biraz sonra tekrar dene.")
        case 429:
            return String(localized: "Çok fazla istek yapıldı. Biraz sonra tekrar dene.")
        case 500:
            return String(localized: "Wiqo sunucusunda beklenmeyen bir hata oluştu. Lütfen tekrar dene.")
        case 502, 503, 504:
            return String(localized: "Wiqo sunucusu şu anda kullanılamıyor. Biraz sonra tekrar dene.")
        default:
            return String(localized: "Wiqo sunucusu isteği tamamlayamadı. Lütfen tekrar dene.")
        }
    }

    static func nonEmptyMessage(_ message: String?, fallback: String) -> String {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    static func serverErrorMessage(from data: Data) -> String? {
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
    static func appendingErrorCode(_ message: String, code: String?) -> String {
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
final class WiqoMobileReadCache: @unchecked Sendable {
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
    static let timeout: Duration = .milliseconds(1_000)

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
    enum DeviceOperation: String {
        case none, list_running_applications, control_application, close_managed_browser
    }

    @Generable
    enum ProjectKind: String {
        case website, document, presentation, images, none
    }

    @Generable
    struct Decision {
        @Guide(description: String(localized: "İsteğin türü. Tekrarlı zamanlama veya hatırlatma automation_setup'tır; belge adı bunu değiştirmez."))
        let intentClass: IntentClass
        @Guide(description: String(localized: "İşin yürütüleceği yer."))
        let target: Target
        @Guide(description: String(localized: "Güncel/canlı bilgi gerekiyorsa current."))
        let freshness: Freshness
        let sideEffect: SideEffect
        @Guide(description: String(localized: "Gerekli araç grupları; en az olanı seç."), .maximumCount(4))
        let candidateToolGroups: [ToolGroup]
        @Guide(description: String(localized: "PC isteğinin dar semantik işlemi: açık uygulamaları sorma=list_running_applications; normal uygulama kontrolü=control_application; Wiqo görev tarayıcısını veya Google Chrome for Testing'i kapatma=close_managed_browser; diğerleri=none."))
        let deviceOperation: DeviceOperation
        @Guide(description: String(localized: "Çok uzun belge, sunum, web sitesi veya görsel seti ise türü; değilse none."))
        let projectKind: ProjectKind
        @Guide(description: String(localized: "Karardan ne kadar eminsin."), .range(0.0...1.0))
        let confidence: Double
    }

    static let instructions = """
    Wiqo asistanına gelen bir isteği yalnızca sınıflandırırsın; işi yapmaz, araç çağırmaz, yetki vermezsin. \
    Kullanıcının kendi PC/dosya kapsamı güncellik gerektirmez. Olumsuz istek ("gönderme") sohbettir. \
    PC'de açık/çalışan uygulamaları soran farklı günlük ifadeleri aynı list_running_applications anlamında sınıflandır. \
    Wiqo'nun görünür görev tarayıcısını ve Google Chrome for Testing'i kapatma isteğini close_managed_browser seç. \
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
                "deviceOperation": decision.deviceOperation.rawValue,
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
