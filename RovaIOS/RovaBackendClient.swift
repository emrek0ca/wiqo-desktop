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
    static let baseURL = URL(string: "https://84-247-172-213.sslip.io")!
}

enum RovaBackendError: Error, LocalizedError {
    case notAuthenticated
    case network(String)
    case invalidResponse
    case declined(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Önce Rova hesabına giriş yap."
        case .network(let message): return message
        case .invalidResponse: return "Sunucudan geçersiz yanıt alındı."
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

    static var isAuthenticated: Bool { token != nil }

    static var token: String? {
        guard let data = try? RovaKeychainStore.load(account: tokenAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func signOut() {
        try? RovaKeychainStore.delete(account: tokenAccount)
    }

    @discardableResult
    static func register(email: String, password: String) async throws -> String {
        try await authenticate(path: "auth/register", email: email, password: password)
    }

    @discardableResult
    static func login(email: String, password: String) async throws -> String {
        try await authenticate(path: "auth/login", email: email, password: password)
    }

    private static func authenticate(path: String, email: String, password: String) async throws -> String {
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])

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

    struct ArtifactDescriptor: Decodable, Identifiable, Equatable {
        let id: String
        let kind: String
        let filename: String
        let mimeType: String
        let byteCount: Int
        let sha256: String
        let downloadURL: URL
        let expiresAt: String
    }

    struct ConverseResult {
        let reply: String
        let steps: [PlannedCommand]
        let executionState: String?
        let artifacts: [ArtifactDescriptor]
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
        conversationID: String = "default",
        turnCount: Int? = nil,
        deviceResults: [DeviceExecutionResult] = [],
        requestID: UUID = UUID(),
        attachments: [ChatAttachment] = [],
        onStatus: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> ConverseResult {
        guard let token else { throw RovaBackendError.notAuthenticated }
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent("copilot/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The backend caps its own work at 45s and always emits a terminal event by then; this
        // just needs enough margin on top of that for a slow mobile network.
        request.timeoutInterval = 90
        let body: [String: Any] = [
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "availableApps": availableApps.map(\.rawValue),
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
                if let error = result.error { value["error"] = error.message }
                if let dataText = result.dataText { value["dataText"] = dataText }
                return value
            }
        ]
        var requestBody = body
        if let turnCount { requestBody["turnCount"] = turnCount }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [.fragmentsAllowed])

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw RovaBackendError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw RovaBackendError.invalidResponse }
        if http.statusCode == 401 {
            signOut()
            throw RovaBackendError.notAuthenticated
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RovaBackendError.network("İstek başarısız oldu (kod \(http.statusCode)).")
        }

        struct StepResponse: Decodable {
            let id: UUID?
            let type: CommandType
            let payload: CommandPayload
            let summary: String
            let isDestructive: Bool
            let requiresUserPresence: Bool?
        }
        struct StatusEvent: Decodable { let text: String }
        struct DoneEvent: Decodable { let reply: String; let steps: [StepResponse]; let executionState: String?; let artifacts: [ArtifactDescriptor]? }
        struct ErrorEvent: Decodable { let message: String }
        struct EventKind: Decodable { let type: String }
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
                        onStatus(event.text)
                    }
                case "done":
                    let event = try decoder.decode(DoneEvent.self, from: json)
                    let steps = event.steps.map {
                        PlannedCommand(
                            id: $0.id ?? UUID(),
                            type: $0.type,
                            payload: $0.payload,
                            summary: $0.summary,
                            isDestructive: $0.isDestructive,
                            requiresUserPresence: $0.requiresUserPresence == true || $0.isDestructive || requiresLocalPresence(for: $0.type)
                        )
                    }
                    return ConverseResult(reply: event.reply, steps: steps, executionState: event.executionState, artifacts: event.artifacts ?? [])
                case "error":
                    let event = try? decoder.decode(ErrorEvent.self, from: json)
                    throw RovaBackendError.declined(event?.message ?? "İstek anlaşılamadı.")
                default:
                    continue
                }
            }
        } catch let error as RovaBackendError {
            throw error
        } catch {
            throw RovaBackendError.network(error.localizedDescription)
        }
        throw RovaBackendError.invalidResponse
    }

    struct DeviceExecutionResult: Codable {
        let stepID: UUID
        let type: CommandType
        let status: CommandStatus
        let message: String
        let error: RovaError?
        let dataText: String?

        init(stepID: UUID, type: CommandType, status: CommandStatus, message: String, error: RovaError?, dataText: String? = nil) {
            self.stepID = stepID
            self.type = type
            self.status = status
            self.message = message
            self.error = error
            self.dataText = dataText
        }
    }

    static func refreshProactiveSuggestions() async throws -> [ProactiveSuggestion] {
        struct Response: Decodable { let suggestions: [ProactiveSuggestion] }
        return try await authorizedPost("proactive/refresh", body: [:], as: Response.self).suggestions
    }

    static func updateProactiveSuggestion(id: Int, action: String) async throws {
        guard action == "accept" || action == "dismiss" else { return }
        _ = try await authorizedMutate("proactive/suggestions/\(id)/\(action)", method: "POST")
    }

    private static func requiresLocalPresence(for type: CommandType) -> Bool {
        switch type {
        case .lockMac, .sleepMac, .displaySleep, .quitApplication, .saveTextFile,
             .sendMessage, .createCalendarEvent, .moveDesktopFile, .renameDesktopFile,
             .saveArtifact, .editDocument:
            return true
        default:
            return false
        }
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
            let message = (try? JSONDecoder().decode(BackendErrorEnvelope.self, from: data))?.error.message
            throw RovaBackendError.network(message ?? "İstek başarısız oldu (kod \(response.statusCode)).")
        }
        return data
    }

    // MARK: - Shared plumbing

    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RovaBackendError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw RovaBackendError.invalidResponse }
        return (data, http)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, response: HTTPURLResponse) throws -> T {
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(BackendErrorEnvelope.self, from: data))?.error.message
            if response.statusCode == 422 {
                throw RovaBackendError.declined(message ?? "İstek anlaşılamadı.")
            }
            throw RovaBackendError.network(message ?? "İstek başarısız oldu (kod \(response.statusCode)).")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RovaBackendError.invalidResponse
        }
    }
}

private struct BackendErrorEnvelope: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
}
