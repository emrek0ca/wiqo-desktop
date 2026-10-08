import SwiftUI
import WebKit

/// What an inline app may tell the app. Anything else it posts is ignored: its height, a few bytes of its own saved state,
/// a text to copy / share / offer in the composer, a haptic tick, and (for the card's own banner) the problems it ran into.
final class InlineAppBridge: NSObject, WKScriptMessageHandler {
    var onHeight: ((CGFloat) -> Void)?
    var onProblem: ((String) -> Void)?
    var stateKey = ""
    private var lastAction = Date.distantPast

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let number = message.body as? NSNumber {
            let height = CGFloat(truncating: number)
            guard height.isFinite, height > 0, height < 20_000 else { return }
            onHeight?(height)
            return
        }
        guard let body = message.body as? [String: Any] else { return }
        if let save = body["save"] as? [String: Any], let key = save["k"] as? String, let value = save["v"] as? String {
            InlineAppStateStore.shared.set(key, value, for: stateKey)
        } else if let problem = body["err"] as? String {
            onProblem?(String(problem.prefix(200)))
        } else if let check = body["check"] as? [String: Any], check["blank"] as? Bool == true {
            onProblem?("Sayfa boş göründü; hiçbir şey çizilmedi.")
        } else {
            performAction(body)
        }
    }

    /// Copy, share, ask and haptic: at most one a second, so a page cannot flood the clipboard or the composer.
    private func performAction(_ body: [String: Any]) {
        guard Date().timeIntervalSince(lastAction) >= 1 else { return }
        if let text = body["copy"] as? String {
            lastAction = Date()
            UIPasteboard.general.string = String(text.prefix(20_000))
            WiqoToastCenter.shared.show("Kopyalandı")
        } else if let text = body["share"] as? String {
            lastAction = Date()
            InlineAppActions.share(items: [String(text.prefix(20_000))])
        } else if let text = body["ask"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastAction = Date()
            NotificationCenter.default.post(name: .wiqoInlineAppAsk, object: String(text.prefix(500)))
        } else if let kind = body["haptic"] as? String {
            switch kind {
            case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
            default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }
}

extension Notification.Name {
    /// A card's page offered a text for the composer (the person still decides whether to send it).
    static let wiqoInlineAppAsk = Notification.Name("wiqo.inlineApp.ask")
    /// A card asked Wiqo to fix itself: the text is sent as the person's message.
    static let wiqoInlineAppFix = Notification.Name("wiqo.inlineApp.fix")
}

/// A card's saved state (wiqo.save / wiqo.load), kept on this phone per card: at most 32 short texts of 2,000 characters and 8,000 in all,
/// and the 100 most recently used cards. Nothing here ever leaves the phone.
final class InlineAppStateStore: @unchecked Sendable {
    static let shared = InlineAppStateStore()
    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private let storeKey = "wiqo.inlineApp.state.v1"
    private let orderKey = "wiqo.inlineApp.state.order.v1"

    func state(for card: String) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return ((defaults.dictionary(forKey: storeKey) as? [String: [String: String]]) ?? [:])[card] ?? [:]
    }

    func set(_ key: String, _ value: String, for card: String) {
        guard !card.isEmpty, !key.isEmpty, key.count <= 40, value.count <= 2_000 else { return }
        lock.lock(); defer { lock.unlock() }
        var all = (defaults.dictionary(forKey: storeKey) as? [String: [String: String]]) ?? [:]
        var entries = all[card] ?? [:]
        entries[key] = value
        guard entries.count <= 32, entries.reduce(0, { $0 + $1.key.count + $1.value.count }) <= 8_000 else { return }
        all[card] = entries
        var order = (defaults.stringArray(forKey: orderKey) ?? []).filter { $0 != card }
        order.append(card)
        while order.count > 100 { all[order.removeFirst()] = nil }
        defaults.set(all, forKey: storeKey)
        defaults.set(order, forKey: orderKey)
    }

    func clear(card: String) {
        lock.lock(); defer { lock.unlock() }
        var all = (defaults.dictionary(forKey: storeKey) as? [String: [String: String]]) ?? [:]
        all[card] = nil
        defaults.set(all, forKey: storeKey)
    }
}

enum InlineAppActions {
    @MainActor
    static func share(items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = top.view
        top.present(controller, animated: true)
    }
}

