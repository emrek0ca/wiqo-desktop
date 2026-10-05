import Foundation

/// Requests that are a change to a few design values need no writer at all: "koyu tema yap", "ana renk
/// mavi", "tuşları yuvarlak yap", "yazıyı büyüt", "başlığı 'X' yap". They are done on the device, in
/// milliseconds, with no tokens and without a single file leaving the phone.
///
/// This works because new web projects keep their look in CSS variables (the design tokens: --bg,
/// --surface, --fg, --muted, --border, --accent, --accent-fg, --radius, --radius-btn, --text-size).
/// Anything not understood with certainty returns nil and goes to the writer instead; a request with
/// several parts is handled only if every part is understood.
public struct ActQuickEdit: Sendable, Equatable {
    /// Only the files that changed, with their new content.
    public let files: [String: String]
    public let summary: String
}

public enum ActQuickEdits {
    public static func apply(_ request: String, to files: [String: String]) -> ActQuickEdit? {
        let clauses = split(fold(request))
        guard !clauses.isEmpty, clauses.count <= 4 else { return nil }
        var working = files
        var summaries: [String] = []
        for clause in clauses {
            guard let (updated, summary) = applyClause(clause, original: request, files: working) else { return nil }
            working = updated
            summaries.append(summary)
        }
        let changed = working.filter { files[$0.key] != $0.value }
        guard !changed.isEmpty else { return nil }
        return ActQuickEdit(files: changed, summary: summaries.joined(separator: ", ").prefix(1).uppercased() + summaries.joined(separator: ", ").dropFirst())
    }

    // MARK: Reading the request

    /// Lower case without Turkish diacritics, so "Kırmızı" and "kirmizi" read the same.
    static func fold(_ text: String) -> String {
        let map: [Character: Character] = ["ç": "c", "ğ": "g", "ı": "i", "ö": "o", "ş": "s", "ü": "u", "â": "a", "î": "i", "û": "u"]
        return String(text.lowercased(with: Locale(identifier: "tr_TR")).map { map[$0] ?? $0 })
            .replacingOccurrences(of: "i̇", with: "i")
    }

