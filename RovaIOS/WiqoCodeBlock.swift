import SwiftUI
import UIKit

/// One rendered line of a code listing or unified diff.
private struct WiqoCodeLine: Identifiable {
    enum Kind { case plain, added, removed }

    let id: Int
    let number: Int?
    let kind: Kind
    let text: AttributedString
}

/// A line-numbered code panel with a syntax-coloured listing and a unified-diff variant. Lines
/// wrap instead of scrolling sideways, so code stays readable at phone width.
struct WiqoCodeBlock: View {
    private enum Mode { case listing, diff }

    let title: String
    var onRun: (() -> Void)? = nil

    private let mode: Mode
    private let raw: String
    private let lines: [WiqoCodeLine]
    private let addedCount: Int
    private let removedCount: Int

    @State private var copied = false

    /// Listings above this size skip the gutter and render as one text run, which keeps very long
    /// code responsive.
    private static let numberedLineLimit = 300

    init(code: String, title: String, onRun: (() -> Void)? = nil) {
        self.title = title
        self.onRun = onRun
        self.mode = .listing
        self.raw = code
        self.lines = Self.listingLines(code)
        self.addedCount = 0
        self.removedCount = 0
    }

    /// `unified` is the text of a unified diff (`+`/`-`/space prefixed lines, `@@` hunk headers).
    init(diff unified: String, title: String) {
        self.title = title
        self.onRun = nil
        self.mode = .diff
        self.raw = unified
        let parsed = Self.diffLines(unified)
        self.lines = parsed
        self.addedCount = parsed.filter { $0.kind == .added }.count
        self.removedCount = parsed.filter { $0.kind == .removed }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(WiqoTheme.line).frame(height: 0.5)
            content
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiqoCard(radius: 14)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: mode == .diff ? "plus.forwardslash.minus" : "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WiqoTheme.ink3)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)

            if mode == .diff {
                HStack(spacing: 8) {
                    Text("+\(addedCount)").foregroundStyle(WiqoTheme.green)
                    Text("−\(removedCount)").foregroundStyle(WiqoTheme.red)
                }
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .monospacedDigit()
            } else {
                if let onRun {
                    Button(action: onRun) {
                        Label("Çalıştır", systemImage: "play.fill")
                            .font(.caption.weight(.medium))
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                copyButton
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = raw
            WiqoHaptics.selection()
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            Label(copied ? "Kopyalandı" : "Kopyala", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.medium))
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? WiqoTheme.green : Color.secondary)
        .wiqoAnimation(WiqoMotion.ease(0.2), value: copied)
    }

    @ViewBuilder
    private var content: some View {
        if mode == .listing, lines.count > Self.numberedLineLimit {
            Text(SyntaxHighlighter.highlight(raw))
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    row(line)
                }
            }
            .overlay(alignment: .leading) {
                Rectangle().fill(WiqoTheme.line).frame(width: 0.5).padding(.leading, 34)
            }
        }
    }

    private func row(_ line: WiqoCodeLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.number.map { String($0) } ?? "")
                .font(.system(.caption2, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(gutterColor(line.kind))
                .frame(width: 34, alignment: .center)
                .accessibilityHidden(true)
            Text(line.text.characters.isEmpty ? AttributedString(" ") : line.text)
                .font(.system(.footnote, design: .monospaced))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .padding(.trailing, 12)
        }
        .padding(.vertical, 1)
        .background(rowBackground(line.kind))
        .overlay(alignment: .leading) {
            if line.kind != .plain {
                Rectangle()
                    .fill(line.kind == .added ? WiqoTheme.green : WiqoTheme.red)
                    .frame(width: 3)
            }
        }
    }

    private func gutterColor(_ kind: WiqoCodeLine.Kind) -> Color {
        switch kind {
        case .plain: return WiqoTheme.ink3
        case .added: return WiqoTheme.green
        case .removed: return WiqoTheme.red
        }
    }

    private func rowBackground(_ kind: WiqoCodeLine.Kind) -> Color {
        switch kind {
        case .plain: return .clear
        case .added: return WiqoTheme.tint(WiqoTheme.green)
        case .removed: return WiqoTheme.tint(WiqoTheme.red)
        }
    }

    // MARK: - Parsing

    /// Highlights the whole listing once and then cuts it at newlines, so a multi-line string or
    /// comment keeps its colour on every line it spans.
    private static func listingLines(_ code: String) -> [WiqoCodeLine] {
        let source = code.trimmingCharacters(in: .newlines)
        guard !source.isEmpty else { return [] }
        let highlighted = SyntaxHighlighter.highlight(source)
        var result: [WiqoCodeLine] = []
        let characters = highlighted.characters
        var lineStart = characters.startIndex
        var cursor = characters.startIndex
        while cursor < characters.endIndex {
            if characters[cursor] == "\n" {
                result.append(WiqoCodeLine(
                    id: result.count,
                    number: result.count + 1,
                    kind: .plain,
                    text: AttributedString(highlighted[lineStart..<cursor])
                ))
                cursor = characters.index(after: cursor)
                lineStart = cursor
            } else {
                cursor = characters.index(after: cursor)
            }
        }
        result.append(WiqoCodeLine(
            id: result.count,
            number: result.count + 1,
            kind: .plain,
            text: AttributedString(highlighted[lineStart..<characters.endIndex])
        ))
        return result
    }

    /// Reads a unified diff. File headers (`---`/`+++`) and hunk markers (`@@`) are not code and
    /// are dropped; the gutter counts new-file lines, and removed lines keep their old number.
    private static func diffLines(_ unified: String) -> [WiqoCodeLine] {
        var result: [WiqoCodeLine] = []
        var oldNumber = 0
        var newNumber = 0
        for raw in unified.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { continue }
            if line.hasPrefix("@@") {
                let numbers = hunkStart(line)
                oldNumber = numbers.old
                newNumber = numbers.new
                continue
            }
            let kind: WiqoCodeLine.Kind
            let body: String
            let number: Int
            if line.hasPrefix("+") {
                kind = .added
                body = String(line.dropFirst())
                newNumber += 1
                number = newNumber
            } else if line.hasPrefix("-") {
                kind = .removed
                body = String(line.dropFirst())
                oldNumber += 1
                number = oldNumber
            } else {
                kind = .plain
                body = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                oldNumber += 1
                newNumber += 1
                number = newNumber
            }
            result.append(WiqoCodeLine(id: result.count, number: number, kind: kind, text: SyntaxHighlighter.highlight(body)))
        }
        while let last = result.last, last.kind == .plain, last.text.characters.isEmpty { result.removeLast() }
        return result
    }

    /// `@@ -12,4 +12,6 @@` → the line numbers *before* the first line of the hunk.
    private static func hunkStart(_ header: String) -> (old: Int, new: Int) {
        var old = 0
        var new = 0
        for part in header.split(separator: " ") {
            if part.hasPrefix("-"), let value = Int(part.dropFirst().split(separator: ",").first ?? "") {
                old = value - 1
            } else if part.hasPrefix("+"), let value = Int(part.dropFirst().split(separator: ",").first ?? "") {
                new = value - 1
            }
        }
        return (max(old, 0), max(new, 0))
    }
}
