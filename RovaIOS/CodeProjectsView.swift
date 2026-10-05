import SwiftUI

/// "Proje ayrıntıları": what the project screen's menu opens - share link, files, history, delete.
/// Changing the project happens on the project screen (Act tab), not here.
struct CodeProjectDetailView: View {
    let projectID: Int

    @Environment(\.dismiss) private var dismiss
    @State private var detail: RovaBackendClient.CodeProjectDetail?
    @State private var busy = false
    @State private var notice: String?
    @State private var openFile: OpenFile?

    private struct OpenFile: Identifiable {
        let path: String
        let content: String
        var id: String { path }
    }

    var body: some View {
        List {
            if let detail {
                if detail.project.kind == "web" { shareSection(detail.project) }
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
        .disabled(busy)
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
