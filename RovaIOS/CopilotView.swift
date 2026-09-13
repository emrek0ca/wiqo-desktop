import SwiftUI

/// Natural-language entry point for Rova. Text goes to `GroqCopilot.plan(for:availableApps:)`,
/// which returns an ordered list of the exact same commands the manual buttons already send.
/// A plan with no destructive step runs immediately; a plan with any destructive step (lock,
/// sleep, display sleep, quit app) must be confirmed and biometrically authenticated first,
/// matching the confirmation already required for those actions in the manual UI.
struct CopilotView: View {
    @ObservedObject var model: IOSConnectionModel
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyInput = ""
    @State private var hasAPIKey = GroqCopilot.apiKey() != nil
    @State private var requestText = ""
    @State private var isPlanning = false
    @State private var isExecuting = false
    @State private var pendingPlan: [PlannedCommand] = []
    @State private var executedStepIDs: Set<UUID> = []
    @State private var needsConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if !hasAPIKey {
                    apiKeySection
                } else {
                    requestSection
                    if model.state != .connected {
                        Section {
                            Text("Komutları çalıştırmak için Mac'e bağlı olman gerekiyor.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !pendingPlan.isEmpty {
                        planSection
                    }
                    if let errorMessage {
                        Section { Text(errorMessage).foregroundStyle(.red) }
                    }
                    Section {
                        Button("Groq anahtarını kaldır", role: .destructive) {
                            GroqCopilot.clearAPIKey()
                            hasAPIKey = false
                        }
                    }
                }
            }
            .navigationTitle("Rova AI")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
    }

    private var apiKeySection: some View {
        Section("Groq API Anahtarı") {
            SecureField("gsk_…", text: $apiKeyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Kaydet") {
                let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                try? GroqCopilot.saveAPIKey(trimmed)
                hasAPIKey = true
                apiKeyInput = ""
            }
            .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("Anahtar yalnızca bu cihazda, Keychain'de saklanır; Rova sunucusuna veya başka bir yere gönderilmez.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var requestSection: some View {
        Section("Rova'ya söyle") {
            TextField("Örn: toplantıya hazırlan", text: $requestText, axis: .vertical)
                .lineLimit(1...4)
                .disabled(isPlanning || isExecuting)
            Button {
                Task { await runPlanning() }
            } label: {
                if isPlanning {
                    HStack { ProgressView(); Text("Düşünüyor…") }
                } else {
                    Label("Gönder", systemImage: "sparkles")
                }
            }
            .disabled(
                requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || isPlanning || isExecuting || model.state != .connected
            )
        }
    }

    private var planSection: some View {
        Section("Plan") {
            ForEach(pendingPlan) { step in
                HStack {
                    Image(systemName: stepIcon(step))
                        .foregroundStyle(stepColor(step))
                    Text(step.summary)
                    Spacer()
                    if isExecuting && !executedStepIDs.contains(step.id) {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if needsConfirmation {
                Button(role: .destructive) {
                    Task { await confirmAndExecute() }
                } label: {
                    Label("Onayla ve Çalıştır", systemImage: "checkmark.shield")
                }
                Button("İptal", role: .cancel) {
                    pendingPlan = []
                    needsConfirmation = false
                }
            }
        }
    }

    private func stepIcon(_ step: PlannedCommand) -> String {
        if executedStepIDs.contains(step.id) { return "checkmark.circle.fill" }
        return step.isDestructive ? "exclamationmark.triangle.fill" : "circle"
    }

    private func stepColor(_ step: PlannedCommand) -> Color {
        if executedStepIDs.contains(step.id) { return .green }
        return step.isDestructive ? .orange : .secondary
    }

    private var availableApps: [ApplicationID] {
        model.deviceInfo?.availableApplications.map(\.id) ?? []
    }

    private func runPlanning() async {
        errorMessage = nil
        pendingPlan = []
        executedStepIDs = []
        needsConfirmation = false
        isPlanning = true
        defer { isPlanning = false }
        do {
            let plan = try await GroqCopilot.plan(for: requestText, availableApps: availableApps)
            requestText = ""
            pendingPlan = plan
            if plan.contains(where: \.isDestructive) {
                needsConfirmation = true
            } else {
                await execute(plan)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func confirmAndExecute() async {
        let ok = await model.authenticateBiometrics(reason: "Bu eylemleri Mac'te çalıştırmak için kimliğinizi doğrulayın")
        guard ok else { return }
        needsConfirmation = false
        await execute(pendingPlan)
    }

    private func execute(_ plan: [PlannedCommand]) async {
        isExecuting = true
        defer { isExecuting = false }
        for step in plan {
            _ = await model.send(step.type, payload: step.payload)
            executedStepIDs.insert(step.id)
        }
    }
}
