import SwiftUI
import UIKit
import WebKit

/// The two ways a generated interface is shown: as a phone app, or as a wide desktop page.
enum WiqoPreviewDevice: String, CaseIterable, Identifiable {
    case phone
    case desktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .phone: return "Uygulama"
        case .desktop: return "PC"
        }
    }

    var systemImage: String {
        switch self {
        case .phone: return "iphone"
        case .desktop: return "desktopcomputer"
        }
    }

    /// The layout width the page is rendered at before being scaled to fit the frame.
    var viewportWidth: Int {
        switch self {
        case .phone: return 390
        case .desktop: return 1280
        }
    }
}

/// A light device bezel (phone) or browser chrome (desktop) around a preview, so the same result
/// reads as an app on one side and as a page on a PC on the other.
struct WiqoDeviceFrame<Content: View>: View {
    let device: WiqoPreviewDevice
    var address = "app.html"
    @ViewBuilder var content: Content

    var body: some View {
        switch device {
        case .phone:
            content
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(6)
                .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 31, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        case .desktop:
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(WiqoTheme.lineStrong).frame(width: 8, height: 8)
                    }
                    HStack(spacing: 5) {
                        Image(systemName: "lock.fill").font(.system(size: 8))
                        Text(address).font(.system(size: 10.5, design: .monospaced)).lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 18)
                    .frame(maxWidth: .infinity)
                    .background(WiqoTheme.inset, in: Capsule())
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(WiqoTheme.surface)

                Rectangle().fill(WiqoTheme.line).frame(height: 0.5)
                content
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(WiqoTheme.lineStrong, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
        }
    }
}

enum WiqoHTMLDocument {
    /// Wraps generated HTML for on-device preview: fixes the layout width, blocks network access
    /// (a preview is a presentation surface, not a browser) while still allowing scripts and
    /// styles from the two public CDNs generated pages commonly use, and honours reduced motion.
    static func wrap(_ source: String, viewportWidth: Int, reduceMotion: Bool) -> String {
        let viewport = "<meta name=\"viewport\" content=\"width=\(viewportWidth)\">"
        let cdn = "https://cdnjs.cloudflare.com https://cdn.jsdelivr.net"
        let policy = "default-src 'none'; img-src data: blob:; style-src 'unsafe-inline' \(cdn) https://fonts.googleapis.com; script-src 'unsafe-inline' \(cdn); font-src data: \(cdn) https://fonts.gstatic.com; connect-src 'none'"
        let security = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
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

    /// JavaScript that talks to the page (`document`, `window`) can only run in a page. Wrapping it
    /// lets a script written for the browser show up as an interface with no extra step.
    static func wrapBrowserScript(_ script: String) -> String {
        let safe = script.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
        return "<!doctype html><html><head><meta charset=\"utf-8\"></head><body><script>\n\(safe)\n</script></body></html>"
    }

    static func isBrowserScript(_ script: String) -> Bool {
        script.contains("document.") || script.contains("window.") || script.contains("getElementById") || script.contains("querySelector")
    }
}

/// The preview is non-persistent and network-disabled. It presents generated HTML; it is not a
/// second browser and not an escape hatch from the execution sandbox.
/// What a code project's page keeps between visits (window.wiqoStore): one JSON blob per project,
/// on this device only. The page gets it at load time and posts every `set` back.
@MainActor
final class WiqoProjectDataBridge: NSObject, WKScriptMessageHandler {
    static let messageName = "wiqoStore"
    private static let maxBytes = 256 * 1024
    private let key: String

    init(key: String) { self.key = key }

    private static func defaultsKey(_ key: String) -> String { "wiqo.projectdata.\(key)" }

