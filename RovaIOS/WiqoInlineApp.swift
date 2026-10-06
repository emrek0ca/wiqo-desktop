import SwiftUI
import WebKit

/// The one thing an inline app may tell the app: how tall it is. Anything else it posts is ignored.
final class InlineAppBridge: NSObject, WKScriptMessageHandler {
    var onHeight: ((CGFloat) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let value = message.body as? NSNumber else { return }
        let height = CGFloat(truncating: value)
        guard height.isFinite, height > 0, height < 20_000 else { return }
        onHeight?(height)
    }
}

/// Runs one inline app in an isolated web view. Three walls, each enough on its own for the common attacks:
/// 1. the page's Content-Security-Policy (no network, no frames, no forms, no other origins),
/// 2. the web view itself (own web-content process, non-persistent storage, every navigation, popup and dialog refused),
/// 3. a start-up script that removes the network, storage and window APIs and the bridge to the app.
/// The app gets no cookies, tokens or storage of Wiqo, and no message channel except its own height.
struct WiqoInlineAppWebView: UIViewRepresentable {
    let html: String
    var reloadToken = 0
    var scrolls = false
    var onHeight: (CGFloat) -> Void = { _ in }
    var onStopped: () -> Void = {}

    static let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"

    /// Reports the height, then removes the app's own way of talking to the native side and the APIs that reach outside.
    private static let hardening = """
    (function(){
      var post=null;
      try{var h=window.webkit.messageHandlers.wiqoApp;post=function(v){h.postMessage(v)}}catch(e){}
      var lock=function(o,k,v){try{Object.defineProperty(o,k,{value:v,writable:false,configurable:false})}catch(e){}};
      var report=function(){if(post&&document.body){var b=document.body,s=getComputedStyle(b);post(Math.ceil(b.getBoundingClientRect().bottom+window.scrollY+(parseFloat(s.marginBottom)||0)))}};
      lock(window,'open',function(){return null});
      ['fetch','XMLHttpRequest','WebSocket','EventSource','Worker','SharedWorker','RTCPeerConnection','indexedDB','localStorage','sessionStorage','caches'].forEach(function(k){
        try{Object.defineProperty(window,k,{get:function(){throw new Error('Bu uygulamada kullanılamaz')},configurable:false})}catch(e){}});
      try{lock(navigator,'sendBeacon',undefined)}catch(e){}
      document.addEventListener('DOMContentLoaded',function(){
        report();
        try{new ResizeObserver(report).observe(document.documentElement)}catch(e){setInterval(report,500)}
        setTimeout(function(){try{lock(window,'webkit',undefined)}catch(e){}},0);
      });
      window.addEventListener('load',report);
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var lastLoaded: String?
        var lastToken = 0
        var started = false
        let bridge = InlineAppBridge()
        var onStopped: () -> Void = {}

        // The first load is the only navigation there ever is: links, forms, scripts and redirects are all refused.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let first = !started && navigationAction.navigationType == .other
            started = true
            decisionHandler(first ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onStopped() }

        // Popups and JavaScript dialogs do not exist for an inline app.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) { completionHandler() }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) { completionHandler(false) }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) { completionHandler(nil) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.allowsInlineMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.dataDetectorTypes = []
        configuration.userContentController.addUserScript(WKUserScript(source: Self.hardening, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator.bridge, name: "wiqoApp")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.allowsLinkPreview = false
        view.allowsBackForwardNavigationGestures = false
        view.scrollView.bounces = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.bridge.onHeight = onHeight
        context.coordinator.onStopped = onStopped
        view.scrollView.isScrollEnabled = scrolls
        guard context.coordinator.lastLoaded != html || context.coordinator.lastToken != reloadToken else { return }
        context.coordinator.lastLoaded = html
        context.coordinator.lastToken = reloadToken
        context.coordinator.started = false
        view.loadHTMLString(Self.sandboxed(html), baseURL: nil)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "wiqoApp")
        view.configuration.userContentController.removeAllUserScripts()
    }

    /// The page with our policy first in its head, whatever the page contained (a page cannot loosen it: policies only add up).
    static func sandboxed(_ html: String) -> String {
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
        if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var document = html
            document.insert(contentsOf: meta, at: head.upperBound)
            return document
        }
        return "<!doctype html><html><head>\(meta)</head><body>\(html)</body></html>"
    }
}

/// An inline app in the conversation: a small card holding a live, isolated mini tool.
struct WiqoInlineAppCard: View {
    let widget: RovaBackendClient.CopilotResultWidget

    @State private var height: CGFloat?
    @State private var reloadToken = 0
    @State private var stopped = false
    @State private var showingFullScreen = false

    private var html: String { widget.html ?? "" }
    private var shownHeight: CGFloat { min(640, max(120, height ?? CGFloat(widget.height ?? 320))) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text(widget.title ?? "Uygulama").font(.footnote.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Button { stopped = false; height = nil; reloadToken += 1 } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 13, weight: .medium)) }
                    .accessibilityLabel("Sıfırla")
                Button { showingFullScreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 13, weight: .medium)) }
                    .accessibilityLabel("Tam ekran")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 38)
            Divider().opacity(0.5)
            ZStack {
                WiqoInlineAppWebView(html: html, reloadToken: reloadToken, scrolls: (height ?? 0) > 640, onHeight: { height = $0 }, onStopped: { stopped = true })
                    .id("\(widget.stableID)-\(reloadToken)")
                if stopped {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text("Uygulama durdu.").font(.footnote)
                        Button("Yeniden başlat") { stopped = false; height = nil; reloadToken += 1 }.buttonStyle(.wiqoPill(.accent))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
                }
            }
            .frame(height: shownHeight)
            .animation(.easeOut(duration: 0.2), value: shownHeight)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(.separator).opacity(0.35), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .fullScreenCover(isPresented: $showingFullScreen) {
            NavigationStack {
                WiqoInlineAppWebView(html: html, scrolls: true)
                    .background(Color(.systemBackground))
                    .navigationTitle(widget.title ?? "Uygulama")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Kapat") { showingFullScreen = false } } }
            }
        }
    }
}
