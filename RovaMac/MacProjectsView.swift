import AppKit
import SwiftUI
import WebKit

/// The Act projects on this Mac, read straight from `~/Wiqo Projeleri` (the folders `MacProjectSync` keeps in
/// step with the iPhone): pick a project, see the page, read the files, open the folder or an editor.
/// Read-only on purpose - editing happens in the person's editor or on the phone, and sync does the rest.
@MainActor
final class MacProjectsModel: ObservableObject {
    struct Project: Identifiable, Equatable {
        let folder: URL
        let name: String
        let kind: String
        let version: Int
        let files: [String: String]
        var id: String { folder.path }
        var isWeb: Bool { kind != "python" }
        var sortedPaths: [String] {
            files.keys.sorted { lhs, rhs in
                let l = Self.rank(lhs), r = Self.rank(rhs)
                return l == r ? lhs < rhs : l < r
            }
        }
        private static func rank(_ path: String) -> Int { path == "index.html" || path == "main.py" ? 0 : path == "PROJE.md" ? 2 : 1 }
    }

    @Published private(set) var projects: [Project] = []
    private var loop: Task<Void, Never>?

    nonisolated static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Wiqo Projeleri", isDirectory: true)

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let loaded = await Task.detached(priority: .utility) { Self.load() }.value
                if let self, loaded != self.projects { self.projects = loaded }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    private struct Link: Decodable {
        var version: Int
        var meta: ActProjectMeta
    }

    nonisolated private static func load() -> [Project] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var result: [Project] = []
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(MacProjectSync.metaName)),
                  let link = try? JSONDecoder().decode(Link.self, from: data) else { continue }
            result.append(Project(folder: dir, name: link.meta.name, kind: link.meta.kind, version: link.version, files: scan(dir)))
        }
        return result
    }

    nonisolated private static func scan(_ dir: URL) -> [String: String] {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }
        var files: [String: String] = [:]
        for case let url as URL in walker {
            guard files.count < ActSync.maxFiles,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = String(url.path.dropFirst(dir.path.count + 1))
            if ActSync.isSyncable(path: relative, content: content) { files[relative] = content }
        }
        return files
    }
}

struct MacProjectsView: View {
    @StateObject private var model = MacProjectsModel()
    @State private var selection: String?
    @State private var tab: Tab = .preview
    @State private var file: String?

    private enum Tab: Hashable { case preview, code }

    private var project: MacProjectsModel.Project? {
        model.projects.first { $0.id == selection } ?? model.projects.first
    }

    var body: some View {
        NavigationSplitView {
            List(model.projects, selection: $selection) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.isWeb ? "safari" : "terminal")
                        .frame(width: 24)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1)
                        Text("v\(item.version) · \(item.files.count) dosya").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(item.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .overlay {
                if model.projects.isEmpty {
                    Text("Henüz proje yok.\nTelefonda Act'ten bir proje yap, burada görünür.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
        } detail: {
            if let project {
                detail(project)
            } else {
                Text("Bir proje seç").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder private func detail(_ project: MacProjectsModel.Project) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(project.name).font(.headline)
                Text("v\(project.version)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $tab) {
                    Text(project.isWeb ? "Önizleme" : "Çıktı").tag(Tab.preview)
                    Text("Kod").tag(Tab.code)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Button { NSWorkspace.shared.open(project.folder) } label: { Label("Klasör", systemImage: "folder") }
                Button { Self.openInEditor(project.folder) } label: { Label("Editörde aç", systemImage: "chevron.left.forwardslash.chevron.right") }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            switch tab {
            case .preview: preview(project)
            case .code: code(project)
            }
        }
    }

    @ViewBuilder private func preview(_ project: MacProjectsModel.Project) -> some View {
        if project.isWeb {
            let files = project.files.map { ActBundler.File(path: $0.key, content: $0.value) }
            if let page = ActBundler.bundleWeb(files).map(ActBundler.ensureViewport).map({ ActLook.inject($0, files: project.files) }) {
                MacPageView(html: page)
            } else {
                placeholder("Bu projede önizlenecek bir sayfa (index.html) yok.")
            }
        } else {
            placeholder("Python projeleri telefondan \"Bu Mac'te çalıştır\" ile çalışır (Ayarlar > Projeler'den izin ver). Kodu yan sekmede.")
        }
    }

    private func code(_ project: MacProjectsModel.Project) -> some View {
        let paths = project.sortedPaths
        let current = paths.contains(file ?? "") ? file : paths.first
        return HStack(spacing: 0) {
            List(paths, id: \.self, selection: Binding(get: { current }, set: { file = $0 })) { path in
                Label(path, systemImage: Self.icon(path)).font(.system(.callout, design: .monospaced)).lineLimit(1)
            }
            .frame(width: 210)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(Self.numbered(project.files[current ?? ""] ?? ""))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack { Spacer(); Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(30); Spacer() }
            .frame(maxWidth: .infinity)
    }

    /// Line numbers in a dimmed column, the code after them.
    private static func numbered(_ code: String) -> AttributedString {
        let lines = code.components(separatedBy: "\n")
        let width = String(lines.count).count
        var out = AttributedString()
        for (index, line) in lines.enumerated() {
            var number = AttributedString(String(index + 1).leftPad(width) + "  ")
            number.foregroundColor = .secondary
            out += number
            out += AttributedString(line + (index == lines.count - 1 ? "" : "\n"))
        }
        return out
    }

    private static func icon(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "chevron.left.forwardslash.chevron.right"
        case "css": return "paintbrush"
        case "js", "json": return "curlybraces"
        case "py": return "terminal"
        case "md": return "doc.text"
        default: return "doc"
        }
    }

    private static func openInEditor(_ folder: URL) {
        let bundles = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode", "com.sublimetext.4", "com.apple.TextEdit"]
        for id in bundles {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        NSWorkspace.shared.open(folder)
    }
}

private extension String {
    func leftPad(_ width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
}

/// The bundled page, rendered in a web view; reloaded only when the page itself changes.
private struct MacPageView: NSViewRepresentable {
    let html: String

    final class Coordinator { var loaded = "" }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: nil)
    }
}
