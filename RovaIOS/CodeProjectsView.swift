import SwiftUI

/// "Proje ayrıntıları": what the project screen's menu opens - share as a file, files, history.
/// Changing the project happens on the project screen (Act tab), not here.
struct CodeProjectDetailView: View {
    let projectID: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = ActModel.shared
    @State private var exportURL: URL?
    @State private var openFile: OpenFile?

    private struct OpenFile: Identifiable {
        let path: String
        let content: String
        var id: String { path }
    }

    private var project: ActLocalProject? { model.project(projectID) }

    var body: some View {
        List {
            if let project {
                shareSection(project)
                Section {
                    Label(project.mode.title, systemImage: project.mode.systemImage)
                    if project.mode == .devices {
                        Text("Dosyaların sunucuda yalnız şifreli durur; anahtar sadece cihazlarında.").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("Gizlilik") }
                conflictSection(project)
                filesSection(project)
                historySection(project)
            } else {
                Text("Proje bulunamadı.").foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Proje ayrıntıları")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Bitti") { dismiss() } } }
        .sheet(item: $openFile) { file in
            NavigationStack {
                ScrollView { WiqoCodeBlock(code: file.content, title: file.path).padding() }
                    .navigationTitle(file.path)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    /// Sharing is a file, not a link: the page as one HTML file (or the program's files) goes through the share sheet.
    private func shareSection(_ project: ActLocalProject) -> some View {
        Section {
            if let url = exportURL {
                ShareLink(item: url) { Label(project.isWeb ? "Sayfayı HTML dosyası olarak paylaş" : "Programı dosya olarak paylaş", systemImage: "square.and.arrow.up") }
            } else {
                Button { prepareExport() } label: { Label("Paylaşım dosyasını hazırla", systemImage: "square.and.arrow.up") }
            }
        } header: {
            Text("Paylaşım")
        } footer: {
            Text("Dosya AirDrop, Mesajlar veya Dosyalar ile gönderilir; hiçbir şey internette yayınlanmaz.")
        }
    }

    /// Two devices changed the same file: the hub's version stayed, this device's is saved beside it. Choose one.
    @ViewBuilder private func conflictSection(_ project: ActLocalProject) -> some View {
        let copies = model.conflictCopies(project.id)
        if !copies.isEmpty {
            Section {
                ForEach(copies, id: \.copy) { pair in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pair.original).font(.subheadline.weight(.medium))
                        Text("Başka bir cihazdaki sürüm yerinde; bu cihazın sürümü \"\(pair.copy)\" olarak yanına kaydedildi.").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("Kopyayı kullan") { model.resolveConflict(project.id, copy: pair.copy, useCopy: true) }.buttonStyle(.borderedProminent).controlSize(.small)
                            Button("Kopyayı sil") { model.resolveConflict(project.id, copy: pair.copy, useCopy: false) }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: { Text("Çakışmalar") } footer: { Text("İkisini birleştirmek için iki dosyayı bir editörde aç (Mac'teki klasörde yan yana durur).") }
        }
    }

    private func filesSection(_ project: ActLocalProject) -> some View {
        Section("Dosyalar") {
            ForEach(project.sortedFiles, id: \.path) { file in
                Button { openFile = OpenFile(path: file.path, content: file.content) } label: {
                    HStack {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(file.path).foregroundStyle(.primary)
                        Spacer()
                        Text(Self.size(file.content.utf8.count)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func historySection(_ project: ActLocalProject) -> some View {
        Section("Geçmiş") {
            ForEach(project.history) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.verified ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(entry.verified ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.summary).font(.subheadline)
                        Text("\(entry.source) · \(entry.date.formatted(date: .abbreviated, time: .shortened))" + (entry.verified ? "" : " · çalışmıyor olabilir"))
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

    private func prepareExport() {
        do { exportURL = try model.exportURL(projectID) }
        catch { model.notice = (error as? LocalizedError)?.errorDescription ?? "Dosya hazırlanamadı." }
    }
}

/// The chat card for a project that was changed in chat (an older way of working): one summary line.
/// Projects are made and changed in the Act tab now; the card points there.
struct CodeChangeCard: View {
    let widget: RovaBackendClient.CopilotResultWidget

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
            Button { NotificationCenter.default.post(name: .wiqoOpenAct, object: nil) } label: {
                Label("Act'te aç", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
            }
            .buttonStyle(.wiqoPill(.accent))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiqoCard()
    }
}

extension Notification.Name {
    /// Asks the home screen to switch to the Act tab.
    static let wiqoOpenAct = Notification.Name("wiqo.open-act")
}
