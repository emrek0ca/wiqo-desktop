import SwiftUI

/// The code a step will run (or already ran), collapsed by default so the conversation stays
/// readable, plus - once the Mac has a result - the real exit code/stdout/stderr in a matching
/// disclosure instead of a wall of text dumped into the reply.
struct CodeExecutionCard: View {
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
struct ConfirmationSheetView: View {
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
