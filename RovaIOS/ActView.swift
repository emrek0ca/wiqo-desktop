import CryptoKit
import SwiftUI

private func actRequestFingerprint(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Tries the candidate page in the phone's own WebKit and reports the answer. Never throws: if the answer
/// cannot be delivered, the backend saves the change unverified once its grace period is over.
@MainActor
private func verifyActCandidate(taskID: Int, candidateID: String) async {
    do {
        let candidate = try await RovaBackendClient.fetchCodeProjectCandidate(id: taskID)
        guard candidate.candidateId == candidateID else { return }
        switch await ActWebVerifier().verify(candidate.html) {
        case .passed:
            try await RovaBackendClient.reportCodeProjectVerification(id: taskID, candidateId: candidateID, problems: [])
        case .problems(let list):
            try await RovaBackendClient.reportCodeProjectVerification(id: taskID, candidateId: candidateID, problems: list)
        case .unavailable:
            try await RovaBackendClient.reportCodeProjectVerification(id: taskID, candidateId: candidateID, problems: [], skipped: true)
        }
    } catch {
        // Left to the backend's grace period.
    }
}

/// The three steps every Act job goes through, in order.
enum ActStage: Int, CaseIterable {
    case writing, verifying, saving

    var title: String {
        switch self {
        case .writing: return "Yazılıyor"
        case .verifying: return "Telefonda deneniyor"
        case .saving: return "Kaydediliyor"
        }
    }
}

/// One progress card for creating and for changing: the steps in order, the current one marked,
/// the job's own message under it, and a way to stop.
private struct ActJobCard: View {
    let stage: ActStage
    let message: String?
    let onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ActStage.allCases, id: \.rawValue) { step in
                HStack(spacing: 10) {
                    Group {
                        if step.rawValue < stage.rawValue {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                        } else if step == stage {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(step.title)
                        .font(.subheadline.weight(step == stage ? .semibold : .regular))
                        .foregroundStyle(step.rawValue > stage.rawValue ? .secondary : .primary)
                }
            }
            if let message, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let onCancel {
                Button("Durdur", action: onCancel).font(.footnote.weight(.medium))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

enum ActJobOutcome {
    case finished(RovaBackendClient.CodeProjectJob)
    case failed(String)
    case stillRunning
}

/// Follows one Act job to its end: shows the job's real progress, tries the page on this phone when the
/// backend asks, and says what went wrong instead of waiting silently. Server errors are retried for
/// about 30 seconds before the job is reported as unreachable.
@MainActor
private func watchActJob(id: Int, progress: (ActStage, String) -> Void, isCurrent: () -> Bool) async -> ActJobOutcome {
    var tried: Set<String> = []
    var failures = 0
    for _ in 0..<130 {
        if Task.isCancelled || !isCurrent() { return .stillRunning }
        do {
            let job = try await RovaBackendClient.fetchCodeProjectJob(id: id)
            failures = 0
            if job.finished { return .finished(job) }
            if job.status == "waiting_device", let candidate = job.verification {
                progress(.verifying, "Sayfa bu telefonun tarayıcısında açılıp deneniyor.")
                if tried.insert(candidate.candidateId).inserted {
                    await verifyActCandidate(taskID: id, candidateID: candidate.candidateId)
                    progress(.saving, "")
                    continue
                }
            } else {
                progress(.writing, job.progress ?? "Hazırlanıyor…")
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if message.contains("bulunamadı") { return .failed("Görev bulunamadı; listeyi yenileyip tekrar dene.") }
            failures += 1
            if failures >= 15 { return .failed("Sunucuya ulaşılamadı: \(message)") }
            if failures >= 3 { progress(.writing, "Bağlantı zayıf, yeniden deneniyor…") }
        }
        try? await Task.sleep(for: .seconds(2))
    }
    return .stillRunning
}

/// The "Act" tab: where apps, games, pages and programs are made. A description creates a project;
/// every project is a row in the list; opening one keeps all further changes on that project.
struct ActView: View {
    @State private var projects: [RovaBackendClient.CodeProject] = []
    @State private var loaded = false
    @State private var draft = ""
    @State private var creating = false
    @State private var activeJobID: Int?
    @State private var jobProgress: String?
    @State private var jobStage: ActStage = .writing
    @State private var notice: String?
    @State private var opened: OpenedProject?
    @State private var pendingDelete: RovaBackendClient.CodeProject?
    @FocusState private var composerFocused: Bool

    private struct OpenedProject: Hashable { let id: Int }

    private static let suggestions: [(title: String, prompt: String)] = [
        ("Sayaç", "Artır, azalt ve sıfırla butonları olan bir sayaç uygulaması yap"),
        ("Yapılacaklar", "Görev ekleme, silme ve tamamlandı işaretleme olan bir yapılacaklar listesi yap"),
        ("Hafıza oyunu", "4x4 kartlı basit bir hafıza kartı eşleştirme oyunu yap"),
        ("Kişisel site", "Kişisel tanıtım sayfası yap: adım, mesleğim ve iletişim bölümü olsun"),
        ("Python", "Python ile 1'den 100'e kadar asal sayıları yazdıran bir program yap")
    ]

    private var canCreate: Bool { !creating && activeJobID == nil && draft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 }

    var body: some View {
        Group {
            if let opened {
                CodeProjectWorkspaceView(projectID: opened.id, embedded: true, onBack: { self.opened = nil })
            } else {
                projectList
            }
        }
    }

    private var projectList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                composerCard
                projectsSection
            }
            .padding(.horizontal, RovaDesign.screenPadding)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(RovaDesign.canvas)
        .confirmationDialog("Proje silinsin mi?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible, presenting: pendingDelete) { project in
            Button("\(project.name) projesini sil", role: .destructive) { Task { await delete(project) } }
            Button("Vazgeç", role: .cancel) {}
        } message: { _ in
            Text("Dosyalar ve geçmiş silinir; geri alınamaz.")
        }
        .task {
            await load()
            if let id = UserDefaults.standard.object(forKey: createJobStorageKey) as? Int {
                activeJobID = id
                creating = true
                await watchCreateJob(id)
            }
        }
        .refreshable { await load() }
    }

    // MARK: - Yeni proje

    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ne yapalım?")
                .font(.title2.weight(.semibold))

            TextField("Örn. günlük su takibi uygulaması", text: $draft, axis: .vertical)
                .lineLimit(2...5)
                .focused($composerFocused)
                .disabled(creating)
                .padding(12)
                .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if draft.isEmpty && !creating {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.suggestions, id: \.title) { suggestion in
                            Button {
                                draft = suggestion.prompt
                                composerFocused = true
                            } label: {
                                Text(suggestion.title)
                                    .font(.footnote.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .frame(height: 32)
                                    .background(WiqoTheme.inset, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Button { Task { await create() } } label: {
                HStack(spacing: 8) {
                    if creating { ProgressView().controlSize(.small).tint(Color(.systemBackground)) }
                    Text(creating ? "Hazırlanıyor…" : "Oluştur")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.wiqoPill(.accent))
            .disabled(!canCreate)

            if creating || activeJobID != nil {
                ActJobCard(stage: jobStage, message: jobProgress, onCancel: activeJobID.map { id in { Task { await cancelCreateJob(id) } } })
            }

            if let notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(WiqoTheme.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiqoCard(radius: 20)
    }

    // MARK: - Liste

    @ViewBuilder private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Projelerim").font(.headline)
                if !projects.isEmpty {
                    Text("\(projects.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(WiqoTheme.inset, in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 4)

            if !loaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
            } else if projects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Henüz proje yok")
                        .font(.subheadline.weight(.medium))
                    Text("Yukarıya ne istediğini yaz; projen burada listelenir.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                VStack(spacing: 10) {
                    ForEach(projects) { project in
                        Button { opened = OpenedProject(id: project.id) } label: { ProjectRow(project: project) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { opened = OpenedProject(id: project.id) } label: { Label("Aç", systemImage: "arrow.up.right.square") }
                                Button(role: .destructive) { pendingDelete = project } label: { Label("Sil", systemImage: "trash") }
                            }
                    }
                }
            }
        }
    }

    // MARK: - İşlemler

    private func load() async {
        do {
            projects = try await RovaBackendClient.fetchCodeProjects()
            if creating == false { notice = nil }
            let fresh = projects
            Task { await ActProjectStore.sync(with: fresh) }
        } catch {
            // Offline: the copies on this phone are the list.
            if projects.isEmpty {
                projects = ActProjectStore.all().map {
                    RovaBackendClient.CodeProject(id: $0.id, name: $0.name, kind: $0.kind, version: $0.version, updatedAt: "", fileCount: $0.files.count)
                }
                if projects.isEmpty { notice = "Projeler yüklenemedi." }
                else { notice = "Çevrimdışı: bu telefondaki kopyalar gösteriliyor." }
            }
        }
        loaded = true
    }

    private func create() async {
        let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.count >= 3, !creating else { return }
        creating = true
        notice = nil
        composerFocused = false
        defer { creating = false }
        do {
            let fingerprint = actRequestFingerprint(request)
            let key = UserDefaults.standard.string(forKey: "\(createRequestStorageKey)-hash") == fingerprint
                ? (UserDefaults.standard.string(forKey: createRequestStorageKey) ?? UUID().uuidString) : UUID().uuidString
            UserDefaults.standard.set(key, forKey: createRequestStorageKey)
            UserDefaults.standard.set(fingerprint, forKey: "\(createRequestStorageKey)-hash")
            let id = try await RovaBackendClient.startCodeProjectJob(operation: "create", request: request, requestKey: key)
            UserDefaults.standard.set(id, forKey: createJobStorageKey)
            UserDefaults.standard.removeObject(forKey: createRequestStorageKey)
            UserDefaults.standard.removeObject(forKey: "\(createRequestStorageKey)-hash")
            activeJobID = id
            await watchCreateJob(id)
        } catch {
            notice = (error as? RovaBackendError)?.errorDescription ?? "Proje oluşturulamadı; biraz sonra tekrar dene."
        }
    }

    private var createJobStorageKey: String { "act-create-job-\(RovaBackendClient.currentUserID ?? "anonymous")" }
    private var createRequestStorageKey: String { "act-create-request-\(RovaBackendClient.currentUserID ?? "anonymous")" }

    private func watchCreateJob(_ id: Int) async {
        let outcome = await watchActJob(id: id, progress: { jobStage = $0; jobProgress = $1 }, isCurrent: { activeJobID == id })
        switch outcome {
        case .finished(let job):
            UserDefaults.standard.removeObject(forKey: createJobStorageKey)
            activeJobID = nil
            jobProgress = nil
            creating = false
            if job.result?.succeeded == true, let projectId = job.result?.projectId {
                draft = ""
                WiqoHaptics.selection()
                await load()
                opened = OpenedProject(id: projectId)
            } else {
                notice = job.result?.problem ?? job.error ?? "Proje tamamlanamadı."
            }
        case .failed(let message):
            UserDefaults.standard.removeObject(forKey: createJobStorageKey)
            activeJobID = nil
            jobProgress = nil
            creating = false
            notice = message
        case .stillRunning:
            if activeJobID == id { jobProgress = "Görev sürüyor; biraz sonra listeyi yenile." }
        }
    }

    private func cancelCreateJob(_ id: Int) async {
        do {
            try await RovaBackendClient.cancelCodeProjectJob(id: id)
            UserDefaults.standard.removeObject(forKey: createJobStorageKey)
            activeJobID = nil
            creating = false
            jobProgress = nil
            notice = "Görev durduruldu."
        } catch { notice = "Görev şu anda durdurulamadı; durumunu tekrar kontrol et." }
    }

    private func delete(_ project: RovaBackendClient.CodeProject) async {
        do {
            try await RovaBackendClient.deleteCodeProject(id: project.id)
            projects.removeAll { $0.id == project.id }
        } catch {
            notice = "Proje silinemedi."
        }
    }
}

private struct ProjectRow: View {
    let project: RovaBackendClient.CodeProject

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: project.kind == "web" ? "safari" : "terminal")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(WiqoTheme.ink)
                .frame(width: 40, height: 40)
                .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiqoCard()
        .contentShape(Rectangle())
    }

    private var caption: String {
        var parts = [project.kind == "web" ? "Web" : "Python", "v\(project.version)"]
        if let when = Self.relative(project.updatedAt) { parts.append(when) }
        return parts.joined(separator: " · ")
    }

    private static let sqlite: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func relative(_ value: String) -> String? {
        guard let date = sqlite.date(from: value) else { return nil }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Proje çalışma alanı

/// One project, full screen: the running page (or the program's output) on top, one input at the
/// bottom. Whatever is typed there changes this project and nothing else.
struct CodeProjectWorkspaceView: View {
    let projectID: Int
    var isModal = false
    var embedded = false
    var onBack: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detail: RovaBackendClient.CodeProjectDetail?
    @State private var html: String?
    @State private var runResult: RovaBackendClient.CodeRunResult?
    @State private var draft = ""
    @State private var working = false
    @State private var activeJobID: Int?
    @State private var jobProgress: String?
    @State private var jobStage: ActStage = .writing
    @State private var notice: String?
    @State private var warning: String?
    @State private var reloadToken = 0
    @State private var showingDetails = false
    @State private var confirmingDelete = false
    @FocusState private var focused: Bool

    @State private var localKind: String?
    @State private var pcStatus: String?
    @State private var pcOutput: String?
    @State private var localName: String?
    private var isWeb: Bool { (detail?.project.kind ?? localKind) != "python" }
    private var canSend: Bool { !working && activeJobID == nil && draft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }
    private var latest: RovaBackendClient.CodeProjectVersion? { detail?.history.first }

    var body: some View {
        VStack(spacing: 0) {
            if embedded {
                HStack(spacing: 10) {
                    Button { onBack?() } label: { Label("Projeler", systemImage: "chevron.left") }
                        .buttonStyle(.plain)
                        .foregroundStyle(WiqoTheme.ink)
                    Text(detail?.project.name ?? localName ?? "Proje")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    menu
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
            }
            stage
            Divider()
            footer
        }
        .background(RovaDesign.canvas)
        .navigationTitle(embedded ? "" : (detail?.project.name ?? localName ?? "Proje"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isModal {
                ToolbarItem(placement: .topBarLeading) { Button("Kapat") { dismiss() } }
            }
            if !embedded { ToolbarItem(placement: .topBarTrailing) { menu } }
        }
        .sheet(isPresented: $showingDetails, onDismiss: { Task { await load() } }) {
            NavigationStack { CodeProjectDetailView(projectID: projectID) }
        }
        .confirmationDialog("Proje silinsin mi?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Projeyi sil", role: .destructive) { Task { await deleteProject() } }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Dosyalar ve geçmiş silinir; geri alınamaz.")
        }
        .task {
            await RovaBackendClient.openCodeProject(id: projectID)
            await load()
            if let id = UserDefaults.standard.object(forKey: editJobStorageKey) as? Int {
                activeJobID = id
                working = true
                await watchEditJob(id)
            }
        }
    }

    // MARK: Sahne

    @ViewBuilder private var stage: some View {
        ZStack {
            if detail == nil && localKind == nil && notice == nil {
                ProgressView()
            } else if isWeb {
                if let html {
                    WiqoHTMLWebView(
                        html: WiqoHTMLDocument.wrap(html, viewportWidth: WiqoPreviewDevice.phone.viewportWidth, reduceMotion: reduceMotion),
                        projectDataKey: String(projectID),
                        reloadToken: reloadToken
                    )
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(WiqoTheme.lineStrong, lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                } else if notice == nil {
                    ProgressView()
                }
            } else {
                pythonStage
            }
            if working { workingOverlay }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pythonStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Button { Task { await run() } } label: { Label(runResult == nil ? "Çalıştır" : "Tekrar çalıştır", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.wiqoPill(.accent))
                    .disabled(working)
                if let pcOutput, !pcOutput.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mac çıktısı").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(pcOutput).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .wiqoCard()
                }
                if let runResult {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Çıktı").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(runResult.stdout.isEmpty ? (runResult.timedOut ? "Program zamanında bitmedi." : "Çıktı yok.") : runResult.stdout)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !runResult.stderr.isEmpty {
                            Text(runResult.stderr)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(WiqoTheme.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                    .wiqoCard()
                } else {
                    Text("Programı çalıştırınca çıktısı burada görünür.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .padding(14)
        }
    }

    private var workingOverlay: some View {
        ActJobCard(stage: jobStage, message: jobProgress, onCancel: activeJobID.map { id in { Task { await cancelEditJob(id) } } })
            .frame(maxWidth: 300)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .transition(.opacity)
    }

    // MARK: Alt bölüm

    private var footer: some View {
        VStack(spacing: 10) {
            if let notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(WiqoTheme.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let pcStatus {
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                    Text(pcStatus).font(.footnote).lineLimit(3)
                    Spacer(minLength: 4)
                    Button { self.pcStatus = nil; pcOutput = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if let latest { changeStrip(latest) }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ne değiştirelim?", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .disabled(working)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 38, height: 38)
                        .background(canSend ? WiqoTheme.ink : WiqoTheme.ink.opacity(0.25), in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Değişikliği uygula")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private func changeStrip(_ entry: RovaBackendClient.CodeProjectVersion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(entry.verified ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("v\(entry.version) · \(entry.summary)")
                    .font(.footnote)
                    .lineLimit(1)
                if !entry.verified {
                    Text("Çalışmıyor olabilir; geri al ya da düzeltmesini iste.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            Button { Task { await undo() } } label: { Label("Geri al", systemImage: "arrow.uturn.backward").font(.footnote.weight(.medium)) }
                .buttonStyle(.plain)
                .foregroundStyle(WiqoTheme.ink)
                .disabled(working || (detail?.history.count ?? 0) < 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var menu: some View {
        Menu {
            Button { Task { await undo() } } label: { Label("Son değişikliği geri al", systemImage: "arrow.uturn.backward") }
                .disabled(working || (detail?.history.count ?? 0) < 2)
            if isWeb {
                Button { reloadToken += 1 } label: { Label("Sayfayı yenile", systemImage: "arrow.clockwise") }
            }
            Section("Mac'te") {
                if isWeb {
                    Button { Task { await handOff("open_preview", "Mac'te önizleme açılıyor…") } } label: { Label("Mac'te önizle", systemImage: "macwindow") }
                } else {
                    Button { Task { await handOff("run", "Mac'te çalıştırılıyor…") } } label: { Label("Mac'te çalıştır", systemImage: "play.rectangle") }
                }
                Button { Task { await handOff("open_editor", "Editörde açılıyor…") } } label: { Label("Mac'te editörde aç", systemImage: "chevron.left.forwardslash.chevron.right") }
                Button { Task { await handOff("open_folder", "Klasör açılıyor…") } } label: { Label("Klasörü Mac'te aç", systemImage: "folder") }
            }
            Button { showingDetails = true } label: { Label("Dosyalar, geçmiş, dosya olarak paylaş", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive) { confirmingDelete = true } label: { Label("Projeyi sil", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Proje menüsü")
    }

    // MARK: İşlemler

    private func load() async {
        // The copy on this phone opens first, with or without a connection.
        if html == nil, let local = ActProjectStore.load(projectID) {
            localKind = local.kind
            localName = local.name
            if local.kind == "web", let bundle = local.bundle { html = bundle; reloadToken += 1 }
        }
        do {
            let fresh = try await RovaBackendClient.fetchCodeProject(id: projectID)
            detail = fresh
            if fresh.project.kind == "web" {
                if let pulled = await ActProjectStore.pull(projectID, knownServerVersion: fresh.project.version), let bundle = pulled.bundle {
                    if bundle != html { html = bundle; reloadToken += 1 }
                } else {
                    html = try await RovaBackendClient.fetchCodeProjectBundle(id: projectID)
                    reloadToken += 1
                }
            } else {
                await ActProjectStore.pull(projectID, knownServerVersion: fresh.project.version)
            }
            notice = nil
        } catch {
            if detail == nil && localKind != nil { notice = "Çevrimdışı: bu telefondaki kopya gösteriliyor." }
            else { notice = detail == nil ? "Proje yüklenemedi." : "Önizleme açılamadı." }
        }
    }

    private func send() async {
        let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.count >= 2, !working else { return }
        working = true
        notice = nil
        warning = nil
        focused = false
        defer { working = false }
        do {
            let fingerprint = actRequestFingerprint(request)
            let key = UserDefaults.standard.string(forKey: "\(editRequestStorageKey)-hash") == fingerprint
                ? (UserDefaults.standard.string(forKey: editRequestStorageKey) ?? UUID().uuidString) : UUID().uuidString
            UserDefaults.standard.set(key, forKey: editRequestStorageKey)
            UserDefaults.standard.set(fingerprint, forKey: "\(editRequestStorageKey)-hash")
            let id = try await RovaBackendClient.startCodeProjectJob(operation: "edit", request: request, projectId: projectID, requestKey: key)
            UserDefaults.standard.set(id, forKey: editJobStorageKey)
            UserDefaults.standard.removeObject(forKey: editRequestStorageKey)
            UserDefaults.standard.removeObject(forKey: "\(editRequestStorageKey)-hash")
            activeJobID = id
            await watchEditJob(id)
        } catch {
            notice = (error as? RovaBackendError)?.errorDescription ?? "Değişiklik uygulanamadı; proje değişmedi."
        }
    }

    private var editJobStorageKey: String { "act-edit-job-\(RovaBackendClient.currentUserID ?? "anonymous")-\(projectID)" }
    private var editRequestStorageKey: String { "act-edit-request-\(RovaBackendClient.currentUserID ?? "anonymous")-\(projectID)" }

    private func watchEditJob(_ id: Int) async {
        let outcome = await watchActJob(id: id, progress: { jobStage = $0; jobProgress = $1 }, isCurrent: { activeJobID == id })
        switch outcome {
        case .finished(let job):
            UserDefaults.standard.removeObject(forKey: editJobStorageKey)
            activeJobID = nil
            jobProgress = nil
            working = false
            if job.result?.succeeded == true {
                draft = ""
                WiqoHaptics.selection()
                runResult = nil
                warning = job.result?.verified == false ? job.result?.problem : nil
                await load()
            } else {
                notice = job.result?.problem ?? job.error ?? "Değişiklik uygulanamadı; proje değişmedi."
            }
        case .failed(let message):
            UserDefaults.standard.removeObject(forKey: editJobStorageKey)
            activeJobID = nil
            jobProgress = nil
            working = false
            notice = message
        case .stillRunning:
            if activeJobID == id { jobProgress = "Görev sürüyor; projeyi yeniden açınca durumu görürsün." }
        }
    }

    private func cancelEditJob(_ id: Int) async {
        do {
            try await RovaBackendClient.cancelCodeProjectJob(id: id)
            UserDefaults.standard.removeObject(forKey: editJobStorageKey)
            activeJobID = nil
            working = false
            jobProgress = nil
            notice = "Görev durduruldu; proje değişmedi."
        } catch { notice = "Görev şu anda durdurulamadı; durumunu tekrar kontrol et." }
    }

    private func undo() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            try await RovaBackendClient.undoCodeProject(id: projectID)
            warning = nil
            runResult = nil
            await load()
        } catch {
            notice = "Geri alınacak değişiklik yok."
        }
    }

    private func run() async {
        working = true
        defer { working = false }
        do { runResult = try await RovaBackendClient.runCodeProject(id: projectID) }
        catch { notice = "Program çalıştırılamadı." }
    }

    /// Hands one of the fixed actions to the paired Mac and follows it to its answer.
    private func handOff(_ action: String, _ message: String) async {
        pcStatus = message
        pcOutput = nil
        do {
            let task = try await RovaBackendClient.startCodeProjectPcTask(projectId: projectID, action: action)
            for _ in 0..<40 {
                try? await Task.sleep(for: .seconds(2))
                let current = try await RovaBackendClient.fetchCodeProjectPcTask(id: task.id)
                if current.finished {
                    pcStatus = current.status == "done" ? (action == "run" ? "Mac çalıştırdı." : current.output) : "Mac: \(current.output)"
                    if action == "run" { pcOutput = current.output }
                    return
                }
            }
            pcStatus = "Mac yanıt vermedi; açık ve internete bağlı mı?"
        } catch {
            pcStatus = (error as? RovaBackendError)?.errorDescription ?? "Mac'e iletilemedi."
        }
    }

    private func deleteProject() async {
        do {
            try await RovaBackendClient.deleteCodeProject(id: projectID)
            if embedded { onBack?() } else { dismiss() }
        } catch {
            notice = "Proje silinemedi."
        }
    }
}
