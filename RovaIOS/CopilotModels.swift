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
