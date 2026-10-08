import Foundation

/// Tasks, scheduled automations and their runs: created in conversation, managed here.
extension RovaBackendClient {
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

    struct DeferredTaskDetail: Decodable, Sendable {
        let status: String
        let message: String
        let finished: Bool
    }

    static func fetchDeferredTask(id: Int) async throws -> DeferredTaskDetail {
        try await authorizedGet("devices/pending-tasks/\(id)", as: DeferredTaskDetail.self)
    }

    static func cancelDeferredTask(id: Int) async throws -> DeferredCancellationResponse {
        let data = try await authorizedMutate("devices/pending-tasks/\(id)", method: "DELETE")
        return try JSONDecoder().decode(DeferredCancellationResponse.self, from: data)
    }

    static func cancelAutomation(id: Int) async throws {
        _ = try await authorizedMutate("automations/\(id)", method: "DELETE")
        reconcileLocalReminders()
    }
}
