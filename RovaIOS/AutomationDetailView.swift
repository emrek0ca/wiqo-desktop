import SwiftUI

/// Run history and per-step debug view for one automation - the backend has always kept this
/// detail (automation_run_steps carries status/attempt count/error per step), it just never had
/// a screen. Answers "why didn't this run" without needing to ask Wiqo or SSH into the server.
struct AutomationDetailView: View {
    let automation: RovaBackendClient.RovaAutomation

    @State private var runs: [RovaBackendClient.AutomationRun] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RovaDesign.cardSpacing) {
                RovaCard {
                    Text(automation.prompt).font(.subheadline)
                    Label(automation.cron, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let lastRunAt = automation.lastRunAt {
                        Label("Son çalışma: \(lastRunAt)", systemImage: "arrow.clockwise")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let nextRunAt = automation.nextRunAt {
                        Label("Sıradaki: \(nextRunAt)", systemImage: "calendar")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                } else if let loadError {
                    Text(loadError).font(.subheadline).foregroundStyle(.red)
                } else if runs.isEmpty {
                    Text("Henüz çalışma kaydı yok.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                } else {
                    Text("Çalışma Geçmişi").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(runs) { run in
                        RunCard(run: run)
                    }
                }
            }
            .padding(RovaDesign.screenPadding)
        }
        .background(RovaDesign.canvas)
        .navigationTitle("Otomasyon")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            runs = try await RovaBackendClient.fetchAutomationRuns(id: automation.id)
            loadError = nil
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "Çalışma geçmişi yüklenemedi."
        }
        isLoading = false
    }
}

private struct RunCard: View {
    let run: RovaBackendClient.AutomationRun
    @State private var expanded = false

    var body: some View {
        RovaCard {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusLabel).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                        Text(run.startedAt).font(.caption).foregroundStyle(.secondary)
                        if let error = run.error {
                            Text(error).font(.caption).foregroundStyle(.red).lineLimit(expanded ? nil : 2)
                        } else if let reply = run.reply, !reply.isEmpty {
                            Text(reply).font(.caption).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2)
                        }
                    }
                    Spacer(minLength: 8)
                    if !run.steps.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
            }
            .buttonStyle(.plain)

            if expanded && !run.steps.isEmpty {
                Divider().padding(.vertical, 2)
                ForEach(run.steps) { step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: stepIcon(step))
                            .font(.caption)
                            .foregroundStyle(stepColor(step))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.inputSummary ?? step.kind).font(.caption.weight(.medium))
                            if let output = step.outputSummary, !output.isEmpty {
                                Text(output).font(.caption2).foregroundStyle(.secondary)
                            }
                            if let error = step.error, !error.isEmpty {
                                Text(error).font(.caption2).foregroundStyle(.red)
                            }
                            if step.attemptCount > 1 {
                                Text("\(step.attemptCount)/\(step.maxAttempts) deneme")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var statusIcon: String {
        switch run.status {
        case "done": return "checkmark.circle.fill"
        case "failed": return "xmark.circle.fill"
        case "running", "pending": return "clock.fill"
        default: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch run.status {
        case "done": return .green
        case "failed": return .red
        case "running", "pending": return .orange
        default: return .secondary
        }
    }

    private var statusLabel: String {
        switch run.status {
        case "done": return "Tamamlandı"
        case "failed": return "Başarısız"
        case "running": return "Çalışıyor"
        case "pending": return "Bekliyor"
        default: return run.status
        }
    }

    private func stepIcon(_ step: RovaBackendClient.AutomationRunStep) -> String {
        switch step.status {
        case "done": return "checkmark"
        case "failed": return "xmark"
        case "running": return "arrow.triangle.2.circlepath"
        default: return "circle"
        }
    }

    private func stepColor(_ step: RovaBackendClient.AutomationRunStep) -> Color {
        switch step.status {
        case "done": return .green
        case "failed": return .red
        case "running": return .orange
        default: return .secondary
        }
    }
}
