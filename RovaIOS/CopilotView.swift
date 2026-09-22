import AVFoundation
import PhotosUI
import QuickLook
import Speech
import SwiftUI
import UIKit

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
                await loadSideCards()
            } else if bubbles.isEmpty {
                async let messages: Void = loadRemoteMessagesIfNeeded()
                async let cards: Void = loadSideCards()
                _ = await (messages, cards)
            } else {
                await loadSideCards()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                CopilotConversationStore.flushPending()
                return
            }
            Task { await loadSideCards() }
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
        .onDisappear {
            persistConversation()
            CopilotConversationStore.flushPending()
        }
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
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    /// Suggestions and memory candidates are independent of each other.
    private func loadSideCards() async {
        async let suggestions: Void = loadProactiveSuggestions()
        async let candidates: Void = loadMemoryCandidates()
        _ = await (suggestions, candidates)
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
            Text("Öneri")
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
        let needsExecutionAttention = bubble.needsConfirmation
            || !bubble.inFlightStepIDs.isEmpty
            || !bubble.failedSteps.isEmpty
            || deviceSteps.contains { step in
                guard let result = bubble.stepResults[step.id] else {
                    return !bubble.executedStepIDs.contains(step.id)
                }
                return result.status != .completed
            }
            || bubble.backendConfirmations.contains { $0.status == .pending || $0.status == .processing || $0.status == .failed }
            || liveOnlyUpdates.contains {
                $0.status == LiveExecutionStatus.awaitingConfirmation.rawValue
                    || $0.status == LiveExecutionStatus.dispatching.rawValue
                    || $0.status == LiveExecutionStatus.running.rawValue
                    || $0.status == LiveExecutionStatus.failed.rawValue
                    || $0.status == LiveExecutionStatus.denied.rawValue
            }
        return Group {
            // A verified, ordinary completion is already described by Wiqo's reply. Keep the
            // execution details only while the user needs to act, something needs attention, or
            // a read result itself is useful context; don't leave a completed status widget under
            // every successful chat turn.
            if hasExecution && (needsExecutionAttention || !chunks.isEmpty) {
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
            if hasWork { return "checkmark.circle" }
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

    static func canGrantTrust(_ step: PlannedCommand) -> Bool {
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
                let attachmentLimitReached = pendingAttachments.count >= maxAttachments
                PhotosPicker(
                    selection: $selectedPhotos,
                    maxSelectionCount: max(1, maxAttachments - pendingAttachments.count),
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(attachmentLimitReached ? Color(.tertiaryLabel) : .primary)
                        .frame(width: 34, height: 34)
                }
                .disabled(isSending || isPreparingAttachment || attachmentLimitReached)
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
                },
                onUsage: { used, limit in
                    subscriptionStore.applyMessageUsage(used: used, limit: limit)
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
                },
                onUsage: { used, limit in
                    subscriptionStore.applyMessageUsage(used: used, limit: limit)
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
        CopilotConversationStore.saveSoon(id: conversationID, messages: stored, turnCount: turnCount)
    }
}

private extension JSONEncoder {
    static var rovaISO8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
