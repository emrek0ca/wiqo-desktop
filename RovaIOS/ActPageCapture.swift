import SwiftUI
import UIKit
import WebKit

enum ActExportKind: String, CaseIterable, Identifiable {
    case zip, html, pdf, png

    var id: String { rawValue }
    var title: String {
        switch self {
        case .zip: return "Kaynak ZIP"
        case .html: return "Tek HTML dosyası"
        case .pdf: return "PDF"
        case .png: return "Ekran görüntüsü"
        }
    }
    var systemImage: String {
        switch self {
        case .zip: return "doc.zipper"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .pdf: return "doc.richtext"
        case .png: return "photo"
        }
    }
    var busyText: String {
        switch self {
        case .zip: return "ZIP hazırlanıyor…"
        case .html: return "Tek HTML hazırlanıyor…"
        case .pdf: return "PDF hazırlanıyor…"
        case .png: return "Ekran görüntüsü hazırlanıyor…"
        }
    }
    /// Only web projects have a page to print or photograph.
    var needsPage: Bool { self != .zip }
}

/// Takes a PDF or a picture of a project's page, locally, with the same WebKit that shows the preview: the page is
/// loaded (offline, packages already in it), given a moment to draw (charts animate), measured, and captured whole.
@MainActor
enum ActPageCapture {
    enum Output { case pdf, png }

    struct CaptureError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// The longest page captured, in points (taller pages are cut here).
    private static let maxHeight: CGFloat = 8000

    private final class Loader: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Error>?
        func finish(_ error: Error? = nil) {
            guard let continuation else { return }
            self.continuation = nil
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(NSError(domain: "ActPageCapture", code: 2)) }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }

    /// Ignores the page's saves: a capture only looks, it must not change the project's data.
    private final class QuietStore: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
    }

    static func capture(html: String, projectKey: String, width: Int, output: Output) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WiqoProjectDataBridge.script(for: projectKey))
        configuration.userContentController.add(QuietStore(), name: WiqoProjectDataBridge.messageName)
        let startHeight: CGFloat = width < 600 ? 844 : 800
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: CGFloat(width), height: startHeight), configuration: configuration)
        // The picture is of the page itself: no safe-area inset from the (hidden) window pushing it down.
        view.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            // The soft blur iOS draws under a scroll view's edges is not part of the page.
            view.scrollView.topEdgeEffect.isHidden = true
            view.scrollView.bottomEdgeEffect.isHidden = true
            view.scrollView.leftEdgeEffect.isHidden = true
            view.scrollView.rightEdgeEffect.isHidden = true
        }
        let loader = Loader()
        view.navigationDelegate = loader
        // WebKit paints for a snapshot only inside a window; this one sits behind the app and is never seen.
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window = UIWindow(windowScene: scene) } else { window = UIWindow() }
        window.frame = view.frame
        window.windowLevel = UIWindow.Level(rawValue: -1)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true; view.removeFromSuperview(); view.stopLoading() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loader.continuation = continuation
            view.loadHTMLString(html, baseURL: nil)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                loader.finish(CaptureError("Sayfa zamanında açılamadı."))
            }
        }
        // Scripts run and charts draw before the picture is taken.
        try? await Task.sleep(for: .milliseconds(1400))
        let measured = try? await view.evaluateJavaScript("Math.ceil(Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0))")
        let height = min(maxHeight, max(startHeight, CGFloat((measured as? NSNumber)?.doubleValue ?? Double(startHeight))))
        window.frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: height)
        view.frame = window.bounds
        try? await Task.sleep(for: .milliseconds(450))

        switch output {
        case .png:
            let snapshot = WKSnapshotConfiguration()
            snapshot.rect = view.bounds
            snapshot.snapshotWidth = NSNumber(value: min(width, 1600))
            let image = try await view.takeSnapshot(configuration: snapshot)
            guard let data = image.pngData() else { throw CaptureError("Ekran görüntüsü oluşturulamadı.") }
            return data
        case .pdf:
            let pdf = WKPDFConfiguration()
            pdf.rect = view.bounds
            let data = try await view.pdf(configuration: pdf)
            guard data.count > 100 else { throw CaptureError("PDF oluşturulamadı.") }
            return data
        }
    }
}

/// Exports one project as a file and hands it to the share sheet; one export at a time.
@MainActor
final class ActExporter: ObservableObject {
    struct SharedFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    @Published private(set) var busy: String?
    @Published var shared: SharedFile?
    @Published var error: String?

    func run(_ kind: ActExportKind, projectID: String, width: Int = 390) {
        guard busy == nil else { return }
        busy = kind.busyText
        error = nil
        Task {
            defer { busy = nil }
            do { shared = SharedFile(url: try await ActModel.shared.export(kind, id: projectID, width: width)) }
            catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Dışa aktarılamadı." }
        }
    }
}

/// The system share sheet for a file (AirDrop, Messages, Files, ...).
struct ActShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