    static func load(_ key: String) -> [String: Any] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(key)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func script(for key: String) -> WKUserScript {
        let data = (try? JSONSerialization.data(withJSONObject: load(key))) ?? Data("{}".utf8)
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
        return WKUserScript(source: "window.__wiqoData = \(json);", injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let name = body["key"] as? String, name.count <= 120 else { return }
        var stored = Self.load(key)
        stored[name] = body["value"] ?? NSNull()
        guard JSONSerialization.isValidJSONObject(stored),
              let data = try? JSONSerialization.data(withJSONObject: stored), data.count <= Self.maxBytes else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey(key))
    }
}

struct WiqoHTMLWebView: UIViewRepresentable {
    let html: String
    var isInteractive = true
    /// A code project's id: the page then keeps its data (window.wiqoStore) on this device.
    var projectDataKey: String? = nil
    /// Changing this reloads the same HTML from scratch (the "yenile" action).
    var reloadToken = 0

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastLoaded: String?
        var lastToken = 0

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
        if let projectDataKey {
            configuration.userContentController.addUserScript(WiqoProjectDataBridge.script(for: projectDataKey))
            configuration.userContentController.add(WiqoProjectDataBridge(key: projectDataKey), name: WiqoProjectDataBridge.messageName)
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.isUserInteractionEnabled = isInteractive
        guard context.coordinator.lastLoaded != html || context.coordinator.lastToken != reloadToken else { return }
        context.coordinator.lastLoaded = html
        context.coordinator.lastToken = reloadToken
        webView.loadHTMLString(html, baseURL: nil)
    }
}

/// Runs an Act candidate in an isolated phone-sized WebKit page before the backend publishes it.
/// No project store bridge or persistent website data is attached to this page.
/// What the phone found when it tried a candidate page. `unavailable` is not a verdict on the page:
/// WebKit itself did not answer (timeout, process gone), so the change is saved unverified.
enum ActVerification {
    case passed
    case problems([String])
    case unavailable
}

@MainActor
final class ActWebVerifier: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?

    private func finish(_ error: Error? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(NSError(domain: "ActWebVerifier", code: 2))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme
        decisionHandler(navigationAction.navigationType == .other && (scheme == nil || scheme == "about") ? .allow : .cancel)
    }

    func verify(_ html: String) async -> ActVerification {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let script = """
        window.__actErrors=[];
        window.addEventListener('error',e=>window.__actErrors.push(String(e.message||'JavaScript hatası').slice(0,160)));
        window.addEventListener('unhandledrejection',e=>window.__actErrors.push(String(e.reason||'İşlem hatası').slice(0,160)));
        window.wiqoStore={get:(_,fallback)=>fallback,set:()=>{}};
        """
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        page.navigationDelegate = self
        webView = page
        defer { page.stopLoading(); webView = nil; continuation = nil }
        let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; form-action 'none'; frame-src 'none'"
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
        let safeHTML: String
        if let head = html.range(of: "<head(?:\\s[^>]*)?>", options: [.regularExpression, .caseInsensitive]) {
            var document = html
            document.insert(contentsOf: meta, at: head.upperBound)
            safeHTML = document
        } else {
            safeHTML = "<head>\(meta)</head>\(html)"
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                page.loadHTMLString(safeHTML, baseURL: nil)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(15))
                    self.finish(NSError(domain: "ActWebVerifier", code: 1))
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            let check = """
            (()=>{const d=document.documentElement,b=document.body;
            const width=Math.max(d?.scrollWidth||0,b?.scrollWidth||0);
            const text=(b?.innerText||'').trim();
            return {width:width,textLength:text.length,errors:(window.__actErrors||[]).slice(0,5)};})()
            """
            guard let result = try await page.evaluateJavaScript(check) as? [String: Any] else {
                return .unavailable
            }
            var problems = (result["errors"] as? [String] ?? []).prefix(5).map { String($0.prefix(160)) }
            if (result["textLength"] as? Int ?? 0) == 0 { problems.append("Sayfa boş görünüyor.") }
            if (result["width"] as? Int ?? 0) > 410 { problems.append("Sayfa telefon ekranından yatay taşıyor.") }
            return problems.isEmpty ? .passed : .problems(Array(problems.prefix(5)))
        } catch {
            return .unavailable
        }
    }
}

/// A finished HTML answer shown as the running app right inside the conversation. Tapping it opens
/// the same page in the canvas at full size.
struct WiqoAppPreviewCard: View {
    let html: String
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WiqoTheme.ink)
                Text("Uygulama önizlemesi")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
            }

            WiqoDeviceFrame(device: .phone) {
                WiqoHTMLWebView(
                    html: WiqoHTMLDocument.wrap(html, viewportWidth: WiqoPreviewDevice.phone.viewportWidth, reduceMotion: reduceMotion),
                    isInteractive: false
                )
                .frame(height: 380)
                .background(Color.white)
            }
            .frame(maxWidth: 240)
            .frame(maxWidth: .infinity)

            Button(action: onOpen) {
                Label("Canvas'ta aç", systemImage: "arrow.up.left.and.arrow.down.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.wiqoPill(.secondary))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiqoCard()
        .transition(reduceMotion ? .identity : .wiqoFadeUp)
    }
}
