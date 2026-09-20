import Foundation

/// While a reply streams in, only its last block still changes. This finds the point up to which
/// the text is settled, so the parser can keep the earlier part instead of re-reading the whole
/// reply on every update (which made long answers stutter).
///
/// It only ever cuts at a blank line that is safe: never inside a code fence or a `$$` block, and
/// never next to a list item, quote line, table row or indented line, because cutting there would
/// turn one block into two and change how the reply looks.
enum ReplyStreamSplitter {
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

    /// True when every code fence and every `$$` opened between the two offsets is also closed.
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

        var displayMath = 0
        index = from
        while index + 1 < to {
            if bytes[index] == 36, bytes[index + 1] == 36 {
                displayMath += 1
                index += 2
            } else {
                index += 1
            }
        }
        return fences % 2 == 0 && displayMath % 2 == 0
    }
}
