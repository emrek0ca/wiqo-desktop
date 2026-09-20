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
struct WiqoHTMLWebView: UIViewRepresentable {
    let html: String
    var isInteractive = true
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

/// A finished HTML answer shown as the running app right inside the conversation. Tapping it opens
/// the same page in the canvas at full size.
struct WiqoAppPreviewCard: View {
    let html: String
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles.rectangle.stack")
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
