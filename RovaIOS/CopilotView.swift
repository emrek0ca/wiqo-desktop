import AVFoundation
import PhotosUI
import QuickLook
import Speech
import SwiftUI
import UIKit

private enum BackendConfirmationStatus: Equatable {
    case pending
    case processing
    case completed
    case cancelled
    case failed
}

private enum LiveExecutionStatus: String {
    case ready
    case awaitingConfirmation = "awaiting_confirmation"
    case dispatching
    case running
    case succeeded
    case failed
    case denied
    case blocked
}

private enum LocalExecutionAdvanceResult {
    case awaitingConfirmation
    case completed
    case failed
}

private struct BackendConfirmationRow: Identifiable, Equatable {
    var confirmation: RovaBackendClient.BackendConfirmation
    var status: BackendConfirmationStatus = .pending
    var resultText: String?
    var resultDetail: String? = nil
    var artifacts: [RovaBackendClient.ArtifactDescriptor] = []

    var id: UUID { confirmation.id }
}

private struct ChatBubble: Identifiable {
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
}

/// What a user attached shows as small thumbnails sitting above their own message bubble, exactly
/// where the user placed them before sending - not just held ephemerally in the composer and lost
/// the moment the message goes out. Read-only (no remove button, unlike the composer's own
/// attachmentStrip); tapping one opens it large enough to actually look at.
private struct AttachmentThumbnailStrip: View {
    let thumbnails: [Data]
    @State private var fullscreenImage: UIImage?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, data in
                if let uiImage = UIImage(data: data) {
                    Button {
                        fullscreenImage = uiImage
                    } label: {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .fullScreenCover(item: $fullscreenImage) { image in
            AttachmentFullScreenView(image: image)
        }
    }
}

extension UIImage: @retroactive Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

private struct AttachmentFullScreenView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") { dismiss() }
                        .tint(.white)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.black, for: .navigationBar)
        }
    }
}

private struct CopyReplyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Kopyalandı" : "Yanıtı kopyala")
    }
}

/// The code a step will run (or already ran), collapsed by default so the conversation stays
/// readable, plus - once the Mac has a result - the real exit code/stdout/stderr in a matching
/// disclosure instead of a wall of text dumped into the reply.
private struct CodeExecutionCard: View {
    let payload: CodeExecutionPayload
    let summary: String
    let run: ProcessOutputContent?
    let failureMessage: String?
    let isPending: Bool

