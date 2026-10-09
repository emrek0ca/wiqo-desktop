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
        .background(WiqoTheme.card, in: RoundedRectangle(cornerRadius: WiqoTheme.cardCorner, style: .continuous))
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
    let onConfirmTaskReads: () -> Void
    let onConfirmTaskFiles: () -> Void
    let onConfirmAndAlwaysAllow: () -> Void

    /// Everything still waiting, in order: the person sees the whole job, not one step at a time.
    private var waitingSteps: [PlannedCommand] {
        bubble.steps.filter { !bubble.executedStepIDs.contains($0.id) && ($0.isDestructive || $0.requiresUserPresence) }
    }

    private func isReversible(_ step: PlannedCommand) -> Bool {
        !step.isDestructive && RovaOwnFolders.isAutoReadable(type: step.type, payload: step.payload)
            || RovaOwnFolders.isTaskWritable(type: step.type, payload: step.payload)
    }

    /// The task approval for file work is offered when this step is reversible file work and nothing waiting is a delete, an overwrite or a send.
    private var offersTaskFiles: Bool {
        guard let step = currentStep, RovaOwnFolders.isTaskWritable(type: step.type, payload: step.payload) else { return false }
        return true
    }

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
                            .background(WiqoTheme.card, in: RoundedRectangle(cornerRadius: WiqoTheme.cardCorner, style: .continuous))
                        }

                        if waitingSteps.count > 1 {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Bu işte onay bekleyen \(waitingSteps.count) adım var")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(Array(waitingSteps.prefix(8).enumerated()), id: \.element.id) { index, step in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("\(index + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        Text(step.summary).font(.footnote).foregroundStyle(.primary)
                                        Spacer(minLength: 4)
                                        Text(isReversible(step) ? "geri alınabilir" : "geri alınamaz")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(isReversible(step) ? Color.green : Color.orange)
                                    }
                                }
                                if waitingSteps.count > 8 { Text("… ve \(waitingSteps.count - 8) adım daha").font(.caption).foregroundStyle(.secondary) }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(WiqoTheme.card, in: RoundedRectangle(cornerRadius: WiqoTheme.cardCorner, style: .continuous))
                        }

                        Text(laterConfirmationCount > 0
                             ? "İşlem sırayla ilerleyecek. Aynı türden geri alınabilir adımlar için aşağıdan bu görev boyunca izin verebilirsin; silme ve üzerine yazma yine ayrıca sorulur."
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
                    WiqoActionButton(title: String(localized: "Onayla"), isLoading: isProcessing) { onConfirm() }
                    if let step = currentStep, !step.isDestructive, RovaOwnFolders.isAutoReadable(type: step.type, payload: step.payload) {
                        WiqoActionButton(title: String(localized: "Bu görev boyunca dosya okumaya izin ver"), kind: .secondary, isLoading: isGranting) { onConfirmTaskReads() }
                            .disabled(isProcessing)
                        Text("Masaüstü, Belgeler ve İndirilenler. Yazma, silme ve gönderme dahil değil.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if offersTaskFiles {
                        WiqoActionButton(title: String(localized: "Bu görev boyunca dosya işlerine izin ver"), kind: .secondary, isLoading: isGranting) { onConfirmTaskFiles() }
                            .disabled(isProcessing)
                        Text("Okuma, klasör açma, taşıma, kopyalama, yeniden adlandırma ve PDF/zip. Silme, üzerine yazma ve dışarı gönderme hariç; görev bitince izin biter.")
                            .font(.caption).foregroundStyle(.secondary)
                    }


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

/// A durable task plan: one stable row per goal, updated in place from backend receipts.
struct TaskPlanMiniCard: View {
    let widget: RovaBackendClient.CopilotResultWidget
    @State private var expanded: Set<String> = []
    @State private var showsAll = false

    var body: some View {
        let rows = widget.planSteps ?? []
        let done = rows.filter { $0.status == "verified" }.count
        let current = rows.first { $0.status != "verified" }
        let needsAttention = rows.contains { $0.status == "failed" }
        let open = showsAll || needsAttention
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(WiqoMotion.ease(0.25)) { showsAll.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if current?.status == "running" { ProgressView().controlSize(.mini) }
                    Text(current?.title ?? String(localized: "Görev adımları"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(done)/\(rows.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Adımları gizler" : "Adımları gösterir")
            if open {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    let active = ["running", "awaiting_confirmation", "waiting_device", "failed"].contains(row.status)
                    Button {
                        if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            ZStack {
                                Circle().fill(color(row.status).opacity(0.12)).frame(width: 22, height: 22)
                                if row.status == "verified" {
                                    Image(systemName: "checkmark").font(.caption2.weight(.semibold))
                                } else if row.status == "running" {
                                    ProgressView().controlSize(.mini)
                                } else { Text("\(index + 1)").font(.caption2.monospacedDigit()) }
                            }.foregroundStyle(color(row.status))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.title).font(.subheadline).foregroundStyle(row.status == "verified" ? .secondary : .primary)
                                if row.status != "verified" && row.status != "pending" {
                                    Text(label(row.status)).font(.caption2.weight(.medium)).foregroundStyle(color(row.status))
                                }
                                if active || expanded.contains(row.id) {
                                    Text(row.message ?? row.expectedResult)
                                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(index + 1). \(row.title). \(label(row.status))")
                }
                .transition(.opacity)
            }
        }
        .padding(WiqoTheme.cardPadding)
        .background(WiqoTheme.card, in: RoundedRectangle(cornerRadius: WiqoTheme.cardCorner, style: .continuous))
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "verified": return .green
        case "failed": return .red
        case "awaiting_confirmation", "waiting_device": return .orange
        case "running": return .primary
        default: return .secondary
        }
    }
    private func label(_ status: String) -> String {
        switch status {
        case "verified": return "Doğrulandı"
        case "failed": return "Tamamlanamadı"
        case "awaiting_confirmation": return "Onay bekliyor"
        case "waiting_device": return "Mac bekleniyor"
        case "running": return "Çalışıyor"
        default: return String(localized: "Bekliyor")
        }
    }
}
