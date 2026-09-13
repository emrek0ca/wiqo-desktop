import SwiftUI

private struct ChatBubble: Identifiable {
    enum Role { case user, assistant, system }

    let id = UUID()
    let role: Role
    var text: String
    var steps: [PlannedCommand] = []
    var needsConfirmation = false
    var executedStepIDs: Set<UUID> = []
}

/// A real conversation with Rova, not a one-shot "type → plan → confirm" form. Every message
/// (from either side) is kept in `bubbles` and the full history is resent with each new message
/// so the model has context - the backend itself is stateless.
///
/// Non-destructive steps the model decides on (volume, brightness, opening an app, ...) run
/// immediately and silently once the reply is shown, exactly like the model just "did the
/// thing" - no extra screen in between. Destructive steps (lock, sleep, quit app) still show an
/// inline confirmation under that message and require Face ID/Touch ID, matching the manual
/// buttons elsewhere in the app.
struct CopilotView: View {
    @ObservedObject var model: IOSConnectionModel
    @ObservedObject var authSession: AuthSessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var bubbles: [ChatBubble] = []
    @State private var inputText = ""
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(bubbles) { bubble in
                                bubbleView(bubble)
                                    .id(bubble.id)
                            }
                            if isSending {
                                HStack { ProgressView(); Text("Düşünüyor…").foregroundStyle(.secondary) }
                                    .padding(.horizontal)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .onChange(of: bubbles.count) { _, _ in
                        if let last = bubbles.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                Divider()
                inputBar
            }
            .navigationTitle("Rova AI")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
    }

    private func bubbleView(_ bubble: ChatBubble) -> some View {
        VStack(alignment: bubble.role == .user ? .trailing : .leading, spacing: 6) {
            HStack {
                if bubble.role == .user { Spacer(minLength: 40) }
                Text(bubble.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground(bubble.role), in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(bubble.role == .user ? Color.white : Color.primary)
                if bubble.role != .user { Spacer(minLength: 40) }
            }
            if bubble.needsConfirmation {
                confirmationCard(for: bubble)
            }
        }
        .frame(maxWidth: .infinity, alignment: bubble.role == .user ? .trailing : .leading)
        .padding(.horizontal)
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
                HStack {
                    Image(systemName: bubble.executedStepIDs.contains(step.id) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(bubble.executedStepIDs.contains(step.id) ? .green : .orange)
                    Text(step.summary).font(.subheadline)
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
        .padding(10)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 2)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Rova'ya söyle…", text: $inputText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(isSending)
            Button {
                Task { await sendMessage() }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .disabled(
                inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || isSending || model.state != .connected
            )
        }
        .padding(10)
    }

    private var availableApps: [ApplicationID] {
        model.deviceInfo?.availableApplications.map(\.id) ?? []
    }

    private func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        bubbles.append(ChatBubble(role: .user, text: text))
        isSending = true
        defer { isSending = false }

        let history = bubbles
            .filter { $0.role != .system }
            .map { RovaBackendClient.ChatTurn(role: $0.role == .user ? "user" : "assistant", content: $0.text) }

        do {
            let result = try await RovaBackendClient.converse(messages: history, availableApps: availableApps)
            var reply = ChatBubble(role: .assistant, text: result.reply.isEmpty ? "…" : result.reply, steps: result.steps)
            if result.steps.contains(where: \.isDestructive) {
                reply.needsConfirmation = true
                bubbles.append(reply)
            } else {
                bubbles.append(reply)
                await execute(result.steps, bubbleID: reply.id)
            }
        } catch RovaBackendError.notAuthenticated {
            authSession.signOut()
            dismiss()
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
        for step in steps {
            _ = await model.send(step.type, payload: step.payload)
            setBubble(bubbleID) { $0.executedStepIDs.insert(step.id) }
        }
    }

    private func setBubble(_ id: UUID, _ mutate: (inout ChatBubble) -> Void) {
        guard let index = bubbles.firstIndex(where: { $0.id == id }) else { return }
        mutate(&bubbles[index])
    }
}
