import PhotosUI
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
    /// Populated when the Mac actually rejects/fails a step - the model's reply text is written
    /// optimistically before execution happens, so this is the only place a real failure (a
    /// permission denial, a full disk, anything) becomes visible instead of silently vanishing
    /// behind a reply that already claimed success.
    var failedSteps: [UUID: String] = [:]
}

private let suggestions: [(title: String, icon: String)] = [
    ("Toplantıya hazırla", "person.2.fill"),
    ("Sesi kıs", "speaker.wave.1.fill"),
    ("Bugün hava nasıl?", "cloud.sun.fill"),
    ("Ekranı kısarak odaklan", "moon.stars.fill")
]

/// Rova's home screen. A real conversation, not a one-shot "type → plan → confirm" form - every
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
    @State private var statusText = "Düşünüyor…"
    @State private var conversationID = CopilotConversationStore.identifier()
    @State private var turnCount = CopilotConversationStore.turnCount()
    /// Results are sent with the next stateless backend turn, so the model can distinguish a
    /// command that was merely queued from one the paired Mac actually completed.
    @State private var recentDeviceResults: [RovaBackendClient.DeviceExecutionResult] = []
    @State private var proactiveSuggestions: [RovaBackendClient.ProactiveSuggestion] = []
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var pendingAttachment: RovaBackendClient.ChatAttachment?
    @State private var attachmentPreview: UIImage?
    @State private var isPreparingAttachment = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !proactiveSuggestions.isEmpty {
                    proactiveCards
                }
                if bubbles.isEmpty {
                    emptyState
                } else {
                    conversation
                }
                Divider()
                inputBar
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Rova")
            .task { await loadProactiveSuggestions() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await loadProactiveSuggestions() }
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task { await prepareAttachment(item) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
            Text("Rova'ya sor")
                .font(.title2.weight(.semibold))
            Text("Mac'ini kontrol et, bir şey sor ya da tekrarlayan bir görev kur.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(suggestions, id: \.title) { suggestion in
                        RovaChip(title: suggestion.title, systemImage: suggestion.icon) {
                            inputText = suggestion.title
                            Task { await sendMessage() }
                        }
                    }
                }
                .padding(.horizontal)
            }
            Spacer()
            Spacer()
        }
    }

    private var proactiveCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Rova'nın önerisi", systemImage: "lightbulb.fill")
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

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(bubbles) { bubble in
                        bubbleView(bubble)
                            .id(bubble.id)
                    }
                    if isSending {
                        HStack { ProgressView(); Text(statusText).foregroundStyle(.secondary) }
                            .padding(.horizontal)
                            .animation(.easeInOut(duration: 0.15), value: statusText)
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: bubbles.count) { _, _ in
                if let last = bubbles.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private func bubbleView(_ bubble: ChatBubble) -> some View {
        VStack(alignment: bubble.role == .user ? .trailing : .leading, spacing: 6) {
            HStack {
                if bubble.role == .user { Spacer(minLength: 40) }
                Text(bubble.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground(bubble.role), in: RoundedRectangle(cornerRadius: RovaDesign.bubbleRadius, style: .continuous))
                    .foregroundStyle(bubble.role == .user ? Color.white : Color.primary)
                if bubble.role != .user { Spacer(minLength: 40) }
            }
            if bubble.needsConfirmation {
                confirmationCard(for: bubble)
            } else if !bubble.failedSteps.isEmpty {
                failureCard(for: bubble)
            }
            if !bubble.artifacts.isEmpty {
                artifactCard(for: bubble.artifacts)
            }
        }
        .frame(maxWidth: .infinity, alignment: bubble.role == .user ? .trailing : .leading)
        .padding(.horizontal)
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
        case .user: return .accentColor
        case .assistant: return Color(.secondarySystemBackground)
        case .system: return .red.opacity(0.15)
        }
    }

    private func confirmationCard(for bubble: ChatBubble) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(bubble.steps) { step in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: stepIcon(bubble, step))
                        .foregroundStyle(stepColor(bubble, step))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.summary).font(.subheadline)
                        if let message = bubble.failedSteps[step.id] {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Button(role: .destructive) {
                    Task { await confirmAndExecute(bubbleID: bubble.id) }
                } label: {
                    Label("Onayla ve Çalıştır", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                Button("İptal") {
                    setBubble(bubble.id) { $0.needsConfirmation = false; $0.steps = [] }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: RovaDesign.chipRadius, style: .continuous))
        .padding(.top, 2)
    }

    private func stepIcon(_ bubble: ChatBubble, _ step: PlannedCommand) -> String {
        if bubble.failedSteps[step.id] != nil { return "xmark.circle.fill" }
        if bubble.executedStepIDs.contains(step.id) { return "checkmark.circle.fill" }
        return "exclamationmark.triangle.fill"
    }

    private func stepColor(_ bubble: ChatBubble, _ step: PlannedCommand) -> Color {
        if bubble.failedSteps[step.id] != nil { return .red }
        if bubble.executedStepIDs.contains(step.id) { return .green }
        return .orange
    }

    private func artifactCard(for artifacts: [RovaBackendClient.ArtifactDescriptor]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Oluşturulan dosyalar", systemImage: "paperclip")
                .font(.subheadline.weight(.semibold))
            ForEach(artifacts) { artifact in
                HStack(spacing: 8) {
                    Image(systemName: artifact.mimeType.hasPrefix("image/") ? "photo" : "doc.fill")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artifact.filename).font(.subheadline)
                        Text("\(artifact.kind) • \(ByteCountFormatter.string(fromByteCount: Int64(artifact.byteCount), countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("Dosya üretildi. Masaüstüne kaydetme isteği verdiysen Rova Mac onayı bekliyor.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: RovaDesign.chipRadius, style: .continuous))
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if let attachmentPreview {
                HStack(spacing: 8) {
                    Image(uiImage: attachmentPreview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(pendingAttachment?.name ?? "Görsel hazır")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        clearAttachment()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
            }
            HStack(spacing: 10) {
                PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20, weight: .medium))
                }
                .disabled(isSending || isPreparingAttachment)
                TextField("Rova'ya söyle…", text: $inputText, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: RovaDesign.chipRadius, style: .continuous))
                    .disabled(isSending)
                Button {
                    Task { await sendMessage() }
                } label: {
                    if isPreparingAttachment {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    }
                }
                .disabled(!canSend || isSending || isPreparingAttachment || model.state != .connected)
            }
        }
        .padding(12)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingAttachment != nil
    }

    private var availableApps: [ApplicationID] {
        model.deviceInfo?.availableApplications.map(\.id) ?? []
    }

    private func sendMessage() async {
        let typedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typedText.isEmpty || pendingAttachment != nil else { return }
        let text = typedText.isEmpty ? "Bu görseli analiz et." : typedText
        let attachment = pendingAttachment
        inputText = ""
        clearAttachment()
        bubbles.append(ChatBubble(role: .user, text: text))
        isSending = true
        statusText = "Düşünüyor…"
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
        CopilotConversationStore.saveTurnCount(turnCount)
        let requestID = UUID()

        do {
            let result = try await RovaBackendClient.converse(
                messages: history,
                availableApps: availableApps,
                conversationID: conversationID,
                turnCount: turnCount,
                deviceResults: recentDeviceResults,
                requestID: requestID,
                attachments: attachment.map { [$0] } ?? []
            ) { text in
                Task { @MainActor in statusText = text }
            }
            var reply = ChatBubble(role: .assistant, text: result.reply.isEmpty ? "…" : result.reply, steps: result.steps, artifacts: result.artifacts)
            if result.steps.contains(where: { $0.isDestructive || $0.requiresUserPresence }) {
                reply.needsConfirmation = true
                bubbles.append(reply)
            } else {
                bubbles.append(reply)
                recentDeviceResults.removeAll(keepingCapacity: true)
                await execute(result.steps, bubbleID: reply.id)
                if result.steps.contains(where: { $0.type == .readDocument || $0.type == .readDesktopFile }) {
                    await continueAfterLocalRead(history: history, initialReply: result.reply, bubbleID: reply.id)
                }
            }
        } catch RovaBackendError.notAuthenticated {
            // Sends the whole app back to the login screen (RootView switches on this),
            // there's no local sheet/screen of our own to dismiss here.
            authSession.signOut()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            bubbles.append(ChatBubble(role: .system, text: message))
        }
    }

    private func confirmAndExecute(bubbleID: UUID) async {
        let ok = await model.authenticateBiometrics(reason: "Bu eylemleri Mac'te çalıştırmak için kimliğinizi doğrulayın")
        guard ok else { return }
        setBubble(bubbleID) { $0.needsConfirmation = false }
        guard let steps = bubbles.first(where: { $0.id == bubbleID })?.steps else { return }
        await execute(steps, bubbleID: bubbleID)
    }

    private func execute(_ steps: [PlannedCommand], bubbleID: UUID) async {
        var outcomeLines: [String] = []
        for step in steps {
            let result = await model.send(step.type, payload: step.payload, commandID: step.id)
            let deviceResult = RovaBackendClient.DeviceExecutionResult(
                stepID: step.id,
                type: step.type,
                status: result.status,
                message: result.message,
                error: result.error,
                dataText: encodedCommandData(result.data)
            )
            recentDeviceResults.append(deviceResult)
            recentDeviceResults = Array(recentDeviceResults.suffix(12))
            outcomeLines.append(localOutcomeLine(step: step, result: result))
            setBubble(bubbleID) { bubble in
                bubble.executedStepIDs.insert(step.id)
                if result.status != .completed {
                    bubble.failedSteps[step.id] = result.error?.message ?? result.message
                }
            }
        }
        if !outcomeLines.isEmpty {
            setBubble(bubbleID) { bubble in
                bubble.text += "\n\nYerel Mac sonucu:\n" + outcomeLines.joined(separator: "\n")
            }
        }
    }

    /// A local read is a two-phase turn: first the Mac returns private document text, then the
    /// backend receives that structured result and produces the actual answer or the next edit
    /// step. This keeps private files on the local connection while making "oku ve düzenle"
    /// work without asking the user to send a second message manually.
    private func continueAfterLocalRead(history: [RovaBackendClient.ChatTurn], initialReply: String, bubbleID: UUID) async {
        guard !recentDeviceResults.isEmpty, model.state == .connected else { return }
        let continuationHistory = history + [
            RovaBackendClient.ChatTurn(role: "assistant", content: initialReply),
            RovaBackendClient.ChatTurn(role: "user", content: "Yerel Mac sonuçları hazır. Bu sonuçları kullanarak önceki isteği şimdi tamamla; belge içeriğini yeniden isteme.")
        ]
        let localResults = Array(recentDeviceResults.suffix(12))
        do {
            let result = try await RovaBackendClient.converse(
                messages: continuationHistory,
                availableApps: availableApps,
                conversationID: conversationID,
                turnCount: turnCount,
                deviceResults: localResults,
                requestID: UUID()
            ) { text in
                Task { @MainActor in statusText = text }
            }
            var followUp = ChatBubble(role: .assistant, text: result.reply.isEmpty ? "…" : result.reply, steps: result.steps, artifacts: result.artifacts)
            bubbles.append(followUp)
            if result.steps.contains(where: { $0.isDestructive || $0.requiresUserPresence }) {
                followUp.needsConfirmation = true
                setBubble(followUp.id) { $0.needsConfirmation = true }
            } else {
                recentDeviceResults.removeAll(keepingCapacity: true)
                await execute(result.steps, bubbleID: followUp.id)
            }
        } catch {
            // The first local read already succeeded and is visible in the original bubble. Keep
            // that evidence rather than replacing it with a generic network failure.
            setBubble(bubbleID) { $0.text += "\n\nYerel sonuç alındı; yanıtın tamamlanması için tekrar deneyebilirsin." }
        }
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
        case .calendarEvents(let events):
            if events.isEmpty {
                line += "\nYaklaşan etkinlik yok."
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                line += "\n" + events.prefix(8).map { "\($0.title) (\(formatter.string(from: $0.startAt)))" }.joined(separator: "; ")
            }
        default:
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
        default:
            encoded = try? JSONEncoder.rovaISO8601.encode(data)
        }
        guard let encoded else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    private func prepareAttachment(_ item: PhotosPickerItem) async {
        isPreparingAttachment = true
        defer { isPreparingAttachment = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            clearAttachment()
            return
        }
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
            clearAttachment()
            bubbles.append(ChatBubble(role: .system, text: "Görsel desteklenen boyut sınırını aşıyor."))
            return
        }
        pendingAttachment = RovaBackendClient.ChatAttachment(name: item.itemIdentifier ?? "gorsel.jpg", mimeType: "image/jpeg", dataBase64: encoded.base64EncodedString())
        attachmentPreview = normalized
    }

    private func clearAttachment() {
        selectedPhoto = nil
        pendingAttachment = nil
        attachmentPreview = nil
    }

    private func loadProactiveSuggestions() async {
        guard RovaBackendClient.isAuthenticated else { return }
        // This is a foreground refresh only; it never delays the chat request itself. The backend
        // applies an opt-in and cooldown gate before doing any external weather research.
        if let suggestions = try? await RovaBackendClient.refreshProactiveSuggestions() {
            proactiveSuggestions = suggestions
        }
    }

    private func markSuggestion(_ id: Int, action: String) async {
        try? await RovaBackendClient.updateProactiveSuggestion(id: id, action: action)
    }

    private func setBubble(_ id: UUID, _ mutate: (inout ChatBubble) -> Void) {
        guard let index = bubbles.firstIndex(where: { $0.id == id }) else { return }
        mutate(&bubbles[index])
    }
}

private extension JSONEncoder {
    static var rovaISO8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private enum CopilotConversationStore {
    private static let conversationKey = "rova.copilot.conversation-id"
    private static let turnCountKey = "rova.copilot.turn-count"

    static func identifier() -> String {
        if let existing = UserDefaults.standard.string(forKey: conversationKey), !existing.isEmpty {
            return existing
        }
        let identifier = UUID().uuidString
        UserDefaults.standard.set(identifier, forKey: conversationKey)
        return identifier
    }

    static func turnCount() -> Int {
        max(0, UserDefaults.standard.integer(forKey: turnCountKey))
    }

    static func saveTurnCount(_ count: Int) {
        UserDefaults.standard.set(max(0, count), forKey: turnCountKey)
    }
}
