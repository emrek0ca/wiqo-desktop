import Foundation

enum BackendConfirmationStatus: Equatable {
    case pending
    case processing
    case completed
    case cancelled
    case failed
}

enum LiveExecutionStatus: String {
    case ready
    case awaitingConfirmation = "awaiting_confirmation"
    case dispatching
    case running
    case succeeded
    case failed
    case denied
    case blocked
}

enum LocalExecutionAdvanceResult {
    case awaitingConfirmation
    case completed
    case failed
}

struct BackendConfirmationRow: Identifiable, Equatable {
    var confirmation: RovaBackendClient.BackendConfirmation
    var status: BackendConfirmationStatus = .pending
    var resultText: String?
    var resultDetail: String? = nil
    var artifacts: [RovaBackendClient.ArtifactDescriptor] = []

    var id: UUID { confirmation.id }
}

struct ChatBubble: Identifiable {
    enum Role { case user, assistant, system }

    let id = UUID()
    let role: Role
    var text: String
    var errorDetail: String? = nil
    var steps: [PlannedCommand] = []
    var needsConfirmation = false
    var executedStepIDs: Set<UUID> = []
    var inFlightStepIDs: Set<UUID> = []
    var artifacts: [RovaBackendClient.ArtifactDescriptor] = []
    var widgets: [RovaBackendClient.CopilotResultWidget] = []
    /// The task this turn continues (the id of an answered clarification card); nil means the bubble's own id is the task.
    var taskID: UUID? = nil
    var executionState: String? = nil
    var backendConfirmations: [BackendConfirmationRow] = []
    var executionUpdates: [UUID: RovaBackendClient.ExecutionStepUpdate] = [:]
    /// Small (max-240px-side) JPEG thumbnails of what the user attached to this message - kept
    /// deliberately tiny since these persist in local chat history (see CopilotStoredMessage)
    /// rather than the full upload-quality copy already sent to the backend.
    var attachmentThumbnails: [Data] = []
    /// Names of files attached to this user message; shown as chips above it.
    var attachedFileNames: [String] = []
    /// Populated when the Mac actually rejects/fails a step - the model's reply text is written
    /// optimistically before execution happens, so this is the only place a real failure (a
    /// permission denial, a full disk, anything) becomes visible instead of silently vanishing
    /// behind a reply that already claimed success.
    var failedSteps: [UUID: String] = [:]
    /// Populated only for `.executeCode` steps once the Mac returns a result - drives the
    /// collapsible code/output card instead of dumping raw stdout into the reply text.
    var codeRuns: [UUID: ProcessOutputContent] = [:]
    /// The Mac's real CommandResult for every non-executeCode step, keyed by step id - what
    /// drives each row's live detail/result line in executionWidget. In-memory only, exactly like
    /// codeRuns/failedSteps above: after a restart, only the short summary line folded into
    /// `text` (see execute()) survives, not this per-step detail.
    var stepResults: [UUID: CommandResult] = [:]
    /// `text` is only the backend's "doing it now" line; once the steps finish with nothing left
    /// for the model to read, it is replaced by the verified outcome (DeviceOutcomeNarrator).
    var replyIsProgress = false
    /// What Wiqo went through to produce this reply; nil for plain chat and older messages.
    var thinking: ThinkingTrace? = nil
    /// PC work queued for when the PC comes online; shown under the reply with a cancel control.
    var deferredTask: RovaBackendClient.DeferredTask? = nil
    /// A background project this reply started; its live card sits under the reply.
    var projectTask: RovaBackendClient.ProjectTask? = nil
    var agentTask: RovaBackendClient.AgentTaskRef? = nil
    /// What the running project has done so far, told in the reply itself (in memory only; the
    /// verified summary replaces it when the project finishes).
    var projectNarrative: [RovaBackendClient.ProjectDetail.Event] = []
    var projectLiveLine: String? = nil
}

extension RovaBackendClient.CopilotResultWidget {
    var stableID: String {
        if let widgetId, !widgetId.isEmpty { return widgetId }
        switch type {
        case .created_resource:
            return "created:\(resourceType?.rawValue ?? "unknown"):\(id.map { String($0) } ?? "unknown")"
        case .code_change:
            return "code:\(id.map { String($0) } ?? "unknown"):\(projectVersion.map { String($0) } ?? "0")"
        case .weather:
            return "weather:\((location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        case .sources:
            return "sources"
        case .artifact:
            return "artifact:\(artifactId ?? "unknown")"
        case .task_plan:
            return "plan:\(taskId ?? widgetId ?? "unknown")"
        case .task_result:
            return "task:\(taskId ?? widgetId ?? "unknown")"
        case .approval:
            return "approval:\(confirmationId ?? widgetId ?? "unknown")"
        case .clarification:
            return "question:\(questionId ?? widgetId ?? "unknown")"
        case .error:
            return "error:\(taskId ?? widgetId ?? "unknown")"
        case .list:
            return "list:\(domain ?? "unknown")"
        case .table:
            return "table:\((title ?? "").lowercased())"
        case .inline_app:
            return "inlineapp:\((title ?? "").lowercased()):\(html?.count ?? 0)"
        case .act_handoff:
            return "act:\(operation ?? ""):\(String((request ?? "").prefix(80)).lowercased())"
        case .card:
            return "card:\(kind ?? ""):\((title ?? "").lowercased())|\((query ?? contactQuery ?? original ?? expression ?? seconds.map { String(Int($0)) } ?? "").lowercased())"
        case .map:
            return "map:\(mode ?? ""):\((origin ?? "").lowercased())>\((destination ?? query ?? near ?? "").lowercased())"
        case .unknown:
            return "unknown"
        }
    }
}

