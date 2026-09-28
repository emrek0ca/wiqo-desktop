import Foundation

/// While a reply streams in, only its last block still changes. This finds the point up to which
/// the text is settled, so the parser can keep the earlier part instead of re-reading the whole
/// reply on every update (which made long answers stutter).
///
/// It only ever cuts at a blank line that is safe: never inside a code fence or an open math
/// delimiter, and never next to a list item, quote line, table row or indented line, because cutting there would
/// turn one block into two and change how the reply looks.
enum ReplyStreamSplitter {
    private struct OpenMath {
        let start: String.Index
        let contentStart: String.Index
        let closing: String
    }

    /// Code spans/fences are matched as opaque tokens first; math delimiters inside code are text.
    private static let mathOrCodeTokenPattern = try! NSRegularExpression(
        pattern: #"(?:```[\s\S]*?(?:```|$)|~~~[\s\S]*?(?:~~~|$)|`+[^`\n]*`+)|(?<!\\)\$\$|(?<!\\)\$(?!\$)|(?<!\\)\\\(|(?<!\\)\\\)|(?<!\\)\\\[|(?<!\\)\\\]|(?<!\\)\\begin\{(?:equation\*?|align\*?|alignat\*?|gather\*?|multline\*?|CD)\}|(?<!\\)\\end\{(?:equation\*?|align\*?|alignat\*?|gather\*?|multline\*?|CD)\}"#
    )

    /// Hides only the unfinished math expression at the end of a live reply. Prose before it stays
    /// visible, and once its closing delimiter arrives the original text is returned unchanged.
    static func streamingVisibleText(_ text: String) -> String {
        guard let open = unclosedMathStart(in: text) else { return text }
        return String(text[..<open.start])
    }

    /// UTF-8 offset, just after a blank line, up to which `text` is settled. Never less than `known`
    /// (the offset settled by an earlier call on a text this one extends).
    static func settledOffset(in text: String, after known: Int) -> Int {
        let bytes = Array(text.utf8)
        guard known >= 0, known <= bytes.count, !bytes.contains(13) else { return max(known, 0) }

        var boundaries: [Int] = []
        var index = known
        while index + 1 < bytes.count {
            if bytes[index] == 10, bytes[index + 1] == 10 {
                boundaries.append(index + 2)
                index += 2
            } else {
                index += 1
            }
        }

        for cut in boundaries.reversed().prefix(6) {
            guard hasBalancedFencesAndMath(bytes, from: known, to: cut),
                  let before = lineBefore(cut, in: bytes),
                  let after = lineAfter(cut, in: bytes),
                  !isStructural(before), !isStructural(after) else { continue }
            return cut
        }
        return known
    }

    // MARK: - Lines

    /// The last non-blank line before the blank line that ends at `cut`.
    private static func lineBefore(_ cut: Int, in bytes: [UInt8]) -> ArraySlice<UInt8>? {
        var end = cut - 2
        while end > 0, bytes[end - 1] == 10 { end -= 1 }
        guard end > 0 else { return nil }
        var start = end
        while start > 0, bytes[start - 1] != 10 { start -= 1 }
        return bytes[start..<end]
    }

    /// The first non-blank line after `cut`, or nil when nothing follows yet.
    private static func lineAfter(_ cut: Int, in bytes: [UInt8]) -> ArraySlice<UInt8>? {
        var start = cut
        while start < bytes.count, bytes[start] == 10 { start += 1 }
        guard start < bytes.count else { return nil }
        var end = start
        while end < bytes.count, bytes[end] != 10 { end += 1 }
        return bytes[start..<end]
    }

    /// A line that continues a multi-line block (list, quote, table, indented text).
    private static func isStructural(_ line: ArraySlice<UInt8>) -> Bool {
        guard let first = line.first else { return false }
        let start = line.startIndex
        if first == 32 || first == 9 { return true }
        if first == 62 || first == 124 { return true }
        if first == 45 || first == 42 || first == 43, line.count > 1, line[start + 1] == 32 { return true }
        // "• " (U+2022)
        if first == 0xE2, line.count >= 3, line[start + 1] == 0x80, line[start + 2] == 0xA2 { return true }
        var cursor = start
        var digits = 0
        while cursor < line.endIndex, line[cursor] >= 48, line[cursor] <= 57 {
            cursor += 1
            digits += 1
        }
        if digits > 0, cursor + 1 < line.endIndex, line[cursor] == 46 || line[cursor] == 41, line[cursor + 1] == 32 {
            return true
        }
        return false
    }

    // MARK: - Balance

    /// True when every code fence and supported math delimiter opened between the offsets is closed.
    private static func hasBalancedFencesAndMath(_ bytes: [UInt8], from: Int, to: Int) -> Bool {
        var fences = 0
        var lineStart = from
        var index = from
        while index <= to {
            if index == to || bytes[index] == 10 {
                var cursor = lineStart
                while cursor < index, bytes[cursor] == 32 || bytes[cursor] == 9 { cursor += 1 }
                if index - cursor >= 3 {
                    let marker = bytes[cursor]
                    if (marker == 96 || marker == 126), bytes[cursor + 1] == marker, bytes[cursor + 2] == marker {
                        fences += 1
                    }
                }
                lineStart = index + 1
            }
            index += 1
        }

        let segment = String(decoding: bytes[from..<to], as: UTF8.self)
        return fences % 2 == 0 && unclosedMathStart(in: segment) == nil
    }

    private static func unclosedMathStart(in text: String) -> OpenMath? {
        let fullRange = NSRange(text.startIndex..., in: text)
        var openMath: OpenMath?

        for match in mathOrCodeTokenPattern.matches(in: text, range: fullRange) {
            guard let tokenRange = Range(match.range, in: text) else { continue }
            let token = String(text[tokenRange])

            // The first alternative in the regex matches code spans and fences as one token.
            if token.hasPrefix("`") || token.hasPrefix("~~~") { continue }

            if let current = openMath {
                if token == current.closing { openMath = nil }
                continue
            }

            let closing: String
            if token == "$$" { closing = "$$" }
            else if token == "$" { closing = "$" }
            else if token == "\\(" { closing = "\\)" }
            else if token == "\\[" { closing = "\\]" }
            else if token.hasPrefix("\\begin{") {
                let environment = token.dropFirst("\\begin{".count).dropLast()
                closing = "\\end{\(environment)}"
            } else {
                continue
            }

            openMath = OpenMath(start: tokenRange.lowerBound, contentStart: tokenRange.upperBound, closing: closing)
        }

        guard let openMath else { return nil }
        if openMath.closing == "$", !looksLikePartialInlineMath(after: openMath.contentStart, in: text) { return nil }
        return openMath
    }

    /// `$50` is ordinary text; an unfinished `$x` or `$x + y` remains hidden until it closes.
    private static func looksLikePartialInlineMath(after start: String.Index, in text: String) -> Bool {
        guard start < text.endIndex else { return false }
        let first = text[start]
        guard !first.isWhitespace else { return false }
        if first.isLetter { return true }
        let line = text[start...].prefix(while: { $0 != "\n" })
        return line.contains(where: { "\\^_=+-/*".contains($0) })
    }
}
