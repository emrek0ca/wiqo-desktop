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
    // Read-only on purpose: inside Desktop/Documents/Downloads these run without a Face ID prompt,
    // so the first thing a newly paired person sees is the Mac answering instantly.
    QuickSuggestion(title: String(localized: "Masaüstümdeki son dosyalar"), icon: "doc.text.magnifyingglass", requiresDevice: true),
    QuickSuggestion(title: String(localized: "Bu hafta indirdiğim dosyalar"), icon: "arrow.down.doc", requiresDevice: true),
    QuickSuggestion(title: String(localized: "Sesi kıs"), icon: "speaker.wave.1.fill", requiresDevice: true),
    QuickSuggestion(title: String(localized: "Ekranı kısarak odaklan"), icon: "moon.stars.fill", requiresDevice: true),
    QuickSuggestion(title: String(localized: "Bugün hava nasıl?"), icon: "cloud.sun.fill", requiresDevice: false),
    QuickSuggestion(title: String(localized: "Basit bir hesap makinesi yap"), icon: "function", requiresDevice: false),
    QuickSuggestion(title: String(localized: "Toplantıya hazırla"), icon: "person.2.fill", requiresDevice: false),
    QuickSuggestion(title: String(localized: "Bu ayki bütçemi tabloya dök"), icon: "tablecells.fill", requiresDevice: false)
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
    @State private var isCreatingAgent = false
    @State private var isSending = false
    /// The thinking timeline of the turn in flight (see ThinkingTrace). It is copied onto the reply
    /// bubble when the turn ends, where it folds into a "4 adımda tamamlandı · 9 sn" row.
    @State private var thinking = ThinkingTrace()
    /// Permission scope chosen on a terminal approval: one task by default, or a short folder session.
    @State private var terminalGrantDurations: [UUID: Int] = [:]
    @State private var conversationID = ""
    @State private var turnCount = 0
    /// Results are sent with the next stateless backend turn, so the model can distinguish a
    /// command that was merely queued from one the paired Mac actually completed.
    @State private var recentDeviceResults: [RovaBackendClient.DeviceExecutionResult] = []
    /// Browser task ids stay local to this foreground turn and are explicitly closed when its
    /// result has been reconciled. The companion also enforces an idle TTL if the phone vanishes.
    @State private var activeBrowserTaskIDs: Set<String> = []
    /// One task-level recovery budget. Safe multi-step continuations may still use their normal
    /// round budget, but a failed local device step gets at most one alternative attempt.
    @State private var localRecoveryAttemptsRemaining = 1
    @State private var localContinuationRoundsRemaining = 8
    @State private var proactiveSuggestions: [RovaBackendClient.ProactiveSuggestion] = []
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var pendingAttachments: [RovaBackendClient.ChatAttachment] = []
    @State private var attachmentPreviews: [UIImage] = []
    @State private var isPreparingAttachment = false
    /// Content of attached files, read on this phone; the files themselves are never uploaded.
    @State private var pendingFiles: [FileContent] = []
    @State private var showsPhotoPicker = false
    @State private var showsFileImporter = false
    @State private var showsDocumentScanner = false
    @FocusState private var isComposerFocused: Bool
    /// Mirrors the backend's own per-message cap (routes/copilot.ts's chatRequestSchema) - the
    /// picker and the strip both enforce it so the UI never lets the user build a request the
    /// backend would then reject.
    private let maxAttachments = 4
    /// Mirrors the backend's `files` cap in routes/copilot.ts.
    private let maxFiles = 5
    @State private var memoryCandidates: [RovaBackendClient.MemoryCandidate] = []
    @State private var openWork: RovaBackendClient.OpenWork?
    @State private var screenshotObservationCount = 0
    @StateObject private var audioRecorder = WiqoSpeechRecorder()
    @State private var isStartingAudio = false
    @State private var showingMicPermissionAlert = false
    @State private var showingDiscovery = false
    /// The daily message limit was reached: the plans open on their own instead of leaving an error line.
    @State private var showingQuotaPaywall = false
    @StateObject private var liveReply = LiveReplyText()
    @State private var liveReplyBubbleID: UUID?
    /// Follows the conversation's end only while the reader is already there: dragging up to read
    /// stops following, reaching the bottom again resumes it. Nothing ever yanks the view down.
    @State private var followsLatest = true
    @State private var bottomVisible = true
    @State private var lastAutoScrollUptime: TimeInterval = 0
    @State private var scrollToLatestRequest = 0
    @State private var previewURL: URL?
    @State private var openingArtifactID: String?
    /// The bubble currently awaiting confirmation, if any - drives a native bottom sheet instead
    /// of an inline card, so the confirmation is never missed by being scrolled past.
    @State private var confirmationBubbleID: UUID?
    @State private var taskReadApprovalBubbleID: UUID?
    /// The same task approval also covers reversible file work in the own folders (RovaOwnFolders.isTaskWritable); set only by its own button.
    @State private var taskWriteApproved = false
    /// Set right before `confirmationBubbleID` is cleared by an explicit button, so the sheet's
    /// `onDismiss` (which also fires for a plain swipe-down) can tell the two apart.
    @State private var confirmationHandledExplicitly = false
    @State private var isGrantingTrust = false
    @State private var isConfirming = false
    @State private var widgetDestination: CopilotWidgetDestination?

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
            var bubble = ChatBubble(
                role: role,
                text: stored.text,
                artifacts: stored.artifacts ?? [],
                widgets: CopilotWidgetCatalog.normalized(stored.widgets ?? []),
                attachmentThumbnails: stored.attachmentThumbnails ?? []
            )
            bubble.thinking = stored.thinking
            bubble.attachedFileNames = stored.fileNames ?? []
            bubble.deferredTask = stored.deferredTask
            bubble.projectTask = stored.projectTask
            bubble.agentTask = stored.agentTask
            return bubble
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
            if let openWork, !bubbles.isEmpty, !isSending {
                WiqoRecommendationCard(
                    title: String(localized: "Yarım kalan iş"),
                    message: "\(openWork.goal)\n\(openWork.detail)",
                    primaryTitle: String(localized: "Devam et"),
                    onPrimary: {
                        self.openWork = nil
                        Task { await sendMessage(textOverride: "devam et") }
                    },
                    onDismiss: { self.openWork = nil }
                )
                .padding(.horizontal)
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
            } else if bubbles.isEmpty || conversationID.hasPrefix("agent-") {
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
        .sheet(isPresented: $showingQuotaPaywall) {
            PaywallView(subscriptionStore: subscriptionStore)
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
        .environment(\.replacedInlineApps, Set(bubbles.flatMap { $0.widgets.compactMap { $0.type == .inline_app ? $0.replaces : nil } }))
        // A card's page offered a text for the composer: it lands there, and the person decides whether to send it.
        .onReceive(NotificationCenter.default.publisher(for: .wiqoInlineAppAsk)) { note in
            guard let text = note.object as? String, !isSending else { return }
            inputText = text
            isComposerFocused = true
        }
        // A card that ran into a problem asks Wiqo to fix it: one tap, sent as the person's own message.
        .onReceive(NotificationCenter.default.publisher(for: .wiqoInlineAppFix)) { note in
            guard let text = note.object as? String else { return }
            Task { await sendMessage(textOverride: text) }
        }
        .sheet(item: $widgetDestination) { destination in
            NavigationStack {
                Group {
                    switch destination {
                    case .agents:
                        NamedAgentsView()
                    case .automation(let automation):
                        AutomationDetailView(automation: automation)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Kapat") { widgetDestination = nil }
                    }
                }
            }
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
            Text("Bugün ne yapalım?")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
                .wiqoRiseIn(delay: 0.1)
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
        async let unfinished: Void = loadOpenWork()
        _ = await (suggestions, candidates, unfinished)
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
                if deviceSuggestionsReady, let again = WiqoRecentTask.last {
                    suggestionChip(title: String(again.prefix(30)) + (again.count > 30 ? "…" : ""), systemImage: "arrow.counterclockwise", isPrimary: true) {
                        inputText = again
                        Task { await sendMessage() }
                    }
                    .wiqoRiseIn(delay: 0.15)
                }
                ForEach(Array(visibleSuggestions.enumerated()), id: \.element.title) { index, suggestion in
                    suggestionChip(title: suggestion.title, systemImage: suggestion.icon, isPrimary: true) {
                        inputText = suggestion.title
                        Task { await sendMessage() }
                    }
                    .wiqoRiseIn(delay: 0.2 + Double(index) * 0.06)
                }
                suggestionChip(title: String(localized: "Neler yapabilirim?"), systemImage: "square.grid.2x2", isPrimary: false) {
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
                    primaryTitle: String(localized: "Sor"),
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
                    title: String(localized: "Bunu hatırlayayım mı?"),
                    message: candidate.content,
                    primaryTitle: String(localized: "Hatırla"),
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
                    // A finished timeline already sits on its bubble; while the PC runs the steps, the
                    // execution card is the live view.
                    if isSending && liveReply.displayed.isEmpty && !thinking.isFinished {
                        thinkingStagesView
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                        .onAppear {
                            bottomVisible = true
                        }
                        .onDisappear { bottomVisible = false }
                }
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in
                        followsLatest = false
                    }
                    .onEnded { _ in
                        followsLatest = bottomVisible
                        if followsLatest {
                            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                        }
                    }
            )
            .onChange(of: scrollToLatestRequest) { _, _ in
                followsLatest = true
                lastAutoScrollUptime = ProcessInfo.processInfo.systemUptime
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
            }
            .onChange(of: liveReply.displayed) { _, text in
                if !text.isEmpty, let liveReplyBubbleID {
                    setBubble(liveReplyBubbleID) { $0.text = text }
                    persistConversation()
                }
                guard followsLatest else { return }
                followLatestIfNeeded(using: proxy)
            }
            .onChange(of: thinking.steps.count) { _, _ in
                guard followsLatest else { return }
                followLatestIfNeeded(using: proxy)
            }
            .onChange(of: bubbles.count) { _, _ in
                guard followsLatest else { return }
                followLatestIfNeeded(using: proxy)
            }
            .onChange(of: isSending) { _, sending in
                guard !sending, followsLatest else { return }
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    /// Streaming text arrives in small batches. A short, non-animated cadence keeps the newest
    /// content in view without issuing a scroll command for every delta or task event.
    private func followLatestIfNeeded(using proxy: ScrollViewProxy) {
        let now = ProcessInfo.processInfo.systemUptime
        guard followsLatest, now - lastAutoScrollUptime >= 0.12 else { return }
        lastAutoScrollUptime = now
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
    }

    /// A plain answer is one sentence about what is happening right now; a task grows into a
    /// timeline of what Wiqo already did, with the current line and its clock at the bottom.
    private var thinkingStagesView: some View {
        ThinkingTimelineView(trace: thinking)
            .padding(.horizontal)
            .id("thinkingStages")
    }

    /// A background project reached its end: the reply becomes its verified summary and the
    /// delivered files join the bubble, once per outcome (a failed project resumed with "Tekrar
    /// dene" reports again). Later refreshes of the same finished state change nothing, so the
    /// conversation shows one consistent, durable result.
    private func applyProjectResult(_ detail: RovaBackendClient.ProjectDetail, to bubbleID: UUID) {
        guard let current = bubbles.first(where: { $0.id == bubbleID }),
              let task = current.projectTask, task.id == detail.id, !detail.isActive,
              task.status == "running" || task.status != detail.status else { return }
        setBubble(bubbleID) { bubble in
            if let summary = detail.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                bubble.text = summary
            }
            let existing = Set(bubble.artifacts.map(\.id))
            bubble.artifacts.append(contentsOf: detail.artifacts.filter { !existing.contains($0.id) })
            bubble.projectTask = RovaBackendClient.ProjectTask(id: detail.id, kind: detail.kind, title: detail.title, status: detail.status)
        }
        persistConversation()
    }

    /// Keeps the reply's running narration in step with the project (only when something changed,
    /// so polling does not re-render the conversation for nothing).
    private func updateProjectNarrative(_ detail: RovaBackendClient.ProjectDetail, on bubbleID: UUID) {
        guard let current = bubbles.first(where: { $0.id == bubbleID }) else { return }
        let events = detail.events ?? []
        guard current.projectNarrative != events || current.projectLiveLine != detail.progress else { return }
        setBubble(bubbleID) { bubble in
            bubble.projectNarrative = events
            bubble.projectLiveLine = detail.progress
        }
    }

    /// Ends the turn's timeline and keeps it on the reply bubble, so the steps stay readable later.
    private func commitThinking(to bubbleID: UUID, failed: Bool = false) {
        thinking.finish(failed: failed)
        let trace = thinking
        if trace.showsTimeline { failed ? WiqoHaptics.failure() : WiqoHaptics.success() }
        setBubble(bubbleID) { $0.thinking = trace.showsTimeline ? trace : nil }
    }

    private func bubbleView(_ bubble: ChatBubble) -> some View {
        VStack(alignment: bubble.role == .user ? .trailing : .leading, spacing: 10) {
            if !bubble.attachmentThumbnails.isEmpty {
                AttachmentThumbnailStrip(thumbnails: bubble.attachmentThumbnails)
            }
            if !bubble.attachedFileNames.isEmpty {
                AttachedFileNames(names: bubble.attachedFileNames)
            }
            if bubble.role == .assistant {
                if let trace = bubble.thinking, trace.isFinished {
                    ThinkingSummaryView(trace: trace)
                        .padding(.horizontal)
                }
                // No bubble chrome for the assistant, matching ChatGPT/Gemini: clean, full-width,
                // block-structured content rather than a colored speech bubble.
                if !bubble.widgets.contains(where: { $0.presentation == "widget_only" }) {
                    ReplyBlocksView(
                        text: bubble.text,
                        artifacts: bubble.artifacts,
                        isStreaming: bubble.id == liveReplyBubbleID
                    )
                    .contextMenu {
                        Button { UIPasteboard.general.string = bubble.text } label: { Label("Kopyala", systemImage: "doc.on.doc") }
                    }
                }
                ForEach(WiqoChatDeclutter.visible(bubble.widgets, hasArtifact: !bubble.artifacts.isEmpty), id: \.stableID) { widget in
                    let widgetArtifact = widget.artifactId.flatMap { artifactID in
                        bubble.artifacts.first(where: { $0.id == artifactID })
                    }
                    CopilotResultWidgetView(
                        widget: widget,
                        artifact: widgetArtifact,
                        isOpeningArtifact: widgetArtifact.map { openingArtifactID == $0.id } ?? false
                    ) {
                        if let widgetArtifact {
                            Task { await openArtifact(widgetArtifact) }
                        } else {
                            openCreatedResource(widget)
                        }
                    }
                    .environment(\.wiqoFollowUp, WiqoFollowUp { text in Task { await sendMessage(textOverride: text) } })
                    .padding(.horizontal)
                    .transition(.wiqoFadeUp)
                }
                if let task = bubble.deferredTask {
                    DeferredTaskRow(task: task)
                        .padding(.horizontal)
                }
                if let agentTask = bubble.agentTask {
                    AgentTaskCard(task: agentTask)
                        .padding(.horizontal)
                }
                if let project = bubble.projectTask {
                    if project.status == "running", !bubble.projectNarrative.isEmpty || bubble.projectLiveLine != nil {
                        ProjectNarrativeView(events: bubble.projectNarrative, liveLine: bubble.projectLiveLine)
                            .padding(.horizontal)
                    }
                    ProjectTaskCard(
                        task: project,
                        onFinished: { detail in applyProjectResult(detail, to: bubble.id) },
                        onUpdate: { detail in updateProjectNarrative(detail, on: bubble.id) }
                    )
                    .padding(.horizontal)
                }
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
            let widgetArtifactIDs = Set(bubble.widgets.compactMap { $0.type == .artifact ? $0.artifactId : nil })
            let legacyArtifacts = bubble.artifacts.filter { !widgetArtifactIDs.contains($0.id) }
            if !legacyArtifacts.isEmpty {
                artifactCard(for: legacyArtifacts, awaitingSave: bubble.needsConfirmation)
            }
            if bubble.role == .assistant && !bubble.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Only the latest question can still be answered: older ones keep just their copy button.
                if !isSending, bubbles.last(where: { $0.role != .system })?.id == bubble.id {
                    let quickReplies = bubbleAwaitingApproval?.id == bubble.id ? ["Onayla", "Vazgeç"] : QuickReplyChips.options(for: bubble.text)
                    if !quickReplies.isEmpty {
                        QuickReplyChips(options: quickReplies) { option in
                            Task { await sendMessage(textOverride: option) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: bubble.role == .user ? .trailing : .leading)
        .padding(.horizontal)
        .animation(WiqoMotion.ease(), value: bubble.widgets.count)
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

                    if !rows.isEmpty && !bubble.widgets.contains(where: { $0.type == .task_plan }) {
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
        if pendingConfirmation { return String(localized: "Bunu yapabilmem için senden onay almam gerekiyor.") }

        let failed = !bubble.failedSteps.isEmpty
            || bubble.backendConfirmations.contains { $0.status == .failed || $0.status == .cancelled }
            || liveOnlyUpdates.contains { $0.status == LiveExecutionStatus.failed.rawValue || $0.status == LiveExecutionStatus.denied.rawValue }
        if failed { return String(localized: "İşlemi tamamlayamadım; ayrıntıyı açabilirsin.") }

        let processing = !bubble.inFlightStepIDs.isEmpty
            || bubble.backendConfirmations.contains { $0.status == .processing }
            || liveOnlyUpdates.contains { $0.status == LiveExecutionStatus.dispatching.rawValue || $0.status == LiveExecutionStatus.running.rawValue }
        if processing {
            let summary = deviceSteps.first(where: { bubble.inFlightStepIDs.contains($0.id) })?.summary
                ?? liveOnlyUpdates.first(where: { $0.status == LiveExecutionStatus.dispatching.rawValue || $0.status == LiveExecutionStatus.running.rawValue })?.summary
            return summary.map { String(localized: "Şimdi şunu yapıyorum: \($0)") } ?? String(localized: "İstediklerini sırayla yapıyorum.")
        }

        let localDone = deviceSteps.allSatisfy { bubble.executedStepIDs.contains($0.id) }
        let backendDone = bubble.backendConfirmations.allSatisfy { $0.status == .completed }
        let liveDone = liveOnlyUpdates.allSatisfy { $0.status == LiveExecutionStatus.succeeded.rawValue }
        if localDone && backendDone && liveDone { return bubble.replyIsProgress == true ? String(localized: "Adım sonucu alındı; görev kontrol ediliyor.") : String(localized: "Adım sonuçları hazır.") }
        return String(localized: "İstediklerini sırayla yapıyorum.")
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
                if row.confirmation.details["wiqoGrantId"] != nil {
                    let selectedDuration = terminalGrantDurations[row.id] ?? 0
                    let maxSeconds = row.confirmation.details["wiqoGrantMaxSeconds"].flatMap(Int.init) ?? 1_800
                    Menu {
                        Button("Yalnızca bu görev") { terminalGrantDurations[row.id] = 0 }
                        Button("Bu klasör için 30 dakika") { terminalGrantDurations[row.id] = 1_800 }
                        if maxSeconds > 1_800 {
                            Button("Bu klasör için 8 saat") { terminalGrantDurations[row.id] = 8 * 60 * 60 }
                        }
                    } label: {
                        Label(
                            String(localized: "İzin: \(selectedDuration == 0 ? String(localized: "bu görev") : selectedDuration > 1_800 ? String(localized: "8 saat") : String(localized: "30 dakika"))"),
                            systemImage: "lock.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .disabled(row.status == .processing)
                    .padding(.horizontal, 4)
                }
            case .completed:
                WiqoApprovalOutcome(kind: .done, message: nonEmpty(row.resultText) ?? String(localized: "Yaptım."))
            case .cancelled:
                WiqoApprovalOutcome(kind: .declined, message: String(localized: "İşlemi yapmadım."))
            case .failed:
                WiqoApprovalOutcome(kind: .failed, message: nonEmpty(row.resultText) ?? String(localized: "İşlem gerçekleşmedi."))
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
            // wiqo* keys are machine fields (e.g. a terminal grant to sign), not for display.
            guard !key.hasPrefix("wiqo"), let value = confirmation.details[key], !value.isEmpty else { return nil }
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
        if finished == rows.count { return String(localized: "\(rows.count) işlem tamamlandı") }
        return String(localized: "\(rows.count) işlem")
    }

    private func deviceToolIcon(_ type: CommandType) -> String {
        switch type {
        case .openApplication, .openApplicationByName, .controlApplication, .quitApplication, .listRunningApplications:
            return "app.fill"
        case .listDesktopFiles, .readDesktopFile, .moveDesktopFile, .renameDesktopFile, .saveTextFile,
             .saveArtifact, .readDocument, .editDocument, .listFiles, .searchFiles, .readFile, .sendFileToPhone, .writeFile, .moveFile,
             .copyFile, .convertFile, .runFilePlan, .grantAgentAccess, .deleteFile:
            return "doc.fill"
        case .executeCode: return "terminal"
        case .setClipboardText, .getClipboardText, .getClipboardHistory: return "doc.on.clipboard"
        case .setVolume, .toggleMute, .mediaControl: return "speaker.wave.2.fill"
        case .captureScreen, .clickScreen, .controlUIElement, .computerDesktop: return "rectangle.inset.filled.and.person.filled"
        case .computerBrowser, .endBrowserTask: return "safari.fill"
        case .localAnalyze: return "waveform.path.ecg.rectangle"
        case .fileUtility: return "folder.badge.gearshape"
        case .systemUtility: return "gearshape"
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
            return (String(localized: "Bunu tamamlayamadım."), [failure])
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
            return (String(localized: "Bunu yapabilmem için senden onay almam gerekiyor."), [])
        case .dispatching, .running:
            return (String(localized: "Şimdi yapıyorum…"), [])
        case .succeeded:
            return (String(localized: "Oldu."), [])
        case .failed, .denied:
            return (friendlyExecutionFailure(status, message: message), detail)
        case .blocked:
            return (String(localized: "Önceki işlemi tamamlayınca buna geçeceğim."), detail)
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
        let title = String(localized: "Okunan içerik")
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
        if status == .denied { return String(localized: "Bu işlemi yapmadım.") }
        let normalized = (message ?? "").lowercased()
        if normalized.contains("offline")
            || normalized.contains("device_offline")
            || normalized.contains("pc'ye ulaşılamıyor")
            || normalized.contains("pc’ye ulaşılamıyor") {
            return String(localized: "PC’ye şu anda ulaşamıyorum. Açık ve internete bağlı olduğundan emin olun.")
        }
        if normalized.contains("permission")
            || normalized.contains("presence")
            || normalized.contains("authority") {
            return String(localized: "Bu işlem için gerekli izni alamadım.")
        }
        return String(localized: "Bunu tamamlayamadım.")
    }

    private func localResultMessage(_ result: CommandResult) -> String {
        switch result.status {
        case .pending, .running:
            return String(localized: "Şimdi yapıyorum…")
        case .completed:
            return result.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "Oldu.") : result.message
        case .unknown:
            return String(localized: "İşlemin sonucu netleşmedi; tekrar çalıştırmadım.")
        case .denied:
            return String(localized: "Bu işlemi yapmadım.")
        case .failed:
            return String(localized: "Bunu tamamlayamadım.")
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
        isComposerFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        confirmationHandledExplicitly = false
        confirmationBubbleID = bubbleID
    }

    private func presentPlanBubble(_ widget: RovaBackendClient.CopilotResultWidget) -> UUID {
        if let existing = bubbles.last(where: { $0.widgets.contains(where: { $0.stableID == widget.stableID }) }) {
            return existing.id
        }
        var bubble = ChatBubble(role: .assistant, text: "")
        bubble.widgets = [widget]
        bubbles.append(bubble)
        return bubble.id
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
            text: liveReply.displayed.isEmpty ? String(localized: "Bakıyorum…") : liveReply.displayed
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

    /// `confirmation_needed` is a preview. Keep device steps visible, but open the actionable
    /// sheet only after the terminal response has validated the complete plan.
    private func presentEarlyConfirmationIfNeeded(
        steps: [PlannedCommand],
        backendConfirmations: [RovaBackendClient.BackendConfirmation],
        existingBubbleID: UUID?
    ) -> UUID? {
        let needsDeviceConfirmation = steps.contains(where: requiresLocalConfirmation)
        if needsDeviceConfirmation || !backendConfirmations.isEmpty { isComposerFocused = false }
        guard needsDeviceConfirmation || !backendConfirmations.isEmpty else { return existingBubbleID }

        if let existingBubbleID {
            setBubble(existingBubbleID) { bubble in
                let existingStepIDs = Set(bubble.steps.map(\.id))
                bubble.steps.append(contentsOf: steps.filter { !existingStepIDs.contains($0.id) })
                bubble.backendConfirmations = mergedBackendConfirmations(
                    existing: bubble.backendConfirmations,
                    incoming: backendConfirmations,
                    executionUpdates: bubble.executionUpdates
                )
            }
            return existingBubbleID
        }

        let reply = ChatBubble(
            role: .assistant,
            text: liveReply.displayed.isEmpty ? String(localized: "Bunu yapmak için onayını almam gerekiyor.") : liveReply.displayed,
            steps: steps,
            backendConfirmations: backendConfirmations.map { BackendConfirmationRow(confirmation: $0) }
        )
        bubbles.append(reply)
        liveReply.reset()
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
                    // Only a reconciled terminal response opens this sheet. Keep actions
                    // disabled while another request or local execution is in flight.
                    isProcessing: isConfirming || isSending,
                    onCancel: {
                        confirmationHandledExplicitly = true
                        cancelConfirmation(for: bubbleID)
                        confirmationBubbleID = nil
                    },
                    onConfirm: {
                        Task { await confirmAndExecute(bubbleID: bubbleID) }
                    },
                    onConfirmTaskReads: {
                        Task {
                            await confirmAndExecute(bubbleID: bubbleID, reason: String(localized: "Bu görev boyunca Masaüstü, Belgeler ve İndirilenler içindeki hassas olmayan dosyaları okumaya izin ver")) {
                                taskReadApprovalBubbleID = bubbleID
                            }
                        }
                    },
                    onConfirmTaskFiles: {
                        Task {
                            await confirmAndExecute(bubbleID: bubbleID, reason: String(localized: "Bu görev boyunca Masaüstü, Belgeler ve İndirilenler'de dosya okuma, klasör açma, taşıma, kopyalama ve yeniden adlandırmaya izin ver. Silme ve üzerine yazma hariç.")) {
                                taskReadApprovalBubbleID = bubbleID
                                taskWriteApproved = true
                            }
                        }
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
            reason: String(localized: "Bu tür eylemleri onaysız çalıştırmaya izin vermek için kimliğinizi doğrulayın")
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

        // A terminal session card carries the grant fields; approving signs them on this phone.
        var terminalGrant: (grantId: String, signature: String)?
        var terminalGrantExpiresAt: Int?
        var terminalGrantScope = "task"
        let details = row.confirmation.details
        if approved, let grantId = details["wiqoGrantId"] {
            let maximumSeconds = details["wiqoGrantMaxSeconds"].flatMap(Int.init).map { min($0, 8 * 60 * 60) }
            let selectedDuration = terminalGrantDurations[confirmationID] ?? 0
            if selectedDuration > 0 {
                terminalGrantScope = "session"
                let duration: Int
                if selectedDuration > 1_800 {
                    duration = maximumSeconds ?? selectedDuration
                } else {
                    duration = selectedDuration
                }
                terminalGrantExpiresAt = Int(Date().timeIntervalSince1970) + duration - 30
            }
            guard let root = details["wiqoGrantRoot"], let mode = details["wiqoGrantMode"],
                  let expiresAt = terminalGrantExpiresAt ?? details["wiqoGrantExpiresAt"].flatMap(Int.init),
                  let signature = model.signTerminalGrant(grantId: grantId, rootDirectory: root, mode: mode, expiresAt: expiresAt, deviceId: details["wiqoGrantDeviceId"]) else {
                setBubble(bubbleID) { bubble in
                    guard let index = bubble.backendConfirmations.firstIndex(where: { $0.id == confirmationID }) else { return }
                    bubble.backendConfirmations[index].status = .pending
                    bubble.backendConfirmations[index].resultText = nil
                    bubble.backendConfirmations[index].resultDetail = String(localized: "Terminal izni bu telefonda imzalanamadı. PC eşleşmesini kontrol ettikten sonra yeniden deneyebilirsin.")
                }
                persistConversation()
                return
            }
            terminalGrant = (grantId, signature)
        }

        defer { terminalGrantDurations.removeValue(forKey: confirmationID) }
        do {
            let response = try await RovaBackendClient.resolveBackendConfirmation(id: confirmationID, approved: approved, terminalGrant: terminalGrant, terminalGrantExpiresAt: terminalGrantExpiresAt, terminalGrantScope: terminalGrantScope)
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
                    bubble.backendConfirmations[index].resultText = String(localized: "Oturumun geçersiz veya süresi dolmuş.")
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

    /// `awaitingSave` reflects the bubble's actual pending-confirmation state, so the pending
    /// label only appears when a PC save is genuinely waiting for approval.
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
            if awaitingSave {
                Label("PC kaydı için onay bekleniyor", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
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
            if isCreatingAgent {
                HStack(spacing: 8) {
                    Label("Ajan oluştur", systemImage: "person.crop.circle.badge.plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        isCreatingAgent = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ajan oluştur modunu kapat")
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }
            if !attachmentPreviews.isEmpty || !pendingFiles.isEmpty || isPreparingAttachment {
                attachmentStrip
            }
            HStack(alignment: .bottom, spacing: 8) {
                // Code execution moved to a "Çalıştır" button right on each code block Wiqo writes
                // (see CodeBlockView in ReplyBlocks.swift) - that's where code actually exists to
                // run, so this "+" goes back to being a plain attach-a-photo trigger instead of a
                // menu with an item that never had any code to act on yet.
                let attachmentLimitReached = pendingAttachments.count >= maxAttachments
                let fileLimitReached = pendingFiles.count >= maxFiles
                Menu {
                    Button { showsPhotoPicker = true } label: { Label("Fotoğraf", systemImage: "photo") }
                        .disabled(attachmentLimitReached)
                    Button { showsFileImporter = true } label: { Label("Dosya", systemImage: "doc") }
                        .disabled(fileLimitReached)
                    if DocumentScannerView.isSupported {
                        Button { showsDocumentScanner = true } label: { Label("Belge tara", systemImage: "doc.viewfinder") }
                            .disabled(fileLimitReached)
                    }
                    Divider()
                    Button {
                        isCreatingAgent = true
                        isComposerFocused = true
                    } label: {
                        Label("Ajan oluştur", systemImage: "person.crop.circle.badge.plus")
                    }
                    .disabled(isSending || isPreparingAttachment)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(attachmentLimitReached && fileLimitReached ? Color(.tertiaryLabel) : .primary)
                        .frame(width: 34, height: 34)
                }
                .disabled(isSending || isPreparingAttachment)
                .accessibilityLabel("Ekle")

                TextField(audioRecorder.isRecording ? "Dinliyorum…" : (isCreatingAgent ? "Ajanın ne yapsın?" : "Wiqo'ya anlat"), text: $inputText, axis: .vertical)
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
                .strokeBorder(Color.primary.opacity(isComposerFocused ? 0.22 : 0.08), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .animation(.easeOut(duration: 0.15), value: canSend)
        .animation(.easeOut(duration: 0.18), value: isComposerFocused)
        .animation(.easeOut(duration: 0.18), value: attachmentPreviews.count)
        .animation(.easeOut(duration: 0.18), value: pendingFiles.count)
        .animation(.easeOut(duration: 0.18), value: isCreatingAgent)
        .photosPicker(
            isPresented: $showsPhotoPicker,
            selection: $selectedPhotos,
            maxSelectionCount: max(1, maxAttachments - pendingAttachments.count),
            matching: .images,
            photoLibrary: .shared()
        )
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: FileContentExtractor.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { await prepareFiles(urls) }
        }
        .fullScreenCover(isPresented: $showsDocumentScanner) {
            DocumentScannerView(
                onFinish: { pages, wasTruncated in
                    showsDocumentScanner = false
                    Task { await prepareScan(pages, wasTruncated: wasTruncated) }
                },
                onCancel: { showsDocumentScanner = false },
                onError: {
                    showsDocumentScanner = false
                    bubbles.append(ChatBubble(role: .system, text: String(localized: "Belge taranamadı. Kamera iznini kontrol edip yeniden dene.")))
                    persistConversation()
                }
            )
            .ignoresSafeArea()
        }
    }

    /// Horizontal strip of pending image attachments, each individually removable - up to
    /// `maxAttachments`, matching what the backend actually accepts in one request.
    private var attachmentStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !pendingFiles.isEmpty {
                Text("Dosyanın kendisi gönderilmez; telefonda çıkarılan içerik gönderilir.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(pendingFiles.enumerated()), id: \.offset) { index, file in
                        PendingFileChip(file: file) { pendingFiles.remove(at: index) }
                    }
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
        }
        .frame(height: pendingFiles.isEmpty ? 76 : 98)
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
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return isCreatingAgent ? hasText : hasText || !pendingAttachments.isEmpty || !pendingFiles.isEmpty
    }

    private var hasInFlightDeviceWork: Bool {
        bubbles.contains { !$0.inFlightStepIDs.isEmpty }
    }

    private var availableApps: [ApplicationID] {
        model.deviceInfo?.availableApplications.map(\.id) ?? []
    }

    private func sendMessage(textOverride: String? = nil) async {
        let createAgent = isCreatingAgent
        let typedText = (textOverride ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        let hasInput = createAgent
            ? !typedText.isEmpty
            : !typedText.isEmpty || !pendingAttachments.isEmpty || !pendingFiles.isEmpty
        guard !isSending, confirmationBubbleID == nil, !hasInFlightDeviceWork,
              hasInput else { return }
        if !createAgent, pendingAttachments.isEmpty, pendingFiles.isEmpty, answerPendingConfirmation(with: typedText) {
            inputText = ""
            return
        }
        let files = pendingFiles
        let text = !typedText.isEmpty ? typedText
            : !files.isEmpty ? (files.count > 1 ? String(localized: "Bu dosyaları incele.") : String(localized: "Bu dosyayı incele."))
            : (pendingAttachments.count > 1 ? String(localized: "Bu görselleri analiz et.") : String(localized: "Bu görseli analiz et."))
        let attachments = pendingAttachments
        let previews = attachmentPreviews
        let thumbnails = attachmentPreviews.compactMap(makeThumbnailData)
        isComposerFocused = false
        inputText = ""
        isCreatingAgent = false
        clearAttachments()
        screenshotObservationCount = 0
        let userBubble = ChatBubble(role: .user, text: text, attachmentThumbnails: thumbnails, attachedFileNames: files.map(\.name))
        bubbles.append(userBubble)
        persistConversation()
        liveReplyBubbleID = nil
        liveReply.reset()
        isSending = true
        thinking = ThinkingTrace()
        thinking.note(String(localized: "Anlıyorum…"))
        // Results belong to the turn that produced them; never let an older device outcome alter
        // the model's interpretation of a new user message.
        recentDeviceResults.removeAll(keepingCapacity: true)
        taskReadApprovalBubbleID = nil
        taskWriteApproved = false
        localRecoveryAttemptsRemaining = 1
        localContinuationRoundsRemaining = 8
        scrollToLatestRequest += 1
        defer { isSending = false }

        // Only the recent window goes to the model - a long-running chat otherwise resends its
        // entire history (including big replies) on every single new message, which is what
        // drove token usage into Groq's per-minute rate limit during testing. Anything that
        // needs to survive past this window is what the memory/task tools are for.
        let history = bubbles
            .filter { $0.role != .system && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(16)
            .map { RovaBackendClient.ChatTurn(role: $0.role == .user ? "user" : "assistant", content: $0.text) }
        let turnCountBeforeRequest = turnCount
        turnCount += 1
        CopilotConversationStore.saveTurnCount(turnCount, for: conversationID)
        let requestID = UUID()
        let responseBubble = ChatBubble(role: .assistant, text: "")
        bubbles.append(responseBubble)
        liveReplyBubbleID = responseBubble.id
        persistConversation()
        var earlyConfirmationBubbleID: UUID? = responseBubble.id

        do {
            let result = try await RovaBackendClient.converse(
                messages: history,
                availableApps: availableApps,
                applicationTargets: model.deviceInfo?.applicationTargets ?? [],
                availableCapabilities: model.deviceInfo?.capabilities ?? [],
                authorities: model.deviceInfo?.authorities ?? [],
                deviceID: model.pairedDeviceIDForTransfer,
                conversationID: conversationID,
                taskID: responseBubble.id,
                turnCount: turnCount,
                deviceResults: recentDeviceResults,
                requestID: requestID,
                attachments: attachments,
                files: files,
                createAgent: createAgent,
                onStatus: { text in thinking.note(text) },
                // Only the current SSE generation is visible. A reset clears its provisional
                // text; the terminal event below remains the authoritative reconciliation.
                onDelta: { text in liveReply.append(text) },
                onReset: {
                    liveReply.reset()
                    if let liveReplyBubbleID {
                        setBubble(liveReplyBubbleID) { $0.text = "" }
                        persistConversation()
                    }
                },
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
                onWidgetUpdate: { widget in
                    let targetID = earlyConfirmationBubbleID ?? liveReplyBubbleID ?? presentPlanBubble(widget)
                    earlyConfirmationBubbleID = targetID
                    setBubble(targetID) { $0.widgets = CopilotWidgetCatalog.merging($0.widgets, with: [widget]) }
                    persistConversation()
                },
                onActivity: { activity in
                    thinking.apply(
                        id: activity.id,
                        phase: activity.phase,
                        label: activity.label,
                        state: ThinkingTrace.Step.State(rawValue: activity.state) ?? .done,
                        persona: activity.persona
                    )
                },
                onLocationRequired: { requestID in
                    await RovaBackendClient.requestAndContinueCopilotWeatherLocation(requestID: requestID)
                },
                onUsage: { used, limit in
                    subscriptionStore.applyMessageUsage(used: used, limit: limit)
                }
            )
            let replyText = result.reply.isEmpty
                ? (liveReply.currentText.isEmpty ? String(localized: "Bakıyorum…") : liveReply.currentText)
                : result.reply
            let replyBubbleID = earlyConfirmationBubbleID ?? responseBubble.id
            commitThinking(to: replyBubbleID, failed: result.executionState == "partial_success" || result.executionState == "failed")
            liveReply.finish(with: replyText)
            setBubble(replyBubbleID) { bubble in
                // Reconcile the terminal result into the in-flight bubble. Existing execution
                // rows are kept so an early confirmation remains attached to this same reply.
                bubble.text = replyText
                bubble.steps = result.steps
                bubble.executionState = result.executionState
                bubble.replyIsProgress = result.replyIsProgress
                bubble.deferredTask = result.deferredTask
                bubble.projectTask = result.projectTask
                bubble.agentTask = result.agentTask
                bubble.artifacts = result.artifacts
                bubble.widgets = CopilotWidgetCatalog.normalized(result.widgets)
                bubble.backendConfirmations = mergedBackendConfirmations(
                    existing: bubble.backendConfirmations,
                    incoming: result.backendConfirmations,
                    executionUpdates: bubble.executionUpdates
                )
                bubble.needsConfirmation = false
            }
            if !result.steps.isEmpty { WiqoRecentTask.remember(text) }
            liveReplyBubbleID = nil
            liveReply.reset()
            persistConversation()
            CopilotConversationStore.flushPending()
            let advance = await advanceLocalExecution(bubbleID: replyBubbleID)
            if case .awaitingConfirmation = advance {
                // The sheet is presented by advanceLocalExecution for the next gated step.
            } else if shouldContinueAfterLocalExecution(bubbleID: replyBubbleID) {
                await continueAfterLocalExecution(
                    history: history,
                    initialReply: result.reply,
                    bubbleID: replyBubbleID,
                    remainingRounds: localContinuationRoundsRemaining,
                    recoveryAttemptsRemaining: localRecoveryAttemptsRemaining
                )
            } else {
                recentDeviceResults.removeAll(keepingCapacity: true)
            }
            persistConversation()
        } catch RovaBackendError.copilotPayloadTooLarge {
            // This is rejected before any request reaches the backend, so restore the draft and
            // remove its optimistic bubbles. The user can remove an attachment and safely retry.
            liveReplyBubbleID = nil
            liveReply.reset()
            thinking.finish(failed: true)
            bubbles.removeAll { $0.id == userBubble.id || $0.id == responseBubble.id }
            inputText = typedText
            pendingFiles = files
            pendingAttachments = attachments
            attachmentPreviews = previews
            isCreatingAgent = createAgent
            turnCount = turnCountBeforeRequest
            CopilotConversationStore.saveTurnCount(turnCount, for: conversationID)
            bubbles.append(ChatBubble(role: .system, text: RovaBackendError.copilotPayloadTooLarge.localizedDescription))
            persistConversation()
            CopilotConversationStore.flushPending()
        } catch RovaBackendError.notAuthenticated {
            // Sends the whole app back to the login screen (RootView switches on this),
            // there's no local sheet/screen of our own to dismiss here.
            liveReplyBubbleID = nil
            thinking.finish(failed: true)
            confirmationBubbleID = nil
            if let earlyConfirmationBubbleID {
                setBubble(earlyConfirmationBubbleID) { bubble in
                    bubble.steps.removeAll()
                    bubble.needsConfirmation = false
                }
            }
            setBubble(responseBubble.id) { bubble in
                if bubble.text.isEmpty { bubble.text = String(localized: "Oturum sona erdi; yanıt alınamadı.") }
            }
            liveReply.reset()
            persistConversation()
            CopilotConversationStore.flushPending()
            authSession.signOut()
        } catch {
            // A recoverable network/model error must not destroy the visible task browser. The
            // worker's bounded idle timeout cleans it up if the user does not retry.
            liveReplyBubbleID = nil
            commitThinking(to: earlyConfirmationBubbleID ?? responseBubble.id, failed: true)
            let presentation = errorPresentation(error)
            if case RovaBackendError.declined(let message) = error, message.contains("QUOTA_EXCEEDED") { showingQuotaPaywall = true }
            // An early confirmation is only a preview of the plan. If the terminal response
            // cannot be read, there is no final command list to approve or execute.
            if confirmationBubbleID == earlyConfirmationBubbleID { confirmationBubbleID = nil }
            if let earlyConfirmationBubbleID {
                setBubble(earlyConfirmationBubbleID) { bubble in
                    bubble.steps.removeAll()
                    bubble.needsConfirmation = false
                    bubble.executionUpdates.removeAll()
                    bubble.widgets.removeAll { $0.type == .task_plan }
                    bubble.backendConfirmations.removeAll { $0.status == .pending }
                    bubble.text = presentation.message
                    bubble.errorDetail = presentation.detail
                }
            }
            if earlyConfirmationBubbleID != responseBubble.id {
                bubbles.removeAll { $0.id == responseBubble.id }
            } else {
                setBubble(responseBubble.id) { bubble in
                    bubble.text = presentation.message
                    bubble.errorDetail = presentation.detail
                }
            }
            liveReply.reset()
            persistConversation()
            CopilotConversationStore.flushPending()
        }
    }

    private func requiresLocalConfirmation(_ step: PlannedCommand) -> Bool {
        if let approvedID = taskReadApprovalBubbleID,
           liveReplyBubbleID == approvedID || bubbles.first(where: { $0.id == approvedID })?.steps.contains(where: { $0.id == step.id }) == true {
            // One approval for this task: reading in the own folders, and (when the person gave it) reversible file work there. Delete, overwrite and
            // anything that leaves the Mac still ask, step by step.
            if !step.isDestructive, RovaOwnFolders.isAutoReadable(type: step.type, payload: step.payload) { return false }
            if taskWriteApproved, RovaOwnFolders.isTaskWritable(type: step.type, payload: step.payload) { return false }
        }
        return step.isDestructive || step.requiresUserPresence
    }

    private func isForceQuitStep(_ step: PlannedCommand) -> Bool {
        guard step.type == .controlApplication,
              case .applicationControl(let payload) = step.payload else { return false }
        return payload.action == .quit && payload.force
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

    private func confirmAndExecute(bubbleID: UUID, reason: String = String(localized: "Bu eylemi PC'de çalıştırmak için kimliğinizi doğrulayın"), beforeExecute: () async -> Void = {}) async {
        guard !isConfirming, !isSending,
              let current = bubbles.first(where: { $0.id == bubbleID }),
              current.needsConfirmation else { return }
        isConfirming = true
        let wasSending = isSending
        isSending = true
        defer {
            isSending = wasSending
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
        let gatedStepSucceeded = bubbles.first(where: { $0.id == bubbleID })?.stepResults[pending[gateIndex].id]?.isConfirmedSuccess == true
        let advance: LocalExecutionAdvanceResult = gatedStepSucceeded
            ? await advanceLocalExecution(bubbleID: bubbleID)
            : .failed
        if case .awaitingConfirmation = advance {
            // The next gated step presents its own sheet from advanceLocalExecution.
        } else if shouldContinueAfterLocalExecution(bubbleID: bubbleID) {
            await continueAfterLocalExecution(
                history: history,
                initialReply: initialReply,
                bubbleID: bubbleID,
                remainingRounds: localContinuationRoundsRemaining,
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
                        message: String(localized: "Ekran gözlem sınırına ulaşıldı."),
                        startedAt: now,
                        finishedAt: now,
                        error: RovaError(code: "SCREEN_OBSERVATION_LIMIT", message: String(localized: "Bu istek için en fazla üç ekran gözlemi yapılabilir."), category: "tool_failure")
                    )
                    setBubble(bubbleID) { bubble in
                        bubble.inFlightStepIDs.remove(step.id)
                        bubble.executedStepIDs.insert(step.id)
                        bubble.failedSteps[step.id] = result.error?.message ?? (result.data?.hasFailedVerification == true ? String(localized: "Beklenen sonuç doğrulanamadı.") : result.message)
                        bubble.stepResults[step.id] = result
                if let evidence = DeviceOutcomeNarrator.fileWidget(step: step, result: result),
                   !bubble.widgets.contains(where: { $0.widgetId == evidence.widgetId }) {
                    bubble.widgets.append(evidence)
                }
                    }
                    break
                }
                screenshotObservationCount += 1
            }
            if step.type == .sendFileToPhone {
                do {
                    guard let deviceID = model.pairedDeviceIDForTransfer else { throw RovaBackendError.invalidResponse }
                    try await RovaBackendClient.registerFileTransfer(commandID: step.id, deviceID: deviceID)
                    result = await model.send(step.type, payload: step.payload, commandID: step.id)
                } catch {
                    let now = Date()
                    result = CommandResult(commandID: step.id, status: .failed, message: String(localized: "Dosya aktarımı başlatılamadı."), startedAt: now, finishedAt: now, error: RovaError(code: "TRANSFER_UNAVAILABLE", message: String(localized: "Dosya aktarımı başlatılamadı.")))
                }
            } else if step.type == .runFilePlan, case .filePlan(let plan) = step.payload {
                // Every file the plan sends needs its transfer registered before the Mac uploads it.
                do {
                    let transfers = plan.steps.filter { $0.op == "send" }.compactMap { $0.transferId.flatMap(UUID.init(uuidString:)) }
                    if !transfers.isEmpty {
                        guard let deviceID = model.pairedDeviceIDForTransfer else { throw RovaBackendError.invalidResponse }
                        for transfer in transfers { try await RovaBackendClient.registerFileTransfer(commandID: transfer, deviceID: deviceID) }
                    }
                    result = await model.send(step.type, payload: step.payload, commandID: step.id)
                } catch {
                    let now = Date()
                    result = CommandResult(commandID: step.id, status: .failed, message: String(localized: "Dosya aktarımı başlatılamadı."), startedAt: now, finishedAt: now, error: RovaError(code: "TRANSFER_UNAVAILABLE", message: String(localized: "Dosya aktarımı başlatılamadı.")))
                }
            } else {
                result = await model.send(step.type, payload: step.payload, commandID: step.id)
            }
            let delivery = deliveredFile(step: step, data: result.data)
            let deviceResult = RovaBackendClient.DeviceExecutionResult(
                stepID: step.id,
                type: step.type,
                summary: step.summary,
                status: result.isConfirmedSuccess ? .completed : (result.status == .completed ? .failed : result.status),
                message: result.message,
                error: result.error ?? (result.data?.hasFailedVerification == true ? RovaError(code: "POSTCONDITION_FAILED", message: String(localized: "Beklenen sonuç doğrulanamadı; işlem otomatik tekrarlanmadı.")) : nil),
                dataText: encodedCommandData(result.data),
                imageBase64: screenshotBase64(result.data),
                fileBase64: delivery?.base64,
                artifactID: {
                    if case .fileTransfer(let id) = result.data { return id }
                    return nil
                }(),
                fileName: delivery?.name,
                mimeType: delivery?.mimeType
            )
            recentDeviceResults.append(deviceResult)
            recentDeviceResults = Array(recentDeviceResults.suffix(12))
            switch result.data {
            case .computerBrowser(let browser):
                activeBrowserTaskIDs.insert(browser.taskId)
            case .browserTask(let browser) where browser.closed == true:
                activeBrowserTaskIDs.remove(browser.taskId)
            default:
                break
            }
            setBubble(bubbleID) { bubble in
                bubble.inFlightStepIDs.remove(step.id)
                bubble.executedStepIDs.insert(step.id)
                bubble.stepResults[step.id] = result
                if let evidence = DeviceOutcomeNarrator.fileWidget(step: step, result: result),
                   !bubble.widgets.contains(where: { $0.widgetId == evidence.widgetId }) {
                    bubble.widgets.append(evidence)
                }
                if !result.isConfirmedSuccess {
                    bubble.failedSteps[step.id] = result.error?.message ?? (result.data?.hasFailedVerification == true ? String(localized: "Beklenen sonuç doğrulanamadı.") : result.message)
                }
                if case .processOutput(let output) = result.data {
                    bubble.codeRuns[step.id] = output
                }
            }
            if !result.isConfirmedSuccess { break }
        }
        // The full per-step breakdown (detail/onay/sonuç) is executionWidget, reading `steps` +
        // `stepResults` live for as long as this session runs - none of that survives a restart
        // (see CopilotStoredMessage), so a short summary line is still folded into `text` here as
        // the one thing that does.
        // The model's own follow-up answer describes the outcome; this one line is kept only when
        // the bubble would otherwise be empty after a restart (steps don't survive one).
        if let bubble = bubbles.first(where: { $0.id == bubbleID }), let summary = overallStepsSummary(bubble) {
            // A "doing it now" reply becomes what actually happened, unless the model still has to
            // read a result (that follow-up turn writes the final answer itself).
            let replaceProgress = bubble.replyIsProgress && !bubble.steps.contains(where: needsLocalResultFollowUp)
            let outcome = replaceProgress ? DeviceOutcomeNarrator.text(steps: bubble.steps, results: bubble.stepResults) : nil
            setBubble(bubbleID) { bubble in
                if let outcome {
                    bubble.text = outcome
                    bubble.replyIsProgress = false
                } else {
                    let text = executionNoticeFreeText(bubble.text)
                    bubble.text = text.isEmpty ? summary : text
                }
            }
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
        if failedCount == 0 { return String(localized: "Mac adımlarının sonuçları alındı; görevin kalanını kontrol ediyorum.") }
        if failedCount == relevant.count { return String(localized: "Bu isteği tamamlayamadım.") }
        return String(localized: "İşin bir kısmını yaptım; kalanını tamamlayamadım.")
    }

    /// Local reads and verified system controls are two-phase turns: first the Mac returns the
    /// private/verified result, then the backend receives that result and produces the final
    /// answer or the next bounded fallback step. This keeps private files local while allowing
    /// a failed Shortcut/AX action to be handled without asking the user to repeat the request.
    private func continueAfterLocalExecution(
        history: [RovaBackendClient.ChatTurn],
        initialReply: String,
        bubbleID: UUID,
        remainingRounds: Int,
        recoveryAttemptsRemaining: Int
    ) async {
        guard remainingRounds > 0, localContinuationRoundsRemaining > 0 else {
            setBubble(bubbleID) { $0.text = String(localized: "Bu turdaki adım sınırına ulaştım. Görevin tamamlandığı doğrulanmadı; devam etmemi isteyebilirsin.") }
            persistConversation()
            return
        }
        guard !recentDeviceResults.isEmpty else {
            return
        }
        let localResults = Array(recentDeviceResults.suffix(12))
        if localResults.contains(where: { $0.status == .unknown || $0.error?.code == "OUTCOME_UNKNOWN" || $0.error?.code == "TIMEOUT" }) {
            recentDeviceResults.removeAll(keepingCapacity: true)
            setBubble(bubbleID) { $0.text = String(localized: "Mac işleminin sonucu belirsiz. Aynı işlemi tekrar başlatmadım; önce Mac'teki sonucu kontrol et.") }
            persistConversation()
            return
        }
        let hasFailure = localResults.contains { $0.status != .completed || $0.error != nil }
        guard !hasFailure || recoveryAttemptsRemaining > 0 else {
            recentDeviceResults.removeAll(keepingCapacity: true)
            return
        }
        let nextRecoveryBudget = hasFailure ? recoveryAttemptsRemaining - 1 : recoveryAttemptsRemaining
        localRecoveryAttemptsRemaining = nextRecoveryBudget
        let taskStart = history.lastIndex { $0.role == "user" && !$0.content.hasPrefix("Yerel PC sonuçları hazır.") }
        let taskHistory = taskStart.map { Array(history[$0...]).filter { !$0.content.hasPrefix("Yerel PC sonuçları hazır.") } } ?? history
        let continuationHistory = Array(taskHistory.prefix(1)) + [
            RovaBackendClient.ChatTurn(role: "assistant", content: initialReply),
            RovaBackendClient.ChatTurn(role: "user", content: "Yerel PC sonuçları hazır. Bu sonuçları kullanarak önceki isteği şimdi tamamla; belge içeriğini yeniden isteme.")
        ]
        recentDeviceResults.removeAll(keepingCapacity: true)
        localContinuationRoundsRemaining -= 1
        liveReplyBubbleID = nil
        liveReply.reset()
        liveReplyBubbleID = bubbleID
        // The follow-up is the same task: its lines extend the timeline already on this bubble,
        // which goes live again (and leaves the bubble) until this round ends.
        if let previous = bubbles.first(where: { $0.id == bubbleID })?.thinking { thinking = previous }
        thinking.reopen()
        setBubble(bubbleID) { $0.thinking = nil }
        let priorBubble = bubbles.first(where: { $0.id == bubbleID })
        let priorStepIDs = Set(priorBubble?.steps.map(\.id) ?? [])
        let priorUpdateIDs = Set(priorBubble?.executionUpdates.keys.map { $0 } ?? [])
        let priorConfirmationIDs = Set(priorBubble?.backendConfirmations.map(\.id) ?? [])
        let priorPlanWidgets = priorBubble?.widgets.filter { $0.type == .task_plan } ?? []
        var earlyConfirmationBubbleID: UUID? = bubbleID
        do {
            let result = try await RovaBackendClient.converse(
                messages: continuationHistory,
                availableApps: availableApps,
                applicationTargets: model.deviceInfo?.applicationTargets ?? [],
                availableCapabilities: model.deviceInfo?.capabilities ?? [],
                authorities: model.deviceInfo?.authorities ?? [],
                deviceID: model.pairedDeviceIDForTransfer,
                conversationID: conversationID,
                taskID: bubbleID,
                turnCount: turnCount,
                deviceResults: localResults,
                requestID: UUID(),
                onStatus: { text in thinking.note(text) },
                onDelta: { text in liveReply.append(text) },
                onReset: {
                    liveReply.reset()
                    setBubble(bubbleID) { $0.text = "" }
                    persistConversation()
                },
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
                onWidgetUpdate: { widget in
                    let targetID = earlyConfirmationBubbleID ?? liveReplyBubbleID ?? presentPlanBubble(widget)
                    earlyConfirmationBubbleID = targetID
                    setBubble(targetID) { $0.widgets = CopilotWidgetCatalog.merging($0.widgets, with: [widget]) }
                    persistConversation()
                },
                onActivity: { activity in
                    thinking.apply(
                        id: activity.id,
                        phase: activity.phase,
                        label: activity.label,
                        state: ThinkingTrace.Step.State(rawValue: activity.state) ?? .done,
                        persona: activity.persona
                    )
                },
                onLocationRequired: { requestID in
                    await RovaBackendClient.requestAndContinueCopilotWeatherLocation(requestID: requestID)
                },
                onUsage: { used, limit in
                    subscriptionStore.applyMessageUsage(used: used, limit: limit)
                }
            )
            let replyText = result.reply.isEmpty
                ? (liveReply.currentText.isEmpty ? String(localized: "Bakıyorum…") : liveReply.currentText)
                : result.reply
            commitThinking(to: bubbleID, failed: result.executionState == "partial_success" || result.executionState == "failed")
            liveReply.finish(with: replyText)
            mergeContinuationResult(
                result,
                into: bubbleID,
                streamBubbleID: earlyConfirmationBubbleID,
                priorStepIDs: priorStepIDs,
                priorUpdateIDs: priorUpdateIDs,
                priorConfirmationIDs: priorConfirmationIDs,
                text: replyText
            )
            liveReplyBubbleID = nil
            liveReply.reset()
            persistConversation()
            CopilotConversationStore.flushPending()
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
                if remainingRounds <= 1 && !result.steps.isEmpty {
                    setBubble(bubbleID) { $0.text = String(localized: "Adım sınırına ulaştım. Son Mac sonucu alındı ancak görevin bütünü henüz doğrulanmadı; devam etmemi isteyebilirsin.") }
                }
                recentDeviceResults.removeAll(keepingCapacity: true)
            }
            persistConversation()
        } catch {
            // Keep the isolated task browser visible for an explicit retry. Its owner closes it
            // only when the user explicitly asks or the desktop runtime itself shuts down.
            liveReplyBubbleID = nil
            liveReply.reset()
            commitThinking(to: bubbleID, failed: true)
            if confirmationBubbleID == bubbleID { confirmationBubbleID = nil }
            // The first local read already succeeded and is visible in the original bubble. Keep
            // that evidence rather than replacing it with a generic network failure.
            setBubble(bubbleID) { bubble in
                bubble.steps.removeAll { !priorStepIDs.contains($0.id) }
                bubble.executionUpdates = bubble.executionUpdates.filter { priorUpdateIDs.contains($0.key) || $0.value.kind != "device" }
                bubble.widgets.removeAll { $0.type == .task_plan }
                bubble.widgets.append(contentsOf: priorPlanWidgets)
                bubble.backendConfirmations.removeAll { !priorConfirmationIDs.contains($0.id) && $0.status == .pending }
                bubble.needsConfirmation = false
                bubble.text = executionNoticeFreeText(bubble.text) + String(localized: "\n\nYerel sonuç alındı; kalan adımı tamamlayamadım.")
            }
            persistConversation()
            CopilotConversationStore.flushPending()
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
        priorStepIDs: Set<UUID>,
        priorUpdateIDs: Set<UUID>,
        priorConfirmationIDs: Set<UUID>,
        text: String
    ) {
        let streamBubble = streamBubbleID.flatMap { id in bubbles.first(where: { $0.id == id }) }
        let incomingForceQuit = result.steps.contains { isForceQuitStep($0) }
        setBubble(bubbleID) { bubble in
            if let streamBubble, streamBubble.id != bubbleID {
                for (id, update) in streamBubble.executionUpdates { bubble.executionUpdates[id] = update }
                for row in streamBubble.backendConfirmations where !bubble.backendConfirmations.contains(where: { $0.id == row.id }) {
                    bubble.backendConfirmations.append(row)
                }
            }
            if incomingForceQuit {
                // The graceful close receipt is the reason for the next safety decision, not a
                // second user-facing failure. Replace that intermediate row with the pending
                // force-quit row so the sheet and execution card tell one coherent story.
                let superseded = Set(bubble.stepResults.compactMap { id, commandResult in
                    commandResult.error?.code == "APPLICATION_QUIT_REQUIRES_FORCE" ? id : nil
                })
                bubble.steps.removeAll { superseded.contains($0.id) }
                for id in superseded {
                    bubble.stepResults.removeValue(forKey: id)
                    bubble.failedSteps.removeValue(forKey: id)
                    bubble.executedStepIDs.remove(id)
                }
            }
            if !bubble.failedSteps.isEmpty && !result.steps.isEmpty {
                for step in bubble.steps where !bubble.executedStepIDs.contains(step.id) && !result.steps.contains(where: { $0.id == step.id }) {
                    bubble.executedStepIDs.insert(step.id)
                    bubble.failedSteps[step.id] = String(localized: "Önceki hata nedeniyle çalıştırılmadı.")
                }
            }
            // Streamed confirmation steps are only previews. Keep prior turns' history,
            // then take executable steps exclusively from the validated terminal response.
            bubble.steps.removeAll { !priorStepIDs.contains($0.id) }
            let incomingStepIDs = Set(result.steps.map(\.id))
            bubble.steps.removeAll { incomingStepIDs.contains($0.id) }
            bubble.steps.append(contentsOf: result.steps)
            let terminalConfirmationIDs = Set(result.backendConfirmations.map(\.id))
            bubble.backendConfirmations.removeAll {
                !priorConfirmationIDs.contains($0.id) && !terminalConfirmationIDs.contains($0.id)
            }
            let representedIDs = incomingStepIDs.union(terminalConfirmationIDs)
            bubble.executionUpdates = bubble.executionUpdates.filter {
                priorUpdateIDs.contains($0.key) || representedIDs.contains($0.key)
            }
            let existingArtifactIDs = Set(bubble.artifacts.map(\.id))
            bubble.artifacts.append(contentsOf: result.artifacts.filter { !existingArtifactIDs.contains($0.id) })
            bubble.widgets = CopilotWidgetCatalog.merging(bubble.widgets, with: result.widgets)
            bubble.text = text
            bubble.executionState = result.executionState
            bubble.replyIsProgress = result.replyIsProgress
            if let deferred = result.deferredTask { bubble.deferredTask = deferred }
            if let project = result.projectTask { bubble.projectTask = project }
            if let agentTask = result.agentTask { bubble.agentTask = agentTask }
            bubble.backendConfirmations = mergedBackendConfirmations(
                existing: bubble.backendConfirmations,
                incoming: result.backendConfirmations,
                executionUpdates: bubble.executionUpdates
            )
            let pendingStates: Set<String> = [
                "pending_local_execution",
                "awaiting_local_confirmation",
                "awaiting_backend_confirmation",
                "awaiting_weather_location"
            ]
            if let executionState = result.executionState, !pendingStates.contains(executionState) {
                let representedIDs = Set(bubble.steps.map(\.id))
                    .union(bubble.backendConfirmations.map(\.id))
                    .union(bubble.backendConfirmations.compactMap { row in
                        bubble.executionUpdates.values.first(where: { $0.confirmationId == row.id })?.id
                    })
                let transientStatuses: Set<String> = [
                    LiveExecutionStatus.ready.rawValue,
                    LiveExecutionStatus.awaitingConfirmation.rawValue,
                    LiveExecutionStatus.dispatching.rawValue,
                    LiveExecutionStatus.running.rawValue
                ]
                let orphanedUpdateIDs = bubble.executionUpdates.compactMap { id, update in
                    !representedIDs.contains(id) && transientStatuses.contains(update.status) ? id : nil
                }
                for id in orphanedUpdateIDs { bubble.executionUpdates.removeValue(forKey: id) }
            }
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
            return files.isEmpty ? String(localized: "Masaüstü boş.") : "Dosyalar: \(names)"
        case .files(let files):
            let names = files.map { $0.name + ($0.isDirectory ? "/" : "") }.joined(separator: ", ")
            return files.isEmpty ? String(localized: "Klasör boş.") : "Dosyalar: \(names)"
        case .fileData(let content):
            if let text = content.text { return String(text.prefix(2_000)) }
            return String(localized: "\(content.mimeType) dosyası okundu.")
        case .screenshot(let content):
            return String(localized: "Ekran görüntüsü: \(content.width)×\(content.height)")
        case .shortcutResult(let content):
            return String(localized: "Doğrulama: \(content.verified ? String(localized: "başarılı") : String(localized: "başarısız")) (beklenen: \(content.expectedState), gözlenen: \(content.observedState ?? String(localized: "belirsiz")))")
        case .uiElement(let content):
            return String(localized: "Eşleşme: \(content.title ?? content.description ?? String(localized: "etiket")) (\(content.verified ? String(localized: "doğrulandı") : String(localized: "doğrulanamadı")))")
        case .screenClick(let content):
            return String(localized: "Koordinat: \(Int(content.x.rounded())), \(Int(content.y.rounded())) — yeniden gözlem gerekli.")
        case .applicationControl(let content):
            return String(localized: "Doğrulama: \(content.verified ? String(localized: "başarılı") : String(localized: "başarısız")) (önce: \(content.stateBefore), sonra: \(content.stateAfter))")
        case .calendarEvents(let events):
            if events.isEmpty { return String(localized: "Yaklaşan etkinlik yok.") }
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return events.prefix(8).map { "\($0.title) (\(formatter.string(from: $0.startAt)))" }.joined(separator: "; ")
        case .reminders(let reminders):
            if reminders.isEmpty { return String(localized: "Hatırlatıcı yok.") }
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
            if entries.isEmpty { return String(localized: "Pano geçmişi boş.") }
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return entries.prefix(10).map { "\(formatter.string(from: $0.copiedAt)): \($0.text.prefix(120))" }.joined(separator: "\n")
        case .processOutput(let output):
            // The code and its full stdout/stderr are shown in the dedicated, collapsible code
            // card instead (see CodeExecutionCard) - this line stays short.
            return String(localized: "Çıkış kodu \(output.exitCode), \(output.durationMs) ms")
        case .systemStatus(let status):
            var parts = ["PC · \(status.macOSVersion)", formatUptime(status.uptimeSeconds)]
            if let battery = status.batteryPercentage { parts.append("pil %\(battery)\(status.isCharging == true ? " ⚡︎" : "")") }
            return parts.joined(separator: " • ")
        case .installedApplications(let apps):
            return apps.isEmpty ? String(localized: "Yüklü uygulama bulunamadı.") : "Uygulamalar: \(apps.prefix(20).map(\.name).joined(separator: ", "))"
        case .runningApplications(let apps):
            if apps.isEmpty { return String(localized: "Açık uygulama yok.") }
            return apps.prefix(30).map { $0.isActive ? String(localized: "\($0.name) (öndeki)") : $0.name }.joined(separator: ", ")
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
                "value": files.map { ["path": $0.path, "name": $0.name, "fileType": $0.fileType ?? "", "byteCount": $0.byteCount, "isDirectory": $0.isDirectory] }
            ], options: [.sortedKeys])
        case .fileData(let content):
            // Raw bytes never go in dataText: the model can't use base64, and it pushed the field
            // past the backend's 12,000-character limit so the whole follow-up was rejected. A
            // file the user asked to receive travels separately (deliveredFile).
            var value: [String: Any] = ["path": content.path, "mimeType": content.mimeType, "truncated": content.truncated]
            if let text = content.text { value["text"] = String(text.prefix(10_000)) }
            if let base64 = content.base64 { value["binaryBytes"] = base64.count * 3 / 4 }
            encoded = try? JSONSerialization.data(withJSONObject: ["kind": "fileData", "value": value], options: [.sortedKeys])
        case .screenshot(let content):
            encoded = try? JSONSerialization.data(withJSONObject: [
                "kind": "screenshot", "value": ["filename": content.filename, "mimeType": content.mimeType, "width": content.width, "height": content.height]
            ], options: [.sortedKeys])
        case .fileTransfer:
            return nil
        default:
            encoded = try? JSONEncoder.rovaISO8601.encode(data)
        }
        guard let encoded else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    /// Must match SEND_TO_PHONE_SUMMARY_PREFIX in rova-backend/src/tools/deviceTools.ts.
    private static let sendToPhonePrefix = "Telefona gönder: "

    /// The bytes of a file the user asked Wiqo to send to the phone. Only a step the backend
    /// planned as "Telefona gönder" uploads anything; an ordinary read keeps its content local.
    private func deliveredFile(step: PlannedCommand, data: CommandData?) -> (base64: String, name: String, mimeType: String)? {
        guard step.type == .readFile, step.summary.hasPrefix(Self.sendToPhonePrefix),
              case .fileData(let content) = data else { return nil }
        let base64 = content.base64 ?? content.text.map { Data($0.utf8).base64EncodedString() }
        guard let base64, !base64.isEmpty, !content.truncated else { return nil }
        let name = (content.path as NSString).lastPathComponent
        return (base64, name.isEmpty ? "dosya" : name, content.mimeType)
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
                bubbles.append(ChatBubble(role: .system, text: String(localized: "Bir görsel desteklenen boyut sınırını aştığı için eklenmedi.")))
                continue
            }
            pendingAttachments.append(RovaBackendClient.ChatAttachment(name: item.itemIdentifier ?? "gorsel.jpg", mimeType: "image/jpeg", dataBase64: encoded.base64EncodedString()))
            attachmentPreviews.append(normalized)
        }
    }

    /// Reads picked files on device. A file that can't be read is reported and skipped; the rest
    /// still attach.
    private func prepareFiles(_ urls: [URL]) async {
        isPreparingAttachment = true
        defer { isPreparingAttachment = false }
        for url in urls {
            guard pendingFiles.count < maxFiles else {
                bubbles.append(ChatBubble(role: .system, text: "Bir mesaja en fazla \(maxFiles) dosya eklenebilir."))
                break
            }
            do {
                pendingFiles.append(try await FileContentExtractor.extract(from: url))
            } catch {
                bubbles.append(ChatBubble(role: .system, text: "\(url.lastPathComponent): \(error.localizedDescription)"))
            }
        }
    }

    private func prepareScan(_ pages: [UIImage], wasTruncated: Bool) async {
        guard !pages.isEmpty, pendingFiles.count < maxFiles else { return }
        isPreparingAttachment = true
        defer { isPreparingAttachment = false }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        do {
            pendingFiles.append(try await FileContentExtractor.extract(scannedPages: pages, name: "Tarama \(formatter.string(from: Date()))", wasTruncated: wasTruncated))
        } catch {
            bubbles.append(ChatBubble(role: .system, text: error.localizedDescription))
        }
    }

    private func removeAttachment(at index: Int) {
        guard attachmentPreviews.indices.contains(index) else { return }
        attachmentPreviews.remove(at: index)
        pendingAttachments.remove(at: index)
    }

    private func clearAttachments() {
        selectedPhotos = []
        pendingFiles = []
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

    private func loadOpenWork() async {
        guard RovaBackendClient.isAuthenticated, !bubbles.isEmpty else { return }
        openWork = try? await RovaBackendClient.fetchOpenWork(conversationID: conversationID)
    }

    private func loadMemoryCandidates() async {
        guard RovaBackendClient.isAuthenticated else { return }
        if let candidates = try? await RovaBackendClient.fetchMemoryCandidates() {
            memoryCandidates = candidates.filter { $0.status == "pending" }
        }
    }

    /// Loads remote history for an empty local conversation and refreshes named-agent chats when
    /// opened, so a corrected background result cannot remain stuck in the device cache.
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
            return ChatBubble(
                role: role,
                text: item.text,
                artifacts: item.artifacts ?? [],
                widgets: CopilotWidgetCatalog.normalized(item.widgets ?? [])
            )
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
                    bubbles.append(ChatBubble(role: .system, text: String(localized: "Ses net anlaşılamadı. Lütfen tekrar dene.")))
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
                bubbles.append(ChatBubble(role: .system, text: String(localized: "Konuşma tanıma şu anda kullanılamıyor - Siri ve Dikte'nin Ayarlar'dan açık olduğundan ve internete bağlı olduğundan emin ol. Ses sunucuya gönderilmedi; bu arada metni yazabilirsin.")))
            case .setupFailed:
                bubbles.append(ChatBubble(role: .system, text: String(localized: "Mikrofon başlatılamadı; başka bir uygulama mikrofonu kullanıyor olabilir. Lütfen tekrar dene.")))
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func needsLocalResultFollowUp(_ step: PlannedCommand) -> Bool {
        // Every device result returns to the same task, including writes. A successful write
        // may be only the first part of a longer request; the UI cannot finalize the goal.
        step.type != .executeCode
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
            String(localized: "\n\nİstediklerini sırayla yapıyorum…"),
            String(localized: "İstediklerini sırayla yapıyorum…"),
            String(localized: "\n\nİstediklerini yaptım."),
            String(localized: "\n\nOnayını bekliyor; onay verdiğinde PC'de çalıştırılacak."),
            String(localized: "\n\nBu cihaz eylemleri henüz çalıştırılmadı; önce uygulamadaki onayını bekliyor."),
            String(localized: "\n\nBu PC komutları hazırlanıp yerel cihaza gönderilecek; gerçek sonucu henüz doğrulamadım."),
            String(localized: "\n\nİstediğin işlemi PC'ye gönderiyorum; gerçek sonucu alınca haber vereceğim."),
            String(localized: "\n\nPC'de çalıştırılıyor; gerçek sonuç doğrulanınca burada gösterilecek."),
            String(localized: "\n\nPC'de çalıştırılıyor…"),
            String(localized: " için onayını bekliyorum."),
            String(localized: " isteği PC'de çalıştırılıyor; gerçek sonuç doğrulanınca burada göstereceğim."),
            String(localized: " başlatılıyor.")
        ]
        var result = text
        for notice in notices { result = result.replacingOccurrences(of: notice, with: "") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Live progress is the execution card's job ("Şimdi şunu yapıyorum: …"); writing a filler line
    /// into the answer text only stacked "İstediklerini sırayla yapıyorum…" once per round.
    private func executionStartedText(_ text: String) -> String {
        executionNoticeFreeText(text)
    }

    /// The latest reply's PC step that still waits for approval (also one whose sheet was dismissed), if the conversation has not moved on.
    private var bubbleAwaitingApproval: ChatBubble? {
        guard let last = bubbles.last(where: { $0.role != .system }), last.role == .assistant else { return nil }
        if last.needsConfirmation { return last }
        return currentLocalConfirmationStep(in: last) == nil ? nil : last
    }

    /// "devam et", "evet", "onayla" typed while a PC step waits for approval is that approval: the approval sheet comes back, instead of a new
    /// request that cannot see the waiting step (it answered "Bu sonuç önceki bir göreve ait"). "vazgeç" / "iptal" cancels it.
    private func answerPendingConfirmation(with text: String) -> Bool {
        let folded = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        // Turkish as before, plus the words of the phone's own language for the same answers ("Ja", "Abbrechen"...).
        let approve = Set(["devam", "devam et", "devam edelim", "kaldığın yerden devam et", "evet", "onayla", "onaylıyorum", "tamam", "olur", "yap", "başla", "evet devam et"])
            .union([String(localized: "Evet"), String(localized: "Onayla"), String(localized: "Tamam"), String(localized: "Devam et")].map { $0.lowercased() })
        let decline = Set(["vazgeç", "iptal", "iptal et", "hayır", "dur", "yapma"])
            .union([String(localized: "Hayır"), String(localized: "İptal"), String(localized: "Vazgeç")].map { $0.lowercased() })
        guard approve.contains(folded) || decline.contains(folded), let bubble = bubbleAwaitingApproval else { return false }
        if decline.contains(folded) {
            if bubble.needsConfirmation { cancelConfirmation(for: bubble.id) }
            return true
        }
        if !bubble.needsConfirmation, let step = currentLocalConfirmationStep(in: bubble) {
            setBubble(bubble.id) { reopened in
                reopened.failedSteps[step.id] = nil
                reopened.needsConfirmation = true
                reopened.text = reopened.text.replacingOccurrences(of: "\n\nİşlem iptal edildi.", with: "")
            }
        }
        confirmationBubbleID = bubble.id
        return true
    }

    private func cancelConfirmation(for bubbleID: UUID) {
        isComposerFocused = false
        if taskReadApprovalBubbleID == bubbleID { taskReadApprovalBubbleID = nil; taskWriteApproved = false }
        setBubble(bubbleID) { bubble in
            bubble.needsConfirmation = false
            if let step = bubble.steps.first(where: { step in
                !bubble.executedStepIDs.contains(step.id) && requiresLocalConfirmation(step)
            }) {
                bubble.failedSteps[step.id] = String(localized: "İşlem iptal edildi.")
            }
            let base = executionNoticeFreeText(bubble.text)
            bubble.text = base.isEmpty ? String(localized: "İşlem iptal edildi.") : base + String(localized: "\n\nİşlem iptal edildi.")
        }
    }

    private func openCreatedResource(_ widget: RovaBackendClient.CopilotResultWidget) {
        guard widget.type == .created_resource,
              let resourceType = widget.resourceType,
              let resourceID = widget.id else { return }

        switch resourceType {
        case .agent:
            widgetDestination = .agents
        case .automation:
            widgetDestination = .automation(RovaBackendClient.RovaAutomation(
                id: resourceID,
                prompt: widget.detail ?? widget.title ?? String(localized: "Otomasyon"),
                cron: widget.schedule ?? "",
                isActive: widget.status == "active",
                nextRunAt: widget.nextRunAt,
                scheduleLabel: widget.scheduleLabel
            ))
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
            let widgets = CopilotWidgetCatalog.normalized(bubble.widgets)
            return CopilotStoredMessage(
                role: role,
                text: bubble.text,
                artifacts: bubble.artifacts.isEmpty ? nil : bubble.artifacts,
                widgets: widgets.isEmpty ? nil : widgets,
                attachmentThumbnails: bubble.attachmentThumbnails.isEmpty ? nil : bubble.attachmentThumbnails,
                thinking: bubble.thinking,
                fileNames: bubble.attachedFileNames.isEmpty ? nil : bubble.attachedFileNames,
                deferredTask: bubble.deferredTask,
                projectTask: bubble.projectTask,
                agentTask: bubble.agentTask
            )
        }
        CopilotConversationStore.saveSoon(id: conversationID, messages: stored, turnCount: turnCount)
    }
}
