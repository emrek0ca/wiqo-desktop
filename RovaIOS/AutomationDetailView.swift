import SwiftUI

/// Run history and per-step debug view for one automation - the backend has always kept this
/// detail (automation_run_steps carries status/attempt count/error per step), it just never had
/// a screen. Answers "why didn't this run" without needing to ask Wiqo or SSH into the server.
struct AutomationDetailView: View {
    let automation: RovaBackendClient.RovaAutomation

    @State private var runs: [RovaBackendClient.AutomationRun] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isTrying = false
    @State private var tryMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RovaDesign.cardSpacing) {
                RovaCard {
                    Text(automation.prompt).font(.subheadline)
                    Label(automation.scheduleLabel ?? automation.cron, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let delivery = automation.delivery {
                        Label(
                            delivery == "phone" ? "Telefonun kendisi gösteriyor (internetsiz de gelir)" : "Wiqo sunucusu çalıştırıp bildiriyor",
                            systemImage: delivery == "phone" ? "iphone" : "cloud"
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
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
                    if automation.isActive {
                        Button {
                            Task { await tryNow() }
                        } label: {
                            Label(isTrying ? "Başlatılıyor…" : "Şimdi bir kez dene", systemImage: "play.circle")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .disabled(isTrying)
                        .padding(.top, 4)
                    }
                    if let tryMessage {
                        Text(tryMessage).font(.caption2).foregroundStyle(.secondary)
                    }
                }

                if let loadError {
                    Text(loadError).font(.subheadline).foregroundStyle(.red)
                }
                if isLoading && runs.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                } else if runs.isEmpty {
                    Text("Henüz çalışma kaydı yok.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                } else {
                    Text("Çalışma Geçmişi").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(runs) { run in
                        RunCard(automationID: automation.id, run: run)
                    }
                }
            }
            .padding(RovaDesign.screenPadding)
        }
        .background(RovaDesign.canvas)
        .navigationTitle("Otomasyon")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
            while !Task.isCancelled {
                guard runs.contains(where: { $0.status == "pending" || $0.status == "running" }) else { break }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                await load(silent: true)
            }
        }
        .refreshable { await load() }
    }

    /// Runs the automation once now, so the result is seen without waiting for its time.
    private func tryNow() async {
        isTrying = true
        defer { isTrying = false }
        do {
            _ = try await RovaBackendClient.runAutomationNow(id: automation.id)
            tryMessage = "Başlattım; sonucu aşağıda ve bildirimde göreceksin."
            await load(silent: true)
        } catch {
            tryMessage = (error as? LocalizedError)?.errorDescription ?? "Şu an başlatılamadı."
        }
    }

    private func load(silent: Bool = false) async {
        if !silent { isLoading = true }
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
    let automationID: Int
    let run: RovaBackendClient.AutomationRun
    @State private var expanded = false
    @State private var journal: [RovaBackendClient.ExecutionJournalEntry] = []
    @State private var journalError: String?

    var body: some View {
        RovaCard {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                if !expanded && journal.isEmpty {
                    Task { await loadJournal() }
                }
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
                        if let lastProgressAt = run.lastProgressAt {
                            Text("Son ilerleme: \(lastProgressAt)").font(.caption2).foregroundStyle(.tertiary)
                        }
                        if (run.status == "pending" || run.status == "running"), let deadlineAt = run.deadlineAt {
                            Text("Süre sonu: \(deadlineAt)").font(.caption2).foregroundStyle(.tertiary)
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

            if let delivery = run.completionDeliveryState {
                Label(completionDeliveryLabel(delivery), systemImage: "arrow.up.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let pushState = run.pushState, pushState != "accepted" {
                Text(run.pushError ?? pushDeliveryLabel(pushState))
                    .font(.caption2)
                    .foregroundStyle(pushState == "failed" ? .red : .secondary)
            }

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
                            if let deliveryState = step.deliveryState, step.kind == "device" {
                                Text(deliveryLabel(deliveryState)).font(.caption2).foregroundStyle(.secondary)
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
            if expanded && !journal.isEmpty {
                Divider().padding(.vertical, 2)
                Text("İşlem kanıtı").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(journal) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: entry.verified ? "checkmark.seal.fill" : "circle.dotted")
                            .font(.caption)
                            .foregroundStyle(entry.verified ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(humanEvent(entry.event)).font(.caption.weight(.medium))
                            Text(entry.summary).font(.caption2).foregroundStyle(.secondary)
                            if entry.sideEffectUncertain {
                                Text("Sonuç belirsiz; tekrar çalıştırılmadı.")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(.vertical, 2)
                }
            } else if expanded, let journalError {
                Text(journalError).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func loadJournal() async {
        do {
            journal = try await RovaBackendClient.fetchAutomationJournal(automationID: automationID, runID: run.id)
            journalError = nil
        } catch {
            journalError = "İşlem kanıtı şu anda yüklenemedi."
        }
    }

    private func humanEvent(_ event: String) -> String {
        switch event {
        case "created": return "Görev kaydedildi"
        case "started": return "İşlem başladı"
        case "waiting": return "Bekliyor"
        case "approval_required": return "Onay gerekiyor"
        case "retry_scheduled": return "Tekrar denenecek"
        case "completed": return "Sonuç doğrulandı"
        case "unknown": return "Sonuç doğrulanamadı"
        case "failed": return "İşlem tamamlanamadı"
        default: return "İşlem güncellendi"
        }
    }

    private var statusIcon: String {
        switch run.status {
        case "done": return "checkmark.circle.fill"
        case "failed": return "xmark.circle.fill"
        case "running", "pending": return "clock.fill"
        case "unknown": return "exclamationmark.triangle.fill"
        default: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch run.status {
        case "done": return .green
        case "failed": return .red
        case "running", "pending": return .orange
        case "unknown": return .orange
        default: return .secondary
        }
    }

    private var statusLabel: String {
        switch run.status {
        case "done": return "Tamamlandı"
        case "failed": return "Başarısız"
        case "running": return "Çalışıyor"
        case "pending": return "Bekliyor"
        case "unknown": return "Sonuç doğrulanamadı"
        default: return "Bilinmeyen durum"
        }
    }

    private func stepIcon(_ step: RovaBackendClient.AutomationRunStep) -> String {
        switch step.status {
        case "completed": return "checkmark"
        case "failed": return "xmark"
        case "running": return "arrow.triangle.2.circlepath"
        case "unknown": return "exclamationmark.triangle"
        default: return "circle"
        }
    }

    private func stepColor(_ step: RovaBackendClient.AutomationRunStep) -> Color {
        switch step.status {
        case "completed": return .green
        case "failed": return .red
        case "running": return .orange
        case "unknown": return .orange
        default: return .secondary
        }
    }

    private func deliveryLabel(_ state: String) -> String {
        switch state {
        case "not_sent": return "PC'ye henüz gönderilmedi"
        case "sent": return "PC'ye gönderildi; alındı bilgisi bekleniyor"
        case "acknowledged": return "PC komutu aldı; sonuç bekleniyor"
        case "completed": return "PC sonucu doğruladı"
        case "failed": return "PC komutu başarısız oldu"
        case "unknown": return "Komutun sonucu doğrulanamadı"
        default: return "Cihaz durumu bilinmiyor"
        }
    }

    private func completionDeliveryLabel(_ state: String) -> String {
        switch state {
        case "accepted": return "Sonuç PC'ye iletildi"
        case "pending": return "Sonuç PC'ye iletilmeyi bekliyor"
        default: return "Sonuç iletim durumu bilinmiyor"
        }
    }

    private func pushDeliveryLabel(_ state: String) -> String {
        switch state {
        case "pending": return "Bildirim henüz gönderilmedi."
        case "retrying": return "Bildirim gönderilemedi; tekrar denenecek."
        case "failed": return "Bildirim gönderilemedi."
        case "not_configured": return "Telefon bildirimi servisi yapılandırılmamış."
        default: return "Bildirim durumu bilinmiyor."
        }
    }
}
