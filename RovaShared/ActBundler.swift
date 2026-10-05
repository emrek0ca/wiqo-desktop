import Foundation

/// Builds the page a project is shown as, on the device itself: the entry page with its stylesheets and
/// scripts folded in, the project's other pages as hidden sections that local links reveal, and the
/// `window.wiqoStore` shim. This is a port of the backend's `bundleWeb`/`ensureViewport` (the two are
/// checked against each other in tests), so a preview never needs the project to leave the device.
public enum ActBundler {
    public struct File: Sendable {
        public let path: String
        public let content: String
        public init(path: String, content: String) { self.path = path; self.content = content }
    }

    /// What a page keeps between visits (window.wiqoStore). The phone fills `window.__wiqoData`.
    public static let storeShim = ##"(function(){var d=window.__wiqoData||{};window.wiqoStore={get:function(k,f){return Object.prototype.hasOwnProperty.call(d,k)?d[k]:f},set:function(k,v){d[k]=v;try{window.webkit.messageHandlers.wiqoStore.postMessage({key:k,value:v})}catch(e){}}}})();"##

    /// Shows another page of the project inside the one document: local .html links swap which page is visible.
    private static let pageNav = ##"(function(){var pages={};document.querySelectorAll('[data-wiqo-page]').forEach(function(n){pages[n.getAttribute('data-wiqo-page')]=n});var home=Array.prototype.filter.call(document.body.children,function(n){return !n.hasAttribute('data-wiqo-page')&&n.tagName!=='SCRIPT'&&n.tagName!=='STYLE'});function show(name){home.forEach(function(n){n.style.display=name==='index.html'?'':'none'});Object.keys(pages).forEach(function(k){pages[k].style.display=k===name?'':'none'});window.scrollTo(0,0)}document.addEventListener('click',function(e){var a=e.target&&e.target.closest?e.target.closest('a[href]'):null;if(!a)return;var m=(a.getAttribute('href')||'').match(/^(?:\.\/)?([^#?:]+\.html)(#.+)?$/i);if(!m)return;var name=m[1];if(name!=='index.html'&&!pages[name])return;e.preventDefault();show(name);if(m[2]){var t=document.getElementById(m[2].slice(1));if(t)t.scrollIntoView()}})})();"##

    private static let maxExtraPages = 8

    // MARK: Regex helpers (JavaScript-style replace with a closure)

    private static func group(_ match: NSTextCheckingResult, _ text: NSString, _ index: Int) -> String? {
        let range = match.range(at: index)
        return range.location == NSNotFound ? nil : text.substring(with: range)
    }

