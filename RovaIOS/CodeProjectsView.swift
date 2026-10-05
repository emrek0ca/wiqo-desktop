import SwiftUI

/// "Kod projelerim": the web and Python projects Wiqo builds from chat. Editing stays in chat
/// ("butonu kırmızı yap"); here a project is previewed or run, its files read, a change undone,
/// and a web project shared by link.
struct CodeProjectsView: View {
    @State private var projects: [RovaBackendClient.CodeProject] = []
    @State private var loaded = false
    @State private var notice: String?

    var body: some View {
        List {
            if loaded && projects.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("Henüz kod projesi yok")
                        .font(.body.weight(.medium))
                    Text("Sohbette \"bir sayaç uygulaması yap\" ya da \"Python ile asal sayıları bulan program yaz\" de; proje burada görünür.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .listRowSeparator(.hidden)
            }
            ForEach(projects) { project in
                NavigationLink {
                    CodeProjectDetailView(projectID: project.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: project.kind == "web" ? "safari" : "terminal")
                            .font(.title3)
                            .foregroundStyle(WiqoTheme.ink)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name).font(.body.weight(.medium))
                            Text("\(project.kind == "web" ? "Web" : "Python") · v\(project.version) · \(project.fileCount ?? 0) dosya\(project.share != nil ? " · paylaşılıyor" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(WiqoTheme.red)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Kod projelerim")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            projects = try await RovaBackendClient.fetchCodeProjects()
            notice = nil
        } catch {
            notice = "Projeler yüklenemedi."
        }
        loaded = true
    }
}

struct CodeProjectDetailView: View {
    let projectID: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detail: RovaBackendClient.CodeProjectDetail?
    @State private var busy = false
    @State private var notice: String?
    @State private var previewHTML: String?
    @State private var runResult: RovaBackendClient.CodeRunResult?
    @State private var openFile: OpenFile?
    @State private var confirmingDelete = false

    private struct OpenFile: Identifiable {
        let path: String
        let content: String
        var id: String { path }
    }

