import SwiftUI
import WebKit

/// Two very different run modes behind one sheet, chosen by `language`:
///
/// - "html": nothing is sent to the server at all. The code IS a webpage, so it's rendered
///   directly in an on-device WKWebView the instant the sheet opens - instant, and it's the only
///   mode that can show a real interface (buttons, layout, interaction), not just text output.
///   This is how a GUI request ("hesap makinesi", a small website, a game) is actually shown to
///   the user; Python/JS in this app have no window system to render into, so the system prompt
///   steers Wiqo to write GUI requests as self-contained HTML precisely so this path can run them.
/// - anything else (python/javascript/shell): runs on Wiqo's server (the same stateless sandbox
///   run_python uses - see RovaBackendClient.runCanvasCode / backend routes/canvas.ts) and shows
///   stdout, stderr, and any produced files/charts inline.
///
/// Either way this is opened from a code block's "Çalıştır" button (CodeBlockView in
/// ReplyBlocks.swift), pre-filled with that exact code - but the code stays editable and
/// re-runnable here too, so this doubles as a general scratch canvas, not just a one-shot result
/// viewer. Deliberately small and self-contained: no shared state with the chat transcript, so
/// closing it leaves nothing behind to clean up.
struct CanvasView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var language: String
    @State private var code: String
    @State private var isRunning = false
    @State private var result: RovaBackendClient.CanvasRunResult?
    @State private var errorMessage: String?
    @State private var previewURL: URL?
    /// True when opened from a code block's "Çalıştır" button (see CodeBlockView) instead of the
    /// composer - runs once automatically on appear so tapping "Çalıştır" really does go straight
    /// to a result, matching "kodu çalıştırınca direkt pencere açılır" rather than requiring a
    /// second tap inside the sheet that just opened.
    private let autoRun: Bool

    /// HTML has no "run" step (it's rendered, not executed) and shows a live interface instead of
    /// text output, so it gets its own toolbar/layout entirely - see htmlPreviewBody.
    private var isHTMLPreview: Bool { language == "html" }

    private enum DeviceMode: String, CaseIterable {
        case mobile = "Mobil"
        case desktop = "Masaüstü"
    }
    @State private var deviceMode: DeviceMode = .mobile
    /// Defaults to false so opening from "Çalıştır" goes straight to the rendered interface, not
    /// its source - "çalıştırınca açılan pencerede kod ayrımı olmamalı, arayüzü göstermeli".
    @State private var showingSource = false

    private let languages = [("python", "Python"), ("javascript", "JavaScript"), ("shell", "Shell")]

    init(language: String = "python", code: String = "", autoRun: Bool = false) {
        _language = State(initialValue: language)
        _code = State(initialValue: code)
        self.autoRun = autoRun
    }

    var body: some View {
        if isHTMLPreview {
            htmlPreviewBody
        } else {
            codeRunnerBody
        }
    }

    private var htmlPreviewBody: some View {
        NavigationStack {
            Group {
                if showingSource {
                    sourceEditor
                } else {
                    HTMLPreviewWebView(html: htmlDocument)
                }
            }
            .background(RovaDesign.canvas)
            .navigationTitle("Canvas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Kapat") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Picker("Görünüm", selection: $deviceMode) {
                        ForEach(DeviceMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSource.toggle()
                    } label: {
                        Image(systemName: showingSource ? "eye" : "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityLabel(showingSource ? "Önizlemeyi göster" : "Kodu göster")
                }
            }
        }
    }

    private var sourceEditor: some View {
        TextEditor(text: $code)
            .font(.system(.footnote, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
    }

    /// The raw HTML Wiqo wrote, wrapped so the device-mode toggle actually changes the rendered
    /// layout: a fixed virtual viewport width (390 for "Mobil", 1280 for "Masaüstü") that WKWebView
    /// auto-scales to fit its own on-screen size - the exact mechanism a browser's own "request
    /// desktop site" uses, so a page's real CSS media queries/flex/grid reflow instead of Wiqo's
    /// code having to know about device modes at all. Any viewport meta tag Wiqo already wrote is
    /// stripped first so this one always wins and the toggle stays reliable.
    private var htmlDocument: String {
        let width = deviceMode == .mobile ? "390" : "1280"
        let viewportTag = "<meta name=\"viewport\" content=\"width=\(width)\">"
        let stripped = code.replacingOccurrences(
            of: #"<meta[^>]*name=["']viewport["'][^>]*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        if let headTagRange = stripped.range(of: "<head", options: .caseInsensitive),
           let headCloseRange = stripped.range(of: ">", range: headTagRange.upperBound..<stripped.endIndex) {
            var result = stripped
            result.insert(contentsOf: viewportTag, at: headCloseRange.upperBound)
            return result
        }
        if let htmlTagRange = stripped.range(of: "<html", options: .caseInsensitive),
           let htmlCloseRange = stripped.range(of: ">", range: htmlTagRange.upperBound..<stripped.endIndex) {
            var result = stripped
            result.insert(contentsOf: "<head><meta charset=\"utf-8\">\(viewportTag)</head>", at: htmlCloseRange.upperBound)
            return result
        }
        // Wiqo wrote a bare fragment (no <html>/<head> boilerplate) - wrap it fully.
        return "<!doctype html><html><head><meta charset=\"utf-8\">\(viewportTag)</head><body>\(stripped)</body></html>"
    }

    private var codeRunnerBody: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Dil", selection: $language) {
                        ForEach(languages, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)

                    codeEditor

                    Button {
                        Task { await run() }
                    } label: {
                        HStack {
                            if isRunning {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text(isRunning ? "Çalışıyor..." : "Çalıştır")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RovaDesign.ink)
                    .disabled(isRunning || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if let result {
                        resultView(result)
                    }
                }
                .padding(RovaDesign.screenPadding)
            }
            .background(RovaDesign.canvas)
            .navigationTitle("Canvas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") { dismiss() }
                }
            }
            .quickLookPreview($previewURL)
        }
        .task {
            guard autoRun, result == nil, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await run()
        }
    }

    private var codeEditor: some View {
        TextEditor(text: $code)
            .font(.system(.footnote, design: .monospaced))
            .frame(minHeight: 200)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(RovaDesign.cardSurface, in: RoundedRectangle(cornerRadius: RovaDesign.cardRadius, style: .continuous))
            .overlay(alignment: .topLeading) {
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

    private var placeholder: String {
        switch language {
        case "python": return "# Python kodunu buraya yaz\nprint(\"merhaba\")"
        case "javascript": return "// JavaScript kodunu buraya yaz\nconsole.log(\"merhaba\")"
        default: return "# Shell komutlarını buraya yaz\necho merhaba"
        }
    }

    @ViewBuilder
    private func resultView(_ result: RovaBackendClient.CanvasRunResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                statusBadge(result)
                Text("\(result.durationMs) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !result.stdout.isEmpty {
                outputBlock(title: "Çıktı", text: result.stdout)
            }
            if !result.stderr.isEmpty {
                outputBlock(title: "Hata çıktısı", text: result.stderr, isError: true)
            }
            if result.truncated {
                Text("Çıktı çok uzun olduğu için kısaltıldı.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(result.artifacts) { artifact in
                if case .none = ArtifactInlineKind(mimeType: artifact.mimeType) {
                    ArtifactFileRow(artifact: artifact, isBusy: false) {
                        Task { previewURL = try? await RovaBackendClient.downloadArtifact(artifact) }
                    }
                } else {
                    InlineArtifactPreview(artifact: artifact) {
                        Task { previewURL = try? await RovaBackendClient.downloadArtifact(artifact) }
                    }
                }
            }
        }
    }

    private func statusBadge(_ result: RovaBackendClient.CanvasRunResult) -> some View {
        let (label, color): (String, Color) = {
            if result.timedOut { return ("Zaman aşımı", .orange) }
            if result.exitCode != 0 { return ("Hata (kod \(result.exitCode))", .red) }
            return ("Başarılı", RovaDesign.signal)
        }()
        return Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func outputBlock(title: String, text: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(isError ? AttributedString(text) : SyntaxHighlighter.highlight(text))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isError ? .red : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RovaDesign.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func run() async {
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            result = try await RovaBackendClient.runCanvasCode(language: language, code: code)
        } catch RovaBackendError.declined(let message) {
            errorMessage = message
        } catch RovaBackendError.network(let message) {
            errorMessage = message
        } catch {
            errorMessage = "Kod çalıştırılamadı."
        }
    }
}

/// Renders a full HTML document entirely on-device - no server round trip, no sandbox, nothing but
/// WebKit loading a string, the same trust boundary as opening any webpage. Reloads only when the
/// document text actually changed, so toggling other canvas UI (like the source editor) doesn't
/// reset any JS state (a running calculator's current total, a game's score) already on the page.
private struct HTMLPreviewWebView: UIViewRepresentable {
    let html: String

    final class Coordinator {
        var lastLoaded: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        WKWebView(frame: .zero)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastLoaded != html else { return }
        context.coordinator.lastLoaded = html
        webView.loadHTMLString(html, baseURL: nil)
    }
}
