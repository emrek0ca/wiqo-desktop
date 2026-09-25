import PDFKit
import SwiftUI
import WebKit

/// Whether an artifact can render directly in the conversation - a picture, a generated chart, or
/// a document's first page - instead of only ever showing as a tap-to-open file row. Anything
/// else (Word/Excel/CSV/etc.) keeps the file-card treatment; there's no useful "inline" form of a
/// spreadsheet, and forcing one would just be complexity for its own sake.
enum ArtifactInlineKind {
    case image
    case vectorChart
    case pdf
    /// A self-contained page Wiqo built (project website or slide deck), previewed as a live app.
    case html
    case none

    init(mimeType: String) {
        if mimeType.hasPrefix("text/html") {
            self = .html
        } else if mimeType == "image/svg+xml" {
            self = .vectorChart
        } else if mimeType.hasPrefix("image/") {
            self = .image
        } else if mimeType == "application/pdf" {
            self = .pdf
        } else {
            self = .none
        }
    }
}

/// A picture, chart, or PDF shown right in the chat - downloaded once the bubble appears rather
/// than waiting for a tap, matching how ChatGPT/Gemini surface generated media. Tapping it still
/// opens the full Quick Look viewer via `onOpenFullscreen`, so nothing is lost versus the plain
/// file card this replaces for these three MIME types.
struct InlineArtifactPreview: View {
    let artifact: RovaBackendClient.ArtifactDescriptor
    let onOpenFullscreen: () -> Void

    @State private var localURL: URL?
    @State private var failed = false
    // PDF gets its own in-app, all-pages viewer instead of routing through the shared Quick Look
    // sheet (onOpenFullscreen) - Quick Look works fine, but this reads far more like a first-class
    // part of the app rather than a hand-off to iOS chrome, and it's the one artifact type common
    // enough (create_document's docx/pdf output) to be worth the dedicated viewer.
    @State private var showingFullScreenPDF = false
    @State private var showingCanvas = false

    var body: some View {
        Group {
            if let localURL {
                content(for: localURL)
            } else if failed {
                // A download failure degrades to the ordinary file row instead of an error state -
                // the file is still perfectly openable, it just won't preview inline.
                ArtifactFileRow(artifact: artifact, isBusy: false, action: onOpenFullscreen)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 160)
                    .overlay(ProgressView())
            }
        }
        .task(id: artifact.id) {
            do {
                localURL = try await RovaBackendClient.downloadArtifact(artifact)
            } catch {
                failed = true
            }
        }
    }

    @ViewBuilder
    private func content(for url: URL) -> some View {
        switch ArtifactInlineKind(mimeType: artifact.mimeType) {
        case .image:
            if let uiImage = UIImage(contentsOfFile: url.path) {
                Button(action: onOpenFullscreen) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            } else {
                ArtifactFileRow(artifact: artifact, isBusy: false, action: onOpenFullscreen)
            }
        case .vectorChart:
            if let data = try? Data(contentsOf: url) {
                // No outer "open fullscreen" button here on purpose: the chart itself is tappable
                // (see createChartSvg's onclick handlers - tapping a bar/point/slice reveals its
                // exact value), so a wrapping button would just compete with the SVG's own taps.
                SVGView(data: data)
                    .aspectRatio(12.0 / 7.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
            } else {
                ArtifactFileRow(artifact: artifact, isBusy: false, action: onOpenFullscreen)
            }
        case .pdf:
            if let document = PDFDocument(url: url), let page = document.page(at: 0) {
                Button {
                    showingFullScreenPDF = true
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        PDFPagePreview(page: page)
                            .frame(maxWidth: .infinity)
                            .frame(height: 220)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
                        if document.pageCount > 1 {
                            Text("\(document.pageCount) sayfa")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(10)
                        }
                    }
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showingFullScreenPDF) {
                    PDFFullScreenView(url: url, filename: artifact.filename)
                }
            } else {
                ArtifactFileRow(artifact: artifact, isBusy: false, action: onOpenFullscreen)
            }
        case .html:
            if let data = try? Data(contentsOf: url), let html = String(data: data, encoding: .utf8), html.contains("<") {
                VStack(alignment: .leading, spacing: 8) {
                    WiqoAppPreviewCard(html: html) { showingCanvas = true }
                    ArtifactFileRow(artifact: artifact, isBusy: false, action: onOpenFullscreen)
                }
                .sheet(isPresented: $showingCanvas) {
                    CanvasView(language: "html", code: html, autoRun: true)
                }
            } else {
                ArtifactFileRow(artifact: artifact, isBusy: false, action: onOpenFullscreen)
            }
        case .none:
            ArtifactFileRow(artifact: artifact, isBusy: false, action: onOpenFullscreen)
        }
    }
}