    var body: some View {
        List {
            if let detail {
                actionsSection(detail)
                outputSection
                if detail.project.kind == "web" { shareSection(detail.project) }
                filesSection(detail.files)
                historySection(detail.history)
                Section {
                    Button("Projeyi sil", role: .destructive) { confirmingDelete = true }
                }
            } else {
                ProgressView()
            }
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(WiqoTheme.red)
            }
        }
        .navigationTitle(detail?.project.name ?? "Proje")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $openFile) { file in
            NavigationStack {
                ScrollView {
                    WiqoCodeBlock(code: file.content, title: file.path).padding()
                }
                .navigationTitle(file.path)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: Binding(get: { previewHTML != nil }, set: { if !$0 { previewHTML = nil } })) {
            NavigationStack {
                WiqoHTMLWebView(html: WiqoHTMLDocument.wrap(previewHTML ?? "", viewportWidth: WiqoPreviewDevice.phone.viewportWidth, reduceMotion: reduceMotion), projectDataKey: String(projectID))
                    .navigationTitle(detail?.project.name ?? "Önizleme")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .confirmationDialog("Proje silinsin mi?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Projeyi sil", role: .destructive) { Task { await delete() } }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Dosyalar ve geçmiş silinir; geri alınamaz.")
        }
    }

    private func actionsSection(_ detail: RovaBackendClient.CodeProjectDetail) -> some View {
        Section {
            HStack(spacing: 10) {
                if detail.project.kind == "web" {
                    Button { Task { await showPreview() } } label: { Label("Önizle", systemImage: "play.rectangle") }
                        .buttonStyle(.wiqoPill(.accent))
                } else {
                    Button { Task { await run() } } label: { Label("Çalıştır", systemImage: "play.fill") }
                        .buttonStyle(.wiqoPill(.accent))
                }
                Button { Task { await undo() } } label: { Label("Geri al", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.wiqoPill(.secondary))
                    .disabled(detail.history.isEmpty)
            }
            .disabled(busy)
            Text("Değiştirmek için sohbette anlat: \"butonları kırmızı yap\", \"sıfırla düğmesi ekle\".")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var outputSection: some View {
        if let runResult {
            Section("Çıktı") {
                Text(outputText(runResult))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                if !runResult.stderr.isEmpty {
                    Text(runResult.stderr)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(WiqoTheme.red)
                }
            }
        }
    }

    private func outputText(_ result: RovaBackendClient.CodeRunResult) -> String {
        if !result.stdout.isEmpty { return result.stdout }
        return result.timedOut ? "Program zamanında bitmedi." : "Çıktı yok."
    }

    private func shareSection(_ project: RovaBackendClient.CodeProject) -> some View {
        Section {
            if let share = project.share, let url = URL(string: share.url) {
                ShareLink(item: url) { Label("Bağlantıyı paylaş", systemImage: "square.and.arrow.up") }
                Text(share.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Paylaşımı kapat", role: .destructive) { Task { await setShare(false) } }
            } else {
                Button { Task { await setShare(true) } } label: { Label("Bağlantıyla paylaş (7 gün)", systemImage: "link") }
            }
        } header: {
            Text("Paylaşım")
        } footer: {
            Text("Bağlantıyı açan herkes sayfayı çalışır halde görür; hesabına veya verilerine erişemez.")
        }
    }

    private func filesSection(_ files: [RovaBackendClient.CodeProjectFile]) -> some View {
        Section("Dosyalar") {
            ForEach(files) { file in
                Button { Task { await show(file) } } label: {
                    HStack {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(file.path).foregroundStyle(.primary)
                        Spacer()
                        Text("\(file.bytes) B").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func historySection(_ history: [RovaBackendClient.CodeProjectVersion]) -> some View {
        Section("Geçmiş") {
            ForEach(history) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: entry.verified ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(entry.verified ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.summary).font(.subheadline)
                        Text(historyCaption(entry)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func historyCaption(_ entry: RovaBackendClient.CodeProjectVersion) -> String {
        entry.verified ? "v\(entry.version)" : "v\(entry.version) · çalışmıyor olabilir"
    }

    private func load() async {
        do {
            detail = try await RovaBackendClient.fetchCodeProject(id: projectID)
            notice = nil
        } catch {
            notice = "Proje yüklenemedi."
        }
    }

    private func showPreview() async {
        busy = true
        defer { busy = false }
        do { previewHTML = try await RovaBackendClient.fetchCodeProjectBundle(id: projectID) }
        catch { notice = "Önizleme açılamadı." }
    }

    private func run() async {
        busy = true
        defer { busy = false }
        do { runResult = try await RovaBackendClient.runCodeProject(id: projectID) }
        catch { notice = "Program çalıştırılamadı." }
    }

    private func undo() async {
        busy = true
        defer { busy = false }
        do {
            try await RovaBackendClient.undoCodeProject(id: projectID)
            runResult = nil
            await load()
        } catch {
            notice = "Geri alınacak değişiklik yok."
        }
    }

    private func setShare(_ enabled: Bool) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await RovaBackendClient.shareCodeProject(id: projectID, enabled: enabled)
            await load()
        } catch {
            notice = "Paylaşım ayarı değiştirilemedi."
        }
    }

    private func show(_ file: RovaBackendClient.CodeProjectFile) async {
        do {
            let content = try await RovaBackendClient.fetchCodeFile(id: projectID, path: file.path)
            openFile = OpenFile(path: file.path, content: content)
        } catch {
            notice = "Dosya açılamadı."
        }
    }

    private func delete() async {
        do {
            try await RovaBackendClient.deleteCodeProject(id: projectID)
            dismiss()
        } catch {
            notice = "Proje silinemedi."
        }
    }
}

/// The chat card for a change to a code project: what changed, per file, and whether it was
/// checked. "Önizle" opens the project's current page, "Geri al" reverses this change, "Proje"
/// opens the project screen.
struct CodeChangeCard: View {
    let widget: RovaBackendClient.CopilotResultWidget

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewHTML: String?
    @State private var showingProject = false
    @State private var busy = false
    @State private var status: String?

    private var verified: Bool { widget.verified ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let rows = widget.items, !rows.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text").font(.caption).foregroundStyle(.secondary)
                            Text(row.title).font(.footnote.monospaced()).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(row.subtitle ?? "").font(.caption2).foregroundStyle(.secondary)
                            Text(row.meta ?? "").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !verified {
                Label("Çalışmıyor olabilir; geri alabilir veya düzeltmesini isteyebilirsin.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                if widget.variant == "web" {
                    Button { Task { await showPreview() } } label: { Label("Önizle", systemImage: "play.rectangle") }
                        .buttonStyle(.wiqoPill(.accent))
                }
                Button { Task { await undo() } } label: { Label("Geri al", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.wiqoPill(.secondary))
                Button { showingProject = true } label: { Label("Proje", systemImage: "folder") }
                    .buttonStyle(.wiqoPill(.ghost))
            }
            .disabled(busy)
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiqoCard()
        .sheet(isPresented: Binding(get: { previewHTML != nil }, set: { if !$0 { previewHTML = nil } })) {
            NavigationStack {
                WiqoHTMLWebView(html: WiqoHTMLDocument.wrap(previewHTML ?? "", viewportWidth: WiqoPreviewDevice.phone.viewportWidth, reduceMotion: reduceMotion), projectDataKey: widget.id.map { String($0) })
                    .navigationTitle(widget.title ?? "Önizleme")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showingProject) {
            if let id = widget.id {
                NavigationStack { CodeProjectDetailView(projectID: id) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: widget.variant == "python" ? "terminal" : "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 36)
                .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(widget.title ?? "Proje") · v\(widget.projectVersion ?? 0)").font(.subheadline.weight(.semibold))
                Text(widget.detail ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
            Image(systemName: verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(verified ? Color.green : Color.orange)
        }
    }

    private func showPreview() async {
        guard let id = widget.id else { return }
        busy = true
        defer { busy = false }
        do { previewHTML = try await RovaBackendClient.fetchCodeProjectBundle(id: id) }
        catch { status = "Önizleme açılamadı." }
    }

    private func undo() async {
        guard let id = widget.id else { return }
        busy = true
        defer { busy = false }
        do {
            try await RovaBackendClient.undoCodeProject(id: id)
            status = "Projenin son değişikliği geri alındı."
        } catch {
            status = "Geri alınacak değişiklik yok."
        }
    }
}