    @State private var showsCode = false
    @State private var showsOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: languageIcon)
                    .foregroundStyle(statusColor)
                Text(summary)
                    .font(.subheadline.weight(.medium))
                Spacer()
                statusBadge
            }

            DisclosureGroup(isExpanded: $showsCode) {
                WiqoCodeBlock(code: payload.code, title: payload.language.lowercased())
                    .padding(.top, 4)
            } label: {
                Text("Kodu görüntüle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let run {
                DisclosureGroup(isExpanded: $showsOutput) {
                    VStack(alignment: .leading, spacing: 6) {
                        let stdout = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                        let stderr = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !stdout.isEmpty {
                            Text(stdout)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if !stderr.isEmpty {
                            Text(stderr)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        if stdout.isEmpty && stderr.isEmpty {
                            Text("Çıktı yok.").font(.caption).foregroundStyle(.secondary)
                        }
                        if run.truncated {
                            Text("Çıktı kısaltıldı.").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } label: {
                    Text("Çıktıyı gör")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .onAppear { if run.exitCode != 0 { showsOutput = true } }
            } else if let failureMessage {
                Text(failureMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: RovaDesign.chipRadius, style: .continuous))
    }

    private var languageIcon: String {
        switch payload.language.lowercased() {
        case "python": return "chevron.left.forwardslash.chevron.right"
        case "javascript": return "curlybraces"
        default: return "terminal"
        }
    }

    private var statusColor: Color {
        if failureMessage != nil { return .red }
        if let run { return run.exitCode == 0 ? .green : .red }
        return isPending ? .orange : .secondary
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isPending {
            Text("Bunu çalıştırmam için onayını bekliyorum.")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
        } else if let run {
            Text(run.exitCode == 0 ? "Kod çalıştı." : "Kodu çalıştırırken bir sorun çıktı.")
                .font(.caption2.weight(.medium))
                .foregroundStyle(run.exitCode == 0 ? .green : .red)
        } else if failureMessage != nil {
            Text("Kodu çalıştıramadım.")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.red)
        }
    }
}

/// The confirmation UI as a native bottom sheet instead of an inline card lost somewhere in the
/// scroll history - it opens the moment a turn needs approval and stays reachable regardless of
/// where the conversation is scrolled to.
private struct ConfirmationSheetView: View {
    let bubble: ChatBubble
    let isGranting: Bool
    let isProcessing: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onConfirmAndAlwaysAllow: () -> Void

    private var currentStep: PlannedCommand? {
        bubble.steps.first { step in
            !bubble.executedStepIDs.contains(step.id)
                && (step.isDestructive || step.requiresUserPresence)
        }
    }

    private var laterConfirmationCount: Int {
        guard let currentStep,
              let index = bubble.steps.firstIndex(where: { $0.id == currentStep.id }) else { return 0 }
        return bubble.steps.dropFirst(index + 1).filter { step in
            !bubble.executedStepIDs.contains(step.id)
                && (step.isDestructive || step.requiresUserPresence)
        }.count
    }

    private var qualifiesForAlwaysAllow: Bool {
        guard let currentStep else { return false }
        return CopilotView.canGrantTrust(currentStep)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let currentStep {
                        if currentStep.type == .executeCode, case .codeExecution(let payload) = currentStep.payload {
                            CodeExecutionCard(payload: payload, summary: currentStep.summary, run: nil, failureMessage: nil, isPending: true)
                        } else {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Sıradaki adım")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                    Text(currentStep.summary)
                                        .font(.headline)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(16)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: RovaDesign.chipRadius, style: .continuous))
                        }

                        Text(laterConfirmationCount > 0
                             ? "İşlem sırayla ilerleyecek. Sonraki izin gerektiğinde ayrıca sorulacak."
                             : "Onayından sonra bu adım çalıştırılacak.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if qualifiesForAlwaysAllow {
                            Text("Bu eylem türü için gelecekte onay istememeyi seçebilirsin.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Onaylanacak adım bulunamadı.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Bu adım için onay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("İptal", role: .cancel) { onCancel() }
                        .disabled(isProcessing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    WiqoActionButton(title: "Onayla", isLoading: isProcessing) { onConfirm() }

                    if qualifiesForAlwaysAllow {
                        WiqoActionButton(title: "Onayla, her zaman izin ver", kind: .secondary, isLoading: isGranting) {
                            onConfirmAndAlwaysAllow()
                        }
                        .disabled(isProcessing)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(.bar)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isProcessing)
    }
}

/// A suggestion tagged `requiresDevice: true` only makes sense with a Mac actually reachable
/// right now - showing "Sesi kıs" to a Free-tier user (no PC access at all) or to someone whose
/// Mac is unpaired/offline just produces a confused, doomed-to-fail first message. Ordered PC
/// suggestions first, non-PC after, so filtering + prefix(4) below naturally fills the row with
/// non-PC alternatives instead of coming up short when device suggestions get excluded.
private struct QuickSuggestion { let title: String; let icon: String; let requiresDevice: Bool }

private let allSuggestions: [QuickSuggestion] = [
    QuickSuggestion(title: "Sesi kıs", icon: "speaker.wave.1.fill", requiresDevice: true),
    QuickSuggestion(title: "Ekranı kısarak odaklan", icon: "moon.stars.fill", requiresDevice: true),
    QuickSuggestion(title: "Bugün hava nasıl?", icon: "cloud.sun.fill", requiresDevice: false),
    QuickSuggestion(title: "Basit bir hesap makinesi yap", icon: "function", requiresDevice: false),
    QuickSuggestion(title: "Toplantıya hazırla", icon: "person.2.fill", requiresDevice: false),
    QuickSuggestion(title: "Bu ayki bütçemi tabloya dök", icon: "tablecells.fill", requiresDevice: false)
]

/// Wiqo's conversation surface. A real conversation, not a one-shot "type → plan → confirm" form - every
/// message (from either side) is kept in `bubbles` and the full history is resent with each new
/// message so the model has context (the backend itself is stateless).
///
/// Non-destructive steps the model decides on (volume, brightness, opening or gracefully closing
/// an app, ...) run immediately once the reply is shown. Destructive or presence-gated steps
/// (lock, sleep, force quit, file writes, messages, calendar writes) require Face ID/Touch ID.
struct CopilotView: View {
    @ObservedObject var model: IOSConnectionModel
    @ObservedObject var authSession: AuthSessionStore
    @ObservedObject var subscriptionStore: SubscriptionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var bubbles: [ChatBubble] = []
    @State private var inputText = ""
    @State private var isSending = false
    /// Every progress checkpoint Wiqo reports for the turn in flight, oldest first - shown as a
    /// growing stack of lines rather than one line overwriting the last, so a multi-step answer
    /// visibly shows its own reasoning stages instead of a single static "thinking" label.
    @State private var statusMessages: [String] = []
    @State private var conversationID = ""
    @State private var turnCount = 0
    /// Results are sent with the next stateless backend turn, so the model can distinguish a
    /// command that was merely queued from one the paired Mac actually completed.
    @State private var recentDeviceResults: [RovaBackendClient.DeviceExecutionResult] = []
    /// One task-level recovery budget. Safe multi-step continuations may still use their normal
    /// round budget, but a failed local device step gets at most one alternative attempt.
    @State private var localRecoveryAttemptsRemaining = 1
    @State private var proactiveSuggestions: [RovaBackendClient.ProactiveSuggestion] = []
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var pendingAttachments: [RovaBackendClient.ChatAttachment] = []
    @State private var attachmentPreviews: [UIImage] = []
    @State private var isPreparingAttachment = false
    @FocusState private var isComposerFocused: Bool
    /// Mirrors the backend's own per-message cap (routes/copilot.ts's chatRequestSchema) - the
    /// picker and the strip both enforce it so the UI never lets the user build a request the
    /// backend would then reject.
    private let maxAttachments = 4
    @State private var memoryCandidates: [RovaBackendClient.MemoryCandidate] = []
    @State private var screenshotObservationCount = 0
    @StateObject private var audioRecorder = WiqoSpeechRecorder()
    @State private var isStartingAudio = false
    @State private var showingMicPermissionAlert = false
    @State private var showingDiscovery = false
    @StateObject private var liveReply = LiveReplyText()
    /// Follows the conversation's end only while the reader is already there: dragging up to read
    /// stops following, reaching the bottom again resumes it. Nothing ever yanks the view down.
    @State private var followsLatest = true
    @State private var bottomVisible = true
    @State private var scrollToLatestRequest = 0
    @State private var previewURL: URL?
    @State private var openingArtifactID: String?
    /// The bubble currently awaiting confirmation, if any - drives a native bottom sheet instead
    /// of an inline card, so the confirmation is never missed by being scrolled past.
    @State private var confirmationBubbleID: UUID?
    /// Set right before `confirmationBubbleID` is cleared by an explicit button, so the sheet's
    /// `onDismiss` (which also fires for a plain swipe-down) can tell the two apart.
    @State private var confirmationHandledExplicitly = false
    @State private var isGrantingTrust = false
    @State private var isConfirming = false

    /// Set only when this conversation should open with one prompt already sitting in the
    /// composer - e.g. picking an automation template. Pre-fills and focuses the composer so the
    /// user can still edit it before sending; never sent on their behalf. Consumed once in `.task`.
    private let draftPrompt: String?

    init(model: IOSConnectionModel, authSession: AuthSessionStore, subscriptionStore: SubscriptionStore, conversationID: String? = nil, draftPrompt: String? = nil) {
        self.model = model
        self.authSession = authSession
        self.subscriptionStore = subscriptionStore
        self.draftPrompt = draftPrompt
        let resolvedID = conversationID ?? CopilotConversationStore.currentIdentifier()
        _conversationID = State(initialValue: resolvedID)
        _turnCount = State(initialValue: CopilotConversationStore.turnCount(for: resolvedID))

        let loadedBubbles = CopilotConversationStore.messages(for: resolvedID).map { stored in
            let role: ChatBubble.Role
            switch stored.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .system: role = .system
            }
            return ChatBubble(role: role, text: stored.text, artifacts: stored.artifacts ?? [], attachmentThumbnails: stored.attachmentThumbnails ?? [])
        }
        _bubbles = State(initialValue: loadedBubbles)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !proactiveSuggestions.isEmpty {
                proactiveCards
            }
            if !memoryCandidates.isEmpty {
                memoryCandidatesCard
            }
            if bubbles.isEmpty {
                emptyState
                if !isSending { suggestionRow.padding(.bottom, 4) }
            } else {
                conversation
            }
        }
        .background(Color(.systemBackground))
        // A safe-area inset (rather than a plain trailing child) is what lets the floating
        // composer sit above the conversation instead of being a normal layout sibling that
        // permanently claims its own row - content still reserves exactly enough space to never
        // sit underneath it, but can scroll the rest of the way to the true bottom of the screen.
        .safeAreaInset(edge: .bottom) {
            inputBar
        }
        .task {
            if let draftPrompt, bubbles.isEmpty {
                inputText = draftPrompt
                isComposerFocused = true
            } else if bubbles.isEmpty {
                await loadRemoteMessagesIfNeeded()
            }
            await loadProactiveSuggestions()
            await loadMemoryCandidates()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await loadProactiveSuggestions()
                await loadMemoryCandidates()
            }
        }
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await prepareAttachments(items) }
        }
        .onChange(of: audioRecorder.transcript) { _, transcript in
            guard !transcript.isEmpty else { return }
            inputText = transcript
        }
        .onChange(of: audioRecorder.lastErrorMessage) { _, message in
            guard let message, !message.isEmpty else { return }
            bubbles.append(ChatBubble(role: .system, text: message))
            persistConversation()
        }
        .quickLookPreview($previewURL)
        .alert("Sesli giriş izni gerekli", isPresented: $showingMicPermissionAlert) {
            Button("Ayarları Aç") { openSystemSettings() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Wiqo'nun konuşmanızı cihazda metne çevirebilmesi için Ayarlar'dan Wiqo'ya mikrofon ve konuşma tanıma izinlerini vermen gerekiyor.")
        }
        .sheet(isPresented: $showingDiscovery) {
            DiscoveryView(deviceReady: deviceSuggestionsReady) { prompt in
                inputText = prompt
                isComposerFocused = true
            }
        }
        .sheet(isPresented: Binding(
            get: { confirmationBubbleID != nil },
            set: { isPresented in
                if !isPresented, let bubbleID = confirmationBubbleID, !confirmationHandledExplicitly {
                    // A plain swipe-down, not one of the sheet's own buttons - treat exactly like
                    // "İptal" so the bubble is never left silently stuck awaiting confirmation.
                    cancelConfirmation(for: bubbleID)
                }
                confirmationBubbleID = nil
                confirmationHandledExplicitly = false
            }
        )) {
            confirmationSheetContent
        }
        .onDisappear { persistConversation() }
    }

    /// Just the mark, centered - the input bar and the suggestion row below already say what to do.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image("WiqoMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
                .accessibilityLabel("Wiqo")
                .wiqoRiseIn()
            connectionPill
                .wiqoRiseIn(delay: 0.14)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    /// One quiet line about the PC, so the first screen answers "is my computer ready?" without a
    /// greeting or a paragraph.
    private var connectionPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(RovaConnectionStatus.color(for: model))
                .frame(width: 7, height: 7)
            Text(RovaConnectionStatus.label(for: model))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(WiqoTheme.inset, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("PC durumu: \(RovaConnectionStatus.label(for: model))")
    }

    /// A Mac suggestion is only actually actionable when one is paired, currently reachable, and
    /// the account's tier allows PC control at all - any one of those missing means the same
    /// "Sesi kıs" tap that works perfectly for another user would just fail or hang here.
    private var deviceSuggestionsReady: Bool {
        model.isPaired && model.state == .connected && subscriptionStore.info.pcAllowed
    }

    private var visibleSuggestions: [QuickSuggestion] {
        Array(allSuggestions.filter { deviceSuggestionsReady || !$0.requiresDevice }.prefix(4))
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(visibleSuggestions.enumerated()), id: \.element.title) { index, suggestion in
                    suggestionChip(title: suggestion.title, systemImage: suggestion.icon, isPrimary: true) {
                        inputText = suggestion.title
                        Task { await sendMessage() }
                    }
                    .wiqoRiseIn(delay: 0.2 + Double(index) * 0.06)
                }
                suggestionChip(title: "Neler yapabilirim?", systemImage: "square.grid.2x2", isPrimary: false) {
                    showingDiscovery = true
                }
                .wiqoRiseIn(delay: 0.2 + Double(visibleSuggestions.count) * 0.06)
            }
            .padding(.horizontal, 12)
        }
    }

    private func suggestionChip(title: String, systemImage: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                    .foregroundStyle(isPrimary ? Color.primary : Color.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(WiqoTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(WiqoTheme.line, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(WiqoPillButtonStyle(kind: .ghost))
    }

    private var proactiveCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Wiqo önerisi", systemImage: "lightbulb.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(proactiveSuggestions) { suggestion in
                WiqoRecommendationCard(
                    title: suggestion.title,
                    message: suggestion.body,
                    primaryTitle: "Sor",
                    onPrimary: {
                        inputText = suggestion.prompt
                        proactiveSuggestions.removeAll { $0.id == suggestion.id }
                        Task { await markSuggestion(suggestion.id, action: "accept") }
                    },
                    onDismiss: {
                        proactiveSuggestions.removeAll { $0.id == suggestion.id }
                        Task { await markSuggestion(suggestion.id, action: "dismiss") }
                    }
                )
            }
        }
        .padding(.horizontal)
    }

    private var memoryCandidatesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Wiqo hafıza önerisi", systemImage: "brain.head.profile")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(memoryCandidates) { candidate in
                WiqoRecommendationCard(
                    title: "Bunu hatırlayayım mı?",
                    message: candidate.content,
                    primaryTitle: "Hatırla",
                    onPrimary: {
                        memoryCandidates.removeAll { $0.id == candidate.id }
                        Task {
                            do { try await RovaBackendClient.acceptMemoryCandidate(id: candidate.id) }
                            catch { await loadMemoryCandidates() }
                        }
                    },
                    onDismiss: {
                        memoryCandidates.removeAll { $0.id == candidate.id }
                        Task {
                            do { try await RovaBackendClient.dismissMemoryCandidate(id: candidate.id) }
                            catch { await loadMemoryCandidates() }
                        }
                    }
                )
            }
        }
        .padding(.horizontal)
    }

    private static let bottomAnchorID = "conversation-bottom"

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(bubbles) { bubble in
                        bubbleView(bubble)
                            .id(bubble.id)
                    }
                    if !liveReply.displayed.isEmpty {
                        // Same layout as a finished assistant bubble, so swapping the live text
                        // for the stored reply produces no visual jump.
                        ReplyBlocksView(text: liveReply.displayed, isStreaming: true)
                            .padding(.horizontal)
                    } else if isSending {
                        thinkingStagesView
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                        .onAppear {
                            bottomVisible = true
                            followsLatest = true
                        }
                        .onDisappear { bottomVisible = false }
                }
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in followsLatest = false }
                    .onEnded { _ in followsLatest = bottomVisible }
            )
            .onChange(of: scrollToLatestRequest) { _, _ in
                followsLatest = true
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
            }
            .onChange(of: liveReply.displayed) { _, _ in
                guard followsLatest else { return }
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: statusMessages.count) { _, _ in
                guard followsLatest else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
            }
            .onChange(of: bubbles.count) { _, _ in
                guard followsLatest else { return }
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    /// Progress is one sentence about what is happening right now ("PC'ye bağlanıyorum"); when the
    /// step changes it dissolves into the next one. No spinner, no "thinking" label.
    private var thinkingStagesView: some View {
        WiqoStatusLine(text: statusMessages.last(where: { !$0.isEmpty }) ?? "Bakıyorum…")
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .id("thinkingStages")
    }

    private func bubbleView(_ bubble: ChatBubble) -> some View {
        VStack(alignment: bubble.role == .user ? .trailing : .leading, spacing: 6) {
            if !bubble.attachmentThumbnails.isEmpty {
                AttachmentThumbnailStrip(thumbnails: bubble.attachmentThumbnails)
            }
            if bubble.role == .assistant {
                // No bubble chrome for the assistant, matching ChatGPT/Gemini: clean, full-width,
                // block-structured content rather than a colored speech bubble.
                ReplyBlocksView(text: bubble.text, artifacts: bubble.artifacts)
            } else if bubble.role == .system {
                systemErrorView(for: bubble)
            } else {
                HStack {
                    if bubble.role == .user { Spacer(minLength: 40) }
                    Text(bubble.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(bubbleBackground(bubble.role), in: RoundedRectangle(cornerRadius: RovaDesign.bubbleRadius, style: .continuous))
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)
                    if bubble.role != .user { Spacer(minLength: 40) }
                }
            }
            executionWidget(for: bubble)
            codeExecutionCards(for: bubble)
            if !bubble.artifacts.isEmpty {
                artifactCard(for: bubble.artifacts, awaitingSave: bubble.needsConfirmation)
            }
            if bubble.role == .assistant {
                CopyReplyButton(text: bubble.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: bubble.role == .user ? .trailing : .leading)
        .padding(.horizontal)
    }

    private func systemErrorView(for bubble: ChatBubble) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(bubble.text, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
            if let detail = bubble.errorDetail, !detail.isEmpty {
                DisclosureGroup("Ayrıntı") {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 3)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WiqoTheme.tint(WiqoTheme.red), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func executionWidget(for bubble: ChatBubble) -> some View {
        let deviceSteps = bubble.steps.filter { $0.type != .executeCode }
        let liveOnlyUpdates = standaloneExecutionUpdates(for: bubble, deviceSteps: deviceSteps)
        let hasExecution = !deviceSteps.isEmpty || !bubble.backendConfirmations.isEmpty || !liveOnlyUpdates.isEmpty
        let rows = toolRows(for: bubble, deviceSteps: deviceSteps, liveOnlyUpdates: liveOnlyUpdates)
        let chunks = contextChunks(for: bubble)
        return Group {
            if hasExecution {
                VStack(alignment: .leading, spacing: 10) {
                    if shouldShowExecutionNarration(bubble, liveOnlyUpdates: liveOnlyUpdates) {
                        HStack(spacing: 8) {
                            Image(systemName: executionNarrationIcon(bubble, deviceSteps: deviceSteps, liveOnlyUpdates: liveOnlyUpdates))
                                .foregroundStyle(.secondary)
                            Text(executionNarration(bubble, deviceSteps: deviceSteps, liveOnlyUpdates: liveOnlyUpdates))
                                .font(.subheadline)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                        }
                    }

                    if !rows.isEmpty {
                        WiqoToolChips(rows: rows, summary: toolSummary(rows))
                    }

                    ForEach(chunks) { chunk in
                        WiqoContextCard(chunk: chunk)
                    }

                    ForEach(Array(bubble.backendConfirmations.enumerated()), id: \.element.id) { index, row in
                        backendConfirmationView(row, index: index, total: bubble.backendConfirmations.count, bubbleID: bubble.id)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func shouldShowExecutionNarration(
        _ bubble: ChatBubble,
        liveOnlyUpdates: [RovaBackendClient.ExecutionStepUpdate]
    ) -> Bool {
        bubble.needsConfirmation
            || !bubble.inFlightStepIDs.isEmpty
            || bubble.failedSteps.isEmpty == false
            || bubble.backendConfirmations.contains { $0.status == .pending || $0.status == .processing || $0.status == .failed }
            || liveOnlyUpdates.contains {
                $0.status == LiveExecutionStatus.awaitingConfirmation.rawValue
                    || $0.status == LiveExecutionStatus.dispatching.rawValue
                    || $0.status == LiveExecutionStatus.running.rawValue
                    || $0.status == LiveExecutionStatus.failed.rawValue
                    || $0.status == LiveExecutionStatus.denied.rawValue
            }
    }

    private func executionNarrationIcon(
        _ bubble: ChatBubble,
        deviceSteps: [PlannedCommand],
        liveOnlyUpdates: [RovaBackendClient.ExecutionStepUpdate]
    ) -> String {
        if bubble.needsConfirmation || bubble.backendConfirmations.contains(where: { $0.status == .pending }) {
            return "hand.raised.fill"
        }
        if bubble.failedSteps.isEmpty,
           !bubble.backendConfirmations.contains(where: { $0.status == .failed || $0.status == .cancelled }),
           !liveOnlyUpdates.contains(where: { $0.status == LiveExecutionStatus.failed.rawValue || $0.status == LiveExecutionStatus.denied.rawValue }) {
            let hasWork = !deviceSteps.isEmpty || !liveOnlyUpdates.isEmpty || !bubble.backendConfirmations.isEmpty
            if hasWork { return "sparkles" }
        }
        return "arrow.triangle.2.circlepath"
    }

    private func executionNarration(
        _ bubble: ChatBubble,
        deviceSteps: [PlannedCommand],
        liveOnlyUpdates: [RovaBackendClient.ExecutionStepUpdate]
    ) -> String {
        let pendingConfirmation = bubble.needsConfirmation
            || bubble.backendConfirmations.contains { $0.status == .pending }
            || liveOnlyUpdates.contains { $0.status == LiveExecutionStatus.awaitingConfirmation.rawValue }
        if pendingConfirmation { return "Bunu yapabilmem için senden onay almam gerekiyor." }

        let failed = !bubble.failedSteps.isEmpty
            || bubble.backendConfirmations.contains { $0.status == .failed || $0.status == .cancelled }
            || liveOnlyUpdates.contains { $0.status == LiveExecutionStatus.failed.rawValue || $0.status == LiveExecutionStatus.denied.rawValue }
        if failed { return "İşlemi tamamlayamadım; ayrıntıyı açabilirsin." }

        let processing = !bubble.inFlightStepIDs.isEmpty
            || bubble.backendConfirmations.contains { $0.status == .processing }
            || liveOnlyUpdates.contains { $0.status == LiveExecutionStatus.dispatching.rawValue || $0.status == LiveExecutionStatus.running.rawValue }
        if processing {
            let summary = deviceSteps.first(where: { bubble.inFlightStepIDs.contains($0.id) })?.summary
                ?? liveOnlyUpdates.first(where: { $0.status == LiveExecutionStatus.dispatching.rawValue || $0.status == LiveExecutionStatus.running.rawValue })?.summary
            return summary.map { "Şimdi şunu yapıyorum: \($0)" } ?? "İstediklerini sırayla yapıyorum."
        }

        let localDone = deviceSteps.allSatisfy { bubble.executedStepIDs.contains($0.id) }
        let backendDone = bubble.backendConfirmations.allSatisfy { $0.status == .completed }
        let liveDone = liveOnlyUpdates.allSatisfy { $0.status == LiveExecutionStatus.succeeded.rawValue }
        if localDone && backendDone && liveDone { return "İstediklerini yaptım." }
        return "İstediklerini sırayla yapıyorum."
    }

    private func standaloneExecutionUpdates(
        for bubble: ChatBubble,
        deviceSteps: [PlannedCommand]
    ) -> [RovaBackendClient.ExecutionStepUpdate] {
        let representedIDs = Set(deviceSteps.map(\.id)).union(bubble.backendConfirmations.map(\.id))
        return bubble.executionUpdates.values
            .filter { update in
                isUserVisibleExecutionUpdate(update)
                    && !representedIDs.contains(update.id)
                    && !(update.confirmationId.map { representedIDs.contains($0) } ?? false)
            }
            .sorted { lhs, rhs in
                switch (lhs.sequence, rhs.sequence) {
                case let (left?, right?): return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.id.uuidString < rhs.id.uuidString
                }
            }
    }

    /// Backend/service steps such as memory bookkeeping, code generation and research are
    /// internal implementation details. They must not turn an ordinary chat reply into a gray
    /// execution card. Real PC steps and explicit permission/presence gates remain visible.
    private func isUserVisibleExecutionUpdate(_ update: RovaBackendClient.ExecutionStepUpdate) -> Bool {
        update.kind == "device" || update.requiresConfirmation || update.requiresUserPresence
    }

    /// A pending or in-progress approval is a card with two clear answers; once answered it settles
    /// into a single quiet pill. Everything else about the action lives in the details.
    private func backendConfirmationView(_ row: BackendConfirmationRow, index: Int, total: Int, bubbleID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch row.status {
            case .pending, .processing:
                WiqoApprovalCard(
                    title: row.confirmation.title,
                    summary: row.confirmation.summary,
                    fields: approvalFields(row.confirmation),
                    step: index + 1,
                    stepCount: total,
                    isDestructive: row.confirmation.isDestructive,
                    isProcessing: row.status == .processing,
                    onApprove: { Task { await resolveBackendConfirmation(bubbleID: bubbleID, confirmationID: row.id, approved: true) } },
                    onDecline: { Task { await resolveBackendConfirmation(bubbleID: bubbleID, confirmationID: row.id, approved: false) } }
                )
            case .completed:
                WiqoApprovalOutcome(kind: .done, message: nonEmpty(row.resultText) ?? "Yaptım.")
            case .cancelled:
                WiqoApprovalOutcome(kind: .declined, message: "İşlemi yapmadım.")
            case .failed:
                WiqoApprovalOutcome(kind: .failed, message: nonEmpty(row.resultText) ?? "İşlem gerçekleşmedi.")
            }

            if let resultDetail = row.resultDetail, !resultDetail.isEmpty {
                DisclosureGroup("Ayrıntı") {
                    Text(resultDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 3)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !row.artifacts.isEmpty {
                artifactCard(for: row.artifacts, awaitingSave: false)
            }
        }
        .wiqoAnimation(WiqoMotion.ease(0.4), value: row.status)
    }

    private func approvalFields(_ confirmation: RovaBackendClient.BackendConfirmation) -> [WiqoApprovalCard.Field] {
        confirmation.details.keys.sorted().compactMap { key in
            guard let value = confirmation.details[key], !value.isEmpty else { return nil }
            return WiqoApprovalCard.Field(id: key, label: key.replacingOccurrences(of: "_", with: " ").capitalized, value: value)
        }
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// One collapsible card per `.executeCode` step in this bubble - shown both while a step is
    /// still awaiting confirmation (so the sheet's summary line isn't the only place to see what
    /// will actually run) and afterwards, once the Mac has returned real stdout/stderr.
    private func codeExecutionCards(for bubble: ChatBubble) -> some View {
        ForEach(bubble.steps.filter { $0.type == .executeCode }) { step in
            if let payload = codePayload(step) {
                CodeExecutionCard(
                    payload: payload,
                    summary: step.summary,
                    run: bubble.codeRuns[step.id],
                    failureMessage: bubble.failedSteps[step.id],
                    isPending: bubble.needsConfirmation || bubble.inFlightStepIDs.contains(step.id)
                )
            }
        }
    }

    private func codePayload(_ step: PlannedCommand) -> CodeExecutionPayload? {
        guard case .codeExecution(let payload) = step.payload else { return nil }
        return payload
    }

    private func toolRows(
        for bubble: ChatBubble,
        deviceSteps: [PlannedCommand],
        liveOnlyUpdates: [RovaBackendClient.ExecutionStepUpdate]
    ) -> [WiqoToolRow] {
        let local = deviceSteps.map { step -> WiqoToolRow in
            let presentation = stepPresentation(step: step, bubble: bubble)
            return WiqoToolRow(
                id: step.id.uuidString,
                icon: deviceToolIcon(step.type),
                label: step.summary,
                tone: deviceToolTone(step: step, bubble: bubble),
                status: presentation.status,
                detail: presentation.detail
            )
        }
        let live = liveOnlyUpdates.map { update -> WiqoToolRow in
            let presentation = livePresentation(LiveExecutionStatus(rawValue: update.status) ?? .ready, message: update.message)
            return WiqoToolRow(
                id: update.id.uuidString,
                icon: "desktopcomputer",
                label: update.summary,
                tone: liveToolTone(update.status),
                status: presentation.status,
                detail: presentation.detail
            )
        }
        return local + live
    }

    private func toolSummary(_ rows: [WiqoToolRow]) -> String {
        let finished = rows.filter { $0.tone == .success }.count
        if finished == rows.count { return "\(rows.count) işlem tamamlandı" }
        return "\(rows.count) işlem"
    }

    private func deviceToolIcon(_ type: CommandType) -> String {
        switch type {
        case .openApplication, .openApplicationByName, .controlApplication, .quitApplication, .listRunningApplications:
            return "app.fill"
        case .listDesktopFiles, .readDesktopFile, .moveDesktopFile, .renameDesktopFile, .saveTextFile,
             .saveArtifact, .readDocument, .editDocument, .listFiles, .readFile, .writeFile, .moveFile,
             .copyFile, .deleteFile:
            return "doc.fill"
        case .executeCode: return "terminal"
        case .setClipboardText, .getClipboardText, .getClipboardHistory: return "doc.on.clipboard"
        case .setVolume, .toggleMute, .mediaControl: return "speaker.wave.2.fill"
        case .captureScreen, .clickScreen, .controlUIElement: return "rectangle.inset.filled.and.person.filled"
        case .getSystemStatus, .ping: return "desktopcomputer"
        default: return "bolt.fill"
        }
    }

    private func deviceToolTone(step: PlannedCommand, bubble: ChatBubble) -> WiqoToolChipTone {
        if let result = bubble.stepResults[step.id] {
            switch result.status {
            case .completed: return .success
            case .unknown: return .attention
            case .failed: return .failure
            case .denied: return .attention
            case .pending, .running: return .active
            }
        }
        if bubble.failedSteps[step.id] != nil { return .failure }
        if bubble.inFlightStepIDs.contains(step.id) { return .active }
        if bubble.needsConfirmation && currentLocalConfirmationStep(in: bubble)?.id == step.id { return .attention }
        return .neutral
    }

    private func liveToolTone(_ status: String) -> WiqoToolChipTone {
        switch LiveExecutionStatus(rawValue: status) {
        case .succeeded: return .success
        case .failed: return .failure
        case .denied, .awaitingConfirmation: return .attention
        case .dispatching, .running: return .active
        default: return .neutral
        }
    }

    /// The one sentence and the optional technical lines shown for a step - what used to be a
    /// stack of status views is now plain text, so every row reads the same way.
    private func stepPresentation(step: PlannedCommand, bubble: ChatBubble) -> (status: String?, detail: [String]) {
        if let result = bubble.stepResults[step.id] {
            var detail: [String] = []
            if let error = result.error {
                detail = [error.message, "Kod: \(error.code)"]
            } else if let data = result.data, contextChunk(from: data, id: step.id.uuidString) == nil,
                      let text = stepResultDataDetail(data) {
                detail = [text]
            }
            return (localResultMessage(result), detail)
        }
        if let failure = bubble.failedSteps[step.id] {
            return ("Bunu tamamlayamadım.", [failure])
        }
        if let update = bubble.executionUpdates[step.id], let status = LiveExecutionStatus(rawValue: update.status) {
            return livePresentation(status, message: update.message)
        }
        if bubble.inFlightStepIDs.contains(step.id) {
            return livePresentation(.running, message: nil)
        }
        if bubble.needsConfirmation {
            if currentLocalConfirmationStep(in: bubble)?.id == step.id {
                return livePresentation(.awaitingConfirmation, message: nil)
            }
            if requiresLocalConfirmation(step) {
                return livePresentation(.blocked, message: nil)
            }
        }
        return (nil, [])
    }

    private func livePresentation(_ status: LiveExecutionStatus, message: String?) -> (status: String?, detail: [String]) {
        let detail = (message ?? "").isEmpty ? [] : [message ?? ""]
        switch status {
        case .ready:
            return (nil, [])
        case .awaitingConfirmation:
            return ("Bunu yapabilmem için senden onay almam gerekiyor.", [])
        case .dispatching, .running:
            return ("Şimdi yapıyorum…", [])
        case .succeeded:
            return ("Oldu.", [])
        case .failed, .denied:
            return (friendlyExecutionFailure(status, message: message), detail)
        case .blocked:
            return ("Önceki işlemi tamamlayınca buna geçeceğim.", detail)
        }
    }

    /// File and document reads are shown as what they are - text taken from a file - rather than
    /// as a technical detail line.
    private func contextChunks(for bubble: ChatBubble) -> [WiqoContextChunk] {
        bubble.steps.compactMap { step in
            guard let data = bubble.stepResults[step.id]?.data else { return nil }
            return contextChunk(from: data, id: step.id.uuidString)
        }
    }

    private func contextChunk(from data: CommandData, id: String) -> WiqoContextChunk? {
        let title = "Okunan içerik"
        switch data {
        case .fileContent(let content):
            guard !content.content.isEmpty else { return nil }
            return WiqoContextChunk(id: id, title: title, text: String(content.content.prefix(4_000)), source: content.filename)
        case .documentContent(let content):
            guard !content.text.isEmpty else { return nil }
            return WiqoContextChunk(id: id, title: title, text: String(content.text.prefix(4_000)), source: content.filename)
        case .fileData(let content):
            guard let text = content.text, !text.isEmpty else { return nil }
            return WiqoContextChunk(id: id, title: title, text: String(text.prefix(4_000)), source: (content.path as NSString).lastPathComponent)
        default:
            return nil
        }
    }

    private func friendlyExecutionFailure(_ status: LiveExecutionStatus, message: String?) -> String {
        if status == .denied { return "Bu işlemi yapmadım." }
        let normalized = (message ?? "").lowercased()
        if normalized.contains("offline")
            || normalized.contains("device_offline")
            || normalized.contains("pc'ye ulaşılamıyor")
            || normalized.contains("pc’ye ulaşılamıyor") {
            return "PC’ye şu anda ulaşamıyorum. Açık ve internete bağlı olduğundan emin olun."
        }
        if normalized.contains("permission")
            || normalized.contains("presence")
            || normalized.contains("authority") {
            return "Bu işlem için gerekli izni alamadım."
        }
        return "Bunu tamamlayamadım."
    }

    private func localResultMessage(_ result: CommandResult) -> String {
        switch result.status {
        case .pending, .running:
            return "Şimdi yapıyorum…"
        case .completed:
            return result.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Oldu." : result.message
        case .unknown:
            return "İşlemin sonucu netleşmedi; tekrar çalıştırmadım."
        case .denied:
            return "Bu işlemi yapmadım."
        case .failed:
            return "Bunu tamamlayamadım."
        }
    }

    private func bubbleBackground(_ role: ChatBubble.Role) -> Color {
        switch role {
        case .user: return Color(.secondarySystemBackground)
        case .assistant: return Color(.secondarySystemBackground)
        case .system: return .red.opacity(0.15)
        }
    }

    /// Types the "Her zaman izin ver" control is even shown for - must match the backend's
    /// USER_GRANTABLE_TRUST_TYPES (groq/trust.ts) or the grant call just 400s harmlessly.
    fileprivate static let userGrantableTypes: Set<CommandType> = [.executeCode, .controlApplication, .quitApplication]

    fileprivate static func canGrantTrust(_ step: PlannedCommand) -> Bool {
        guard userGrantableTypes.contains(step.type) else { return false }
        return !(step.type == .controlApplication && step.summary.localizedCaseInsensitiveContains("zorla kapat"))
    }

    private func presentConfirmation(for bubbleID: UUID) {
        confirmationHandledExplicitly = false
        confirmationBubbleID = bubbleID
    }

    private func presentLiveExecutionBubble(
        for update: RovaBackendClient.ExecutionStepUpdate,
        existingBubbleID: UUID?
    ) -> UUID {
        if let existingBubbleID {
            applyStepUpdate(update, to: existingBubbleID)
            return existingBubbleID
        }

        var reply = ChatBubble(
            role: .assistant,
            text: liveReply.displayed.isEmpty ? "Bakıyorum…" : liveReply.displayed
        )
        reply.executionUpdates[update.id] = update
        bubbles.append(reply)
        liveReply.reset()
        return reply.id
    }

    private func applyStepUpdate(_ update: RovaBackendClient.ExecutionStepUpdate, to bubbleID: UUID) {
        setBubble(bubbleID) { bubble in
            bubble.executionUpdates[update.id] = update
            let confirmationID = update.confirmationId ?? update.id
            guard let index = bubble.backendConfirmations.firstIndex(where: { $0.id == confirmationID }) else { return }
            applyBackendExecutionUpdate(update, to: &bubble.backendConfirmations[index])
        }
    }

    private func applyBackendExecutionUpdate(
        _ update: RovaBackendClient.ExecutionStepUpdate,
        to row: inout BackendConfirmationRow
    ) {
        switch update.status {
        case LiveExecutionStatus.awaitingConfirmation.rawValue:
            row.status = .pending
        case LiveExecutionStatus.running.rawValue, LiveExecutionStatus.dispatching.rawValue:
            row.status = .processing
        case LiveExecutionStatus.succeeded.rawValue:
            row.status = .completed
            row.resultText = update.message
            row.resultDetail = nil
        case LiveExecutionStatus.denied.rawValue:
            row.status = .cancelled
            row.resultText = friendlyExecutionFailure(.denied, message: update.message)
            row.resultDetail = update.message
        case LiveExecutionStatus.failed.rawValue, LiveExecutionStatus.blocked.rawValue:
            row.status = .failed
            row.resultText = friendlyExecutionFailure(.failed, message: update.message)
            row.resultDetail = update.message
        default:
            break
        }
    }

    /// Called as soon as `confirmation_needed` arrives. Device steps open the existing native
    /// sheet; backend confirmations remain independent inline rows whose buttons can be used
    /// immediately, even while the rest of the SSE turn is still streaming.
    private func presentEarlyConfirmationIfNeeded(
        steps: [PlannedCommand],
        backendConfirmations: [RovaBackendClient.BackendConfirmation],
        existingBubbleID: UUID?
    ) -> UUID? {
        let needsDeviceConfirmation = steps.contains { $0.isDestructive || $0.requiresUserPresence }
        guard needsDeviceConfirmation || !backendConfirmations.isEmpty else { return existingBubbleID }

        if let existingBubbleID {
            setBubble(existingBubbleID) { bubble in
                if !steps.isEmpty { bubble.steps = steps }
                bubble.backendConfirmations = mergedBackendConfirmations(
                    existing: bubble.backendConfirmations,
                    incoming: backendConfirmations,
                    executionUpdates: bubble.executionUpdates
                )
                bubble.needsConfirmation = bubble.needsConfirmation || needsDeviceConfirmation
            }
            if needsDeviceConfirmation { presentConfirmation(for: existingBubbleID) }
            return existingBubbleID
        }

        var reply = ChatBubble(
            role: .assistant,
            text: liveReply.displayed.isEmpty ? "Bunu yapmak için onayını almam gerekiyor." : liveReply.displayed,
            steps: steps,
            backendConfirmations: backendConfirmations.map { BackendConfirmationRow(confirmation: $0) }
        )
        reply.needsConfirmation = needsDeviceConfirmation
        bubbles.append(reply)
        liveReply.reset()
        if needsDeviceConfirmation { presentConfirmation(for: reply.id) }
        return reply.id
    }

    private func mergedBackendConfirmations(
        existing: [BackendConfirmationRow],
        incoming: [RovaBackendClient.BackendConfirmation],
        executionUpdates: [UUID: RovaBackendClient.ExecutionStepUpdate] = [:]
    ) -> [BackendConfirmationRow] {
        guard !incoming.isEmpty else { return existing }
        var merged = existing
        for confirmation in incoming {
            if let index = merged.firstIndex(where: { $0.id == confirmation.id }) {
                merged[index].confirmation = confirmation
            } else {
                var row = BackendConfirmationRow(confirmation: confirmation)
                if let update = executionUpdates.values.first(where: { update in
                    update.id == confirmation.id || update.confirmationId == confirmation.id
                }) {
                    applyBackendExecutionUpdate(update, to: &row)
                }
                merged.append(row)
            }
        }
        return merged
    }

    /// Native bottom sheet (not an inline card) so a confirmation is never missed by scrolling
    /// past it - opens automatically the moment a turn needs one.
    private var confirmationSheetContent: some View {
        Group {
            if let bubbleID = confirmationBubbleID, let bubble = bubbles.first(where: { $0.id == bubbleID }) {
                ConfirmationSheetView(
                    bubble: bubble,
                    isGranting: isGrantingTrust,
                    // While the turn is still streaming, the sheet may be showing a partial plan
                    // (see presentEarlyConfirmationIfNeeded) - keep it visible immediately, but
                    // never let Onayla fire until `done` has reconciled the bubble with the final,
                    // complete step list.
                    isProcessing: isConfirming || isSending,
                    onCancel: {
                        confirmationHandledExplicitly = true
                        cancelConfirmation(for: bubbleID)
                        confirmationBubbleID = nil
                    },
                    onConfirm: {
                        Task { await confirmAndExecute(bubbleID: bubbleID) }
                    },
                    onConfirmAndAlwaysAllow: {
                        Task { await grantTrustThenExecute(bubbleID: bubbleID) }
                    }
                )
            }
        }
    }

    /// Grant and execute share the one biometric prompt confirmAndExecute already performs, so
    /// choosing "always allow" never asks Face ID/Touch ID twice - the grant itself happens
    /// inside that same gate, right before this run's steps execute.
    private func grantTrustThenExecute(bubbleID: UUID) async {
        await confirmAndExecute(
            bubbleID: bubbleID,
            reason: "Bu tür eylemleri onaysız çalıştırmaya izin vermek için kimliğinizi doğrulayın"
        ) {
            guard let bubble = self.bubbles.first(where: { $0.id == bubbleID }) else { return }
            let pending = self.pendingLocalSteps(in: bubble)
            guard let step = pending.first(where: self.requiresLocalConfirmation), Self.canGrantTrust(step) else { return }
            self.isGrantingTrust = true
            _ = try? await RovaBackendClient.grantTrust(type: step.type.rawValue, summary: step.summary)
            self.isGrantingTrust = false
        }
    }

    private func resolveBackendConfirmation(bubbleID: UUID, confirmationID: UUID, approved: Bool) async {
        guard let bubble = bubbles.first(where: { $0.id == bubbleID }),
              let row = bubble.backendConfirmations.first(where: { $0.id == confirmationID }),
              row.status == .pending else { return }

        setBubble(bubbleID) { bubble in
            guard let index = bubble.backendConfirmations.firstIndex(where: { $0.id == confirmationID }) else { return }
            bubble.backendConfirmations[index].status = .processing
            bubble.backendConfirmations[index].resultText = nil
            bubble.backendConfirmations[index].resultDetail = nil
        }

        do {
            let response = try await RovaBackendClient.resolveBackendConfirmation(id: confirmationID, approved: approved)
            guard response.confirmationId == confirmationID else { throw RovaBackendError.invalidResponse }
            let resultText = response.result?.text
            let resultArtifacts = response.result?.artifacts ?? []
            setBubble(bubbleID) { bubble in
                guard let index = bubble.backendConfirmations.firstIndex(where: { $0.id == confirmationID }) else { return }
                switch response.status {
                case "completed":
                    if response.result?.ok == false {
                        bubble.backendConfirmations[index].status = .failed
                    } else {
                        bubble.backendConfirmations[index].status = .completed
                    }
                case "cancelled":
                    bubble.backendConfirmations[index].status = .cancelled
                default:
                    bubble.backendConfirmations[index].status = .failed
                }
                bubble.backendConfirmations[index].resultText = resultText
                bubble.backendConfirmations[index].resultDetail = nil
                bubble.backendConfirmations[index].artifacts = resultArtifacts
            }
            persistConversation()
        } catch RovaBackendError.notAuthenticated {
            setBubble(bubbleID) { bubble in
                if let index = bubble.backendConfirmations.firstIndex(where: { $0.id == confirmationID }) {
                    bubble.backendConfirmations[index].status = .failed
                    bubble.backendConfirmations[index].resultText = "Oturumun geçersiz veya süresi dolmuş."
                    bubble.backendConfirmations[index].resultDetail = nil
                }
            }
            authSession.signOut()
        } catch {
            let presentation = errorPresentation(error)
            setBubble(bubbleID) { bubble in
                if let index = bubble.backendConfirmations.firstIndex(where: { $0.id == confirmationID }) {
                    bubble.backendConfirmations[index].status = .failed
                    bubble.backendConfirmations[index].resultText = presentation.message
                    bubble.backendConfirmations[index].resultDetail = presentation.detail
                }
            }
            persistConversation()
        }
    }

    /// `awaitingSave` reflects the bubble's actual pending-confirmation state - previously this
    /// caption was static and shown "Mac onayı bekleniyor" even when no save was ever queued
    /// (e.g. the turn ran out of time before save_artifact was called), which read as a save
    /// silently stuck rather than a save that was never attempted.
    /// A picture, chart, or PDF renders right in the conversation (see ArtifactPreview.swift);
    /// anything else (Word/Excel/CSV/etc.) keeps the tap-to-open file row - there's no useful
    /// inline form of a spreadsheet, so it isn't worth inventing one.
    private func artifactCard(for artifacts: [RovaBackendClient.ArtifactDescriptor], awaitingSave: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(artifacts) { artifact in
                if case .none = ArtifactInlineKind(mimeType: artifact.mimeType) {
                    ArtifactFileRow(artifact: artifact, isBusy: openingArtifactID == artifact.id) {
                        Task { await openArtifact(artifact) }
                    }
                } else {
                    InlineArtifactPreview(artifact: artifact) {
                        Task { await openArtifact(artifact) }
                    }
                }
            }
            Text(awaitingSave ? "PC'ye kaydetmek için onayını bekliyor." : "Dosyayı açıp paylaşabilirsin. PC'ye kaydetmemi istersen söylemen yeterli.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openArtifact(_ artifact: RovaBackendClient.ArtifactDescriptor) async {
        openingArtifactID = artifact.id
        defer { openingArtifactID = nil }
        do {
            previewURL = try await RovaBackendClient.downloadArtifact(artifact)
        } catch RovaBackendError.notAuthenticated {
            authSession.signOut()
        } catch {
            let presentation = errorPresentation(error)
            bubbles.append(ChatBubble(role: .system, text: presentation.message, errorDetail: presentation.detail))
        }
    }

    /// A single floating capsule - attach, text, and send/mic all live inside one continuous
    /// material card instead of separate circles/pills, and it floats above the conversation
    /// (via `.safeAreaInset` on the body) with its own margin/shadow rather than sitting flush
    /// against the screen edges, so content can scroll all the way to the bottom behind it.
    private var inputBar: some View {
        VStack(spacing: 0) {
            if !attachmentPreviews.isEmpty || isPreparingAttachment {
                attachmentStrip
            }
            HStack(alignment: .bottom, spacing: 8) {
                // Code execution moved to a "Çalıştır" button right on each code block Wiqo writes
                // (see CodeBlockView in ReplyBlocks.swift) - that's where code actually exists to
                // run, so this "+" goes back to being a plain attach-a-photo trigger instead of a
                // menu with an item that never had any code to act on yet.
                PhotosPicker(
                    selection: $selectedPhotos,
                    maxSelectionCount: max(1, maxAttachments - pendingAttachments.count),
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(pendingAttachments.count >= maxAttachments ? Color(.tertiaryLabel) : .primary)
                        .frame(width: 34, height: 34)
                }
                .disabled(isSending || isPreparingAttachment || pendingAttachments.count >= maxAttachments)
                .accessibilityLabel("Görsel ekle")

                TextField(audioRecorder.isRecording ? "Dinliyorum…" : "Wiqo'ya anlat", text: $inputText, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.vertical, 7)
                    .focused($isComposerFocused)
                    .disabled(isSending || audioRecorder.isRecording)

                trailingComposerButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: isComposerFocused
                            ? [RovaDesign.ink.opacity(0.55), RovaDesign.signal.opacity(0.55)]
                            : [Color(.separator).opacity(0.35), Color(.separator).opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isComposerFocused ? 1.4 : 0.75
                )
        )
        .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .animation(.easeOut(duration: 0.15), value: canSend)
        .animation(.easeOut(duration: 0.18), value: isComposerFocused)
        .animation(.easeOut(duration: 0.18), value: attachmentPreviews.count)
    }

    /// Horizontal strip of pending image attachments, each individually removable - up to
    /// `maxAttachments`, matching what the backend actually accepts in one request.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(attachmentPreviews.enumerated()), id: \.offset) { index, image in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Button {
                            removeAttachment(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.55))
                                .font(.system(size: 18))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("Eki kaldır")
                    }
                }
                if isPreparingAttachment {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 60, height: 60)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
        .frame(height: 76)
    }

    @ViewBuilder
    private var trailingComposerButton: some View {
        if isPreparingAttachment || isSending || isStartingAudio {
            ProgressView()
                .controlSize(.small)
                .frame(width: 30, height: 30)
        } else if canSend && !audioRecorder.isRecording {
            Button {
                Task { await sendMessage() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(width: 30, height: 30)
                    .background(Color.primary, in: Circle())
            }
            .accessibilityLabel("Gönder")
            .transition(.wiqoBlur)
        } else {
            Button {
                toggleAudioRecording()
            } label: {
                Image(systemName: audioRecorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(audioRecorder.isRecording ? Color.white : Color.primary)
                    .frame(width: 30, height: 30)
                    .background(audioRecorder.isRecording ? Color.red : Color(.tertiarySystemFill), in: Circle())
            }
            .accessibilityLabel(audioRecorder.isRecording ? "Ses kaydını bitir" : "Sesli mesaj kaydet")
            .transition(.wiqoBlur)
        }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    }

    private var hasInFlightDeviceWork: Bool {
        bubbles.contains { !$0.inFlightStepIDs.isEmpty }
    }

    private var availableApps: [ApplicationID] {
        model.deviceInfo?.availableApplications.map(\.id) ?? []
    }

    private func sendMessage(textOverride: String? = nil) async {
        let typedText = (textOverride ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, confirmationBubbleID == nil, !hasInFlightDeviceWork,
              !typedText.isEmpty || !pendingAttachments.isEmpty else { return }
        let text = typedText.isEmpty ? (pendingAttachments.count > 1 ? "Bu görselleri analiz et." : "Bu görseli analiz et.") : typedText
        let attachments = pendingAttachments
        let thumbnails = attachmentPreviews.compactMap(makeThumbnailData)
        inputText = ""
        clearAttachments()
        screenshotObservationCount = 0
        bubbles.append(ChatBubble(role: .user, text: text, attachmentThumbnails: thumbnails))
        persistConversation()
        liveReply.reset()
        isSending = true
        statusMessages = ["Anlıyorum…"]
        // Results belong to the turn that produced them; never let an older device outcome alter
        // the model's interpretation of a new user message.
        recentDeviceResults.removeAll(keepingCapacity: true)
        localRecoveryAttemptsRemaining = 1
        scrollToLatestRequest += 1
        defer { isSending = false }

        // Only the recent window goes to the model - a long-running chat otherwise resends its
        // entire history (including big replies) on every single new message, which is what
        // drove token usage into Groq's per-minute rate limit during testing. Anything that
        // needs to survive past this window is what the memory/task tools are for.
        let history = bubbles
            .filter { $0.role != .system }
            .suffix(16)
            .map { RovaBackendClient.ChatTurn(role: $0.role == .user ? "user" : "assistant", content: $0.text) }
        turnCount += 1
        CopilotConversationStore.saveTurnCount(turnCount, for: conversationID)
        let requestID = UUID()
        var earlyConfirmationBubbleID: UUID?

        do {
            let result = try await RovaBackendClient.converse(
                messages: history,
                availableApps: availableApps,
                applicationTargets: model.deviceInfo?.applicationTargets ?? [],
                availableCapabilities: model.deviceInfo?.capabilities ?? [],
                authorities: model.deviceInfo?.authorities ?? [],
                deviceID: model.deviceInfo?.id,
                conversationID: conversationID,
                turnCount: turnCount,
                deviceResults: recentDeviceResults,
                requestID: requestID,
                attachments: attachments,
                onStatus: { text in statusMessages.append(text) },
                onDelta: { text in liveReply.append(text) },
                onReset: { liveReply.reset() },
                onConfirmationNeeded: { steps, backendConfirmations in
                    earlyConfirmationBubbleID = presentEarlyConfirmationIfNeeded(
                        steps: steps,
                        backendConfirmations: backendConfirmations,
                        existingBubbleID: earlyConfirmationBubbleID
                    )
                },
                onStepUpdate: { update in
                    guard isUserVisibleExecutionUpdate(update) else { return }
                    earlyConfirmationBubbleID = presentLiveExecutionBubble(
                        for: update,
                        existingBubbleID: earlyConfirmationBubbleID
                    )
                }
            )
            let replyText = result.reply.isEmpty ? "Bakıyorum…" : result.reply
            await liveReply.finish(with: replyText)
            if let earlyID = earlyConfirmationBubbleID, let index = bubbles.firstIndex(where: { $0.id == earlyID }) {
                // Reconcile the same bubble with the terminal plan rather than appending a second
                // one. Existing backend row statuses are deliberately preserved because the user
                // may already have approved one while the SSE turn was still streaming.
                bubbles[index].text = replyText
                bubbles[index].steps = result.steps
                bubbles[index].executionState = result.executionState
                bubbles[index].artifacts = result.artifacts
                bubbles[index].backendConfirmations = mergedBackendConfirmations(
                    existing: bubbles[index].backendConfirmations,
                    incoming: result.backendConfirmations,
                    executionUpdates: bubbles[index].executionUpdates
                )
                bubbles[index].needsConfirmation = false
                liveReply.reset()
                let advance = await advanceLocalExecution(bubbleID: earlyID)
                if case .awaitingConfirmation = advance {
                    // The next local step owns the confirmation sheet. Its approval continues
                    // this same bubble; no second assistant message is created.
                } else if shouldContinueAfterLocalExecution(bubbleID: earlyID) {
                    await continueAfterLocalExecution(
                        history: history,
                        initialReply: result.reply,
                        bubbleID: earlyID,
                        recoveryAttemptsRemaining: localRecoveryAttemptsRemaining
                    )
                } else {
                    recentDeviceResults.removeAll(keepingCapacity: true)
                }
                persistConversation()
                return
            }
            let reply = ChatBubble(
                role: .assistant,
                text: replyText,
                steps: result.steps,
                artifacts: result.artifacts,
                executionState: result.executionState,
                backendConfirmations: result.backendConfirmations.map { BackendConfirmationRow(confirmation: $0) }
            )
            bubbles.append(reply)
            liveReply.reset()
            let advance = await advanceLocalExecution(bubbleID: reply.id)
            if case .awaitingConfirmation = advance {
                // The sheet is presented by advanceLocalExecution for the next gated step.
            } else if shouldContinueAfterLocalExecution(bubbleID: reply.id) {
                await continueAfterLocalExecution(
                    history: history,
                    initialReply: result.reply,
                    bubbleID: reply.id,
                    recoveryAttemptsRemaining: localRecoveryAttemptsRemaining
                )
            } else {
                recentDeviceResults.removeAll(keepingCapacity: true)
            }
            persistConversation()
        } catch RovaBackendError.notAuthenticated {
            // Sends the whole app back to the login screen (RootView switches on this),
            // there's no local sheet/screen of our own to dismiss here.
            liveReply.reset()
            authSession.signOut()
        } catch {
            liveReply.reset()
            let presentation = errorPresentation(error)
            bubbles.append(ChatBubble(role: .system, text: presentation.message, errorDetail: presentation.detail))
            persistConversation()
        }
    }

    private func requiresLocalConfirmation(_ step: PlannedCommand) -> Bool {
        step.isDestructive || step.requiresUserPresence
    }

    private func pendingLocalSteps(in bubble: ChatBubble) -> [PlannedCommand] {
        bubble.steps.filter { !bubble.executedStepIDs.contains($0.id) }
    }

    private func currentLocalConfirmationStep(in bubble: ChatBubble) -> PlannedCommand? {
        pendingLocalSteps(in: bubble).first(where: requiresLocalConfirmation)
    }

    /// Runs only the safe prefix of a plan. The first permission-gated step stops the queue and
    /// owns the sheet; after approval this method is called again, so a later gated step never
    /// gets silently bundled into the previous approval.
    private func advanceLocalExecution(bubbleID: UUID) async -> LocalExecutionAdvanceResult {
        guard let bubble = bubbles.first(where: { $0.id == bubbleID }) else { return .failed }
        guard bubble.failedSteps.isEmpty else {
            setBubble(bubbleID) { $0.needsConfirmation = false }
            return .failed
        }
        let pending = pendingLocalSteps(in: bubble)
        guard !pending.isEmpty else {
            setBubble(bubbleID) { $0.needsConfirmation = false }
            return .completed
        }

        if let gateIndex = pending.firstIndex(where: requiresLocalConfirmation) {
            let safePrefix = Array(pending.prefix(upTo: gateIndex))
            if !safePrefix.isEmpty {
                await execute(safePrefix, bubbleID: bubbleID)
                guard let updated = bubbles.first(where: { $0.id == bubbleID }) else { return .failed }
                let prefixFailed = safePrefix.contains { step in
                    updated.failedSteps[step.id] != nil || updated.stepResults[step.id]?.status != .completed
                }
                if prefixFailed {
                    setBubble(bubbleID) { $0.needsConfirmation = false }
                    return .failed
                }
            }
            setBubble(bubbleID) { $0.needsConfirmation = true }
            presentConfirmation(for: bubbleID)
            return .awaitingConfirmation
        }

        await execute(pending, bubbleID: bubbleID)
        guard let updated = bubbles.first(where: { $0.id == bubbleID }) else { return .failed }
        let failed = pending.contains { step in
            updated.failedSteps[step.id] != nil || updated.stepResults[step.id]?.status != .completed
        }
        setBubble(bubbleID) { $0.needsConfirmation = false }
        return failed ? .failed : .completed
    }

    private func confirmAndExecute(bubbleID: UUID, reason: String = "Bu eylemi PC'de çalıştırmak için kimliğinizi doğrulayın", beforeExecute: () async -> Void = {}) async {
        guard !isConfirming else { return }
        isConfirming = true
        defer {
            isConfirming = false
            isGrantingTrust = false
        }
        let ok = await model.authenticateBiometrics(reason: reason)
        guard ok, let bubble = bubbles.first(where: { $0.id == bubbleID }) else { return }
        let pending = pendingLocalSteps(in: bubble)
        guard let gateIndex = pending.firstIndex(where: requiresLocalConfirmation) else {
            confirmationHandledExplicitly = true
            confirmationBubbleID = nil
            return
        }
        let stepsThroughGate = Array(pending.prefix(through: gateIndex))
        let initialReply = executionNoticeFreeText(bubble.text)
        let history = bubbles
            .filter { $0.role != .system }
            .suffix(16)
            .map { RovaBackendClient.ChatTurn(role: $0.role == .user ? "user" : "assistant", content: $0.text) }
        await beforeExecute()
        confirmationHandledExplicitly = true
        setBubble(bubbleID) { bubble in
            bubble.needsConfirmation = false
            bubble.text = executionStartedText(bubble.text)
        }
        confirmationBubbleID = nil
        recentDeviceResults.removeAll(keepingCapacity: true)
        await execute(stepsThroughGate, bubbleID: bubbleID)
        let advance = await advanceLocalExecution(bubbleID: bubbleID)
        if case .awaitingConfirmation = advance {
            // The next gated step presents its own sheet from advanceLocalExecution.
        } else if shouldContinueAfterLocalExecution(bubbleID: bubbleID) {
            await continueAfterLocalExecution(
                history: history,
                initialReply: initialReply,
                bubbleID: bubbleID,
                recoveryAttemptsRemaining: localRecoveryAttemptsRemaining
            )
        } else {
            recentDeviceResults.removeAll(keepingCapacity: true)
        }
        persistConversation()
    }

    private func execute(_ steps: [PlannedCommand], bubbleID: UUID) async {
        var startedAnyStep = false
        for step in steps {
            guard let bubble = bubbles.first(where: { $0.id == bubbleID }),
                  !bubble.executedStepIDs.contains(step.id),
                  !bubble.inFlightStepIDs.contains(step.id) else { continue }
            setBubble(bubbleID) { $0.inFlightStepIDs.insert(step.id) }
            if !startedAnyStep {
                startedAnyStep = true
                setBubble(bubbleID) { $0.text = executionStartedText($0.text) }
            }

            let result: CommandResult
            if step.type == .captureScreen {
                guard screenshotObservationCount < 3 else {
                    let now = Date()
                    result = CommandResult(
                        commandID: step.id,
                        status: .failed,
                        message: "Ekran gözlem sınırına ulaşıldı.",
                        startedAt: now,
                        finishedAt: now,
                        error: RovaError(code: "SCREEN_OBSERVATION_LIMIT", message: "Bu istek için en fazla üç ekran gözlemi yapılabilir.", category: "tool_failure")
                    )
                    setBubble(bubbleID) { bubble in
                        bubble.inFlightStepIDs.remove(step.id)
                        bubble.executedStepIDs.insert(step.id)
                        bubble.failedSteps[step.id] = result.error?.message ?? result.message
                        bubble.stepResults[step.id] = result
                    }
                    break
                }
                screenshotObservationCount += 1
            }
            result = await model.send(step.type, payload: step.payload, commandID: step.id)
            let deviceResult = RovaBackendClient.DeviceExecutionResult(
                stepID: step.id,
                type: step.type,
                summary: step.summary,
                status: result.status,
                message: result.message,
                error: result.error,
                dataText: encodedCommandData(result.data),
                imageBase64: screenshotBase64(result.data)
            )
            recentDeviceResults.append(deviceResult)
            recentDeviceResults = Array(recentDeviceResults.suffix(12))
            setBubble(bubbleID) { bubble in
                bubble.inFlightStepIDs.remove(step.id)
                bubble.executedStepIDs.insert(step.id)
                bubble.stepResults[step.id] = result
                if result.status != .completed {
                    bubble.failedSteps[step.id] = result.error?.message ?? result.message
                }
                if case .processOutput(let output) = result.data {
                    bubble.codeRuns[step.id] = output
                }
            }
            if result.status != .completed { break }
        }
        // The full per-step breakdown (detail/onay/sonuç) is executionWidget, reading `steps` +
        // `stepResults` live for as long as this session runs - none of that survives a restart
        // (see CopilotStoredMessage), so a short summary line is still folded into `text` here as
        // the one thing that does.
        if let bubble = bubbles.first(where: { $0.id == bubbleID }), let summary = overallStepsSummary(bubble) {
            setBubble(bubbleID) { $0.text = executionNoticeFreeText($0.text) + "\n\n" + summary }
        }
        persistConversation()
    }

    /// One line, only once every non-executeCode step in this bubble has actually finished -
    /// exactly what the user asked for at the end of a multi-step run: a clear, final "did it
    /// work or not," not a repeat of each step's own detail (that's executionWidget above it).
    private func overallStepsSummary(_ bubble: ChatBubble) -> String? {
        let relevant = bubble.steps.filter { $0.type != .executeCode }
        guard !relevant.isEmpty, relevant.allSatisfy({ bubble.executedStepIDs.contains($0.id) }) else { return nil }
        let failedCount = relevant.filter { bubble.failedSteps[$0.id] != nil }.count
        if failedCount == 0 { return "İstediklerini yaptım." }
        if failedCount == relevant.count { return "Bu isteği tamamlayamadım." }
        return "İşin bir kısmını yaptım; kalanını tamamlayamadım."
    }

    /// Local reads and verified system controls are two-phase turns: first the Mac returns the
    /// private/verified result, then the backend receives that result and produces the final
    /// answer or the next bounded fallback step. This keeps private files local while allowing
    /// a failed Shortcut/AX action to be handled without asking the user to repeat the request.
    private func continueAfterLocalExecution(
        history: [RovaBackendClient.ChatTurn],
        initialReply: String,
        bubbleID: UUID,
        remainingRounds: Int = 3,
        recoveryAttemptsRemaining: Int
    ) async {
        guard remainingRounds > 0 else { return }
        guard !recentDeviceResults.isEmpty else { return }
        let localResults = Array(recentDeviceResults.suffix(12))
        let hasFailure = localResults.contains { $0.status != .completed || $0.error != nil }
        guard !hasFailure || recoveryAttemptsRemaining > 0 else {
            recentDeviceResults.removeAll(keepingCapacity: true)
            return
        }
        let nextRecoveryBudget = hasFailure ? recoveryAttemptsRemaining - 1 : recoveryAttemptsRemaining
        localRecoveryAttemptsRemaining = nextRecoveryBudget
        let continuationHistory = history + [
            RovaBackendClient.ChatTurn(role: "assistant", content: initialReply),
            RovaBackendClient.ChatTurn(role: "user", content: "Yerel PC sonuçları hazır. Bu sonuçları kullanarak önceki isteği şimdi tamamla; belge içeriğini yeniden isteme.")
        ]
        recentDeviceResults.removeAll(keepingCapacity: true)
        var earlyConfirmationBubbleID: UUID?
        do {
            let result = try await RovaBackendClient.converse(
                messages: continuationHistory,
                availableApps: availableApps,
                applicationTargets: model.deviceInfo?.applicationTargets ?? [],
                availableCapabilities: model.deviceInfo?.capabilities ?? [],
                authorities: model.deviceInfo?.authorities ?? [],
                deviceID: model.deviceInfo?.id,
                conversationID: conversationID,
                turnCount: turnCount,
                deviceResults: localResults,
                requestID: UUID(),
                onStatus: { text in statusMessages.append(text) },
                onDelta: { text in liveReply.append(text) },
                onReset: { liveReply.reset() },
                onConfirmationNeeded: { steps, backendConfirmations in
                    earlyConfirmationBubbleID = presentEarlyConfirmationIfNeeded(
                        steps: steps,
                        backendConfirmations: backendConfirmations,
                        existingBubbleID: earlyConfirmationBubbleID
                    )
                },
                onStepUpdate: { update in
                    guard isUserVisibleExecutionUpdate(update) else { return }
                    earlyConfirmationBubbleID = presentLiveExecutionBubble(
                        for: update,
                        existingBubbleID: earlyConfirmationBubbleID
                    )
                }
            )
            let replyText = result.reply.isEmpty ? "Bakıyorum…" : result.reply
            await liveReply.finish(with: replyText)
            mergeContinuationResult(result, into: bubbleID, streamBubbleID: earlyConfirmationBubbleID, text: replyText)
            liveReply.reset()
            let advance = await advanceLocalExecution(bubbleID: bubbleID)
            if case .awaitingConfirmation = advance {
                // The next gated step presents its own sheet and continues this same bubble.
            } else if shouldContinueAfterLocalExecution(bubbleID: bubbleID), remainingRounds > 1 {
                await continueAfterLocalExecution(
                    history: continuationHistory,
                    initialReply: result.reply,
                    bubbleID: bubbleID,
                    remainingRounds: remainingRounds - 1,
                    recoveryAttemptsRemaining: nextRecoveryBudget
                )
            } else {
                recentDeviceResults.removeAll(keepingCapacity: true)
            }
            persistConversation()
        } catch {
            liveReply.reset()
            // The first local read already succeeded and is visible in the original bubble. Keep
            // that evidence rather than replacing it with a generic network failure.
            setBubble(bubbleID) { $0.text = executionNoticeFreeText($0.text) + "\n\nYerel sonuç alındı; kalan adımı tamamlayamadım." }
            persistConversation()
        }
    }

    private func shouldContinueAfterLocalExecution(bubbleID: UUID) -> Bool {
        if recentDeviceResults.contains(where: { $0.status != .completed || $0.error != nil }) { return true }
        guard let bubble = bubbles.first(where: { $0.id == bubbleID }) else { return false }
        return bubble.steps.contains(where: needsLocalResultFollowUp)
    }

    private func mergeContinuationResult(
        _ result: RovaBackendClient.ConverseResult,
        into bubbleID: UUID,
        streamBubbleID: UUID?,
        text: String
    ) {
        let streamBubble = streamBubbleID.flatMap { id in bubbles.first(where: { $0.id == id }) }
        setBubble(bubbleID) { bubble in
            if let streamBubble, streamBubble.id != bubbleID {
                for (id, update) in streamBubble.executionUpdates { bubble.executionUpdates[id] = update }
                for row in streamBubble.backendConfirmations where !bubble.backendConfirmations.contains(where: { $0.id == row.id }) {
                    bubble.backendConfirmations.append(row)
                }
            }
            let existingStepIDs = Set(bubble.steps.map(\.id))
            bubble.steps.append(contentsOf: result.steps.filter { !existingStepIDs.contains($0.id) })
            let existingArtifactIDs = Set(bubble.artifacts.map(\.id))
            bubble.artifacts.append(contentsOf: result.artifacts.filter { !existingArtifactIDs.contains($0.id) })
            bubble.text = text
            bubble.executionState = result.executionState
            bubble.backendConfirmations = mergedBackendConfirmations(
                existing: bubble.backendConfirmations,
                incoming: result.backendConfirmations,
                executionUpdates: bubble.executionUpdates
            )
            bubble.needsConfirmation = false
        }
        if let streamBubbleID, streamBubbleID != bubbleID {
            bubbles.removeAll { $0.id == streamBubbleID }
        }
    }

    private func formatUptime(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let hours = totalMinutes / 60
        let days = hours / 24
        if days > 0 { return "\(days)g \(hours % 24)sa" }
        if hours > 0 { return "\(hours)sa \(totalMinutes % 60)dk" }
        return "\(max(1, totalMinutes))dk"
    }

    /// The rich, per-type detail line shown under a step's own message in executionWidget (file
    /// listings, calendar/reminder previews, verification before/after, etc.) - nil when this
    /// result type has nothing more to add beyond message/error.
    private func stepResultDataDetail(_ data: CommandData?) -> String? {
        switch data {
        case .fileContent(let content):
            return String(content.content.prefix(2_000))
        case .documentContent(let content):
            return String(content.text.prefix(4_000))
        case .desktopFiles(let files):
            let names = files.map(\.filename).joined(separator: ", ")
            return files.isEmpty ? "Masaüstü boş." : "Dosyalar: \(names)"
        case .files(let files):
            let names = files.map { $0.name + ($0.isDirectory ? "/" : "") }.joined(separator: ", ")
            return files.isEmpty ? "Klasör boş." : "Dosyalar: \(names)"
        case .fileData(let content):
            if let text = content.text { return String(text.prefix(2_000)) }
            return "\(content.mimeType) dosyası okundu."
        case .screenshot(let content):
            return "Ekran görüntüsü: \(content.width)×\(content.height)"
        case .shortcutResult(let content):
            return "Doğrulama: \(content.verified ? "başarılı" : "başarısız") (beklenen: \(content.expectedState), gözlenen: \(content.observedState ?? "belirsiz"))"
        case .uiElement(let content):
            return "Eşleşme: \(content.title ?? content.description ?? "etiket") (\(content.verified ? "doğrulandı" : "doğrulanamadı"))"
        case .screenClick(let content):
            return "Koordinat: \(Int(content.x.rounded())), \(Int(content.y.rounded())) — yeniden gözlem gerekli."
        case .applicationControl(let content):
            return "Doğrulama: \(content.verified ? "başarılı" : "başarısız") (önce: \(content.stateBefore), sonra: \(content.stateAfter))"
        case .calendarEvents(let events):
            if events.isEmpty { return "Yaklaşan etkinlik yok." }
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return events.prefix(8).map { "\($0.title) (\(formatter.string(from: $0.startAt)))" }.joined(separator: "; ")
        case .reminders(let reminders):
            if reminders.isEmpty { return "Hatırlatıcı yok." }
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return reminders.prefix(8).map { reminder in
                let due = reminder.dueAt.map { " (\(formatter.string(from: $0)))" } ?? ""
                return "\(reminder.isCompleted ? "✓" : "•") \(reminder.title)\(due)"
            }.joined(separator: "; ")
        case .clipboardText(let text):
            return String(text.prefix(2_000))
        case .clipboardHistory(let entries):
            if entries.isEmpty { return "Pano geçmişi boş." }
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return entries.prefix(10).map { "\(formatter.string(from: $0.copiedAt)): \($0.text.prefix(120))" }.joined(separator: "\n")
        case .processOutput(let output):
            // The code and its full stdout/stderr are shown in the dedicated, collapsible code
            // card instead (see CodeExecutionCard) - this line stays short.
            return "Çıkış kodu \(output.exitCode), \(output.durationMs) ms"
        case .systemStatus(let status):
            var parts = ["macOS \(status.macOSVersion)", formatUptime(status.uptimeSeconds)]
            if let battery = status.batteryPercentage { parts.append("pil %\(battery)\(status.isCharging == true ? " ⚡︎" : "")") }
            return parts.joined(separator: " • ")
        case .installedApplications(let apps):
            return apps.isEmpty ? "Yüklü uygulama bulunamadı." : "Uygulamalar: \(apps.prefix(20).map(\.name).joined(separator: ", "))"
        case .runningApplications(let apps):
            if apps.isEmpty { return "Açık uygulama yok." }
            return apps.prefix(30).map { $0.isActive ? "\($0.name) (öndeki)" : $0.name }.joined(separator: ", ")
        default:
            return nil
        }
    }

    private func encodedCommandData(_ data: CommandData?) -> String? {
        guard let data else { return nil }
        let encoded: Data?
        switch data {
        case .fileContent(let content):
            let clipped = String(content.content.prefix(10_000))
            encoded = try? JSONSerialization.data(withJSONObject: [
                "kind": "fileContent",
                "value": [
                    "filename": content.filename,
                    "content": clipped,
                    "truncated": content.content.count > clipped.count
                ]
            ], options: [.sortedKeys])
        case .documentContent(let content):
            let clipped = String(content.text.prefix(10_000))
            encoded = try? JSONSerialization.data(withJSONObject: [
                "kind": "documentContent",
                "value": [
                    "filename": content.filename,
                    "format": content.format.rawValue,
                    "text": clipped,
                    "truncated": content.text.count > clipped.count
                ]
            ], options: [.sortedKeys])
        case .files(let files):
            encoded = try? JSONSerialization.data(withJSONObject: [
                "kind": "files",
                "value": files.map { ["path": $0.path, "name": $0.name, "byteCount": $0.byteCount, "isDirectory": $0.isDirectory] }
            ], options: [.sortedKeys])
        case .fileData(let content):
            var value: [String: Any] = ["path": content.path, "mimeType": content.mimeType, "truncated": content.truncated]
            if let text = content.text { value["text"] = String(text.prefix(10_000)) }
            if let base64 = content.base64 { value["base64"] = String(base64.prefix(900_000)) }
            encoded = try? JSONSerialization.data(withJSONObject: ["kind": "fileData", "value": value], options: [.sortedKeys])
        case .screenshot(let content):
            encoded = try? JSONSerialization.data(withJSONObject: [
                "kind": "screenshot", "value": ["filename": content.filename, "mimeType": content.mimeType, "width": content.width, "height": content.height]
            ], options: [.sortedKeys])
        default:
            encoded = try? JSONEncoder.rovaISO8601.encode(data)
        }
        guard let encoded else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    private func screenshotBase64(_ data: CommandData?) -> String? {
        guard case .screenshot(let screenshot) = data else { return nil }
        return screenshot.dataBase64
    }

    /// Processes every newly picked item in order, stopping once the shared cap is hit - the
    /// picker's own `maxSelectionCount` already limits a single pick, but this also protects the
    /// case where the user re-opens the picker with attachments already pending.
    private func prepareAttachments(_ items: [PhotosPickerItem]) async {
        defer { selectedPhotos = [] }
        isPreparingAttachment = true
        defer { isPreparingAttachment = false }
        for item in items {
            guard pendingAttachments.count < maxAttachments else { break }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { continue }
            let maxSide: CGFloat = 2_048
            let scale = min(1, maxSide / max(image.size.width, image.size.height))
            let normalized: UIImage
            if scale < 1 {
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                normalized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            } else {
                normalized = image
            }
            var quality: CGFloat = 0.82
            var encoded = normalized.jpegData(compressionQuality: quality)
            while let value = encoded, value.count > 8_000_000, quality > 0.45 {
                quality -= 0.08
                encoded = normalized.jpegData(compressionQuality: quality)
            }
            guard let encoded, encoded.count <= 8_000_000 else {
                bubbles.append(ChatBubble(role: .system, text: "Bir görsel desteklenen boyut sınırını aştığı için eklenmedi."))
                continue
            }
            pendingAttachments.append(RovaBackendClient.ChatAttachment(name: item.itemIdentifier ?? "gorsel.jpg", mimeType: "image/jpeg", dataBase64: encoded.base64EncodedString()))
            attachmentPreviews.append(normalized)
        }
    }

    private func removeAttachment(at index: Int) {
        guard attachmentPreviews.indices.contains(index) else { return }
        attachmentPreviews.remove(at: index)
        pendingAttachments.remove(at: index)
    }

    private func clearAttachments() {
        selectedPhotos = []
        pendingAttachments = []
        attachmentPreviews = []
    }

    /// Downsizes a composer preview image to a small JPEG for the chat-history thumbnail row -
    /// deliberately much smaller than the upload-quality copy already sent to the backend, since
    /// this one gets persisted per-message in local UserDefaults (see CopilotStoredMessage) and
    /// should stay cheap even across a long history.
    private func makeThumbnailData(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 240
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = scale < 1 ? UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) } : image
        return resized.jpegData(compressionQuality: 0.6)
    }

    private func loadProactiveSuggestions() async {
        guard RovaBackendClient.isAuthenticated else { return }
        // This is a foreground refresh only; it never delays the chat request itself. The backend
        // applies an opt-in and cooldown gate before doing any external weather research.
        if let suggestions = try? await RovaBackendClient.refreshProactiveSuggestions() {
            proactiveSuggestions = suggestions
        }
    }

    private func loadMemoryCandidates() async {
        guard RovaBackendClient.isAuthenticated else { return }
        if let candidates = try? await RovaBackendClient.fetchMemoryCandidates() {
            memoryCandidates = candidates.filter { $0.status == "pending" }
        }
    }

    /// Brings a conversation's messages back after a reinstall or a new device - only runs when
    /// this device has no local copy AND the sidebar already knows this id is a real, previously
    /// saved conversation (never for a brand-new chat's freshly minted id, which correctly has no
    /// server-side messages yet and shouldn't cost a network round trip).
    private func loadRemoteMessagesIfNeeded() async {
        guard RovaBackendClient.isAuthenticated,
              let summary = CopilotConversationStore.all().first(where: { $0.id == conversationID }),
              let remote = try? await RovaBackendClient.fetchConversationMessages(id: conversationID),
              !remote.isEmpty else { return }
        let stored = CopilotConversationStore.saveRemoteMessages(remote, for: conversationID)
        bubbles = stored.map { item in
            let role: ChatBubble.Role
            switch item.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .system: role = .system
            }
            return ChatBubble(role: role, text: item.text, artifacts: item.artifacts ?? [])
        }
        turnCount = summary.turnCount
        CopilotConversationStore.saveTurnCount(summary.turnCount, for: conversationID)
    }

    private func toggleAudioRecording() {
        guard !isStartingAudio else { return }
        if audioRecorder.isRecording {
            isStartingAudio = true
            Task { @MainActor in
                defer { isStartingAudio = false }
                let transcript = await audioRecorder.stop()
                guard !transcript.isEmpty else {
                    bubbles.append(ChatBubble(role: .system, text: "Ses net anlaşılamadı. Lütfen tekrar dene."))
                    return
                }
                await sendMessage(textOverride: transcript)
            }
            return
        }
        isStartingAudio = true
        Task { @MainActor in
            defer { isStartingAudio = false }
            switch await audioRecorder.start() {
            case .started:
                break
            case .startedWithNetworkFallback:
                break
            case .permissionDenied:
                // iOS won't show its own prompt again once a decision is recorded - Settings is
                // the only remaining path, so offer it directly instead of a dead-end error line.
                showingMicPermissionAlert = true
            case .speechUnavailable:
                bubbles.append(ChatBubble(role: .system, text: "Konuşma tanıma şu anda kullanılamıyor - Siri ve Dikte'nin Ayarlar'dan açık olduğundan ve internete bağlı olduğundan emin ol. Ses sunucuya gönderilmedi; bu arada metni yazabilirsin."))
            case .setupFailed:
                bubbles.append(ChatBubble(role: .system, text: "Mikrofon başlatılamadı; başka bir uygulama mikrofonu kullanıyor olabilir. Lütfen tekrar dene."))
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func needsLocalResultFollowUp(_ step: PlannedCommand) -> Bool {
        switch step.type {
        case .readDocument, .readDesktopFile, .readFile, .listFiles, .captureScreen,
             .runShortcut, .controlUIElement, .clickScreen, .listRunningApplications:
            return true
        default:
            return false
        }
    }

    private func markSuggestion(_ id: Int, action: String) async {
        try? await RovaBackendClient.updateProactiveSuggestion(id: id, action: action)
    }

    private func setBubble(_ id: UUID, _ mutate: (inout ChatBubble) -> Void) {
        guard let index = bubbles.firstIndex(where: { $0.id == id }) else { return }
        mutate(&bubbles[index])
    }

    private func errorPresentation(_ error: Error) -> (message: String, detail: String?) {
        let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let marker = " (kod: "
        guard let range = raw.range(of: marker), raw.hasSuffix(")") else {
            return (raw, nil)
        }
        let message = String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = String(raw[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (message.isEmpty ? raw : message, detail.isEmpty ? nil : detail)
    }

    private func executionNoticeFreeText(_ text: String) -> String {
        let notices = [
            "\n\nOnayını bekliyor; onay verdiğinde PC'de çalıştırılacak.",
            "\n\nBu cihaz eylemleri henüz çalıştırılmadı; önce uygulamadaki onayını bekliyor.",
            "\n\nBu PC komutları hazırlanıp yerel cihaza gönderilecek; gerçek sonucu henüz doğrulamadım.",
            "\n\nİstediğin işlemi PC'ye gönderiyorum; gerçek sonucu alınca haber vereceğim.",
            "\n\nPC'de çalıştırılıyor; gerçek sonuç doğrulanınca burada gösterilecek.",
            "\n\nPC'de çalıştırılıyor…",
            " için onayını bekliyorum.",
            " isteği PC'de çalıştırılıyor; gerçek sonuç doğrulanınca burada göstereceğim.",
            " başlatılıyor."
        ]
        var result = text
        for notice in notices { result = result.replacingOccurrences(of: notice, with: "") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func executionStartedText(_ text: String) -> String {
        let base = executionNoticeFreeText(text)
        return base.isEmpty ? "İstediklerini sırayla yapıyorum…" : base + "\n\nİstediklerini sırayla yapıyorum…"
    }

    private func cancelConfirmation(for bubbleID: UUID) {
        setBubble(bubbleID) { bubble in
            bubble.needsConfirmation = false
            if let step = bubble.steps.first(where: { step in
                !bubble.executedStepIDs.contains(step.id) && requiresLocalConfirmation(step)
            }) {
                bubble.failedSteps[step.id] = "İşlem iptal edildi."
            }
            let base = executionNoticeFreeText(bubble.text)
            bubble.text = base.isEmpty ? "İşlem iptal edildi." : base + "\n\nİşlem iptal edildi."
        }
    }

    private func persistConversation() {
        let stored = bubbles.map { bubble -> CopilotStoredMessage in
            let role: CopilotStoredMessage.Role
            switch bubble.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .system: role = .system
            }
            return CopilotStoredMessage(
                role: role,
                text: bubble.text,
                artifacts: bubble.artifacts.isEmpty ? nil : bubble.artifacts,
                attachmentThumbnails: bubble.attachmentThumbnails.isEmpty ? nil : bubble.attachmentThumbnails
            )
        }
        CopilotConversationStore.save(id: conversationID, messages: stored, turnCount: turnCount)
    }
}

@MainActor
private final class WiqoSpeechRecorder: NSObject, ObservableObject {
    enum StartResult {
        case started
        /// The user tapped Don't Allow (this time, or on a previous launch). iOS never shows its
        /// own permission dialog a second time once a decision is recorded, so the only way
        /// forward is Settings - the caller shows that path explicitly instead of silently
        /// re-attempting a request that's guaranteed to fail the same way again.
        case permissionDenied
        /// The selected locale cannot be constructed at all. The normal unsupported-on-device
        /// case uses Apple's own recognizer as a controlled network fallback below.
        case speechUnavailable
        /// The device can use Apple's recognizer, but not its on-device model for this locale.
        /// This is deliberately not the Groq/server audio path.
        case startedWithNetworkFallback
        /// Permission is fine; something about configuring the audio session/recorder itself
        /// failed (e.g. another app holding exclusive audio hardware access).
        case setupFailed
    }

    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var lastErrorMessage: String?

    private let speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var inputTapInstalled = false
    private var audioSessionIsActive = false
    private var isFinishing = false

    override init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
        super.init()
    }

    func start() async -> StartResult {
        // Checked before ever calling requestRecordPermission: iOS only shows its native prompt
        // once per app install, on the FIRST ever call while status is .undetermined - calling it
        // again after a .denied decision just resolves immediately with `false` and shows nothing,
        // which used to read as "the app never even asks". Requesting only when genuinely
        // undetermined is what makes the system prompt appear automatically exactly once, and
        // lets a real prior denial be told apart from "never asked yet".
        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            return .permissionDenied
        case .undetermined:
            // AVAudioApplication's native async overload handles its arbitrary callback queue
            // without inheriting this recorder's MainActor isolation.
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else { return .permissionDenied }
        case .granted:
            break
        @unknown default:
            return .permissionDenied
        }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            // isAvailable (not just the locale existing) is what actually reflects whether a
            // recognition task can run right now - false here almost always means Siri/Dictation
            // is off system-wide (Settings > Siri & Search, or no network and no on-device model
            // ready), and no amount of retrying the request will change that.
            return .speechUnavailable
        }
        // supportsOnDeviceRecognition reports the DEVICE CLASS's general capability, not whether
        // this specific language's on-device model is actually downloaded and ready right now -
        // forcing requiresOnDeviceRecognition based on it alone (as this used to) disables
        // SFSpeechRecognizer's own automatic network fallback, so an unready-but-"supported"
        // on-device model fails outright instead of transparently using the network path. Leaving
        // the request's default (false) lets the framework pick on-device when it's truly ready
        // and fall back to network itself - this is what actually made recognition fail before.
        let usesOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition

        switch await requestSpeechAuthorization() {
        case .authorized:
            break
        case .denied, .restricted, .notDetermined:
            return .permissionDenied
        @unknown default:
            return .permissionDenied
        }

        transcript = ""
        lastErrorMessage = nil
        isFinishing = false

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            // setActive(_:) is synchronous and can block for the duration of an audio route
            // negotiation (e.g. a Bluetooth headset) - AVFoundation's own runtime warning flags
            // calling it on the main thread ("can lead to UI unresponsiveness"). Off-loading it to
            // a detached task keeps the actual system call off the main thread while `start()`
            // (already async) still correctly waits for it before installing the tap/starting the
            // engine below, which need the session already active.
            try await Task.detached(priority: .userInitiated) {
                try AVAudioSession.sharedInstance().setActive(true)
            }.value
            audioSessionIsActive = true

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.channelCount > 0 else {
                cleanupCapture()
                return .setupFailed
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Deliberately NOT forced to usesOnDeviceRecognition - see the comment above where
            // that capability is read. Leaving this false lets SFSpeechRecognizer choose on-device
            // when it's actually ready and fall back to network transparently, instead of a hard
            // failure when the capability check said "yes" but the model wasn't ready yet.
            audioEngine = engine
            recognitionRequest = request
            isRecording = true

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal == true
                let didFail = error != nil
                Task { @MainActor [weak self] in
                    self?.handleRecognitionUpdate(text: text, isFinal: isFinal, didFail: didFail)
                }
            }

            // The tap block runs on AVAudioEngine's own realtime audio thread, never on the main
            // actor - a closure literal written directly here would still lexically inherit this
            // method's @MainActor isolation under Swift 6 strict concurrency, so the compiler
            // attaches a dynamic executor check to it. AVAudioEngine then invokes it from the
            // realtime thread, the check finds it's NOT running on the main actor's queue, and
            // Swift traps with dispatch_assert_queue_fail (EXC_BREAKPOINT) on the very first audio
            // buffer - exactly the "says Dinliyorum then gets stuck" crash this fixes. Building
            // the block in a `nonisolated` factory instead means the closure is lexically declared
            // in a context with no actor isolation to inherit, so no such check is attached.
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format, block: Self.makeTapBlock(for: request))
            inputTapInstalled = true
            engine.prepare()
            try engine.start()
            return usesOnDeviceRecognition ? .started : .startedWithNetworkFallback
        } catch {
            cleanupCapture()
            return .setupFailed
        }
    }

    func stop() async -> String {
        guard isRecording else { return normalizedTranscript }

        isFinishing = true
        audioEngine?.stop()
        if inputTapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        recognitionRequest?.endAudio()

        // The last partial result arrives asynchronously after endAudio(). This short, bounded
        // wait keeps the final Turkish word without blocking the main thread or polling forever.
        try? await Task.sleep(nanoseconds: 250_000_000)
        let finalTranscript = normalizedTranscript
        cleanupCapture()
        return finalTranscript
    }

    private var normalizedTranscript: String {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nonisolated` so the closure it returns is declared in a context with no actor to inherit -
    /// see the long comment at the installTap call site for why that's what actually matters here
    /// (isolation is a property of a closure's lexical declaration site, not of what it does
    /// inside). `SFSpeechAudioBufferRecognitionRequest.append(_:)` being called from the realtime
    /// audio thread while the rest of the request's lifecycle runs on the main actor is Apple's
    /// own documented pattern for this API, not a real data race this happens to paper over.
    nonisolated private static func makeTapBlock(for request: SFSpeechAudioBufferRecognitionRequest) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in request.append(buffer) }
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await WiqoSpeechPermissionBridge.requestSpeechRecognition()
    }

    private func handleRecognitionUpdate(text: String?, isFinal: Bool, didFail: Bool) {
        if let text, !text.isEmpty {
            transcript = text
        }
        guard isRecording else { return }
        if didFail, !isFinishing {
            lastErrorMessage = "Konuşma tanıma durdu. Lütfen tekrar dene."
            cleanupCapture()
        } else if isFinal {
            cleanupCapture()
        }
    }

    private func cleanupCapture() {
        isRecording = false
        isFinishing = false
        if inputTapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine = nil
        if audioSessionIsActive {
            audioSessionIsActive = false
            // cleanupCapture() itself stays synchronous (called from non-async contexts too, like
            // the recognition task's completion handling) - the deactivate call doesn't need to be
            // awaited by anything here, so it's just moved off the main thread rather than made
            // blocking-async, for the same reason as the activate call in start() above.
            Task.detached(priority: .utility) {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}

private extension JSONEncoder {
    static var rovaISO8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

struct CopilotStoredMessage: Codable, Hashable {
    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    let role: Role
    let text: String
    /// Optional (not defaulted) so decoding an entry saved before this field existed - already on
    /// disk for every account - succeeds with nil rather than failing the whole conversation load.
    let artifacts: [RovaBackendClient.ArtifactDescriptor]?
    /// Small JPEG thumbnails (see ChatBubble.attachmentThumbnails) - same nil-on-missing-key
    /// backward compatibility as `artifacts` above. Defaulted so call sites that never have
    /// thumbnails (server-fetched history) don't need to pass it explicitly.
    let attachmentThumbnails: [Data]?

    init(role: Role, text: String, artifacts: [RovaBackendClient.ArtifactDescriptor]? = nil, attachmentThumbnails: [Data]? = nil) {
        self.role = role
        self.text = text
        self.artifacts = artifacts
        self.attachmentThumbnails = attachmentThumbnails
    }
}

struct CopilotConversationSummary: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    var preview: String
    var updatedAt: Date
    var turnCount: Int
}

/// Every key here is namespaced per signed-in account (see RovaBackendClient.currentUserID) - a
/// device shared by more than one Wiqo account must never let one account see another's chat
/// history. "anon" is only ever hit in the narrow window before a token exists, so it can't
/// collide with a real account's data.
enum CopilotConversationStore {
    private static var namespace: String { RovaBackendClient.currentUserID ?? "anon" }
    private static var conversationKey: String { "rova.copilot.conversation-id.\(namespace)" }
    private static var summariesKey: String { "rova.copilot.conversations.\(namespace)" }
    private static var messagesPrefix: String { "rova.copilot.messages.\(namespace)." }
    private static var turnCountPrefix: String { "rova.copilot.turn-count.\(namespace)." }

    static func currentIdentifier() -> String {
        if let existing = UserDefaults.standard.string(forKey: conversationKey), !existing.isEmpty {
            return existing
        }
        return newIdentifier()
    }

    static func newIdentifier() -> String {
        let identifier = UUID().uuidString
        UserDefaults.standard.set(identifier, forKey: conversationKey)
        return identifier
    }

    static func all() -> [CopilotConversationSummary] {
        guard let data = UserDefaults.standard.data(forKey: summariesKey),
              let summaries = try? JSONDecoder().decode([CopilotConversationSummary].self, from: data) else {
            return []
        }
        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func messages(for id: String) -> [CopilotStoredMessage] {
        guard let data = UserDefaults.standard.data(forKey: messagesPrefix + id),
              let messages = try? JSONDecoder().decode([CopilotStoredMessage].self, from: data) else {
            return []
        }
        return messages
    }

    static func turnCount(for id: String) -> Int {
        max(0, UserDefaults.standard.integer(forKey: turnCountPrefix + id))
    }

    static func saveTurnCount(_ count: Int, for id: String) {
        guard !id.isEmpty else { return }
        UserDefaults.standard.set(max(0, count), forKey: turnCountPrefix + id)
    }

    /// Removes a conversation from this device. The id is remembered so the still-open chat view
    /// can't resurrect it when it persists on disappear.
    static func delete(id: String) {
        guard !id.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: messagesPrefix + id)
        UserDefaults.standard.removeObject(forKey: turnCountPrefix + id)
        let remaining = all().filter { $0.id != id }
        if let data = try? JSONEncoder().encode(remaining) {
            UserDefaults.standard.set(data, forKey: summariesKey)
        }
        let deleted = (UserDefaults.standard.stringArray(forKey: deletedKey) ?? []) + [id]
        UserDefaults.standard.set(Array(deleted.suffix(100)), forKey: deletedKey)
    }

    private static var deletedKey: String { "rova.copilot.deleted.\(namespace)" }

    /// Wipes every locally stored conversation of the current account (used on account deletion).
    static func removeAllForCurrentUser() {
        let ns = namespace
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("rova.copilot.") {
            if key.hasSuffix(".\(ns)") || key.contains(".\(ns).") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    static func save(id: String, messages: [CopilotStoredMessage], turnCount: Int) {
        guard !id.isEmpty else { return }
        guard !(UserDefaults.standard.stringArray(forKey: deletedKey) ?? []).contains(id) else { return }
        // A chat that was opened but never used must not clutter the history list.
        guard !messages.isEmpty else { return }
        let boundedMessages = Array(messages.suffix(80)).map {
            CopilotStoredMessage(role: $0.role, text: String($0.text.prefix(12_000)), artifacts: $0.artifacts, attachmentThumbnails: $0.attachmentThumbnails)
        }
        if let data = try? JSONEncoder().encode(boundedMessages) {
            UserDefaults.standard.set(data, forKey: messagesPrefix + id)
        }
        UserDefaults.standard.set(max(0, turnCount), forKey: turnCountPrefix + id)

        let userMessages = boundedMessages.filter { $0.role == .user }
        let title = userMessages.first.map { short($0.text, limit: 42) } ?? "Yeni sohbet"
        let preview = boundedMessages.last.map { short($0.text, limit: 90) } ?? "Boş sohbet"
        var summaries = all().filter { $0.id != id }
        summaries.append(CopilotConversationSummary(
            id: id,
            title: title,
            preview: preview,
            updatedAt: Date(),
            turnCount: max(0, turnCount)
        ))
        summaries = Array(summaries.sorted { $0.updatedAt > $1.updatedAt }.prefix(30))
        if let data = try? JSONEncoder().encode(summaries) {
            UserDefaults.standard.set(data, forKey: summariesKey)
        }
        UserDefaults.standard.set(id, forKey: conversationKey)
    }

    /// The backend stores `updated_at` as SQLite's `datetime('now')` format - not ISO 8601 - so
    /// this matches that exact shape instead of relying on a decoder's ISO 8601 strategy.
    private static let remoteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// Folds freshly fetched server summaries into the local list and returns the merged result -
    /// the server is durable (every successful `/copilot/chat` call persists there) so a remote
    /// summary always overwrites its local counterpart; anything local-only stays untouched. This
    /// is what brings history back after a reinstall or a new device, on top of the existing
    /// instant local cache the sidebar already shows before this resolves.
    static func mergeRemoteSummaries(_ remote: [RovaBackendClient.RemoteConversationSummary]) -> [CopilotConversationSummary] {
        guard !remote.isEmpty else { return all() }
        var byID = Dictionary(uniqueKeysWithValues: all().map { ($0.id, $0) })
        for item in remote {
            byID[item.id] = CopilotConversationSummary(
                id: item.id,
                title: item.title.isEmpty ? "Yeni sohbet" : item.title,
                preview: item.preview.isEmpty ? "Boş sohbet" : item.preview,
                updatedAt: remoteDateFormatter.date(from: item.updatedAt) ?? Date(),
                turnCount: item.turnCount
            )
        }
        let merged = Array(byID.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(30))
        if let data = try? JSONEncoder().encode(merged) {
            UserDefaults.standard.set(data, forKey: summariesKey)
        }
        return merged
    }

    /// Caches a conversation's messages fetched from the backend (used the first time this device
    /// opens a conversation it has no local copy of) and returns them decoded, ready for the view.
    @discardableResult
    static func saveRemoteMessages(_ remote: [RovaBackendClient.RemoteConversationMessage], for id: String) -> [CopilotStoredMessage] {
        let stored = remote.compactMap { item -> CopilotStoredMessage? in
            guard let role = CopilotStoredMessage.Role(rawValue: item.role) else { return nil }
            return CopilotStoredMessage(role: role, text: item.content, artifacts: item.artifacts)
        }
        guard !id.isEmpty, let data = try? JSONEncoder().encode(stored) else { return stored }
        UserDefaults.standard.set(data, forKey: messagesPrefix + id)
        return stored
    }

    private static func short(_ value: String, limit: Int) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(max(1, limit - 1))) + "…"
    }
}
