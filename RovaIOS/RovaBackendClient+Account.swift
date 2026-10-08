import Foundation

/// Profile, conversation history backup and the canvas: the account's own data on the backend.
extension RovaBackendClient {
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
                throw RovaBackendError.declined(nonEmptyMessage(task.error, fallback: String(localized: "Kod çalıştırma tamamlanamadı.")))
            case "cancelled":
                throw RovaBackendError.declined(String(localized: "Kod çalıştırma iptal edildi."))
            default:
                if let progress = task.progress, !progress.isEmpty { await onProgress(progress) }
                try await Task.sleep(nanoseconds: 350_000_000)
            }
        }
        throw RovaBackendError.network(String(localized: "Kod çalıştırma beklenenden uzun sürdü. İstersen tekrar deneyebilirsin."))
    }

    private static func fetchQueueTask(id: Int) async throws -> QueueTask {
        try await authorizedGet("queue/\(id)", as: QueueTask.self)
    }

    static func cancelCanvasRun(taskID: Int) async throws {
        _ = try await authorizedMutate("queue/\(taskID)/cancel", method: "POST")
    }
}