    private static func split(_ folded: String) -> [String] {
        folded
            .replacingOccurrences(of: " ve ", with: "|").replacingOccurrences(of: ",", with: "|").replacingOccurrences(of: ";", with: "|")
            .replacingOccurrences(of: " ayrica ", with: "|").replacingOccurrences(of: " sonra ", with: "|").replacingOccurrences(of: " bir de ", with: "|")
            .split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static let colors: [(words: [String], hex: String)] = [
        (["kirmizi", "kirmizisi"], "#e5322d"), (["mavi", "mavisi"], "#2563eb"), (["yesil", "yesili"], "#16a34a"),
        (["turuncu"], "#f97316"), (["mor"], "#7c3aed"), (["pembe"], "#ec4899"), (["sari"], "#eab308"),
        (["turkuaz"], "#0d9488"), (["lacivert"], "#1e3a8a"), (["bordo"], "#9f1239"), (["kahverengi"], "#92400e"),
        (["siyah"], "#111827"), (["gri"], "#6b7280")
    ]

    private static func hexColor(in clause: String) -> String? {
        if let range = clause.range(of: #"#[0-9a-f]{6}\b"#, options: .regularExpression) { return String(clause[range]) }
        let tokens = Set(clause.split { !$0.isLetter }.map(String.init))
        for color in colors where color.words.contains(where: { tokens.contains($0) }) { return color.hex }
        return nil
    }

    private static func has(_ clause: String, _ pattern: String) -> Bool { clause.range(of: pattern, options: .regularExpression) != nil }

    // MARK: One part of a request

    private static func applyClause(_ clause: String, original: String, files: [String: String]) -> ([String: String], String)? {
        // Anything that adds, removes or changes behaviour belongs to the writer.
        if has(clause, #"\b(ekle|ekleme|sil|kaldir|degistir(?!\s*$)|olustur|calisma|islev|davranis|hesapla|yeni|sayfa|dosya|animasyon|resim|gorsel)\w*"#), !has(clause, #"basli[kg]"#) { return nil }

        // Title: Başlığı 'X' yap
        if has(clause, #"basli[kg]"#) {
            guard let title = quoted(in: original) else { return nil }
            return setTitle(title, in: files).map { ($0, "Başlık “\(title)” oldu") }
        }
        // Theme
        if has(clause, #"\b(tema|mod|modu)\b"#) || has(clause, #"\btemay"#) {
            if has(clause, #"\b(koyu|karanlik|gece|dark)\b"#) { return setPalette(dark: true, in: files).map { ($0, "Koyu tema") } }
            if has(clause, #"\b(acik|aydinlik|gunduz|light)\b"#) { return setPalette(dark: false, in: files).map { ($0, "Açık tema") } }
            return nil
        }
        // Corners
        if has(clause, #"\b(yuvarlak|keskin|kare|kosesiz|yuvarlat)\w*"#) {
            let buttons = has(clause, #"\b(buton|tus|dugme)\w*"#)
            let sharp = has(clause, #"\b(keskin|kare|kosesiz)\w*"#)
            if buttons { return setVariables(["--radius-btn": sharp ? "0px" : "999px"], in: files).map { ($0, sharp ? "Düğmeler köşeli" : "Düğmeler yuvarlak") } }
            return setVariables(sharp ? ["--radius": "0px", "--radius-btn": "0px"] : ["--radius": "28px", "--radius-btn": "20px"], in: files).map { ($0, sharp ? "Köşeler keskin" : "Köşeler daha yuvarlak") }
        }
        // Text size
        if has(clause, #"\b(yazi|font|punto|boyut|puntosu|yazilar)\w*"#), has(clause, #"\b(buyut|artir|buyuk|kucult|azalt|kucuk)\w*"#) {
            let bigger = has(clause, #"\b(buyut|artir|buyuk)\w*"#)
            guard let current = variable("--text-size", in: files).flatMap({ Double($0.replacingOccurrences(of: "px", with: "").trimmingCharacters(in: .whitespaces)) }) else { return nil }
            let next = min(28, max(12, current + (bigger ? 2 : -2)))
            return setVariables(["--text-size": "\(Int(next))px"], in: files).map { ($0, bigger ? "Yazı büyüdü" : "Yazı küçüldü") }
        }
        // Colour
        if let hex = hexColor(in: clause) {
            if has(clause, #"arka\s*plan|zemin"#) { return setBackground(hex, in: files).map { ($0, "Arka plan rengi değişti") } }
            if has(clause, #"yazi\s*renk|metin\s*renk|yazilar"#) { return setVariables(["--fg": hex], in: files).map { ($0, "Yazı rengi değişti") } }
            // "butonları kırmızı yap", "ana renk mavi", "vurgu rengi turuncu", or just "mavi yap"
            var values = ["--accent": hex, "--accent-fg": foreground(for: hex)]
            if has(clause, #"\b(arka|zemin)"#) { values = [:] }
            return setVariables(values, in: files).map { ($0, "Ana renk değişti") }
        }
        return nil
    }

    private static func quoted(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"['"“”‘’‚„]([^'"“”‘’‚„]{1,60})['"“”‘’‚„]"#), let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        return (text as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Editing the files

    private static let rootBlock = try! NSRegularExpression(pattern: #":root\s*\{[^}]*\}"#, options: [])

    /// The file whose `:root` block holds the design tokens.
    private static func tokenFile(_ files: [String: String]) -> String? {
        files.keys.sorted().first { path in
            guard let text = files[path], path.hasSuffix(".css") || path.hasSuffix(".html") else { return false }
            return rootBlock.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).contains { match in
                (text as NSString).substring(with: match.range).contains("--accent")
            }
        }
    }

    private static func variable(_ name: String, in files: [String: String]) -> String? {
        guard let path = tokenFile(files), let text = files[path],
              let regex = try? NSRegularExpression(pattern: "\(NSRegularExpression.escapedPattern(for: name))\\s*:\\s*([^;}]+)"),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        return (text as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
    }

    /// Sets design tokens in the `:root` block that defines them; nil when a token does not exist there.
    private static func setVariables(_ values: [String: String], in files: [String: String]) -> [String: String]? {
        guard !values.isEmpty, let path = tokenFile(files), var text = files[path] else { return nil }
        for (name, value) in values {
            guard let regex = try? NSRegularExpression(pattern: "(\(NSRegularExpression.escapedPattern(for: name))\\s*:\\s*)[^;}]+") else { return nil }
            let range = NSRange(location: 0, length: (text as NSString).length)
            guard regex.firstMatch(in: text, range: range) != nil else { return nil }
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1\(value)")
        }
        var result = files
        result[path] = text
        return result
    }

    private static let darkPalette = ["--bg": "#0e1014", "--surface": "#1a1d24", "--fg": "#f2f4f8", "--muted": "#9aa3b2", "--border": "#2c313b"]
    private static let lightPalette = ["--bg": "#f5f6f8", "--surface": "#ffffff", "--fg": "#14161a", "--muted": "#6b7280", "--border": "#e2e4e9"]

    private static func setPalette(dark: Bool, in files: [String: String]) -> [String: String]? {
        setVariables(dark ? darkPalette : lightPalette, in: files)
    }

    private static func setBackground(_ hex: String, in files: [String: String]) -> [String: String]? {
        var values = ["--bg": hex]
        // Text must stay readable on the new background.
        values["--fg"] = luminance(hex) < 0.45 ? "#f2f4f8" : "#14161a"
        values["--muted"] = luminance(hex) < 0.45 ? "#b4bcc9" : "#6b7280"
        return setVariables(values, in: files)
    }

    private static func setTitle(_ title: String, in files: [String: String]) -> [String: String]? {
        let escaped = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        var result = files
        var changed = false
        for path in files.keys.sorted() where path.hasSuffix(".html") {
            guard var text = files[path] else { continue }
            if let h1 = try? NSRegularExpression(pattern: #"(<h1\b[^>]*>)[\s\S]*?(</h1>)"#, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: (text as NSString).length)
                if let first = h1.firstMatch(in: text, range: range) {
                    text = (text as NSString).replacingCharacters(in: first.range, with: (text as NSString).substring(with: first.range(at: 1)) + escaped + (text as NSString).substring(with: first.range(at: 2)))
                    changed = true
                }
            }
            if let titleTag = try? NSRegularExpression(pattern: #"(<title>)[\s\S]*?(</title>)"#, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: (text as NSString).length)
                if let first = titleTag.firstMatch(in: text, range: range) {
                    text = (text as NSString).replacingCharacters(in: first.range, with: "<title>\(escaped)</title>")
                    changed = true
                }
            }
            result[path] = text
        }
        return changed ? result : nil
    }

    // MARK: Colour maths

    static func luminance(_ hex: String) -> Double {
        let digits = hex.dropFirst()
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return 0.5 }
        func channel(_ c: Int) -> Double {
            let v = Double(c) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((value >> 16) & 255) + 0.7152 * channel((value >> 8) & 255) + 0.0722 * channel(value & 255)
    }

    /// Text on a coloured button: dark on light colours, white on the rest.
    static func foreground(for hex: String) -> String { luminance(hex) > 0.4 ? "#14161a" : "#ffffff" }
}
