import SwiftUI
import UIKit

/// What a user attached shows as small thumbnails sitting above their own message bubble, exactly
/// where the user placed them before sending - not just held ephemerally in the composer and lost
/// the moment the message goes out. Read-only (no remove button, unlike the composer's own
/// attachmentStrip); tapping one opens it large enough to actually look at.
struct AttachmentThumbnailStrip: View {
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

struct AttachmentFullScreenView: View {
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

struct CopyReplyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            WiqoHaptics.selection()
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

/// "PC açılınca yapılacak" under a reply whose PC steps were queued because the PC was offline.
/// The work runs by itself when the PC reconnects and a notification reports the result; until
/// then the user can cancel it here.
struct DeferredTaskRow: View {
    let task: RovaBackendClient.DeferredTask
    @State private var state: RowState = .waiting

    private enum RowState: Equatable {
        case waiting
        case cancelling
        case cancelled(outcomeUnknown: Bool)
        case failed(String)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if case .failed(let message) = state {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(WiqoTheme.red)
                }
            }
            Spacer(minLength: 8)
            if state == .waiting || state == .cancelling || isFailed {
                Button("İptal") { Task { await cancel() } }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(state == .cancelling)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: WiqoTheme.controlRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private var title: String {
        switch state {
        case .cancelled(outcomeUnknown: false): "PC işi iptal edildi"
        case .cancelled(outcomeUnknown: true): "Kuyruktan alındı; PC sonucu belirsiz. Etkinlik'i kontrol et."
        default: task.status == "dispatched" ? "PC'de çalışıyor · bitince bildirim gelecek" : "PC açılınca yapılacak · bitince bildirim gelecek"
        }
    }

    private var icon: String {
        switch state {
        case .cancelled(outcomeUnknown: true), .failed: "exclamationmark.circle"
        case .cancelled(outcomeUnknown: false): "xmark.circle"
        default: "clock.arrow.circlepath"
        }
    }

    private func cancel() async {
        state = .cancelling
        do {
            let result = try await RovaBackendClient.cancelDeferredTask(id: task.id)
            state = .cancelled(outcomeUnknown: result.cancelled != true || result.outcomeUnknown != false)
        } catch {
            state = .failed("İptal edilemedi. Bağlantıyı kontrol edip yeniden dene.")
        }
    }
}

/// The live card of a background project (website, long document, presentation, image set). It
/// shows the plan as a checklist, the step being worked on, what verification found, and lets the
/// user cancel a running project or resume a failed one. The card polls the backend - the project
/// keeps running there even when the app is closed - and reports the finished state once.
struct ProjectTaskCard: View {
    let task: RovaBackendClient.ProjectTask
    let onFinished: @MainActor (RovaBackendClient.ProjectDetail) -> Void
    /// Every fresh state while the project runs - the reply narrates it (ProjectNarrativeView).
    var onUpdate: @MainActor (RovaBackendClient.ProjectDetail) -> Void = { _ in }

