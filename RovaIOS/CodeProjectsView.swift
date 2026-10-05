import SwiftUI

/// "Proje ayrıntıları": what the project screen's menu opens - share as a file, files, history.
/// Changing the project happens on the project screen (Act tab), not here.
struct CodeProjectDetailView: View {
    let projectID: Int

    @Environment(\.dismiss) private var dismiss
    @State private var detail: RovaBackendClient.CodeProjectDetail?
    @State private var busy = false
    @State private var notice: String?
    @State private var openFile: OpenFile?
    @State private var exportURL: URL?

    private struct OpenFile: Identifiable {
        let path: String
        let content: String
        var id: String { path }
    }

    var body: some View {
        List {
            if let detail {
                shareSection(detail)
                filesSection(detail.files)
                historySection(detail.history)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(WiqoTheme.red)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Proje ayrıntıları")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Bitti") { dismiss() } }
        }
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
    }

    /// Sharing is a file, not a link: the page as one HTML file (or the program's files) goes through the share sheet.
    private func shareSection(_ detail: RovaBackendClient.CodeProjectDetail) -> some View {
        Section {
            if let url = exportURL {
                ShareLink(item: url) { Label(detail.project.kind == "web" ? "Sayfayı HTML dosyası olarak paylaş" : "Programı dosya olarak paylaş", systemImage: "square.and.arrow.up") }
            } else {
                Button { Task { await prepareExport(detail.project) } } label: { Label("Paylaşım dosyasını hazırla", systemImage: "square.and.arrow.up") }
                    .disabled(busy)
            }
        } header: {
            Text("Paylaşım")
        } footer: {
            Text("Dosya AirDrop, Mesajlar veya Dosyalar ile gönderilir; hiçbir şey internette yayınlanmaz.")
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
                        Text(Self.size(file.bytes)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func historySection(_ history: [RovaBackendClient.CodeProjectVersion]) -> some View {
        Section("Geçmiş") {
            ForEach(history) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.verified ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(entry.verified ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.summary).font(.subheadline)
                        Text(entry.verified ? "v\(entry.version)" : "v\(entry.version) · çalışmıyor olabilir")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private static func size(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B" : String(format: "%.1f KB", Double(bytes) / 1024)
    }

    private func load() async {
        do {
            detail = try await RovaBackendClient.fetchCodeProject(id: projectID)
            notice = nil
        } catch {
            notice = "Proje yüklenemedi."
        }
    }

    /// Writes the project to a temporary file from the local copy on this phone (so it works offline too).
    private func prepareExport(_ project: RovaBackendClient.CodeProject) async {
        busy = true
        defer { busy = false }
        guard let local = await ActProjectStore.pull(projectID) else { notice = "Dosya hazırlanamadı."; return }
        let safe = project.name.replacingOccurrences(of: "/", with: "-")
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("wiqo-export-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if project.kind == "web", let bundle = local.bundle {
                let url = dir.appendingPathComponent("\(safe).html")
                try bundle.write(to: url, atomically: true, encoding: .utf8)
                exportURL = url
            } else if let entry = local.files.first(where: { $0.path == "main.py" }) ?? local.files.first {
                let url = dir.appendingPathComponent(local.files.count == 1 ? URL(fileURLWithPath: entry.path).lastPathComponent : "\(safe).py")
                try (local.files.count == 1 ? entry.content : local.files.map { "# --- \($0.path) ---\n\($0.content)" }.joined(separator: "\n\n")).write(to: url, atomically: true, encoding: .utf8)
                exportURL = url
            } else { notice = "Projede dosya yok." }
        } catch { notice = "Dosya hazırlanamadı." }
    }

    private func show(_ file: RovaBackendClient.CodeProjectFile) async {
        do {
            let content = try await RovaBackendClient.fetchCodeFile(id: projectID, path: file.path)
            openFile = OpenFile(path: file.path, content: content)
        } catch {
            notice = "Dosya açılamadı."
        }
    }
}

/// The chat card for a project that was changed: one summary line and one way in. The project
/// itself (live page, further changes, undo) is on its screen in the Act tab.
struct CodeChangeCard: View {
    let widget: RovaBackendClient.CopilotResultWidget

    @State private var showingProject = false

    private var verified: Bool { widget.verified ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: widget.variant == "python" ? "terminal" : "safari")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(WiqoTheme.ink)
                    .frame(width: 38, height: 38)
                    .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(widget.title ?? "Proje") · v\(widget.projectVersion ?? 0)")
                        .font(.subheadline.weight(.semibold))
                    if let detail = widget.detail, !detail.isEmpty {
                        Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(verified ? Color.green : Color.orange)
            }
            if let rows = widget.items, !rows.isEmpty {
                Text(rows.prefix(4).map { "\($0.title) \($0.meta ?? "")".trimmingCharacters(in: .whitespaces) }.joined(separator: "  ·  "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !verified {
                Label("Çalışmıyor olabilir; projeden geri alabilir veya düzeltmesini isteyebilirsin.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button { showingProject = true } label: {
                Label("Projeyi aç", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
            }
            .buttonStyle(.wiqoPill(.accent))
            .disabled(widget.id == nil)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiqoCard()
        .fullScreenCover(isPresented: $showingProject) {
            if let id = widget.id {
                NavigationStack { CodeProjectWorkspaceView(projectID: id, isModal: true) }
            }
        }
    }
}