/// Runs one inline app in an isolated web view. Three walls, each enough on its own for the common attacks:
/// 1. the page's Content-Security-Policy (no network, no frames, no forms, no other origins),
/// 2. the web view itself (own web-content process, non-persistent storage, every navigation, popup and dialog refused),
/// 3. a start-up script that removes the network, storage and window APIs and the bridge to the app.
/// The app gets no cookies, tokens or storage of Wiqo, and no message channel except its own height.
struct WiqoInlineAppWebView: UIViewRepresentable {
    let html: String
    /// Where this card's saved state lives, the data handed to the page as `wiqo.data`, and the libraries the phone injects.
    var stateKey = ""
    var data: String?
    var libs: [String] = []
    var onProblem: (String) -> Void = { _ in }
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
        // Order matters: state and data first, then the page-side API (it keeps the message channel), then the libraries, then the lock-down.
        for script in Self.startScripts(stateKey: stateKey, data: data, libs: libs) {
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        configuration.userContentController.addUserScript(WKUserScript(source: Self.hardening, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        context.coordinator.bridge.stateKey = stateKey
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
        context.coordinator.bridge.onProblem = onProblem
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

    /// A value as a JavaScript literal the page can read back (JSON, with the two characters JavaScript treats as line ends escaped).
    private static func literal(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// The libraries a page asked for, in the order they need each other (templates draw their charts with the chart library).
    static func libraries(_ requested: [String]) -> [(name: String, source: String)] {
        var wanted = Set(requested)
        if wanted.contains("templates") { wanted.insert("chart") }
        return [("chart", WiqoInlineKit.chart), ("confetti", WiqoInlineKit.confetti), ("templates", WiqoInlineKit.templates)].filter { wanted.contains($0.0) }.map { (name: $0.0, source: $0.1) }
    }

    /// Everything injected before the page runs, except the lock-down.
    static func startScripts(stateKey: String, data: String?, libs: [String]) -> [String] {
        let state = InlineAppStateStore.shared.state(for: stateKey)
        let parsed = data.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
        let header = "window.__WIQO_STATE__=\(literal(state));window.__WIQO_DATA__=\(parsed.map(literal) ?? "null");"
        return [header, WiqoInlineKit.core] + libraries(libs).map(\.source)
    }

    /// The page as a file anyone can open in a browser: the same scripts, inline (the bridge calls are guarded, so outside the app they do nothing).
    static func exportDocument(html: String, data: String?, libs: [String]) -> String {
        let scripts = startScripts(stateKey: "", data: data, libs: libs).map { "<script>\($0)</script>" }.joined()
        if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var document = html
            document.insert(contentsOf: scripts, at: head.upperBound)
            return document
        }
        return "<!doctype html><html><head>\(scripts)</head><body>\(html)</body></html>"
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

private struct ReplacedInlineAppsKey: EnvironmentKey { static let defaultValue: Set<String> = [] }

extension EnvironmentValues {
    /// Cards a later card has replaced (an edit in place): they fold into one quiet line.
    var replacedInlineApps: Set<String> {
        get { self[ReplacedInlineAppsKey.self] }
        set { self[ReplacedInlineAppsKey.self] = newValue }
    }
}

/// An inline app in the conversation: a small card holding a live, isolated mini tool. It runs on this phone, from the page the server
/// sent and the libraries the app carries; the server does no work for it after the reply.
struct WiqoInlineAppCard: View {
    let widget: RovaBackendClient.CopilotResultWidget

    @Environment(\.replacedInlineApps) private var replaced
    @State private var height: CGFloat?
    @State private var reloadToken = 0
    @State private var stopped = false
    @State private var showingFullScreen = false
    @State private var problem: String?
    @State private var problemDismissed = false

    private var html: String { widget.html ?? "" }
    private var stateKey: String { widget.stateKey ?? widget.stableID }
    private var libs: [String] { widget.libs ?? [] }
    private var shownHeight: CGFloat { min(640, max(120, height ?? CGFloat(widget.height ?? 320))) }

    var body: some View {
        if replaced.contains(widget.stableID) {
            Label("“\(widget.title ?? "Uygulama")” güncellendi; yeni sürümü aşağıda.", systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            card
        }
    }

    private func restart(clearingState: Bool) {
        if clearingState { InlineAppStateStore.shared.clear(card: stateKey) }
        stopped = false
        height = nil
        problem = nil
        problemDismissed = false
        reloadToken += 1
    }

    /// The card becomes a project of its own in Act, on this phone: the same page (libraries and data inside), nothing sent anywhere.
    /// From there it is changed with the writer like any other project.
    private func moveToAct() {
        let document = WiqoInlineAppWebView.exportDocument(html: html, data: widget.data, libs: libs)
        guard let id = ActModel.shared.importProject(name: widget.title ?? "Uygulama", files: ["index.html": document], mode: .deviceOnly) else { return }
        WiqoHaptics.selection()
        NotificationCenter.default.post(name: .wiqoOpenProjectInAct, object: id)
    }

    private func exportFile() {
        let name = (widget.title ?? "uygulama").replacingOccurrences(of: "/", with: "-").prefix(40)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).html")
        let document = WiqoInlineAppWebView.exportDocument(html: html, data: widget.data, libs: libs)
        guard (try? document.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        InlineAppActions.share(items: [url])
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text(widget.title ?? "Uygulama").font(.footnote.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    Button { restart(clearingState: true) } label: { Label("Sıfırla", systemImage: "arrow.counterclockwise") }
                    Button { moveToAct() } label: { Label("Act'te geliştir", systemImage: "hammer") }
                    Button { exportFile() } label: { Label("Dosya olarak paylaş", systemImage: "square.and.arrow.up") }
                    Button { showingFullScreen = true } label: { Label("Tam ekran", systemImage: "arrow.up.left.and.arrow.down.right") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 15, weight: .medium)).frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .accessibilityLabel("Uygulama seçenekleri")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 38)
            Divider().opacity(0.5)
            ZStack {
                WiqoInlineAppWebView(html: html, stateKey: stateKey, data: widget.data, libs: libs,
                                     onProblem: { message in if problem == nil { problem = message } },
                                     reloadToken: reloadToken, scrolls: (height ?? 0) > 640, onHeight: { height = $0 }, onStopped: { stopped = true })
                    .id("\(widget.stableID)-\(reloadToken)")
                if stopped {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text("Uygulama durdu.").font(.footnote)
                        Button("Yeniden başlat") { restart(clearingState: false) }.buttonStyle(.wiqoPill(.accent))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
                }
            }
            .frame(height: shownHeight)
            .animation(.easeOut(duration: 0.2), value: shownHeight)
            if let problem, !problemDismissed {
                Divider().opacity(0.5)
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text("Uygulamada sorun var: \(problem)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Düzelt") {
                        problemDismissed = true
                        NotificationCenter.default.post(name: .wiqoInlineAppFix, object: "“\(widget.title ?? "Uygulama")” uygulaması çalışırken hata verdi (\(problem)). Aynı uygulamayı düzeltip yeniden göster.")
                    }
                    .buttonStyle(.wiqoPill(.accent))
                    Button { problemDismissed = true } label: { Image(systemName: "xmark").font(.caption) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Kapat")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(.separator).opacity(0.35), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .fullScreenCover(isPresented: $showingFullScreen) {
            NavigationStack {
                WiqoInlineAppWebView(html: html, stateKey: stateKey, data: widget.data, libs: libs, scrolls: true)
                    .background(Color(.systemBackground))
                    .navigationTitle(widget.title ?? "Uygulama")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Kapat") { showingFullScreen = false } } }
            }
        }
    }
}

// BEGIN GENERATED inline-app kit (contracts/inline-app/sync.mjs - edit the .js files, not this block)
enum WiqoInlineKit {
    static let core = #"""
(function(){
  var post=function(){};
  try{var h=window.webkit.messageHandlers.wiqoApp;post=function(v){try{h.postMessage(v)}catch(e){}}}catch(e){}
  var state={};var saved=window.__WIQO_STATE__||{};for(var k0 in saved){if(Object.prototype.hasOwnProperty.call(saved,k0))state[k0]=String(saved[k0])}
  var freeze=function(o){if(o&&typeof o==='object'&&!Object.isFrozen(o)){Object.freeze(o);Object.keys(o).forEach(function(k){freeze(o[k])})}return o};
  var data=window.__WIQO_DATA__===undefined?null:freeze(window.__WIQO_DATA__);
  var text=function(t,n){return String(t===undefined||t===null?'':t).slice(0,n)};
  var api={
    data:data,
    load:function(k){k=text(k,40);return Object.prototype.hasOwnProperty.call(state,k)?state[k]:null},
    save:function(k,v){k=text(k,40);v=text(v,2000);if(!k)return;state[k]=v;post({save:{k:k,v:v}})},
    copy:function(t){post({copy:text(t,20000)})},
    share:function(t){post({share:text(t,20000)})},
    haptic:function(kind){post({haptic:kind==='success'||kind==='warning'||kind==='error'?kind:'light'})},
    ask:function(t){post({ask:text(t,500)})}
  };
  try{Object.defineProperty(window,'wiqo',{value:Object.freeze(api)})}catch(e){}
  window.WIQO_DATA=data;
  var problem=function(m){post({err:text(m,200)})};
  window.addEventListener('error',function(e){problem(e&&e.message?e.message:'Betik hatası')});
  window.addEventListener('unhandledrejection',function(e){problem(e&&e.reason&&e.reason.message?e.reason.message:'İşlenmeyen hata')});
  window.addEventListener('load',function(){setTimeout(function(){
    var b=document.body;if(!b)return;
    var drawn=b.innerText.trim().length>2||b.querySelector('canvas,svg,img,button,input,select,textarea,table');
    var el=document.documentElement;
    post({check:{blank:!drawn,overflow:el.scrollWidth>el.clientWidth+4}});
  },800)});
})();
"""#

    static let chart = #"""
(function(){
  var NS='http://www.w3.org/2000/svg';
  var COLORS=['#0a84ff','#30b0c7','#ff9f0a','#bf5af2','#32d74b','#ff453a','#64d2ff','#ffd60a'];
  function el(name,attrs,text){var n=document.createElementNS(NS,name);for(var k in attrs)n.setAttribute(k,attrs[k]);if(text!==undefined)n.textContent=text;return n}
  function nice(max){if(max<=0)return 1;var p=Math.pow(10,Math.floor(Math.log10(max)));var f=max/p;return(f<=1?1:f<=2?2:f<=5?5:10)*p}
  function fmt(v){var a=Math.abs(v);if(a>=1e9)return(v/1e9).toFixed(1).replace(/\.0$/,'')+' Mr';if(a>=1e6)return(v/1e6).toFixed(1).replace(/\.0$/,'')+' Mn';if(a>=1e4)return(v/1e3).toFixed(0)+' B';return String(Math.round(v*100)/100).replace('.',',')}
  function series(o){
    if(o.series&&o.series.length)return o.series.map(function(s,i){return{name:String(s.name||('Seri '+(i+1))),values:(s.values||[]).map(Number)}});
    return[{name:String(o.title||''),values:(o.values||[]).map(Number)}];
  }
  /* WiqoChart.render(container, {type:'bar'|'line'|'pie', labels:[], values:[] | series:[{name,values}], unit?, title?}) */
  function render(root,o){
    o=o||{};var labels=(o.labels||[]).map(String);var data=series(o);var type=o.type||'bar';
    var n=Math.max(labels.length,data[0]?data[0].values.length:0);
    root.innerHTML='';
    if(!n||!data[0]||!data[0].values.length){root.textContent='Gösterilecek veri yok.';return}
    var W=360,H=type==='pie'?240:220,svg=el('svg',{viewBox:'0 0 '+W+' '+H,role:'img','aria-label':String(o.title||'Grafik'),style:'width:100%;height:auto;display:block;font:11px -apple-system,system-ui,sans-serif'});
    var fg='var(--fg,#14161a)',muted='var(--muted,#5c6573)',grid='var(--border,rgba(120,120,128,.28))';
    if(type==='pie'){
      var vals=data[0].values,total=vals.reduce(function(a,b){return a+Math.max(0,b)},0)||1,cx=110,cy=120,r=90,a0=-Math.PI/2;
      vals.forEach(function(v,i){
        var a1=a0+Math.max(0,v)/total*Math.PI*2;
        if(Math.max(0,v)/total>=0.9999){svg.appendChild(el('circle',{cx:cx,cy:cy,r:r,fill:COLORS[i%COLORS.length]}))}
        else{var large=a1-a0>Math.PI?1:0;svg.appendChild(el('path',{d:'M'+cx+','+cy+' L'+(cx+r*Math.cos(a0))+','+(cy+r*Math.sin(a0))+' A'+r+','+r+' 0 '+large+' 1 '+(cx+r*Math.cos(a1))+','+(cy+r*Math.sin(a1))+' Z',fill:COLORS[i%COLORS.length],stroke:'var(--bg,#fff)','stroke-width':1.5}))}
        a0=a1;
      });
      vals.slice(0,10).forEach(function(v,i){
        var y=30+i*20;svg.appendChild(el('rect',{x:225,y:y-9,width:10,height:10,rx:2,fill:COLORS[i%COLORS.length]}));
        svg.appendChild(el('text',{x:241,y:y,fill:fg},(labels[i]||('#'+(i+1)))+' · %'+Math.round(Math.max(0,v)/total*100)));
      });
      root.appendChild(svg);return;
    }
    var all=[];data.forEach(function(s){all=all.concat(s.values)});
    var min=Math.min(0,Math.min.apply(null,all)),max=nice(Math.max.apply(null,all.concat([0.0001])));
    var L=38,R=8,T=14,B=labels.length>6?44:28,pw=W-L-R,ph=H-T-B,span=max-min||1;
    var y=function(v){return T+ph-(v-min)/span*ph};
    for(var g=0;g<=4;g++){var gv=min+span*g/4,gy=y(gv);svg.appendChild(el('line',{x1:L,x2:W-R,y1:gy,y2:gy,stroke:grid,'stroke-width':.6}));svg.appendChild(el('text',{x:L-4,y:gy+3,'text-anchor':'end',fill:muted},fmt(gv)))}
    var step=pw/n;
    labels.slice(0,n).forEach(function(lab,i){
      var x=L+step*(i+.5),t=el('text',{x:x,y:H-B+14,'text-anchor':labels.length>6?'end':'middle',fill:muted,transform:labels.length>6?'rotate(-35 '+x+' '+(H-B+14)+')':''},lab.length>12?lab.slice(0,11)+'…':lab);
      if(labels.length<=12||i%Math.ceil(labels.length/12)===0)svg.appendChild(t);
    });
    if(type==='line'){
      data.forEach(function(s,si){
        var pts=s.values.map(function(v,i){return[L+step*(i+.5),y(v)]});
        svg.appendChild(el('polyline',{points:pts.map(function(p){return p.join(',')}).join(' '),fill:'none',stroke:COLORS[si%COLORS.length],'stroke-width':2.2,'stroke-linejoin':'round','stroke-linecap':'round'}));
        pts.forEach(function(p,i){svg.appendChild(el('circle',{cx:p[0],cy:p[1],r:2.8,fill:COLORS[si%COLORS.length]}));if(n<=10&&data.length===1)svg.appendChild(el('text',{x:p[0],y:p[1]-6,'text-anchor':'middle',fill:fg},fmt(s.values[i])))});
      });
    }else{
      var gw=step*.72,bw=gw/data.length;
      data.forEach(function(s,si){s.values.forEach(function(v,i){
        var x=L+step*i+(step-gw)/2+bw*si,top=y(Math.max(v,0)),h=Math.abs(y(v)-y(0));
        svg.appendChild(el('rect',{x:x,y:v>=0?top:y(0),width:Math.max(1,bw-1),height:Math.max(1,h),rx:3,fill:COLORS[si%COLORS.length]}));
        if(n<=10&&data.length===1)svg.appendChild(el('text',{x:x+bw/2,y:(v>=0?top:y(v))-4,'text-anchor':'middle',fill:fg},fmt(v)+(o.unit?' '+o.unit:'')));
      })});
    }
    root.appendChild(svg);
    if(data.length>1){var lg=document.createElement('div');lg.style.cssText='display:flex;gap:12px;flex-wrap:wrap;font-size:12px;margin-top:6px';data.forEach(function(s,i){var it=document.createElement('span');it.innerHTML='<i style="display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:5px;background:'+COLORS[i%COLORS.length]+'"></i>';it.appendChild(document.createTextNode(s.name));lg.appendChild(it)});root.appendChild(lg)}
  }
  window.WiqoChart=Object.freeze({render:render});
})();
"""#

    static let confetti = #"""
(function(){
  /* WiqoConfetti.burst(): a short burst of coloured pieces over the page; removes itself. */
  var COLORS=['#ff453a','#ff9f0a','#ffd60a','#32d74b','#0a84ff','#bf5af2'];
  function burst(){
    var c=document.createElement('canvas');var w=c.width=window.innerWidth||360,h=c.height=window.innerHeight||400;
    c.style.cssText='position:fixed;left:0;top:0;width:100%;height:100%;pointer-events:none;z-index:9999';document.body.appendChild(c);
    var g=c.getContext('2d'),p=[],i;
    for(i=0;i<90;i++)p.push({x:w/2,y:h*.35,vx:(Math.random()-.5)*9,vy:-Math.random()*9-2,s:4+Math.random()*5,r:Math.random()*6,vr:(Math.random()-.5)*.4,c:COLORS[i%COLORS.length]});
    var t=0;
    (function frame(){
      g.clearRect(0,0,w,h);t++;
      p.forEach(function(q){q.vy+=.28;q.x+=q.vx;q.y+=q.vy;q.r+=q.vr;g.save();g.translate(q.x,q.y);g.rotate(q.r);g.fillStyle=q.c;g.globalAlpha=Math.max(0,1-t/110);g.fillRect(-q.s/2,-q.s/2,q.s,q.s*.6);g.restore()});
      if(t<110)requestAnimationFrame(frame);else c.remove();
    })();
  }
  window.WiqoConfetti=Object.freeze({burst:burst});
})();
"""#

    static let templates = #"""
(function(){
  /* WiqoTemplates.mount(root, config?): ready-made small tools drawn from a config (wiqo.data by default).
     kinds: checklist, counter, timer, calculator, converter, quiz, table, chart. Everything runs on the phone. */
  var css='.wq{max-width:520px;margin:0 auto}.wq h2{font-size:17px;margin:0 0 10px}.wq .row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}.wq .big{font-size:44px;font-weight:600;font-variant-numeric:tabular-nums;text-align:center;margin:8px 0}'
   +'.wq .item{display:flex;gap:10px;align-items:center;padding:10px 4px;border-bottom:1px solid var(--border)}.wq .item.done span{text-decoration:line-through;color:var(--muted)}'
   +'.wq .bar{height:6px;border-radius:3px;background:var(--surface);overflow:hidden;margin:8px 0}.wq .bar i{display:block;height:100%;background:var(--accent);transition:width .2s}'
   +'.wq .grid{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}.wq .grid button{min-height:52px;font-size:20px}.wq .screen{font-size:32px;text-align:right;padding:8px 4px;min-height:56px;overflow-x:auto;white-space:nowrap;font-variant-numeric:tabular-nums}'
   +'.wq .opt{display:block;width:100%;text-align:left;margin:6px 0}.wq .ok{background:#30d158!important;color:#fff!important}.wq .bad{background:#ff453a!important;color:#fff!important}.wq .muted{color:var(--muted);font-size:13px}'
   +'.wq th{cursor:pointer;white-space:nowrap}.wq .scroll{overflow-x:auto}.wq input,.wq select{flex:1;min-width:0}';
  var $=function(tag,attrs,kids){var n=document.createElement(tag);for(var k in attrs||{}){if(k==='text')n.textContent=attrs[k];else if(k==='class')n.className=attrs[k];else n.setAttribute(k,attrs[k])}(kids||[]).forEach(function(c){n.appendChild(c)});return n};
  var num=function(v,d){var x=Number(v);return isFinite(x)?x:d};
  var fmt=function(v){return String(Math.round(v*1e9)/1e9).replace('.',',')};
  var load=function(k){try{return window.wiqo.load(k)}catch(e){return null}};
  var save=function(k,v){try{window.wiqo.save(k,v)}catch(e){}};
  var haptic=function(k){try{window.wiqo.haptic(k)}catch(e){}};

  function checklist(root,c){
    var items=(c.items||[]).map(function(it){return typeof it==='string'?{text:it,done:false}:{text:String(it.text||''),done:!!it.done}});
    var stored;try{stored=JSON.parse(load('done')||'null')}catch(e){stored=null}
    if(stored&&stored.length===items.length)items.forEach(function(it,i){it.done=!!stored[i]});
    var bar=$('div',{class:'bar'},[$('i')]),count=$('div',{class:'muted'}),list=$('div');
    function draw(){
      list.innerHTML='';var d=0;
      items.forEach(function(it,i){
        if(it.done)d++;
        var cb=$('input',{type:'checkbox'});cb.checked=it.done;
        cb.addEventListener('change',function(){it.done=cb.checked;save('done',JSON.stringify(items.map(function(x){return x.done?1:0})));haptic('light');draw();if(d+(it.done?1:-1)===items.length&&it.done&&window.WiqoConfetti)window.WiqoConfetti.burst()});
        var row=$('label',{class:'item'+(it.done?' done':'')},[cb,$('span',{text:it.text})]);list.appendChild(row);
      });
      bar.firstChild.style.width=(items.length?d/items.length*100:0)+'%';count.textContent=d+' / '+items.length+' tamamlandı';
    }
    root.appendChild(bar);root.appendChild(count);root.appendChild(list);draw();
  }
  function counter(root,c){
    var step=num(c.step,1),goal=c.goal===undefined?null:num(c.goal,null),start=num(c.start,0);
    var v=num(load('value'),start);var out=$('div',{class:'big'}),bar=$('div',{class:'bar'},[$('i')]);
    function draw(){out.textContent=fmt(v);if(goal){bar.firstChild.style.width=Math.max(0,Math.min(100,v/goal*100))+'%'}save('value',String(v))}
    function change(d){v=Math.round((v+d)*1e9)/1e9;haptic('light');draw();if(goal&&v>=goal&&window.WiqoConfetti)window.WiqoConfetti.burst()}
    var minus=$('button',{text:'−','aria-label':'Azalt'}),plus=$('button',{text:'+','aria-label':'Artır'}),reset=$('button',{text:'Sıfırla',class:'secondary'});
    minus.onclick=function(){change(-step)};plus.onclick=function(){change(step)};reset.onclick=function(){v=start;draw()};
    root.appendChild(out);if(goal){root.appendChild(bar);root.appendChild($('div',{class:'muted',text:'Hedef: '+fmt(goal)}))}
    root.appendChild($('div',{class:'row',style:'justify-content:center'},[minus,plus,reset]));draw();
  }
  function timer(root,c){
    var down=c.mode!=='stopwatch',total=Math.max(1,Math.round(num(c.seconds,60))),left=down?total:0,run=false,last=0,id=null;
    var out=$('div',{class:'big'}),go=$('button',{text:'Başlat'}),reset=$('button',{text:'Sıfırla',class:'secondary'});
    function show(){var s=Math.max(0,Math.ceil(down?left:left)),m=Math.floor(s/60),r=s%60,h=Math.floor(m/60);out.textContent=(h?h+':':'')+('0'+(h?m%60:m)).slice(-2)+':'+('0'+r).slice(-2)}
    function tick(){var now=Date.now(),d=(now-last)/1000;last=now;if(down){left-=d;if(left<=0){left=0;stop();haptic('success');go.textContent='Başlat';if(window.WiqoConfetti)window.WiqoConfetti.burst()}}else left+=d;show()}
    function stop(){run=false;clearInterval(id);id=null;go.textContent='Başlat'}
    go.onclick=function(){if(run){stop();go.textContent='Devam'}else{if(down&&left<=0)left=total;run=true;last=Date.now();id=setInterval(tick,200);go.textContent='Duraklat'}};
    reset.onclick=function(){stop();left=down?total:0;show()};
    root.appendChild(out);root.appendChild($('div',{class:'row',style:'justify-content:center'},[go,reset]));show();
  }
  function evaluate(src){
    var t=src.replace(/×/g,'*').replace(/÷/g,'/').replace(/,/g,'.').replace(/−/g,'-'),pos=0;
    function ws(){while(t[pos]===' ')pos++}
    function number(){ws();var s=pos;if(t[pos]==='('){pos++;var v=expr();ws();if(t[pos]!==')')throw 0;pos++;return v}
      if(t[pos]==='-'){pos++;return -number()}
      while(/[0-9.]/.test(t[pos]||''))pos++;if(s===pos)throw 0;var x=parseFloat(t.slice(s,pos));ws();if(t[pos]==='%'){pos++;x/=100}return x}
    function term(){var v=number();for(;;){ws();var o=t[pos];if(o==='*'||o==='/'){pos++;var r=number();v=o==='*'?v*r:v/r}else return v}}
    function expr(){var v=term();for(;;){ws();var o=t[pos];if(o==='+'||o==='-'){pos++;var r=term();v=o==='+'?v+r:v-r}else return v}}
    var r=expr();ws();if(pos<t.length)throw 0;return r;
  }
  function calculator(root){
    var scr=$('div',{class:'screen',text:'0'}),grid=$('div',{class:'grid'}),exp='';
    ['C','(',')','÷','7','8','9','×','4','5','6','−','1','2','3','+','0',',','⌫','='].forEach(function(k){
      var b=$('button',{text:k,class:/[0-9,]/.test(k)?'secondary':''});
      b.onclick=function(){
        haptic('light');
        if(k==='C')exp='';else if(k==='⌫')exp=exp.slice(0,-1);
        else if(k==='='){try{var r=evaluate(exp);if(!isFinite(r))throw 0;exp=fmt(r)}catch(e){exp='';scr.textContent='Hata';return}}
        else exp+=k;
        scr.textContent=exp||'0';
      };grid.appendChild(b);
    });
    root.appendChild(scr);root.appendChild(grid);
  }
  function converter(root,c){
    var units=(c.units||[]).map(function(u){return{name:String(u.name),factor:num(u.factor,1)||1,offset:num(u.offset,0)}});
    if(units.length<2){root.textContent='En az iki birim gerekli.';return}
    var input=$('input',{type:'number',inputmode:'decimal',value:String(num(c.value,1))}),from=$('select'),to=$('select'),out=$('div',{class:'big'});
    units.forEach(function(u,i){from.appendChild($('option',{value:String(i),text:u.name}));to.appendChild($('option',{value:String(i),text:u.name}))});to.value='1';
    function calc(){var a=units[+from.value],b=units[+to.value],v=parseFloat(input.value);if(!isFinite(v)){out.textContent='—';return}var base=v*a.factor+a.offset;out.textContent=fmt((base-b.offset)/b.factor)+' '+b.name}
    [input,from,to].forEach(function(n){n.addEventListener('input',calc);n.addEventListener('change',calc)});
    root.appendChild($('div',{class:'row'},[input,from]));root.appendChild($('div',{class:'row',style:'margin-top:8px'},[to]));root.appendChild(out);calc();
  }
  function quiz(root,c){
    var qs=(c.questions||[]).filter(function(q){return q&&q.q&&q.options&&q.options.length>1});
    if(!qs.length){root.textContent='Soru yok.';return}
    var i=0,score=0,answered=false,box=$('div');root.appendChild(box);
    function ask(){
      answered=false;box.innerHTML='';var q=qs[i];
      box.appendChild($('div',{class:'muted',text:'Soru '+(i+1)+' / '+qs.length}));box.appendChild($('h2',{text:q.q}));
      var note=$('div',{class:'muted',style:'margin-top:8px'}),next=$('button',{text:i+1<qs.length?'Sonraki':'Sonucu gör',style:'display:none;margin-top:10px'});
      q.options.forEach(function(o,oi){
        var b=$('button',{class:'secondary opt',text:String(o)});
        b.onclick=function(){
          if(answered)return;answered=true;var right=oi===num(q.answer,0);if(right){score++;b.className='opt ok';haptic('success')}else{b.className='opt bad';haptic('error');var ob=box.querySelectorAll('.opt')[num(q.answer,0)];if(ob)ob.className='opt ok'}
          if(q.explain)note.textContent=String(q.explain);next.style.display='inline-block';
        };box.appendChild(b);
      });
      box.appendChild(note);box.appendChild(next);next.onclick=function(){i++;if(i<qs.length)ask();else done()};
    }
    function done(){
      box.innerHTML='';box.appendChild($('div',{class:'big',text:score+' / '+qs.length}));
      box.appendChild($('div',{class:'muted',style:'text-align:center',text:score===qs.length?'Hepsi doğru!':score>=qs.length/2?'İyi gidiyorsun.':'Bir tur daha dene.'}));
      var again=$('button',{text:'Tekrar',style:'display:block;margin:12px auto 0'});again.onclick=function(){i=0;score=0;ask()};box.appendChild(again);
      if(score===qs.length&&window.WiqoConfetti)window.WiqoConfetti.burst();
    }
    ask();
  }
  function table(root,c){
    var cols=(c.columns||[]).map(String),rows=(c.rows||[]).map(function(r){return(r||[]).map(function(x){return x===null||x===undefined?'':String(x)})});
    var sort=-1,asc=true,q='',wrap=$('div',{class:'scroll'});
    var filter=rows.length>8?$('input',{type:'search',placeholder:'Tabloda ara'}):null;
    function draw(){
      var list=rows.filter(function(r){return!q||r.some(function(x){return x.toLowerCase().indexOf(q)>=0})});
      if(sort>=0)list.sort(function(a,b){var x=a[sort]||'',y=b[sort]||'',nx=parseFloat(x.replace(/[^0-9,.\-]/g,'').replace(',','.')),ny=parseFloat(y.replace(/[^0-9,.\-]/g,'').replace(',','.'));var r=isFinite(nx)&&isFinite(ny)?nx-ny:x.localeCompare(y,'tr');return asc?r:-r});
      var t=$('table'),hr=$('tr');
      cols.forEach(function(h,i){var th=$('th',{text:h+(sort===i?(asc?' ▲':' ▼'):'')});th.onclick=function(){if(sort===i)asc=!asc;else{sort=i;asc=true}draw()};hr.appendChild(th)});
      t.appendChild($('thead',{},[hr]));var tb=$('tbody');list.forEach(function(r){var tr=$('tr');cols.forEach(function(_,i){tr.appendChild($('td',{text:r[i]||''}))});tb.appendChild(tr)});t.appendChild(tb);
      wrap.innerHTML='';wrap.appendChild(t);
    }
    if(filter){filter.addEventListener('input',function(){q=filter.value.toLowerCase();draw()});root.appendChild(filter)}
    root.appendChild(wrap);draw();
  }
  function chart(root,c){var host=$('div');root.appendChild(host);window.WiqoChart.render(host,c)}

  var KINDS={checklist:checklist,counter:counter,timer:timer,calculator:calculator,converter:converter,quiz:quiz,table:table,chart:chart};
  function mount(root,config){
    var c=config||window.WIQO_DATA||{};var fn=KINDS[c.kind];
    if(!document.getElementById('wq-css')){var s=document.createElement('style');s.id='wq-css';s.textContent=css;document.head.appendChild(s)}
    root.className='wq';root.innerHTML='';
    if(c.title)root.appendChild($('h2',{text:String(c.title)}));
    if(!fn){root.appendChild($('div',{class:'muted',text:'Bu araç türü bilinmiyor.'}));return}
    fn(root,c);
  }
  window.WiqoTemplates=Object.freeze({mount:mount,kinds:Object.keys(KINDS),evaluate:evaluate});
})();
"""#
}
// END GENERATED