/// The original tap-to-open row, factored out so both the non-previewable file types and any
/// inline preview's own failure/loading fallback share one look.
struct ArtifactFileRow: View {
    let artifact: RovaBackendClient.ArtifactDescriptor
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.filename)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(typeLabel) • \(ByteCountFormatter.string(fromByteCount: Int64(artifact.byteCount), countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Aç").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel("\(artifact.filename) dosyasını aç")
    }

    private var icon: String {
        let name = artifact.filename.lowercased()
        if artifact.mimeType.hasPrefix("image/") { return "photo.fill" }
        if name.hasSuffix(".pdf") { return "doc.richtext.fill" }
        if name.hasSuffix(".zip") { return "doc.zipper" }
        if name.hasSuffix(".pptx") || name.hasSuffix(".key") { return "rectangle.on.rectangle.angled" }
        if name.hasSuffix(".html") { return "globe" }
        if name.hasSuffix(".xlsx") || name.hasSuffix(".xls") || name.hasSuffix(".csv") { return "tablecells.fill" }
        if name.hasSuffix(".docx") || name.hasSuffix(".doc") { return "doc.text.fill" }
        return "doc.fill"
    }

    private var tint: Color {
        let name = artifact.filename.lowercased()
        if name.hasSuffix(".pdf") { return .red }
        if name.hasSuffix(".pptx") { return .orange }
        if name.hasSuffix(".html") || name.hasSuffix(".zip") { return .indigo }
        if name.hasSuffix(".xlsx") || name.hasSuffix(".xls") || name.hasSuffix(".csv") { return .green }
        if name.hasSuffix(".docx") || name.hasSuffix(".doc") { return .blue }
        if artifact.mimeType.hasPrefix("image/") { return .purple }
        return .gray
    }

    private var typeLabel: String {
        let ext = (artifact.filename as NSString).pathExtension.uppercased()
        return ext.isEmpty ? artifact.kind.capitalized : ext
    }
}

/// Renders raw SVG data (Wiqo's own chart artifacts, and only those - never third-party/remote
/// content) with no chrome; WKWebView is the only SVG renderer available on iOS without pulling in
/// a dedicated vector-graphics library for one file type. Touch interaction is deliberately left
/// on (unlike a plain static image) so createChartSvg's own tap-to-reveal-value handlers work -
/// scrolling/bouncing/zooming stay off so it still behaves like part of the chat layout, not a
/// pannable web page.
private struct SVGView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.load(data, mimeType: "image/svg+xml", characterEncodingName: "utf-8", baseURL: URL(fileURLWithPath: "/"))
    }
}

/// A static, non-interactive render of one PDF page - just enough to show what the document is at
/// a glance; tapping it opens PDFFullScreenView for every page, interactively.
private struct PDFPagePreview: UIViewRepresentable {
    let page: PDFPage

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        let document = PDFDocument()
        document.insert(page, at: 0)
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}

/// A real, in-app, all-pages PDF viewer: continuous vertical scroll, pinch-to-zoom, and a share
/// sheet - everything Quick Look would offer, but presented as part of Wiqo rather than a hand-off
/// to system chrome.
struct PDFFullScreenView: View {
    let url: URL
    let filename: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PDFKitFullView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .background(Color(.systemGroupedBackground))
                .navigationTitle(filename)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Kapat") { dismiss() }
                    }
                }
        }
    }
}

private struct PDFKitFullView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)
        view.document = PDFDocument(url: url)
        view.backgroundColor = .systemGroupedBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}