    private static func replacing(_ source: String, pattern: String, firstOnly: Bool = false, _ transform: (NSTextCheckingResult, NSString) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return source }
        let text = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: text.length))
        var output = ""
        var last = 0
        for match in (firstOnly ? Array(matches.prefix(1)) : matches) {
            output += text.substring(with: NSRange(location: last, length: match.range.location - last))
            output += transform(match, text)
            last = match.range.location + match.range.length
        }
        return output + text.substring(from: last)
    }

    private static func firstMatch(_ source: String, pattern: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return regex.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length))
    }

    private static func collapseSpaces(_ text: String) -> String {
        let collapsed = replacing(text, pattern: #"\s+"#) { _, _ in " " }
        var result = collapsed
        while result.last?.isWhitespace == true { result.removeLast() }
        return result
    }

    // MARK: Bundle

    public static func bundleWeb(_ files: [File]) -> String? {
        var byPath: [String: String] = [:]
        for file in files where byPath[file.path] == nil { byPath[file.path] = file.content }
        let entry = byPath["index.html"] != nil ? "index.html" : files.map(\.path).first { $0.hasSuffix(".html") }
        guard let entry, let entrySource = byPath[entry] else { return nil }
        let base = entry.contains("/") ? String(entry[...entry.lastIndex(of: "/")!]) : ""

        func resolve(_ href: String) -> String? {
            let clean = href.hasPrefix("./") ? String(href.dropFirst(2)) : href
            return byPath[base + clean]
        }
        func isExternal(_ url: String) -> Bool { firstMatch(url, pattern: #"^(?:https?:)?//"#) != nil }

        func inlineAssets(_ source: String) -> String {
            let withStyles = replacing(source, pattern: #"<link\b[^>]*rel=["']?stylesheet["']?[^>]*>"#) { match, text in
                let tag = text.substring(with: match.range)
                var css: String?
                if let hrefMatch = firstMatch(tag, pattern: #"href=["']([^"']+)["']"#), let href = group(hrefMatch, tag as NSString, 1), !isExternal(href) { css = resolve(href) }
                guard let css else { return tag }
                return "<style>\n" + replacing(css, pattern: #"</style"#) { _, _ in "<\\/style" } + "\n</style>"
            }
            return replacing(withStyles, pattern: #"<script\b([^>]*)\bsrc=["']([^"']+)["']([^>]*)>\s*</script>"#) { match, text in
                let tag = text.substring(with: match.range)
                let before = group(match, text, 1) ?? ""
                let source = group(match, text, 2) ?? ""
                let after = group(match, text, 3) ?? ""
                guard !isExternal(source), let js = resolve(source) else { return tag }
                return "<script" + collapseSpaces(before + after) + ">\n" + replacing(js, pattern: #"</script"#) { _, _ in "<\\/script" } + "\n</script>"
            }
        }

        var html = inlineAssets(entrySource)

        let others = byPath.keys.sorted { lhs, rhs in (files.firstIndex { $0.path == lhs } ?? 0) < (files.firstIndex { $0.path == rhs } ?? 0) }
            .filter { $0 != entry && $0.hasPrefix(base) && $0.hasSuffix(".html") }
            .prefix(maxExtraPages)
        if !others.isEmpty {
            var styles: [String] = []
            var scripts: [String] = []
            var sections: [String] = []
            for path in others {
                var page = inlineAssets(byPath[path] ?? "")
                page = replacing(page, pattern: #"<style\b[^>]*>[\s\S]*?</style>"#) { match, text in
                    let block = text.substring(with: match.range)
                    if !styles.contains(block) { styles.append(block) }
                    return ""
                }
                page = replacing(page, pattern: #"<script\b[^>]*>([\s\S]*?)</script>"#) { match, text in
                    let code = group(match, text, 1) ?? ""
                    if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { scripts.append(code) }
                    return ""
                }
                var body: String
                if let bodyMatch = firstMatch(page, pattern: #"<body[^>]*>([\s\S]*?)</body>"#), let inner = group(bodyMatch, page as NSString, 1) {
                    body = inner
                } else {
                    body = replacing(page, pattern: #"<!doctype[^>]*>|</?html[^>]*>|<head[\s\S]*?</head>"#) { _, _ in "" }
                }
                sections.append("<div data-wiqo-page=\"\(path.dropFirst(base.count))\" style=\"display:none\">\(body)</div>")
            }
            let wrapped = scripts.map { code in
                "<script>(function(){try{\n" + replacing(code, pattern: #"</script"#) { _, _ in "<\\/script" } + "\n}catch(e){console.error(e)}})();</script>"
            }.joined(separator: "\n")
            let tail = sections.joined(separator: "\n") + "\n" + wrapped + "\n<script>" + pageNav + "</script>"
            let css = styles.joined(separator: "\n")
            if firstMatch(html, pattern: #"</head>"#) != nil {
                html = replacing(html, pattern: #"</head>"#, firstOnly: true) { _, _ in css + "\n</head>" }
            } else {
                html = css + html
            }
            if firstMatch(html, pattern: #"</body>"#) != nil {
                html = replacing(html, pattern: #"</body>"#, firstOnly: true) { _, _ in tail + "\n</body>" }
            } else {
                html += tail
            }
        }

        let shim = "<script>" + storeShim + "</script>"
        if let head = firstMatch(html, pattern: #"<head[^>]*>"#) {
            let text = html as NSString
            let end = head.range.location + head.range.length
            return text.substring(to: end) + shim + text.substring(from: end)
        }
        return shim + html
    }

    /// A phone page without the viewport tag renders at desktop width; add it.
    public static func ensureViewport(_ html: String) -> String {
        if firstMatch(html, pattern: #"<meta[^>]+name=["']viewport["']"#) != nil { return html }
        let tag = #"<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">"#
        if firstMatch(html, pattern: #"<head[^>]*>"#) != nil {
            return replacing(html, pattern: #"<head[^>]*>"#, firstOnly: true) { match, text in text.substring(with: match.range) + "\n" + tag }
        }
        return replacing(html, pattern: #"<html[^>]*>"#, firstOnly: true) { match, text in text.substring(with: match.range) + "\n<head>" + tag + "</head>" }
    }
}