/// The single client-side merge point for typed result cards. SSE, polling, and history can all
/// deliver the same verified widget; the catalog keeps one card per real resource/location and
/// never parses assistant text to decide what to show.
enum CopilotWidgetCatalog {
    static func normalized(_ widgets: [RovaBackendClient.CopilotResultWidget]) -> [RovaBackendClient.CopilotResultWidget] {
        var result: [RovaBackendClient.CopilotResultWidget] = []
        var indexes: [String: Int] = [:]
        for widget in widgets {
            // The current confirmation card already owns the same request ID and approve/reject
            // actions. Keep its typed projection transient, but avoid rendering a duplicate card.
            guard widget.type != .unknown, widget.type != .approval else { continue }
            let key = stableKey(for: widget)
            if let index = indexes[key] {
                result[index] = widget
            } else if result.count < 8 || widget.type == .task_plan {
                indexes[key] = result.count
                result.append(widget)
            }
        }
        return result
    }

    static func merging(
        _ existing: [RovaBackendClient.CopilotResultWidget],
        with incoming: [RovaBackendClient.CopilotResultWidget]
    ) -> [RovaBackendClient.CopilotResultWidget] {
        normalized(existing + incoming)
    }

    private static func stableKey(for widget: RovaBackendClient.CopilotResultWidget) -> String {
        if let widgetId = widget.widgetId, !widgetId.isEmpty { return widgetId }
        switch widget.type {
        case .created_resource:
            return "created:\(widget.resourceType?.rawValue ?? "unknown"):\(widget.id.map { String($0) } ?? "unknown")"
        case .code_change:
            return "code:\(widget.id.map { String($0) } ?? "unknown"):\(widget.projectVersion.map { String($0) } ?? "0")"
        case .weather:
            let location = (widget.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return "weather:\(location)"
        case .sources:
            return "sources"
        case .artifact:
            return "artifact:\(widget.artifactId ?? "unknown")"
        case .task_plan:
            return "plan:\(widget.taskId ?? widget.widgetId ?? "unknown")"
        case .task_result:
            return "task:\(widget.taskId ?? widget.widgetId ?? "unknown")"
        case .approval:
            return "approval:\(widget.confirmationId ?? widget.widgetId ?? "unknown")"
        case .clarification:
            return "question:\(widget.questionId ?? widget.widgetId ?? "unknown")"
        case .error:
            return "error:\(widget.taskId ?? widget.widgetId ?? "unknown")"
        case .list:
            return "list:\(widget.domain ?? "unknown")"
        case .table:
            return "table:\((widget.title ?? "").lowercased())"
        case .inline_app:
            return "inlineapp:\((widget.title ?? "").lowercased()):\(widget.html?.count ?? 0)"
        case .act_handoff:
            return "act:\(widget.operation ?? ""):\(String((widget.request ?? "").prefix(80)).lowercased())"
        case .card:
            return "card:\(widget.kind ?? ""):\((widget.title ?? "").lowercased())|\((widget.query ?? widget.contactQuery ?? widget.original ?? widget.expression ?? widget.seconds.map { String(Int($0)) } ?? "").lowercased())"
        case .map:
            return "map:\(widget.mode ?? ""):\((widget.origin ?? "").lowercased())>\((widget.destination ?? widget.query ?? widget.near ?? "").lowercased())"
        case .unknown:
            return "unknown"
        }
    }
}

/// Which clarification card may still be answered: only the one in the last message of the conversation, and only once.
/// A new message, an answer, a different task or a new chat all leave the older cards read-only.
enum WiqoClarification {
    static func activeQuestionID(in bubbles: [ChatBubble]) -> String? {
        guard let last = bubbles.last(where: { $0.role != .system }), last.role == .assistant else { return nil }
        return last.widgets.last(where: { $0.type == .clarification && ($0.questionId?.isEmpty == false) && ($0.taskId?.isEmpty == false) })?.questionId
    }

    /// The answer to send for a card, or nil when it must not be sent (not the active card, empty text, already being sent).
    static func answer(for widget: RovaBackendClient.CopilotResultWidget, text: String, activeQuestionID: String?, alreadySent: Set<String>) -> (text: String, ids: RovaBackendClient.ClarificationAnswer)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard widget.type == .clarification, let questionId = widget.questionId, let taskId = widget.taskId,
              !trimmed.isEmpty, trimmed.count <= 1_200,
              questionId == activeQuestionID, !alreadySent.contains(questionId) else { return nil }
        return (trimmed, RovaBackendClient.ClarificationAnswer(taskId: taskId, questionId: questionId))
    }
}
