import AVFoundation
import PhotosUI
import QuickLook
import SwiftUI
import UIKit

private struct ChatBubble: Identifiable {
    enum Role { case user, assistant, system }

    let id = UUID()
    let role: Role
    var text: String
    var steps: [PlannedCommand] = []
    var needsConfirmation = false
    var executedStepIDs: Set<UUID> = []
    var artifacts: [RovaBackendClient.ArtifactDescriptor] = []
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
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(payload.code)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.primary)
                        .padding(10)
                }
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    Text("Çıktı • çıkış kodu \(run.exitCode) • \(run.durationMs) ms")
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
            Label("Onay bekliyor", systemImage: "clock.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
        } else if let run {
            Label(run.exitCode == 0 ? "Başarılı" : "Başarısız", systemImage: run.exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(run.exitCode == 0 ? .green : .red)
        } else if failureMessage != nil {
            Label("Başarısız", systemImage: "xmark.circle.fill")
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
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onConfirmAndAlwaysAllow: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var qualifiesForAlwaysAllow: Bool {
        bubble.steps.contains { CopilotView.userGrantableTypes.contains($0.type) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(bubble.steps) { step in
                        if step.type == .executeCode, case .codeExecution(let payload) = step.payload {
                            CodeExecutionCard(payload: payload, summary: step.summary, run: nil, failureMessage: nil, isPending: true)
                        } else {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(step.summary)
                                    .font(.subheadline)
                                Spacer()
                            }
                            .padding(12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: RovaDesign.chipRadius, style: .continuous))
                        }
                    }

                    if qualifiesForAlwaysAllow {
                        Text("\"Her zaman izin ver\" seçilirse Wiqo bu tür eylemleri bundan sonra onay istemeden çalıştırır. Bunu istediğin zaman Ayarlar › Onaylı Eylemler'den geri alabilirsin.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Onay gerekiyor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("İptal", role: .cancel) { onCancel() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        onConfirm()
                    } label: {
                        Label("Onayla ve Çalıştır", systemImage: "checkmark.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if qualifiesForAlwaysAllow {
                        Button {
                            onConfirmAndAlwaysAllow()
                        } label: {
                            if isGranting {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Label("Onayla, her zaman izin ver", systemImage: "checkmark.shield.fill")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(isGranting)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .background(.bar)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private let suggestions: [(title: String, icon: String)] = [
    ("Toplantıya hazırla", "person.2.fill"),
    ("Sesi kıs", "speaker.wave.1.fill"),
    ("Bugün hava nasıl?", "cloud.sun.fill"),
    ("Ekranı kısarak odaklan", "moon.stars.fill")
]

/// Wiqo's conversation surface. A real conversation, not a one-shot "type → plan → confirm" form - every
/// message (from either side) is kept in `bubbles` and the full history is resent with each new
/// message so the model has context (the backend itself is stateless).
///
/// Non-destructive steps the model decides on (volume, brightness, opening an app, ...) run
/// immediately and silently once the reply is shown, exactly like the model just "did the
/// thing" - no extra screen in between. Destructive or presence-gated steps (lock, sleep, quit
/// app, file writes, messages, calendar writes) still show an inline confirmation under that
/// message and require Face ID/Touch ID, matching the manual buttons on the Mac tab.
struct CopilotView: View {
    @ObservedObject var model: IOSConnectionModel
    @ObservedObject var authSession: AuthSessionStore
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
    @State private var proactiveSuggestions: [RovaBackendClient.ProactiveSuggestion] = []
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var pendingAttachments: [RovaBackendClient.ChatAttachment] = []
    @State private var attachmentPreviews: [UIImage] = []
    @State private var isPreparingAttachment = false
    @State private var isPhotosPickerPresented = false
    @State private var showCanvas = false
    @FocusState private var isComposerFocused: Bool
    /// Mirrors the backend's own per-message cap (routes/copilot.ts's chatRequestSchema) - the
    /// picker and the strip both enforce it so the UI never lets the user build a request the
    /// backend would then reject.
    private let maxAttachments = 4
    @State private var memoryCandidates: [RovaBackendClient.MemoryCandidate] = []
    @State private var screenshotObservationCount = 0
    @StateObject private var audioRecorder = RovaAudioRecorder()
    @State private var showingMicPermissionAlert = false
    @StateObject private var audioPlayer = RovaAudioPlayer()
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

    /// Set only when this conversation should open with one prompt already sitting in the
    /// composer - e.g. picking an automation template. Pre-fills and focuses the composer so the
    /// user can still edit it before sending; never sent on their behalf. Consumed once in `.task`.
    private let draftPrompt: String?

    init(model: IOSConnectionModel, authSession: AuthSessionStore, conversationID: String? = nil, draftPrompt: String? = nil) {
        self.model = model
        self.authSession = authSession
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
        .quickLookPreview($previewURL)
        .alert("Mikrofon izni gerekli", isPresented: $showingMicPermissionAlert) {
            Button("Ayarları Aç") { openSystemSettings() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Sesli mesaj gönderebilmek için Ayarlar'dan Wiqo'ya mikrofon izni vermen gerekiyor.")
        }
        .sheet(isPresented: Binding(
            get: { confirmationBubbleID != nil },
            set: { isPresented in
                if !isPresented, let bubbleID = confirmationBubbleID, !confirmationHandledExplicitly {
                    // A plain swipe-down, not one of the sheet's own buttons - treat exactly like
                    // "İptal" so the bubble is never left silently stuck awaiting confirmation.
                    setBubble(bubbleID) { $0.needsConfirmation = false; $0.steps = [] }
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
        VStack {
            Spacer()
            Image("WiqoMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
                .accessibilityLabel("Wiqo")
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.title) { suggestion in
                    Button {
                        inputText = suggestion.title
                        Task { await sendMessage() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: suggestion.icon)
                                .foregroundStyle(.secondary)
                            Text(suggestion.title)
                                .foregroundStyle(.primary)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var proactiveCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Wiqo önerisi", systemImage: "lightbulb.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            ForEach(proactiveSuggestions) { suggestion in
                VStack(alignment: .leading, spacing: 8) {
                    Text(suggestion.title).font(.subheadline.weight(.medium))
                    Text(suggestion.body).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Sor") {
                            inputText = suggestion.prompt
                            proactiveSuggestions.removeAll { $0.id == suggestion.id }
                            Task { await markSuggestion(suggestion.id, action: "accept") }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Kapat") {
                            proactiveSuggestions.removeAll { $0.id == suggestion.id }
                            Task { await markSuggestion(suggestion.id, action: "dismiss") }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: RovaDesign.chipRadius, style: .continuous))
            }
        }
        .padding(.horizontal)
    }

    private var memoryCandidatesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Wiqo hafıza önerisi", systemImage: "brain.head.profile")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.purple)
            ForEach(memoryCandidates) { candidate in
                VStack(alignment: .leading, spacing: 8) {
                    Text(candidate.content)
                        .font(.subheadline)
                    HStack {
                        Button("Hatırla") {
                            memoryCandidates.removeAll { $0.id == candidate.id }
                            Task {
                                do { try await RovaBackendClient.acceptMemoryCandidate(id: candidate.id) }
                                catch { await loadMemoryCandidates() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Kapat") {
                            memoryCandidates.removeAll { $0.id == candidate.id }
                            Task {
                                do { try await RovaBackendClient.dismissMemoryCandidate(id: candidate.id) }
                                catch { await loadMemoryCandidates() }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: RovaDesign.chipRadius, style: .continuous))
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
                        ReplyBlocksView(text: liveReply.displayed)
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

    /// Wiqo's reasoning stages for the turn in flight, oldest first: earlier stages settle into a
    /// dim, checked-off line while the newest one stays highlighted with the live ThinkingOrbsPill
    /// animation - the same "show your work as you go" shape ChatGPT/Gemini use, not a single line
    /// that overwrites.
    private var thinkingStagesView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(statusMessages.enumerated()), id: \.offset) { index, message in
                let isCurrent = index == statusMessages.count - 1
                HStack(spacing: 8) {
                    if isCurrent {
                        // "Görsel" only ever appears in the two image-generation/edit status
                        // strings describeCall emits (groq/client.ts) - everything else (research,
                        // memory, device actions, plain reasoning) gets the ordinary working look.
                        (message.contains("Görsel") ? ThinkingOrbsPill.generatingPreset : ThinkingOrbsPill.workingPreset)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 16)
                    }
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(isCurrent ? .secondary : .tertiary)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal)
        .id("thinkingStages")
        .animation(.easeInOut(duration: 0.2), value: statusMessages)
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
            if !bubble.needsConfirmation && !bubble.failedSteps.isEmpty {
                failureCard(for: bubble)
            }
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
                    isPending: bubble.needsConfirmation
                )
            }
        }
    }

    private func codePayload(_ step: PlannedCommand) -> CodeExecutionPayload? {
        guard case .codeExecution(let payload) = step.payload else { return nil }
        return payload
    }

    /// Shown for auto-run (non-destructive) steps that actually failed - these otherwise have no
    /// visible trace at all once the reply text is on screen.
    private func failureCard(for bubble: ChatBubble) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(bubble.steps.filter { bubble.failedSteps[$0.id] != nil }) { step in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.summary).font(.subheadline.weight(.medium))
                        if let message = bubble.failedSteps[step.id] {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: RovaDesign.chipRadius, style: .continuous))
        .padding(.top, 2)
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

    private func grantableSteps(_ bubble: ChatBubble) -> [PlannedCommand] {
        bubble.steps.filter { Self.userGrantableTypes.contains($0.type) }
    }

    private func presentConfirmation(for bubbleID: UUID) {
        confirmationHandledExplicitly = false
        confirmationBubbleID = bubbleID
    }

    /// Native bottom sheet (not an inline card) so a confirmation is never missed by scrolling
    /// past it - opens automatically the moment a turn needs one.
    private var confirmationSheetContent: some View {
        Group {
            if let bubbleID = confirmationBubbleID, let bubble = bubbles.first(where: { $0.id == bubbleID }) {
                ConfirmationSheetView(
                    bubble: bubble,
                    isGranting: isGrantingTrust,
                    onCancel: {
                        confirmationHandledExplicitly = true
                        setBubble(bubbleID) { $0.needsConfirmation = false; $0.steps = [] }
                        confirmationBubbleID = nil
                    },
                    onConfirm: {
                        confirmationHandledExplicitly = true
                        confirmationBubbleID = nil
                        Task { await confirmAndExecute(bubbleID: bubbleID) }
                    },
                    onConfirmAndAlwaysAllow: {
                        confirmationHandledExplicitly = true
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
        confirmationBubbleID = nil
        await confirmAndExecute(
            bubbleID: bubbleID,
            reason: "Bu tür eylemleri onaysız çalıştırmaya izin vermek için kimliğinizi doğrulayın"
        ) {
            guard let bubble = self.bubbles.first(where: { $0.id == bubbleID }) else { return }
            self.isGrantingTrust = true
            for step in self.grantableSteps(bubble) {
                _ = try? await RovaBackendClient.grantTrust(type: step.type.rawValue, summary: step.summary)
            }
            self.isGrantingTrust = false
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
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            bubbles.append(ChatBubble(role: .system, text: message))
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
                Menu {
                    Button {
                        isPhotosPickerPresented = true
                    } label: {
                        Label("Fotoğraf ekle", systemImage: "photo")
                    }
                    .disabled(pendingAttachments.count >= maxAttachments)

                    Button {
                        showCanvas = true
                    } label: {
                        Label("Kod çalıştır", systemImage: "curlybraces")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                }
                .disabled(isSending || isPreparingAttachment)
                .accessibilityLabel("Ekle")
                .photosPicker(
                    isPresented: $isPhotosPickerPresented,
                    selection: $selectedPhotos,
                    maxSelectionCount: max(1, maxAttachments - pendingAttachments.count),
                    matching: .images,
                    photoLibrary: .shared()
                )
                .sheet(isPresented: $showCanvas) {
                    CanvasView()
                }

                TextField(audioRecorder.isRecording ? "Dinliyorum…" : "Wiqo'ya yaz", text: $inputText, axis: .vertical)
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
        if isPreparingAttachment || isSending {
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
            .transition(.scale.combined(with: .opacity))
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
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    }

    private var availableApps: [ApplicationID] {
        model.deviceInfo?.availableApplications.map(\.id) ?? []
    }

    private func sendMessage() async {
        let typedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typedText.isEmpty || !pendingAttachments.isEmpty else { return }
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
                onReset: { liveReply.reset() }
            )
            let replyText = result.reply.isEmpty ? "…" : result.reply
            await liveReply.finish(with: replyText)
            var reply = ChatBubble(role: .assistant, text: replyText, steps: result.steps, artifacts: result.artifacts)
            if result.steps.contains(where: { $0.isDestructive || $0.requiresUserPresence }) {
                reply.needsConfirmation = true
                bubbles.append(reply)
                liveReply.reset()
                presentConfirmation(for: reply.id)
            } else {
                bubbles.append(reply)
                liveReply.reset()
                recentDeviceResults.removeAll(keepingCapacity: true)
                await execute(result.steps, bubbleID: reply.id)
                if result.steps.contains(where: needsLocalResultFollowUp) {
                    await continueAfterLocalExecution(history: history, initialReply: result.reply, bubbleID: reply.id)
                }
            }
            persistConversation()
        } catch RovaBackendError.notAuthenticated {
            // Sends the whole app back to the login screen (RootView switches on this),
            // there's no local sheet/screen of our own to dismiss here.
            liveReply.reset()
            authSession.signOut()
        } catch {
            liveReply.reset()
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            bubbles.append(ChatBubble(role: .system, text: message))
            persistConversation()
        }
    }

    private func confirmAndExecute(bubbleID: UUID, reason: String = "Bu eylemleri PC'de çalıştırmak için kimliğinizi doğrulayın", beforeExecute: () async -> Void = {}) async {
        let ok = await model.authenticateBiometrics(reason: reason)
        guard ok else { return }
        await beforeExecute()
        setBubble(bubbleID) { $0.needsConfirmation = false }
        guard let steps = bubbles.first(where: { $0.id == bubbleID })?.steps else { return }
        let shouldContinue = steps.contains(where: needsLocalResultFollowUp)
        let initialReply = bubbles.first(where: { $0.id == bubbleID })?.text ?? ""
        let history = bubbles
            .filter { $0.role != .system }
            .suffix(16)
            .map { RovaBackendClient.ChatTurn(role: $0.role == .user ? "user" : "assistant", content: $0.text) }
        await execute(steps, bubbleID: bubbleID)
        if shouldContinue { await continueAfterLocalExecution(history: history, initialReply: initialReply, bubbleID: bubbleID) }
        persistConversation()
    }

    private func execute(_ steps: [PlannedCommand], bubbleID: UUID) async {
        var outcomeLines: [String] = []
        for step in steps {
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
                    outcomeLines.append(localOutcomeLine(step: step, result: result))
                    setBubble(bubbleID) { bubble in
                        bubble.executedStepIDs.insert(step.id)
                        bubble.failedSteps[step.id] = result.error?.message ?? result.message
                    }
                    continue
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
            outcomeLines.append(localOutcomeLine(step: step, result: result))
            setBubble(bubbleID) { bubble in
                bubble.executedStepIDs.insert(step.id)
                if result.status != .completed {
                    bubble.failedSteps[step.id] = result.error?.message ?? result.message
                }
                if case .processOutput(let output) = result.data {
                    bubble.codeRuns[step.id] = output
                }
            }
        }
        if !outcomeLines.isEmpty {
            setBubble(bubbleID) { bubble in
                bubble.text += "\n\nYerel PC sonucu:\n" + outcomeLines.joined(separator: "\n")
            }
        }
        persistConversation()
    }

    /// Local reads and verified system controls are two-phase turns: first the Mac returns the
    /// private/verified result, then the backend receives that result and produces the final
    /// answer or the next bounded fallback step. This keeps private files local while allowing
    /// a failed Shortcut/AX action to be handled without asking the user to repeat the request.
    private func continueAfterLocalExecution(
        history: [RovaBackendClient.ChatTurn],
        initialReply: String,
        bubbleID: UUID,
        remainingRounds: Int = 3
    ) async {
        guard remainingRounds > 0 else { return }
        guard !recentDeviceResults.isEmpty, model.state == .connected else { return }
        let continuationHistory = history + [
            RovaBackendClient.ChatTurn(role: "assistant", content: initialReply),
            RovaBackendClient.ChatTurn(role: "user", content: "Yerel PC sonuçları hazır. Bu sonuçları kullanarak önceki isteği şimdi tamamla; belge içeriğini yeniden isteme.")
        ]
        let localResults = Array(recentDeviceResults.suffix(12))
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
                onReset: { liveReply.reset() }
            )
            let replyText = result.reply.isEmpty ? "…" : result.reply
            await liveReply.finish(with: replyText)
            var followUp = ChatBubble(role: .assistant, text: replyText, steps: result.steps, artifacts: result.artifacts)
            bubbles.append(followUp)
            liveReply.reset()
            if result.steps.contains(where: { $0.isDestructive || $0.requiresUserPresence }) {
                followUp.needsConfirmation = true
                setBubble(followUp.id) { $0.needsConfirmation = true }
                presentConfirmation(for: followUp.id)
            } else {
                recentDeviceResults.removeAll(keepingCapacity: true)
                await execute(result.steps, bubbleID: followUp.id)
                if result.steps.contains(where: needsLocalResultFollowUp), remainingRounds > 1 {
                    await continueAfterLocalExecution(
                        history: continuationHistory,
                        initialReply: result.reply,
                        bubbleID: followUp.id,
                        remainingRounds: remainingRounds - 1
                    )
                }
            }
            persistConversation()
        } catch {
            liveReply.reset()
            // The first local read already succeeded and is visible in the original bubble. Keep
            // that evidence rather than replacing it with a generic network failure.
            setBubble(bubbleID) { $0.text += "\n\nYerel sonuç alındı; yanıtın tamamlanması için tekrar deneyebilirsin." }
            persistConversation()
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

    private func localOutcomeLine(step: PlannedCommand, result: CommandResult) -> String {
        let prefix = result.status == .completed ? "✓" : "✗"
        var line = "\(prefix) \(step.summary): \(result.error?.message ?? result.message)"
        switch result.data {
        case .fileContent(let content):
            line += "\n\(content.content.prefix(2_000))"
        case .documentContent(let content):
            line += "\n\(content.text.prefix(4_000))"
        case .desktopFiles(let files):
            let names = files.map(\.filename).joined(separator: ", ")
            line += files.isEmpty ? "\nMasaüstü boş." : "\nDosyalar: \(names)"
        case .files(let files):
            let names = files.map { $0.name + ($0.isDirectory ? "/" : "") }.joined(separator: ", ")
            line += files.isEmpty ? "\nKlasör boş." : "\nDosyalar: \(names)"
        case .fileData(let content):
            if let text = content.text { line += "\n\(text.prefix(2_000))" }
            else { line += "\n\(content.mimeType) dosyası okundu." }
        case .screenshot(let content):
            line += "\nEkran görüntüsü: \(content.width)×\(content.height)"
        case .shortcutResult(let content):
            line += "\nDoğrulama: \(content.verified ? "başarılı" : "başarısız") (beklenen: \(content.expectedState), gözlenen: \(content.observedState ?? "belirsiz"))"
        case .uiElement(let content):
            line += "\nEşleşme: \(content.title ?? content.description ?? "etiket") (\(content.verified ? "doğrulandı" : "doğrulanamadı"))"
        case .screenClick(let content):
            line += "\nKoordinat: \(Int(content.x.rounded())), \(Int(content.y.rounded())) — yeniden gözlem gerekli."
        case .applicationControl(let content):
            line += "\nDoğrulama: \(content.verified ? "başarılı" : "başarısız") (önce: \(content.stateBefore), sonra: \(content.stateAfter))"
        case .calendarEvents(let events):
            if events.isEmpty {
                line += "\nYaklaşan etkinlik yok."
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                line += "\n" + events.prefix(8).map { "\($0.title) (\(formatter.string(from: $0.startAt)))" }.joined(separator: "; ")
            }
        case .reminders(let reminders):
            if reminders.isEmpty {
                line += "\nHatırlatıcı yok."
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                line += "\n" + reminders.prefix(8).map { reminder in
                    let due = reminder.dueAt.map { " (\(formatter.string(from: $0)))" } ?? ""
                    return "\(reminder.isCompleted ? "✓" : "•") \(reminder.title)\(due)"
                }.joined(separator: "; ")
            }
        case .clipboardText(let text):
            line += "\n\(text.prefix(2_000))"
        case .clipboardHistory(let entries):
            if entries.isEmpty {
                line += "\nPano geçmişi boş."
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                line += "\n" + entries.prefix(10).map { "\(formatter.string(from: $0.copiedAt)): \($0.text.prefix(120))" }.joined(separator: "\n")
            }
        case .processOutput(let output):
            // The code and its full stdout/stderr are shown in the dedicated, collapsible code
            // card below the message instead (see CodeExecutionCard) - this line stays short.
            line += " (çıkış kodu \(output.exitCode), \(output.durationMs) ms)"
        case .systemStatus(let status):
            var parts = ["macOS \(status.macOSVersion)", formatUptime(status.uptimeSeconds)]
            if let battery = status.batteryPercentage { parts.append("pil %\(battery)\(status.isCharging == true ? " ⚡︎" : "")") }
            line += "\n" + parts.joined(separator: " • ")
        case .installedApplications(let apps):
            line += apps.isEmpty ? "\nYüklü uygulama bulunamadı." : "\nUygulamalar: \(apps.prefix(20).map(\.name).joined(separator: ", "))"
        default:
            // A step type this view doesn't have bespoke formatting for yet still gets *some*
            // visible confirmation instead of silently vanishing after the summary line.
            break
        }
        return line
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
        if audioRecorder.isRecording {
            guard let data = audioRecorder.stop() else {
                bubbles.append(ChatBubble(role: .system, text: "Ses kaydı okunamadı."))
                return
            }
            Task { await sendAudio(data) }
            return
        }
        Task {
            switch await audioRecorder.start() {
            case .started:
                break
            case .permissionDenied:
                // iOS won't show its own prompt again once a decision is recorded - Settings is
                // the only remaining path, so offer it directly instead of a dead-end error line.
                showingMicPermissionAlert = true
            case .setupFailed:
                bubbles.append(ChatBubble(role: .system, text: "Mikrofon kaydı başlatılamadı; başka bir uygulama mikrofonu kullanıyor olabilir."))
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func sendAudio(_ data: Data) async {
        guard !data.isEmpty, !isSending else { return }
        screenshotObservationCount = 0
        bubbles.append(ChatBubble(role: .user, text: "🎙️ Sesli mesaj"))
        persistConversation()
        liveReply.reset()
        isSending = true
        statusMessages = ["Sesi çözüyorum…"]
        scrollToLatestRequest += 1
        defer { isSending = false }
        let history = bubbles
            .filter { $0.role != .system }
            .suffix(16)
            .map { RovaBackendClient.ChatTurn(role: $0.role == .user ? "user" : "assistant", content: $0.text) }
        turnCount += 1
        CopilotConversationStore.saveTurnCount(turnCount, for: conversationID)
        do {
            let result = try await RovaBackendClient.converseAudio(
                audioData: data,
                mimeType: "audio/m4a",
                messages: history,
                availableApps: availableApps,
                applicationTargets: model.deviceInfo?.applicationTargets ?? [],
                availableCapabilities: model.deviceInfo?.capabilities ?? [],
                authorities: model.deviceInfo?.authorities ?? [],
                deviceID: model.deviceInfo?.id,
                conversationID: conversationID,
                turnCount: turnCount,
                requestID: UUID(),
                respondWithAudio: true
            )
            if let id = bubbles.last?.id {
                setBubble(id) { $0.text = "🎙️ \(result.transcript)" }
            }
            let replyText = result.reply.isEmpty ? "…" : result.reply
            await liveReply.finish(with: replyText)
            let reply = ChatBubble(role: .assistant, text: replyText, steps: result.steps, artifacts: result.artifacts)
            bubbles.append(reply)
            liveReply.reset()
            if let audioError = result.audioError {
                bubbles.append(ChatBubble(role: .system, text: audioError))
            }
            if let audio = result.audioData { audioPlayer.play(audio) }
            if result.steps.contains(where: { $0.isDestructive || $0.requiresUserPresence }) {
                setBubble(reply.id) { $0.needsConfirmation = true }
                presentConfirmation(for: reply.id)
            } else {
                recentDeviceResults.removeAll(keepingCapacity: true)
                await execute(result.steps, bubbleID: reply.id)
                if result.steps.contains(where: needsLocalResultFollowUp) {
                    await continueAfterLocalExecution(history: history, initialReply: result.reply, bubbleID: reply.id)
                }
            }
            persistConversation()
        } catch RovaBackendError.notAuthenticated {
            liveReply.reset()
            authSession.signOut()
        } catch {
            liveReply.reset()
            bubbles.append(ChatBubble(role: .system, text: (error as? LocalizedError)?.errorDescription ?? "Ses isteği tamamlanamadı."))
            persistConversation()
        }
    }

    private func needsLocalResultFollowUp(_ step: PlannedCommand) -> Bool {
        switch step.type {
        case .readDocument, .readDesktopFile, .readFile, .listFiles, .captureScreen,
             .runShortcut, .controlUIElement, .clickScreen, .controlApplication:
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
private final class RovaAudioRecorder: NSObject, ObservableObject {
    enum StartResult {
        case started
        /// The user tapped Don't Allow (this time, or on a previous launch). iOS never shows its
        /// own permission dialog a second time once a decision is recorded, so the only way
        /// forward is Settings - the caller shows that path explicitly instead of silently
        /// re-attempting a request that's guaranteed to fail the same way again.
        case permissionDenied
        /// Permission is fine; something about configuring the audio session/recorder itself
        /// failed (e.g. another app holding exclusive audio hardware access).
        case setupFailed
    }

    @Published private(set) var isRecording = false
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

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
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard granted else { return .permissionDenied }
        case .granted:
            break
        @unknown default:
            break
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // .spokenAudio is a PLAYBACK-only mode (podcasts/audiobooks); pairing it with the
            // .record category is an invalid combination that AVAudioSession rejects at runtime -
            // setCategory throws, every recording attempt silently fails here, and the resulting
            // "permission denied" message the caller used to show was misleading (permission was
            // never the problem). .default is valid for every category, including .record.
            try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("rova-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.prepareToRecord()
            guard recorder.record() else { return .setupFailed }
            self.recorder = recorder
            recordingURL = url
            isRecording = true
            return .started
        } catch {
            return .setupFailed
        }
    }

    func stop() -> Data? {
        recorder?.stop()
        recorder = nil
        isRecording = false
        defer {
            if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
            recordingURL = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        guard let recordingURL else { return nil }
        return try? Data(contentsOf: recordingURL)
    }
}

@MainActor
private final class RovaAudioPlayer: NSObject, ObservableObject {
    private var player: AVAudioPlayer?

    func play(_ data: Data) {
        guard let player = try? AVAudioPlayer(data: data) else { return }
        self.player = player
        player.prepareToPlay()
        player.play()
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
