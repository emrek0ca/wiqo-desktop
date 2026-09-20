import SwiftUI
import UIKit
import WebKit

/// A focused workspace for code that Wiqo has written or the user wants to try.
///
/// The canvas deliberately has three surfaces instead of mixing source, output and device
/// previews together:
///   - Kod: the editable source and the optional Python dependency list
///   - Uygulama: a phone-sized HTML viewport
///   - PC: the same result in a wide desktop viewport
///
/// Python/JavaScript/shell still run in the existing isolated backend sandbox. A Python program
/// can produce an HTML artifact (for example `app.html`) and that artifact becomes the application
/// preview. Native desktop GUI libraries cannot be rendered inside an iPhone WebView, so the UI
/// stays honest about that boundary instead of showing a fake PC state.
struct CanvasView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var language: String
    @State private var code: String
    @State private var packagesText = ""
    @State private var workspace: WorkspaceTab
    @State private var isRunning = false
    @State private var activeTaskID: Int?
    @State private var runMessage: String?
    @State private var result: RovaBackendClient.CanvasRunResult?
    @State private var errorMessage: String?
    @State private var artifactErrorMessage: String?
    @State private var previewHTML: String?
    @State private var previewURL: URL?
    @State private var copied = false

    private let autoRun: Bool

    private enum WorkspaceTab: String, CaseIterable {
        case code = "Kod"
        case app = "Uygulama"
        case pc = "PC"
    }

    private enum PreviewMode {
        case phone
        case desktop

        var viewportWidth: Int {
            switch self {
            case .phone: return 390
            case .desktop: return 1280
            }
        }
    }

    private let languages = [
        ("python", "Python"),
        ("javascript", "JavaScript"),
        ("shell", "Shell"),
        ("html", "HTML")
    ]

    init(language: String = "python", code: String = "", autoRun: Bool = false) {
        let canonicalLanguage = language.lowercased() == "html" ? "html" : language
        _language = State(initialValue: canonicalLanguage)
        _code = State(initialValue: code)
        _workspace = State(initialValue: canonicalLanguage == "html" ? .app : .code)
        self.autoRun = autoRun
    }

    private var isHTML: Bool { language.lowercased() == "html" }

    private var packageList: [String] {
        packagesText
            .split { $0 == "," || $0 == "\n" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, package in
                if !result.contains(where: { $0.caseInsensitiveCompare(package) == .orderedSame }) {
                    result.append(package)
                }
            }
    }

    private var displayLanguage: String {
        languages.first(where: { $0.0 == language })?.1 ?? language.capitalized
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                workspacePicker
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if workspace == .code {
                            codeWorkspace
                        } else {
                            previewWorkspace
                        }

                        if let runMessage, isRunning {
                            WiqoToolChip(
                                title: runMessage,
                                systemImage: packageList.isEmpty ? "terminal" : "shippingbox",
                                tone: .active
                            )
                        }

                        if let result {
                            resultView(result)
                        }

                        if let artifactErrorMessage {
                            Text(artifactErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let errorMessage {
                            errorView(errorMessage)
                        }
                    }
                    .padding(RovaDesign.screenPadding)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(RovaDesign.canvas)
            .navigationTitle("Canvas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Kapat") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    languageMenu
                }
            }
            .quickLookPreview($previewURL)
        }
        .task {
            guard autoRun, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if isHTML {
                previewHTML = code
                workspace = .app
            } else {
                await run()
            }
        }
        .onChange(of: language) { _, newLanguage in
            if newLanguage == "html" {
                previewHTML = code
                workspace = .app
            } else if workspace != .code {
                workspace = .code
            }
        }
    }

    private var workspacePicker: some View {
        Picker("Canvas görünümü", selection: $workspace) {
            ForEach(WorkspaceTab.allCases, id: \.self) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, RovaDesign.screenPadding)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .onChange(of: workspace) { _, newTab in
            if newTab == .app, isHTML { previewHTML = code }
        }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(languages, id: \.0) { value, label in
                Button {
                    language = value
                } label: {
                    if language == value {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            Label(displayLanguage, systemImage: "chevron.down")
                .font(.caption.weight(.medium))
        }
        .accessibilityLabel("Kod dili")
    }

    private var codeWorkspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            codeEditor

            if language == "python" {
                packageField
            }

            runButton

            if let runMessage, !isRunning {
                WiqoToolChip(
                    title: runMessage,
                    systemImage: result?.exitCode == 0 ? "checkmark.circle" : "info.circle",
                    tone: result?.exitCode == 0 ? .success : .neutral
                )
            }
        }
    }

    private var codeEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: fileIcon)
                    .foregroundStyle(.secondary)
                Text(fileName)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        await MainActor.run { copied = false }
                    }
                } label: {
                    Label(copied ? "Kopyalandı" : "Kopyala", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? .green : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) { Divider() }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $code)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 230)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)

                if code.isEmpty {
                    Text(placeholder)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(RovaDesign.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var packageField: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
                Text("Python kütüphaneleri")
                    .font(.subheadline.weight(.medium))
                Text("İsteğe bağlı")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("numpy, pandas, matplotlib", text: $packagesText, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(1...3)
                .padding(11)
                .background(RovaDesign.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                }
            Text("Güvenli biçimde hazırlanır; kod çalışırken internet erişimi kapalıdır.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var runButton: some View {
        Button {
            if isRunning {
                Task { await cancelRun() }
            } else if isHTML {
                previewHTML = code
                workspace = .app
                runMessage = "Uygulama önizlemesini yeniledim."
            } else {
                Task { await run() }
            }
        } label: {
            HStack(spacing: 8) {
                if isRunning {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                } else {
                    Image(systemName: isHTML ? "eye" : "play.fill")
                }
                Text(isRunning ? "Durdur" : (isHTML ? "Önizlemeyi aç" : "Çalıştır"))
                    .font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(isRunning ? .orange : RovaDesign.ink)
        .disabled(!isRunning && code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var previewWorkspace: some View {
        let previewMode: PreviewMode = workspace == .pc ? .desktop : .phone
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: workspace == .pc ? "desktopcomputer" : "rectangle.on.rectangle")
                    .foregroundStyle(RovaDesign.ink)
                Text(workspace == .pc ? "PC görünümü" : "Uygulama görünümü")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(previewMode.viewportWidth) px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let previewHTML {
                HTMLPreviewWebView(
                    html: htmlDocument(source: previewHTML, viewportWidth: previewMode.viewportWidth),
                    viewportWidth: previewMode.viewportWidth
                )
                .frame(minHeight: workspace == .pc ? 430 : 520)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.09), lineWidth: 1)
                }
            } else {
                emptyPreview
            }

            if workspace == .pc {
                Text("Bu alan, üretilen arayüzün geniş ekran önizlemesidir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyPreview: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.3.group")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Uygulama görünümü için bir HTML çıktısı üret.")
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
            Text("Python kodun app.html veya index.html oluşturduğunda burada açılır.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(20)
        .background(RovaDesign.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func resultView(_ result: RovaBackendClient.CanvasRunResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if result.timedOut {
                WiqoToolChip(title: "Kod beklenenden uzun sürdü; durdurdum.", systemImage: "clock", tone: .attention)
            } else if result.exitCode == 0 {
                WiqoToolChip(title: "Kodu çalıştırdım; çıktıyı hazırladım.", systemImage: "checkmark.circle", tone: .success)
            } else {
                WiqoToolChip(title: "Kod çalışmadı; ayrıntıyı aşağıda bıraktım.", systemImage: "info.circle", tone: .failure)
            }

            if !result.stdout.isEmpty {
                outputBlock(title: "Çıktı", text: result.stdout)
            }
            if !result.stderr.isEmpty {
                outputBlock(title: "Ayrıntı", text: result.stderr, isError: true)
            }
            if result.truncated {
                Text("Çıktının uzun bölümünü kısalttım.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(result.artifacts) { artifact in
                if isHTMLArtifact(artifact) {
                    ArtifactFileRow(artifact: artifact, isBusy: false) {
                        Task { await openArtifact(artifact) }
                    }
                } else if case .none = ArtifactInlineKind(mimeType: artifact.mimeType) {
                    ArtifactFileRow(artifact: artifact, isBusy: false) {
                        Task { await openArtifact(artifact) }
                    }
                } else {
                    InlineArtifactPreview(artifact: artifact) {
                        Task { await openArtifact(artifact) }
                    }
                }
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        DisclosureGroup {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Çalıştırma tamamlanamadı", systemImage: "exclamationmark.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.red)
        }
        .tint(.secondary)
        .padding(12)
        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func outputBlock(title: String, text: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Kopyala", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider() }

            Text(isError ? AttributedString(text) : SyntaxHighlighter.highlight(text))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isError ? .red : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(RovaDesign.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var fileName: String {
        switch language {
        case "python": return "canvas.py"
        case "javascript": return "canvas.js"
        case "shell": return "canvas.sh"
        default: return "app.html"
        }
    }

    private var fileIcon: String {
        switch language {
        case "python": return "chevron.left.forwardslash.chevron.right"
        case "html": return "rectangle.and.text.magnifyingglass"
        default: return "terminal"
        }
    }

    private var placeholder: String {
        switch language {
        case "python": return "# Python kodunu buraya yaz\nprint(\"merhaba\")"
        case "javascript": return "// JavaScript kodunu buraya yaz\nconsole.log(\"merhaba\")"
        case "html": return "<!doctype html>\n<html>\n  <body>\n    <h1>Merhaba</h1>\n  </body>\n</html>"
        default: return "# Shell komutlarını buraya yaz\necho merhaba"
        }
    }

    @MainActor
    private func run() async {
        guard !isRunning else { return }
        let source = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        if packageList.count > 8 {
            errorMessage = "En fazla 8 Python kütüphanesi ekleyebilirsin."
            return
        }

        isRunning = true
        activeTaskID = nil
        result = nil
        previewHTML = nil
        runMessage = packageList.isEmpty ? "Kodu çalıştırıyorum…" : "Kütüphaneleri hazırlıyorum…"
        errorMessage = nil
        artifactErrorMessage = nil
        defer { isRunning = false }

        do {
            let runResult = try await RovaBackendClient.runCanvasCode(
                language: language,
                code: source,
                packages: language == "python" ? packageList : [],
                onTaskID: { taskID in activeTaskID = taskID },
                onProgress: { message in runMessage = naturalProgress(message) }
            )
            result = runResult
            runMessage = naturalResult(for: runResult)
            if let htmlArtifact = runResult.artifacts.first(where: isHTMLArtifact) {
                await loadPreview(htmlArtifact)
                if previewHTML != nil { workspace = .app }
            }
        } catch RovaBackendError.declined(let message) {
            errorMessage = message
            runMessage = "Çalıştırma durdu."
        } catch RovaBackendError.network(let message) {
            errorMessage = message
            runMessage = "Çalıştırma durdu."
        } catch is CancellationError {
            runMessage = "Çalıştırmayı durdurdum."
        } catch {
            errorMessage = "Kod çalıştırılamadı."
            runMessage = "Çalıştırma durdu."
        }
        activeTaskID = nil
    }

    @MainActor
    private func cancelRun() async {
        guard let taskID = activeTaskID else {
            runMessage = "Çalıştırmayı durduruyorum…"
            return
        }
        do {
            try await RovaBackendClient.cancelCanvasRun(taskID: taskID)
            runMessage = "Çalıştırmayı durduruyorum…"
        } catch {
            errorMessage = "Çalıştırma durdurulamadı."
        }
    }

    @MainActor
    private func loadPreview(_ artifact: RovaBackendClient.ArtifactDescriptor) async {
        do {
            let url = try await RovaBackendClient.downloadArtifact(artifact)
            previewHTML = try String(contentsOf: url, encoding: .utf8)
        } catch {
            artifactErrorMessage = "Uygulama önizlemesi açılamadı."
        }
    }

    private func openArtifact(_ artifact: RovaBackendClient.ArtifactDescriptor) async {
        do {
            previewURL = try await RovaBackendClient.downloadArtifact(artifact)
        } catch {
            await MainActor.run { artifactErrorMessage = "Dosya açılamadı." }
        }
    }

    private func isHTMLArtifact(_ artifact: RovaBackendClient.ArtifactDescriptor) -> Bool {
        artifact.mimeType == "text/html" || artifact.filename.lowercased().hasSuffix(".html") || artifact.filename.lowercased().hasSuffix(".htm")
    }

    private func naturalProgress(_ message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("kütüphane") { return "Kütüphaneleri hazırlıyorum…" }
        if lowercased.contains("çıktı") || lowercased.contains("dosya") { return "Çıktıyı düzenliyorum…" }
        return "Kodu çalıştırıyorum…"
    }

    private func naturalResult(for result: RovaBackendClient.CanvasRunResult) -> String {
        if result.timedOut { return "Kod beklenenden uzun sürdü; durdurdum." }
        if result.exitCode == 0 { return "Kodu çalıştırdım; çıktıyı hazırladım." }
        return "Kod çalışmadı; ayrıntıyı aşağıda bıraktım."
    }

    private func htmlDocument(source: String, viewportWidth: Int) -> String {
        let viewport = "<meta name=\"viewport\" content=\"width=\(viewportWidth)\">"
        let security = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; font-src data:; connect-src 'none'\">"
        let motion = reduceMotion ? "<style>*{animation-duration:.01ms!important;transition-duration:.01ms!important;}</style>" : ""
        let stripped = source.replacingOccurrences(
            of: #"<meta[^>]*name=[\"']viewport[\"'][^>]*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        if let head = stripped.range(of: "<head", options: .caseInsensitive),
           let close = stripped.range(of: ">", range: head.upperBound..<stripped.endIndex) {
            var document = stripped
            document.insert(contentsOf: security + viewport + motion, at: close.upperBound)
            return document
        }
        if let html = stripped.range(of: "<html", options: .caseInsensitive),
           let close = stripped.range(of: ">", range: html.upperBound..<stripped.endIndex) {
            var document = stripped
            document.insert(contentsOf: "<head><meta charset=\"utf-8\">\(security)\(viewport)\(motion)</head>", at: close.upperBound)
            return document
        }
        return "<!doctype html><html><head><meta charset=\"utf-8\">\(security)\(viewport)\(motion)</head><body>\(stripped)</body></html>"
    }
}

/// The preview is intentionally non-persistent and network-disabled. It is a presentation surface
/// for generated HTML, not a second browser or an escape hatch from the execution sandbox.
private struct HTMLPreviewWebView: UIViewRepresentable {
    let html: String
    let viewportWidth: Int

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastLoaded: String?

        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastLoaded != html else { return }
        context.coordinator.lastLoaded = html
        webView.loadHTMLString(html, baseURL: nil)
    }
}