    @State private var detail: RovaBackendClient.ProjectDetail?
    @State private var connectionNote: String?
    @State private var actionError: String?
    @State private var isBusy = false
    @State private var expanded = false
    @State private var confirmingCancel = false
    @State private var pollGeneration = 0
    @State private var missing = false
    /// Server clock minus this phone's clock at the last fetch, so the step timer is not skewed.
    @State private var clockOffset: TimeInterval = 0
    @State private var stepStartedAt: Date?
    @State private var lastServerActivity: Date?
    @State private var previewImage: UIImage?
    @State private var previewID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: String { detail?.status ?? task.status }
    private var isRunning: Bool { status == "running" }
    private var title: String { detail?.title ?? task.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isRunning, let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 118)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: WiqoTheme.controlRadius, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        Text("Önizleme")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(7)
                    }
                    .transition(.opacity)
                    .accessibilityLabel("Projenin son önizlemesi")
            }
            if isRunning {
                progressLine
            }
            if let detail, !detail.steps.isEmpty {
                if isRunning || expanded {
                    stepList(detail.steps)
                    if !detail.checks.isEmpty { checkList(detail.checks) }
                } else {
                    Button {
                        expanded = true
                    } label: {
                        Label(finishedCaption(detail), systemImage: "list.bullet.rectangle")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if status == "failed", let error = detail?.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(WiqoTheme.red)
            }
            if detail?.artifactsExpired == true {
                Text("Dosyaların indirme süresi doldu; istersen yeniden oluşturabilirim.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if missing {
                Text("Bu proje artık sunucuda yok (sohbet ya da hesap verisi silinmiş olabilir).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = connectionNote ?? actionError {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(actionError == nil ? .secondary : WiqoTheme.red)
            }
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiqoCard()
        .task(id: "\(task.id)-\(pollGeneration)") { await poll() }
        .confirmationDialog("Proje iptal edilsin mi?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Projeyi iptal et", role: .destructive) { Task { await cancel() } }
        } message: {
            Text("Wiqo projeyi durdurur; yarım kalan iş teslim edilmez.")
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: kindSymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WiqoTheme.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("\(kindLabel) · \(statusLabel)")
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            Spacer(minLength: 0)
            if isRunning || isBusy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
            }
        }
    }

    private var progressLine: some View {
        let steps = detail?.steps ?? []
        let done = steps.filter { $0.status == "done" }.count
        return VStack(alignment: .leading, spacing: 6) {
            if !steps.isEmpty {
                ProgressView(value: Double(done), total: Double(max(steps.count, 1)))
                    .tint(WiqoTheme.ink)
            }
            if steps.isEmpty {
                Text("Plan hazırlanıyor…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Under the running step: how long it has been running, and a reassurance when it runs long.
    /// What is happening right now is told in the reply above the card (ProjectNarrativeView).
    private func liveDetail(for step: RovaBackendClient.ProjectDetail.Step) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Bu adımda \(elapsedLabel(now: context.date))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if isStale {
                Text("Bu adım uzun sürüyor; Wiqo hâlâ çalışıyor.")
                    .font(.caption2)
                    .foregroundStyle(WiqoTheme.orange)
            }
        }
        .padding(.leading, 2)
    }

    private func elapsedLabel(now: Date) -> String {
        guard let stepStartedAt else { return "" }
        let seconds = max(0, Int(now.addingTimeInterval(clockOffset).timeIntervalSince(stepStartedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Nothing reached the server for over a minute: say so plainly instead of looking frozen.
    private var isStale: Bool {
        guard isRunning, let lastServerActivity else { return false }
        return Date().addingTimeInterval(clockOffset).timeIntervalSince(lastServerActivity) > 60
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func absorbTimes(_ fresh: RovaBackendClient.ProjectDetail) {
        if let server = Self.parseDate(fresh.serverTime) { clockOffset = server.timeIntervalSinceNow }
        stepStartedAt = Self.parseDate(fresh.stepStartedAt)
        lastServerActivity = Self.parseDate(fresh.updatedAt)
    }

    private func loadPreview(_ artifact: RovaBackendClient.ArtifactDescriptor?) async {
        guard let artifact, artifact.id != previewID, artifact.mimeType.hasPrefix("image/") else { return }
        guard let url = try? await RovaBackendClient.downloadArtifact(artifact),
              let image = UIImage(contentsOfFile: url.path) else { return }
        previewID = artifact.id
        if reduceMotion { previewImage = image } else { withAnimation(.easeOut(duration: 0.25)) { previewImage = image } }
    }

    private func stepList(_ steps: [RovaBackendClient.ProjectDetail.Step]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(steps, id: \.id) { step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    stepIcon(step.status)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.caption.weight(step.status == "running" ? .semibold : .regular))
                            .foregroundStyle(step.status == "pending" ? .secondary : .primary)
                        if let detail = step.detail, !detail.isEmpty, step.status != "pending" {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(step.status == "failed" ? WiqoTheme.red : .secondary)
                                .lineLimit(3)
                        }
                        if step.status == "running" && isRunning {
                            liveDetail(for: step)
                        }
                    }
                }
            }
        }
    }

    private func checkList(_ checks: [RovaBackendClient.ProjectDetail.Check]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kontroller")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: check.passed ? "checkmark.seal.fill" : "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(check.passed ? WiqoTheme.green : WiqoTheme.orange)
                        .frame(width: 16)
                    Text(check.detail.map { "\(check.label) — \($0)" } ?? check.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(10)
        .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: WiqoTheme.controlRadius, style: .continuous))
    }

    @ViewBuilder
    private func stepIcon(_ status: String) -> some View {
        switch status {
        case "done":
            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(WiqoTheme.green)
        case "running":
            ProgressView().controlSize(.mini)
        case "failed":
            Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(WiqoTheme.red)
        case "skipped":
            Image(systemName: "minus.circle").font(.caption).foregroundStyle(.secondary)
        default:
            Image(systemName: "circle").font(.caption).foregroundStyle(WiqoTheme.ink3)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if isRunning {
            HStack {
                Spacer()
                Button("İptal") { confirmingCancel = true }
                    .buttonStyle(.wiqoPill(.ghost))
                    .disabled(isBusy)
            }
        } else if status == "failed" {
            HStack {
                Spacer()
                Button {
                    Task { await retry() }
                } label: {
                    Label("Tekrar dene", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.wiqoPill(.accent))
                .disabled(isBusy)
            }
        }
    }

    private func finishedCaption(_ detail: RovaBackendClient.ProjectDetail) -> String {
        let passed = detail.checks.filter(\.passed).count
        let steps = detail.steps.filter { $0.status == "done" }.count
        return detail.checks.isEmpty
            ? "\(steps) adım · ayrıntıları göster"
            : "\(steps) adım · \(passed)/\(detail.checks.count) kontrol geçti · ayrıntılar"
    }

    private var kindLabel: String {
        switch detail?.kind ?? task.kind {
        case "website": "Web projesi"
        case "document": "Belge"
        case "presentation": "Sunum"
        case "images": "Görsel seti"
        default: "Proje"
        }
    }

    private var kindSymbol: String {
        switch detail?.kind ?? task.kind {
        case "website": "globe"
        case "document": "doc.text"
        case "presentation": "rectangle.on.rectangle"
        case "images": "photo.on.rectangle"
        default: "square.stack.3d.up"
        }
    }

    private var statusLabel: String {
        switch status {
        case "running": "Adım adım hazırlanıyor"
        case "done": "Hazır"
        case "failed": "Tamamlanamadı"
        case "cancelled": "İptal edildi"
        default: "Durum bilinmiyor"
        }
    }

    private var statusSymbol: String {
        switch status {
        case "done": "checkmark.circle.fill"
        case "failed": "exclamationmark.triangle.fill"
        case "cancelled": "xmark.circle"
        default: "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch status {
        case "done": WiqoTheme.green
        case "failed": WiqoTheme.red
        default: .secondary
        }
    }

    /// Polls while the project runs (every 2 s at first, easing to 8 s; backing off on network
    /// trouble). A finished project is fetched once for its checklist and then left alone.
    private func poll() async {
        let started = Date()
        var failures = 0
        while !Task.isCancelled {
            do {
                let fresh = try await RovaBackendClient.fetchProject(id: task.id)
                detail = fresh
                absorbTimes(fresh)
                connectionNote = nil
                failures = 0
                if fresh.isActive {
                    onUpdate(fresh)
                    await loadPreview(fresh.preview)
                }
                if !fresh.isActive {
                    onFinished(fresh)
                    return
                }
            } catch RovaBackendError.notAuthenticated {
                return
            } catch RovaBackendError.network(let message) where message == "Proje bulunamadı." {
                missing = true
                return
            } catch {
                failures += 1
                if failures >= 2 { connectionNote = "Bağlantı bekleniyor; proje sunucuda çalışmaya devam ediyor." }
            }
            let elapsed = Date().timeIntervalSince(started)
            let seconds: Double = failures > 0 ? min(15, 2 * Double(failures + 1)) : (elapsed < 60 ? 2 : elapsed < 300 ? 4 : 8)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    private func cancel() async {
        isBusy = true
        actionError = nil
        defer { isBusy = false }
        do {
            let result = try await RovaBackendClient.cancelProject(id: task.id)
            detail = result
            onFinished(result)
        } catch {
            actionError = "İptal edilemedi; proje bitmiş olabilir. Birazdan kart güncellenecek."
            pollGeneration += 1
        }
    }

    private func retry() async {
        isBusy = true
        actionError = nil
        defer { isBusy = false }
        do {
            detail = try await RovaBackendClient.retryProject(id: task.id)
            pollGeneration += 1
        } catch {
            actionError = "Yeniden başlatılamadı. Bağlantıyı kontrol edip tekrar dene."
        }
    }
}

/// The running project told in the reply itself, line by line: what Wiqo decided, wrote,
/// checked and fixed, ending with what it is doing right now. Every line is a real event from the
/// project engine; new lines settle in as they arrive.
struct ProjectNarrativeView: View {
    let events: [RovaBackendClient.ProjectDetail.Event]
    let liveLine: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(events, id: \.self) { event in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(event.kind))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint(event.kind))
                        .frame(width: 16)
                    Text(sentence(for: event))
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                .accessibilityElement(children: .combine)
            }
            if let liveLine, !liveLine.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .opacity(reduceMotion ? 1 : (pulse ? 0.35 : 1))
                        .frame(width: 16)
                    Text(liveLine)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                .accessibilityLabel("Şu an: \(liveLine)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: events.count)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private func sentence(for event: RovaBackendClient.ProjectDetail.Event) -> String {
        switch event.kind {
        case "decision": return event.text
        case "write": return "Yazıldı: \(event.text)"
        case "check": return "Kontrol: \(event.text)"
        case "issue": return "Sorun: \(event.text)"
        case "fix": return "Düzeltildi: \(event.text.replacingOccurrences(of: "Düzeltildi: ", with: ""))"
        default: return event.text
        }
    }

    private func symbol(_ kind: String) -> String {
        switch kind {
        case "decision": "lightbulb"
        case "write": "checkmark.circle"
        case "check": "checkmark.seal"
        case "issue": "exclamationmark.triangle"
        case "fix": "wrench.and.screwdriver"
        default: "info.circle"
        }
    }

    private func tint(_ kind: String) -> Color {
        switch kind {
        case "write", "check": WiqoTheme.green
        case "issue": WiqoTheme.orange
        case "decision": Color.accentColor
        default: .secondary
        }
    }
}

private func fileSymbol(for type: FileContent.Kind) -> String {
    switch type {
    case .pdf: "doc.richtext"
    case .docx, .text: "doc.text"
    case .xlsx, .csv: "tablecells"
    case .pptx: "rectangle.on.rectangle"
    case .image: "photo"
    case .scan: "doc.viewfinder"
    }
}

/// A file waiting in the composer: what was read from it on this phone, removable before sending.
struct PendingFileChip: View {
    let file: FileContent
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: fileSymbol(for: file.type))
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 150, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dosyayı kaldır")
        }
        .padding(.horizontal, 10)
        .frame(height: 60)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var detail: String {
        var parts: [String] = []
        if let pages = file.pageCount, pages > 0 {
            parts.append(file.type == .xlsx ? "\(pages) sayfa" : file.type == .pptx ? "\(pages) slayt" : "\(pages) sayfa")
        }
        if !file.tables.isEmpty { parts.append("\(file.tables.reduce(0) { $0 + $1.rows.count }) satır") }
        if !file.text.isEmpty { parts.append("\(file.text.count.formatted()) karakter") }
        if file.source == .ocr { parts.append("OCR") }
        if file.truncated { parts.append("kısaltıldı") }
        return parts.joined(separator: " · ")
    }
}

/// File names above a sent message (the content already went to Wiqo; the files stayed here).
struct AttachedFileNames: View {
    let names: [String]

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                Label(name, systemImage: "doc")
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
    }
}

/// Live card for a background agent task (backend src/agent/tasks.ts): its plan steps as they run
/// (in parallel where the plan allows), what it is waiting on - an approval it can grant right here,
/// or a question answered by typing in this chat - and, when done, how it was verified and what it
/// cost. The result itself arrives as a chat message; the card is the task's live state.
struct AgentTaskCard: View {
    let task: RovaBackendClient.AgentTaskRef

    @State private var detail: RovaBackendClient.AgentTaskDetail?
    @State private var isBusy = false
    @State private var actionError: String?
    @State private var confirmingCancel = false
    @State private var pollGeneration = 0
    @State private var openStep: String?
    @State private var steerText = ""
    @State private var steerSent = false

    private var status: String { detail?.status ?? "running" }

    private var runningSummary: String? {
        guard status == "running", let detail, detail.waiting == nil else { return nil }
        var parts: [String] = []
        if let estimate = detail.estimatedSeconds, estimate > 0 {
            parts.append("~\(max(1, Int((Double(estimate) / 60).rounded()))) dk")
        }
        if !detail.steps.isEmpty {
            let completed = detail.steps.filter { $0.status == "done" }.count
            parts.append("\(completed)/\(detail.steps.count) adım")
        }
        return parts.isEmpty ? detail.progress : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                WiqoAgentMascot(detail?.persona ?? task.persona, size: 64, isWorking: status == "running" && detail?.waiting == nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail?.title ?? task.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text("\(WiqoAgentMascot.Persona(detail?.persona ?? task.persona).label) · \(statusLabel)").font(.caption).foregroundStyle(statusColor)
                }
                Spacer(minLength: 0)
            }
            if let runningSummary {
                Text(runningSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let steps = detail?.steps, !steps.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(steps, id: \.id) { step in
                        Button {
                            guard step.brief != nil else { return }
                            withAnimation(.easeInOut(duration: 0.15)) { openStep = openStep == step.id ? nil : step.id }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: stepSymbol(step.status))
                                    .font(.caption)
                                    .foregroundStyle(stepColor(step.status))
                                    .frame(width: 14)
                                Text(step.title).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                                Spacer(minLength: 4)
                                if step.brief != nil {
                                    Image(systemName: openStep == step.id ? "chevron.down" : "chevron.right")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        if openStep == step.id, let brief = step.brief {
                            // The evidence behind the answer: what this step found and where.
                            Text(brief)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
            if let waiting = detail?.waiting {
                waitingBox(waiting)
            }
            if status == "failed", let error = detail?.error {
                Text(error).font(.caption).foregroundStyle(WiqoTheme.red)
            }
            if let detail, status != "running" {
                Text(footer(detail)).font(.caption2).foregroundStyle(.secondary)
            }
            if let actionError {
                Text(actionError).font(.caption).foregroundStyle(WiqoTheme.red)
            }
            if status == "running" && detail?.waiting == nil {
                // Steer without cancelling: "şunu da ekle", "bunu atla".
                HStack(spacing: 6) {
                    TextField(steerSent ? "Başka yönlendirme…" : "Yönlendirme ekle…", text: $steerText)
                        .font(.subheadline)
                        .textFieldStyle(.roundedBorder)
                        .frame(minHeight: 44)
                        .submitLabel(.send)
                        .onSubmit { Task { await steer() } }
                    Button("Gönder") { Task { await steer() } }
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 44)
                        .disabled(steerText.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
                }
            }
            if status == "running" {
                Button("Durdur", role: .destructive) { confirmingCancel = true }
                    .font(.caption.weight(.semibold))
                    .disabled(isBusy)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiqoCard()
        .task(id: "\(task.id)-\(pollGeneration)") { await poll() }
        .confirmationDialog("Görev durdurulsun mu?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Görevi durdur", role: .destructive) {
                Task {
                    isBusy = true
                    defer { isBusy = false }
                    do {
                        try await RovaBackendClient.cancelAgentTask(id: task.id)
                        pollGeneration += 1
                    } catch {
                        actionError = "Durdurulamadı; görev zaten bitmiş olabilir."
                    }
                }
            }
        } message: {
            Text("Wiqo görevi o adımda bırakır; yarım sonuç teslim edilmez.")
        }
    }

    @ViewBuilder
    private func waitingBox(_ waiting: RovaBackendClient.AgentTaskDetail.Waiting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if waiting.reason == "approval" {
                Text("\(waiting.question ?? "Bir adım") için onayın gerekiyor.").font(.caption.weight(.medium))
                if let id = waiting.confirmationId.flatMap(UUID.init(uuidString:)) {
                    HStack {
                        Button("Onayla") { Task { await resolve(id, approved: true) } }
                            .buttonStyle(.borderedProminent)
                        Button("Reddet") { Task { await resolve(id, approved: false) } }
                            .buttonStyle(.bordered)
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(isBusy)
                }
            } else {
                Text("Görev bir soru soruyor:").font(.caption.weight(.medium))
                Text(waiting.question ?? "").font(.caption)
                Text("Cevabını bu sohbete yazman yeterli.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WiqoTheme.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func steer() async {
        let note = steerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await RovaBackendClient.steerAgentTask(id: task.id, note: note)
            steerText = ""
            steerSent = true
            actionError = nil
        } catch {
            actionError = "Yönlendirme iletilemedi; görev bitmiş olabilir."
        }
    }

    private func resolve(_ id: UUID, approved: Bool) async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await RovaBackendClient.resolveBackendConfirmation(id: id, approved: approved)
            actionError = nil
            pollGeneration += 1
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? "Onay iletilemedi."
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            if let fresh = try? await RovaBackendClient.fetchAgentTask(id: task.id) {
                detail = fresh
                if !fresh.isActive { return }
            }
            let delay: UInt64 = detail?.waiting == nil ? 4_000_000_000 : 10_000_000_000
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    private func footer(_ detail: RovaBackendClient.AgentTaskDetail) -> String {
        if let check = detail.verification {
            return check.checked ? "Doğrulandı" : "Doğrulama yapılamadı"
        }
        return "Doğrulanmadı"
    }

    private var statusLabel: String {
        if detail?.waiting?.reason == "approval" { return "onay bekliyor" }
        if detail?.waiting?.reason == "answer" { return "yanıt bekliyor" }
        switch status {
        case "done": return "tamamlandı"
        case "failed": return "tamamlanamadı"
        case "cancelled": return "durduruldu"
        default: return "çalışıyor"
        }
    }

    private var statusColor: Color {
        if detail?.waiting != nil { return WiqoTheme.orange }
        switch status {
        case "done": return .green
        case "failed": return WiqoTheme.red
        default: return .secondary
        }
    }

    private func stepSymbol(_ status: String) -> String {
        switch status {
        case "done": return "checkmark.circle.fill"
        case "failed": return "xmark.circle"
        case "running": return "arrow.triangle.2.circlepath"
        default: return "circle"
        }
    }

    private func stepColor(_ status: String) -> Color {
        switch status {
        case "done": return .green
        case "failed": return WiqoTheme.red
        case "running": return WiqoTheme.orange
        default: return .secondary
        }
    }
}


/// Wiqo's four sub-agent mascots (Assets: WiqoAgent*). Still when idle; while the agent works each
/// moves in character - General floats, Research looks around, Developer bobs to a typing beat,
/// Execution runs in place. Motion is small, and off entirely under Reduce Motion.
struct WiqoAgentMascot: View {
    enum Persona: String {
        case general, research, developer, execution

        init(_ raw: String?) { self = Persona(rawValue: raw ?? "") ?? .general }

        var imageName: String {
            switch self {
            case .general: return "WiqoAgentGeneral"
            case .research: return "WiqoAgentResearch"
            case .developer: return "WiqoAgentDeveloper"
            case .execution: return "WiqoAgentExecution"
            }
        }

        var label: String {
            switch self {
            case .general: return "Genel ajan"
            case .research: return "Araştırma ajanı"
            case .developer: return "Geliştirici ajan"
            case .execution: return "Yürütme ajanı"
            }
        }
    }

    let persona: Persona
    var size: CGFloat = 44
    var isWorking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displaySize: CGFloat { size * 1.3 }

    init(_ persona: String?, size: CGFloat = 44, isWorking: Bool = false) {
        self.persona = Persona(persona)
        self.size = size
        self.isWorking = isWorking
    }

    var body: some View {
        Group {
            if isWorking && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    mascot.modifier(Motion(persona: persona, time: context.date.timeIntervalSinceReferenceDate, size: displaySize))
                }
            } else {
                mascot
            }
        }
        .padding(displaySize * 0.035)
        .frame(width: displaySize, height: displaySize)
        .overlay(alignment: .bottomTrailing) {
            if isWorking {
                Circle()
                    .fill(.green)
                    .frame(width: max(9, displaySize * 0.18), height: max(9, displaySize * 0.18))
                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(persona.label + (isWorking ? ", çalışıyor" : ""))
    }

    private var mascot: some View {
        Image(persona.imageName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }

    private struct Motion: ViewModifier {
        let persona: Persona
        let time: TimeInterval
        let size: CGFloat

        func body(content: Content) -> some View {
            let unit = size / 44
            switch persona {
            case .general:
                content.offset(y: sin(time * 2.2) * 2.5 * unit)
            case .research:
                content
                    .rotationEffect(.degrees(sin(time * 1.6) * 7))
                    .offset(y: sin(time * 3.2) * 1.5 * unit)
            case .developer:
                content
                    .scaleEffect(1 + abs(sin(time * 5.0)) * 0.035)
                    .offset(y: -abs(sin(time * 5.0)) * 1.5 * unit)
            case .execution:
                content
                    .offset(x: sin(time * 9.0) * 1.6 * unit, y: -abs(sin(time * 9.0)) * 2.4 * unit)
                    .rotationEffect(.degrees(-4))
            }
        }
    }
}


/// Görevler: every background agent task, newest first, with its mascot; opens the live card.
struct AgentTasksView: View {
    @State private var tasks: [RovaBackendClient.AgentTaskDetail] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && tasks.isEmpty {
                VStack(spacing: 12) {
                    WiqoAgentMascot("general", size: 72)
                    Text("Henüz görev yok")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowSeparator(.hidden)
            }
            ForEach(tasks, id: \.id) { task in
                NavigationLink {
                    ScrollView {
                        AgentTaskCard(task: RovaBackendClient.AgentTaskRef(id: task.id, title: task.title, persona: task.persona))
                            .padding()
                    }
                    .navigationTitle("Görev")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack(spacing: 10) {
                        WiqoAgentMascot(task.persona, size: 56, isWorking: task.isActive && task.waiting == nil)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title).font(.body.weight(.semibold)).lineLimit(2)
                            Text(rowStatus(task)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Görevler")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        tasks = (try? await RovaBackendClient.fetchAgentTasks()) ?? tasks
        loaded = true
    }

    private func rowStatus(_ task: RovaBackendClient.AgentTaskDetail) -> String {
        if task.waiting?.reason == "approval" { return "Onayını bekliyor" }
        if task.waiting?.reason == "answer" { return "Yanıt bekliyor" }
        switch task.status {
        case "done": return "Tamamlandı"
        case "failed": return "Tamamlanamadı"
        case "cancelled": return "Durduruldu"
        case "pending", "queued": return "Sırada"
        default: return "Çalışıyor"
        }
    }
}

/// Ajanlarım: named agents, their routine and exactly what they remember - forget or delete here.
struct NamedAgentsView: View {
    @State private var agents: [RovaBackendClient.NamedAgent] = []
    @State private var watch: [RovaBackendClient.WatchSource] = []
    @State private var events: [RovaBackendClient.AgentEvent] = []
    @State private var loaded = false
    @State private var notice: String?
    @State private var agentToDelete: RovaBackendClient.NamedAgent?
    @State private var confirmingDelete = false

    var body: some View {
        List {
            Section {
                ForEach(watch) { source in
                    Toggle(isOn: Binding(
                        get: { source.enabled },
                        set: { value in Task { await setWatch(source.source, enabled: value) } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.source == "gmail" ? "Gelen mailleri izle" : "Takvimi izle")
                            Text(source.lastError ?? (source.source == "gmail" ? "Önemli olanı haber verir, gerisini sessizce not eder" : "Yeni ve değişen etkinlikleri takip eder"))
                                .font(.caption)
                                .foregroundStyle(source.lastError == nil ? Color.secondary : WiqoTheme.red)
                        }
                    }
                }
                ForEach(events.prefix(5)) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.summary ?? event.title).font(.subheadline)
                        Text(Self.statusLabel(event.status)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Wiqo seni izliyor")
            }
            if loaded && agents.isEmpty {
                VStack(spacing: 12) {
                    WiqoAgentMascot("general", size: 72)
                    Text("Henüz ajan yok")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowSeparator(.hidden)
            }
            ForEach(agents) { agent in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        WiqoAgentMascot(agent.persona, size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.name).font(.body.weight(.semibold))
                            Text(agent.cron == nil ? "İş verilince" : "Rutin")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Menu {
                            if !agent.memory.isEmpty {
                                Button("Hafızayı sil", systemImage: "eraser") {
                                    Task { await forgetMemory(for: agent) }
                                }
                            }
                            if agent.isPrimary != true {
                                Button("Ajanı sil", systemImage: "trash", role: .destructive) {
                                    agentToDelete = agent
                                    confirmingDelete = true
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("\(agent.name) seçenekleri")
                    }
                    Text(agent.role).font(.subheadline).foregroundStyle(.secondary)
                    if !agent.memory.isEmpty {
                        DisclosureGroup("Hafıza") {
                            Text(agent.memory)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(.top, 4)
                        }
                        .font(.subheadline.weight(.medium))
                    }
                }
                .padding(.vertical, 6)
            }
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundColor(notice.contains("silinemedi") ? WiqoTheme.red : Color.secondary)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Ajanlarım")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Ajan silinsin mi?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Ajanı sil", role: .destructive) {
                if let agentToDelete {
                    Task { await delete(agent: agentToDelete) }
                }
            }
            Button("Vazgeç", role: .cancel) { agentToDelete = nil }
        } message: {
            Text(agentToDelete?.name ?? "")
        }
    }

    private func forgetMemory(for agent: RovaBackendClient.NamedAgent) async {
        do {
            try await RovaBackendClient.forgetAgentMemory(id: agent.id)
            notice = "Hafıza silindi."
            await load()
        } catch {
            notice = "Hafıza silinemedi."
        }
    }

    private func delete(agent: RovaBackendClient.NamedAgent) async {
        do {
            try await RovaBackendClient.deleteAgent(id: agent.id)
            agentToDelete = nil
            notice = nil
            await load()
        } catch {
            agentToDelete = nil
            notice = "Ajan silinemedi."
        }
    }

    private func load() async {
        agents = (try? await RovaBackendClient.fetchAgents()) ?? agents
        watch = (try? await RovaBackendClient.fetchWatchSources()) ?? watch
        events = (try? await RovaBackendClient.fetchAgentEvents()) ?? events
        loaded = true
    }

    private func setWatch(_ source: String, enabled: Bool) async {
        if let updated = try? await RovaBackendClient.setWatchSource(source, enabled: enabled) { watch = updated }
        else { notice = "Ayar kaydedilemedi." }
    }

    private static func statusLabel(_ status: String) -> String {
        switch status {
        case "notified": return "Haber verdi"
        case "handled": return "Ajan üzerinde çalışıyor"
        case "noted": return "Not aldı"
        case "ignored": return "Önemsiz bulundu"
        default: return "Bekliyor"
        }
    }
}
