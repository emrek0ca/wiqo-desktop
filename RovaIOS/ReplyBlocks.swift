import SwiftUI
import UIKit
import WebKit

/// A lightweight, dependency-free breakdown of an assistant reply into the block shapes that
/// actually show up in Wiqo's answers: prose, headings, lists, quotes, rules, code, and tables.
/// Deliberately not a full CommonMark implementation. Unrecognized syntax always degrades to a
/// plain paragraph, and a partially streamed reply (an unclosed code fence, a half-written table)
/// still renders sensibly at every intermediate step.
enum ReplyBlock {
    struct ListItem {
        let marker: String
        let indent: Int
        let text: AttributedString
    }

    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case list([ListItem])
    case quote(AttributedString)
    case rule
    case codeBlock(language: String?, code: String)
    case table(headers: [AttributedString], rows: [[AttributedString]])
    /// A paragraph that contains LaTeX (`$...$` inline or `$$...$$` display, in any mix with
    /// ordinary prose) - rendered via KaTeX's auto-render extension in RichMathTextView, which
    /// finds and typesets the math in place while leaving the surrounding text alone. Covers both
    /// a formula-only line and a sentence with a formula in the middle, in one code path.
    case richText(String)
}

@MainActor
enum ReplyBlockParser {
    // Every already-finished bubble re-parses its (unchanging) text whenever the list re-renders
    // it, e.g. on scroll; caching the whole block list, not just `inline()`'s output, skips that
    // work entirely for text seen before instead of just cutting its cost.
    private static var parseCache: [String: [ReplyBlock]] = [:]
    private static let maxParseCacheEntries = 200

    static func parse(_ text: String) -> [ReplyBlock] {
        if let cached = parseCache[text] { return cached }
        let blocks = parseUncached(text)
        if parseCache.count >= maxParseCacheEntries { parseCache.removeAll(keepingCapacity: true) }
        parseCache[text] = blocks
        return blocks
    }

    private static func parseUncached(_ text: String) -> [ReplyBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [ReplyBlock] = []
        var paragraphLines: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            // Single newlines are kept: the model uses them deliberately ("Sıcaklık: 24°\nNem: %30").
            let joined = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraphLines.removeAll()
            guard !joined.isEmpty else { return }
            blocks.append(containsMath(joined) ? .richText(joined) : .paragraph(inline(joined)))
        }

        while index < lines.count {
            let rawLine = lines[index]
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                flushParagraph()
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                index += 1
                var codeLines: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.codeBlock(language: language.isEmpty ? nil : language, code: codeLines.joined(separator: "\n")))
                continue
            }

            // A `$$` block that spans several lines still needs to be swallowed as one paragraph
            // (rather than split line-by-line into the accumulator, which would let a blank-looking
            // line inside it - there usually isn't one, but a stray one must not fall through to
            // flushParagraph mid-formula) before the ordinary per-line handling below runs.
            if line.hasPrefix("$$"), !(line.hasSuffix("$$") && line.count > 2) {
                var mathLines = [rawLine]
                index += 1
                while index < lines.count {
                    let current = lines[index]
                    mathLines.append(current)
                    if current.trimmingCharacters(in: .whitespaces).hasSuffix("$$") {
                        index += 1
                        break
                    }
                    index += 1
                }
                paragraphLines.append(contentsOf: mathLines)
                continue
            }

            if line.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let headers = tableCells(line)
                index += 2
                var rows: [[AttributedString]] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var cells = tableCells(lines[index])
                    if cells.count < headers.count { cells += Array(repeating: "", count: headers.count - cells.count) }
                    rows.append(cells.prefix(max(headers.count, 1)).map(inline))
                    index += 1
                }
                blocks.append(.table(headers: headers.map(inline), rows: rows))
                continue
            }

            if isRule(line) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let level = headingLevel(line) {
                flushParagraph()
                let content = line.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: inline(content)))
                index += 1
                continue
            }

            if line.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quoteLines.append(current.dropFirst().trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(inline(quoteLines.joined(separator: "\n"))))
                continue
            }

            if listMarker(line) != nil {
                flushParagraph()
                var items: [ReplyBlock.ListItem] = []
                while index < lines.count, let (marker, body) = listMarker(lines[index].trimmingCharacters(in: .whitespaces)) {
                    let leadingSpaces = lines[index].prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                    items.append(.init(marker: marker, indent: min(leadingSpaces / 2, 3), text: inline(body)))
                    index += 1
                }
                blocks.append(.list(items))
                continue
            }

            if line.isEmpty {
                flushParagraph()
            } else {
                paragraphLines.append(line)
            }
            index += 1
        }
        flushParagraph()
        return mergeAdjacentRichText(blocks)
    }

    /// A multi-step derivation typically lands as one `$$...$$` formula per paragraph (blank line
    /// between each), which without this pass would spin up a separate WKWebView per formula - the
    /// exact "slow, cramped, half-rendered" symptom this was built to fix. Two `.richText` blocks
    /// with nothing but blank lines between them (nothing else in `blocks` split them up) get one
    /// shared WebView instead; anything else in between (a heading, a table) still separates them,
    /// since that's still the right visual grouping.
    private static func mergeAdjacentRichText(_ blocks: [ReplyBlock]) -> [ReplyBlock] {
        var merged: [ReplyBlock] = []
        for block in blocks {
            if case .richText(let text) = block, case .richText(let previous)? = merged.last {
                merged[merged.count - 1] = .richText(previous + "\n\n" + text)
            } else {
                merged.append(block)
            }
        }
        return merged
    }

    // While a reply streams, `parse` reruns on the whole accumulated text on every revealed
    // character (see LiveReplyText below) - every block *before* the one still growing has
    // identical source text tick to tick, so memoizing this by its exact input turns what would
    // be a full markdown re-parse of the entire reply, dozens of times a second, into one cache
    // hit per finished block. This is what actually stopped the stutter; the line-splitting in
    // `parse` itself is cheap enough not to need the same treatment.
    private static var inlineCache: [String: AttributedString] = [:]
    private static let maxInlineCacheEntries = 500

    /// Inline markdown (bold, italic, links, `code`). Code spans get a subtle monospaced chip so
    /// they read as code rather than as ordinary prose.
    static func inline(_ raw: String) -> AttributedString {
        if let cached = inlineCache[raw] { return cached }
        guard var attributed = try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(raw)
        }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(.callout, design: .monospaced)
            attributed[run.range].backgroundColor = Color(uiColor: .tertiarySystemFill)
        }
        if inlineCache.count >= maxInlineCacheEntries { inlineCache.removeAll(keepingCapacity: true) }
        inlineCache[raw] = attributed
        return attributed
    }

    private static func headingLevel(_ line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes <= 6, line.count > hashes, line[line.index(line.startIndex, offsetBy: hashes)] == " " else { return nil }
        return hashes
    }

    /// Matches a `$$...$$` display block anywhere, a `$...$` inline span whose body has at least
    /// one LaTeX-ish character (`\`, `^`, `_`, `{`, `}` - that guard is what keeps an ordinary
    /// price mention like "$50 today" from being misread as an unterminated formula), or a
    /// `[[formula:ID]]` marker - the backend's own pre-rendered-SVG replacement for a `$$...$$`
    /// it already typeset server-side (see RichMathWebView's markdownToHTML).
    private static let mathPattern = try! NSRegularExpression(
        pattern: #"\$\$[\s\S]+?\$\$|\$[^$\n]*[\\^_{}][^$\n]*\$|\[\[formula:[^\]]+\]\]"#
    )

    private static func containsMath(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return mathPattern.firstMatch(in: text, range: range) != nil
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// Returns the display marker and the item body for "- x", "* x", "+ x", "• x" and "12. x".
    /// Ordered numbers are capped at three digits so a sentence like "2026. yılda…" stays prose.
    private static func listMarker(_ line: String) -> (String, String)? {
        for prefix in ["- ", "* ", "+ ", "• "] where line.hasPrefix(prefix) {
            return ("•", String(line.dropFirst(prefix.count)))
        }
        let digits = line.prefix(while: \.isNumber)
        guard (1...3).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return ("\(digits).", String(rest.dropFirst(2)))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) } && trimmed.contains("-")
    }

    private static func tableCells(_ line: String) -> [String] {
        line.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// Renders a reply the way ChatGPT/Gemini do: no bubble chrome, clean flowing content, and a
/// distinct minimal container only where structure calls for one (code, tables, quotes).
struct ReplyBlocksView: View {
    let text: String
    /// The message's own artifacts - threaded down to `richText` blocks so a `[[formula:ID]]`
    /// marker (a server-pre-rendered formula SVG) can be resolved and downloaded the same
    /// authenticated way any other artifact already is. Defaulted so existing call sites that
    /// never show formulas (system messages, previews) don't need to pass it.
    var artifacts: [RovaBackendClient.ArtifactDescriptor] = []
    /// True while the reply is still arriving: the newest words resolve softly into place, and
    /// finished apps are not previewed until the code block is complete.
    var isStreaming = false

    var body: some View {
        let blocks = ReplyBlockParser.parse(text)
        VStack(alignment: .leading, spacing: 12) {
            // Positional identity keeps a block's view stable while its content grows during
            // streaming, instead of tearing down and rebuilding it on every revealed character.
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block, fadesTail: isStreaming && index == blocks.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: ReplyBlock, fadesTail: Bool = false) -> some View {
        switch block {
        case .paragraph(let text):
            Text(fadesTail ? WiqoStreamingTail.fade(text) : text)
                .font(.body)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .heading(let level, let text):
            Text(text)
                .font(level <= 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, level <= 2 ? 4 : 0)
                .textSelection(.enabled)
        case .list(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: item.marker == "•" ? 10 : 22, alignment: .trailing)
                        Text(fadesTail && position == items.count - 1 ? WiqoStreamingTail.fade(item.text) : item.text)
                            .font(.body)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(item.indent) * 18)
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .rule:
            Divider().padding(.vertical, 4)
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code, showsAppPreview: !isStreaming)
        case .table(let headers, let rows):
            TableBlockView(headers: headers, rows: rows)
        case .richText(let raw):
            RichMathTextView(raw: raw, artifacts: artifacts)
        }
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String
    /// A finished HTML answer is shown as the running app under the code.
    var showsAppPreview = false
    @State private var showingRun = false

    /// The fence tag on a code block can be any of the common spellings/aliases for what canvas
    /// can actually do, or something else entirely (swift, json, sql, ...) that isn't runnable at
    /// all. Returns the canonical language canvas expects, or nil to hide the "Çalıştır" button
    /// rather than offer a run that can only fail. "html" is rendered live on-device instead of
    /// going through the server sandbox (routes/canvas.ts) that python/javascript/shell use - it's
    /// the one language with an actual interface to show.
    private var runnableLanguage: String? {
        switch language?.lowercased() {
        case "python", "py", "python3": return "python"
        case "javascript", "js", "node", "nodejs", "mjs": return "javascript"
        case "shell", "bash", "sh", "zsh", "shellscript", "console", "terminal": return "shell"
        case "html", "htm": return "html"
        default: return nil
        }
    }

    private var isDiff: Bool {
        guard let tag = language?.lowercased() else { return false }
        return tag == "diff" || tag == "patch"
    }

    /// The page to show as an app: an HTML answer as is, or JavaScript written for the browser.
    private var appHTML: String? {
        guard showsAppPreview else { return nil }
        switch runnableLanguage {
        case "html": return code.contains("<") ? code : nil
        case "javascript": return WiqoHTMLDocument.isBrowserScript(code) ? WiqoHTMLDocument.wrapBrowserScript(code) : nil
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isDiff {
                WiqoCodeBlock(diff: code, title: "değişiklik")
            } else {
                WiqoCodeBlock(
                    code: code,
                    title: language?.lowercased() ?? "kod",
                    onRun: runnableLanguage == nil ? nil : { showingRun = true }
                )
            }
            if let appHTML {
                WiqoAppPreviewCard(html: appHTML) { showingRun = true }
            }
        }
        .sheet(isPresented: $showingRun) {
            if let runnableLanguage {
                CanvasView(language: runnableLanguage, code: code, autoRun: true)
            }
        }
    }
}

/// Lets the newest characters of a streaming reply resolve into place: the last few fade up from
/// faint instead of appearing at full strength, so text feels like it is settling rather than
/// being typed.
enum WiqoStreamingTail {
    static func fade(_ text: AttributedString, tail: Int = 18) -> AttributedString {
        var result = text
        let total = result.characters.count
        guard total > 6 else { return result }
        let segment = max(1, min(tail, total) / 3)
        let steps: [(back: Int, opacity: Double)] = [(3, 0.3), (2, 0.55), (1, 0.8)]
        for step in steps {
            let startOffset = total - segment * step.back
            let endOffset = total - segment * (step.back - 1)
            guard startOffset >= 0, endOffset <= total, startOffset < endOffset else { continue }
            let start = result.characters.index(result.characters.startIndex, offsetBy: startOffset)
            let end = result.characters.index(result.characters.startIndex, offsetBy: endOffset)
            result[start..<end].foregroundColor = Color.primary.opacity(step.opacity)
        }
        return result
    }
}

/// A small, dependency-free, language-agnostic syntax colorizer - one pass over the characters,
/// no per-language grammar. It only needs to make the four things that make code readable at a
/// glance (keywords, strings, comments, numbers) visually distinct; it doesn't try to be a real
/// tokenizer/parser for any specific language, which is exactly enough for a chat code block and
/// avoids pulling in a full highlighting library for it.
enum SyntaxHighlighter {
    private static let keywords: Set<String> = [
        // Cross-language control flow / declarations (Python, JS/TS, Swift, shell, etc.) -
        // deliberately one shared set rather than per-language grammars.
        "func", "let", "var", "if", "else", "elif", "for", "while", "return", "import", "from",
        "class", "struct", "enum", "protocol", "extension", "guard", "switch", "case", "default",
        "break", "continue", "in", "is", "as", "try", "catch", "finally", "except", "throw", "throws",
        "async", "await", "public", "private", "internal", "static", "final", "def", "with", "lambda",
        "yield", "pass", "global", "nonlocal", "raise", "not", "and", "or", "self", "function", "const",
        "new", "this", "typeof", "instanceof", "export", "extends", "implements", "interface", "type",
        "void", "do", "then", "fi", "esac", "echo", "exit", "true", "false", "null", "none", "nil"
    ]

    static func highlight(_ code: String) -> AttributedString {
        var result = AttributedString()
        let characters = Array(code)
        var index = 0
        var word = ""

        func flushWord() {
            guard !word.isEmpty else { return }
            if keywords.contains(word.lowercased()) {
                var styled = AttributedString(word)
                styled.foregroundColor = .purple
                styled.font = .system(.footnote, design: .monospaced).weight(.semibold)
                result += styled
            } else {
                result += AttributedString(word)
            }
            word = ""
        }
        func appendStyled(_ text: String, _ color: Color) {
            var styled = AttributedString(text)
            styled.foregroundColor = color
            result += styled
        }

        while index < characters.count {
            let char = characters[index]

            if char == "#" || (char == "/" && characters[safe: index + 1] == "/") {
                flushWord()
                var comment = ""
                while index < characters.count, characters[index] != "\n" {
                    comment.append(characters[index])
                    index += 1
                }
                appendStyled(comment, .secondary)
                continue
            }
            if char == "/" && characters[safe: index + 1] == "*" {
                flushWord()
                var comment = "/*"
                index += 2
                while index < characters.count, !(characters[index] == "*" && characters[safe: index + 1] == "/") {
                    comment.append(characters[index])
                    index += 1
                }
                if index < characters.count { comment += "*/"; index += 2 }
                appendStyled(comment, .secondary)
                continue
            }
            if char == "\"" || char == "'" || char == "`" {
                flushWord()
                let quote = char
                var string = String(quote)
                index += 1
                while index < characters.count, characters[index] != quote {
                    if characters[index] == "\\", index + 1 < characters.count {
                        string.append(characters[index])
                        string.append(characters[index + 1])
                        index += 2
                        continue
                    }
                    string.append(characters[index])
                    index += 1
                }
                if index < characters.count { string.append(quote); index += 1 }
                appendStyled(string, .green)
                continue
            }
            if char.isNumber, word.isEmpty {
                var number = ""
                while index < characters.count, characters[index].isNumber || characters[index] == "." {
                    number.append(characters[index])
                    index += 1
                }
                appendStyled(number, .orange)
                continue
            }
            if char.isLetter || char == "_" {
                word.append(char)
                index += 1
                continue
            }
            flushWord()
            result += AttributedString(String(char))
            index += 1
        }
        flushWord()
        return result
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// A markdown table rendered as a real, small data widget - tap a header to sort by that column
/// (numeric-aware), and a search field appears once a table has enough rows that finding one row
/// by scanning is actually a chore. Both are pure client-side, computed straight from the same
/// headers/rows the plain render already had; nothing about how the model produces a table needed
/// to change for this.
private struct TableBlockView: View {
    let headers: [AttributedString]
    let rows: [[AttributedString]]

    @State private var sortColumn: Int?
    @State private var sortAscending = true
    @State private var filterText = ""

    /// Plain-text mirror of `rows`, computed once per render rather than per comparison - sorting
    /// and filtering both need to compare raw text, not AttributedString runs.
    private var plainRows: [[String]] {
        rows.map { row in row.map { String($0.characters) } }
    }

    private var filteredIndices: [Int] {
        guard !filterText.isEmpty else { return Array(rows.indices) }
        let needle = filterText.localizedLowercase
        let values = plainRows
        return rows.indices.filter { index in values[index].contains { $0.localizedLowercase.contains(needle) } }
    }

    private var sortedIndices: [Int] {
        guard let sortColumn, headers.indices.contains(sortColumn) else { return filteredIndices }
        let values = plainRows
        return filteredIndices.sorted { a, b in
            let left = values[a][safe: sortColumn] ?? ""
            let right = values[b][safe: sortColumn] ?? ""
            let ascending: Bool
            if let leftNumber = Double(left.replacingOccurrences(of: ",", with: ".")),
               let rightNumber = Double(right.replacingOccurrences(of: ",", with: ".")) {
                ascending = leftNumber < rightNumber
            } else {
                ascending = left.localizedStandardCompare(right) == .orderedAscending
            }
            return sortAscending ? ascending : !ascending
        }
    }

    private var isFilterable: Bool { rows.count > 5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isFilterable {
                filterField
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                            headerCell(header, column: index)
                        }
                    }
                    .background(Color(uiColor: .tertiarySystemFill))
                    ForEach(Array(sortedIndices.enumerated()), id: \.offset) { position, rowIndex in
                        Divider().gridCellColumns(max(headers.count, 1))
                        GridRow {
                            ForEach(Array(rows[rowIndex].enumerated()), id: \.offset) { _, value in
                                cell(value, isHeader: false)
                            }
                        }
                        .background(position.isMultiple(of: 2) ? Color.clear : Color(uiColor: .quaternarySystemFill))
                    }
                }
            }
            if isFilterable, !filterText.isEmpty {
                Text("\(sortedIndices.count) / \(rows.count) satır")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
        }
        .padding(isFilterable ? 10 : 0)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5))
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("Tabloda ara", text: $filterText)
                .font(.caption)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !filterText.isEmpty {
                Button { filterText = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func headerCell(_ value: AttributedString, column: Int) -> some View {
        Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = true
            }
        } label: {
            HStack(spacing: 3) {
                Text(value)
                    .font(.footnote.weight(.semibold))
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                }
            }
            .frame(minWidth: 72, maxWidth: 240, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func cell(_ value: AttributedString, isHeader: Bool) -> some View {
        Text(value)
            .font(isHeader ? .footnote.weight(.semibold) : .footnote)
            .frame(minWidth: 72, maxWidth: 240, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .textSelection(.enabled)
    }
}

/// Renders a paragraph (or several merged ones - see `mergeAdjacentRichText`) that mixes ordinary
/// prose with LaTeX - a formula-only line, a sentence with one inline `$...$` in the middle, a
/// `[[formula:ID]]` reference to a formula the backend already rendered to SVG server-side, or any
/// mix of these - via a single WKWebView per merged group instead of one per formula. Auto-render
/// finds every remaining `$...$`/`$$...$$` span in the content and typesets just that span, so
/// plain text and live-rendered math can sit in the same line without Swift splitting them apart.
///
/// A `[[formula:ID]]` marker is resolved by downloading that artifact - the same authenticated
/// path any other artifact already uses - and inlined as a `data:` image, so the heavy formula
/// itself never touches the CDN-dependent client-side KaTeX path at all; only whatever raw `$...$`
/// the backend left alone (typically short inline symbols) still goes through auto-render.
private struct RichMathTextView: View {
    let raw: String
    let artifacts: [RovaBackendClient.ArtifactDescriptor]
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 24
    /// Formula ID -> the artifact's own SVG markup (spliced directly into the page as inline
    /// `<svg>`, not a `data:` `<img>`) - MathJax's SVG output paints with `fill="currentColor"`
    /// so the formula picks up the surrounding text color (and so follows light/dark mode
    /// correctly); an `<img>` can't do that, since a `data:`-sourced image is an opaque replaced
    /// element with no CSS inheritance from the page around it.
    @State private var resolvedSVGs: [String: String] = [:]
    @State private var didResolve = false

    private static let formulaMarkerPattern = try! NSRegularExpression(pattern: #"\[\[formula:([^\]]+)\]\]"#)

    private var referencedFormulaIDs: [String] {
        let range = NSRange(raw.startIndex..., in: raw)
        return Self.formulaMarkerPattern.matches(in: raw, range: range).compactMap {
            Range($0.range(at: 1), in: raw).map { String(raw[$0]) }
        }
    }

    var body: some View {
        Group {
            if didResolve {
                RichMathWebView(raw: raw, formulaSVGs: resolvedSVGs, colorScheme: colorScheme, height: $height)
                    .frame(height: height)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: raw) {
            await resolveSVGs()
        }
    }

    private func resolveSVGs() async {
        let ids = referencedFormulaIDs
        guard !ids.isEmpty else {
            didResolve = true
            return
        }
        var resolved: [String: String] = [:]
        for id in ids {
            guard let artifact = artifacts.first(where: { $0.id == id }) else { continue }
            if let url = try? await RovaBackendClient.downloadArtifact(artifact),
               let data = try? Data(contentsOf: url),
               let svg = String(data: data, encoding: .utf8) {
                resolved[id] = svg
            }
        }
        resolvedSVGs = resolved
        didResolve = true
    }
}

private struct RichMathWebView: UIViewRepresentable {
    let raw: String
    /// Formula ID -> raw `<svg>...</svg>` markup, spliced directly into the page (see
    /// RichMathTextView's doc comment for why this has to be inline markup, not an `<img>`).
    let formulaSVGs: [String: String]
    let colorScheme: ColorScheme
    @Binding var height: CGFloat

    /// Whether anything in this block still needs the live, CDN-loaded KaTeX renderer - false for
    /// the now-common case where the backend already pre-rendered every `$$...$$` to SVG and
    /// nothing but plain text and `[[formula:ID]]` markers remains. Skipping KaTeX entirely in
    /// that case is a real speed win on mobile: no external script fetch, no font wait, no
    /// auto-render scan - just local HTML and already-downloaded SVGs.
    private var needsLiveKaTeX: Bool {
        raw.replacingOccurrences(of: #"\[\[formula:[^\]]+\]\]"#, with: "", options: .regularExpression).contains("$")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "heightReporter")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let cacheKey = "\(colorScheme)|\(raw)|\(formulaSVGs.count)"
        guard context.coordinator.lastRendered != cacheKey else { return }
        context.coordinator.lastRendered = cacheKey
        let textColor = colorScheme == .dark ? "#f2f2f7" : "#111318"
        let katexHead = needsLiveKaTeX ? """
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"></script>
        """ : ""
        let katexRender = needsLiveKaTeX ? """
          try {
            renderMathInElement(document.getElementById('content'), {
              delimiters: [
                {left: "$$", right: "$$", display: true},
                {left: "$", right: "$", display: false}
              ],
              throwOnError: false
            });
          } catch (e) {}
        """ : ""
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        \(katexHead)
        <style>
          html,body{margin:0;padding:0;background:transparent;color:\(textColor);}
          #content{font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;font-size:17px;line-height:1.42;word-wrap:break-word;}
          #content p{margin:0.35em 0;}
          #content p:first-child{margin-top:0;}
          #content p:last-child{margin-bottom:0;}
          #content code{font-family:ui-monospace,Menlo,monospace;font-size:15px;background:rgba(127,127,127,0.16);border-radius:4px;padding:1px 4px;}
          #content svg{display:block;max-width:100%;height:auto;margin:0.4em 0;}
          .katex-display{margin:0.5em 0;overflow-x:auto;overflow-y:hidden;}
          .katex-error{color:#e5484d;}
        </style>
        </head><body>
        <div id="content">\(markdownToHTML(raw))</div>
        <script>
          \(katexRender)
          // Report height once fonts are actually ready (KaTeX's web fonts can shift layout after
          // the load event, which is what used to clip fraction denominators) and again on any
          // later size change (ResizeObserver), instead of a single guessed delay - both robust to
          // however long the network happens to take.
          function reportHeight() {
            var h = document.getElementById('content').scrollHeight;
            window.webkit.messageHandlers.heightReporter.postMessage(h);
          }
          reportHeight();
          if (document.fonts && document.fonts.ready) {
            document.fonts.ready.then(reportHeight).catch(reportHeight);
          }
          new ResizeObserver(reportHeight).observe(document.getElementById('content'));
        </script>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "heightReporter")
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Just enough markdown to match what `inline()` already renders for plain paragraphs (bold,
    /// italic, inline code), plus `[[formula:ID]]` substitution - deliberately not a general
    /// converter, since this path only exists for paragraphs that also contain LaTeX. Paragraph
    /// breaks (`\n\n`, from merging several formula-only paragraphs into one WebView) become
    /// separate `<p>` tags so the stacked-formula look still reads as distinct steps; a single
    /// `\n` within one paragraph stays a soft `<br>`, as before.
    private func markdownToHTML(_ text: String) -> String {
        text.components(separatedBy: "\n\n").map { paragraph -> String in
            var html = escapeHTML(paragraph)
            html = replaceFormulaMarkers(in: html)
            html = html.replacingOccurrences(of: #"\*\*([^*\n]+)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
            html = html.replacingOccurrences(of: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, with: "<i>$1</i>", options: .regularExpression)
            html = html.replacingOccurrences(of: #"`([^`\n]+)`"#, with: "<code>$1</code>", options: .regularExpression)
            html = html.replacingOccurrences(of: "\n", with: "<br>")
            return "<p>\(html)</p>"
        }.joined()
    }

    private func replaceFormulaMarkers(in html: String) -> String {
        var result = html
        for (id, svg) in formulaSVGs {
            result = result.replacingOccurrences(of: "[[formula:\(id)]]", with: svg)
        }
        // Any marker that never resolved (artifact expired, download failed) degrades to a short
        // visible note instead of silently vanishing.
        result = result.replacingOccurrences(of: #"\[\[formula:[^\]]+\]\]"#, with: "[formül yüklenemedi]", options: .regularExpression)
        return result
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        @Binding var height: CGFloat
        var lastRendered: String?

        init(height: Binding<CGFloat>) {
            _height = height
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? NSNumber, value.doubleValue > 4 else { return }
            let next = max(20, CGFloat(value.doubleValue))
            DispatchQueue.main.async { self.height = next }
        }
    }
}

/// Paces how the reply appears on screen. Groq delivers a whole answer in a fraction of a second,
/// which would otherwise land as one jump; this reveals it at a steady reading rhythm that speeds
/// up when a lot of text is still queued, so it never falls far behind the network.
@MainActor
final class LiveReplyText: ObservableObject {
    @Published private(set) var displayed = ""
    private var target = ""
    private var revealTask: Task<Void, Never>?

    func append(_ delta: String) {
        target += delta
        startRevealing()
    }

    func reset() {
        revealTask?.cancel()
        revealTask = nil
        target = ""
        displayed = ""
    }

    /// Reveals the authoritative final reply and returns once it is fully on screen. The server's
    /// final text is sanitized and may carry appended notes, so it replaces what streamed.
    func finish(with finalText: String) async {
        let shown = displayed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !shown.isEmpty, !finalText.hasPrefix(shown) {
            revealTask?.cancel()
            revealTask = nil
            target = finalText
            displayed = finalText
            return
        }
        target = finalText
        displayed = String(finalText.prefix(shown.count))
        startRevealing()
        while displayed.count < target.count, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func startRevealing() {
        guard revealTask == nil else { return }
        revealTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let remaining = self.target.count - self.displayed.count
                if remaining <= 0 { break }
                let step = max(3, remaining / 12)
                self.displayed = String(self.target.prefix(self.displayed.count + step))
                try? await Task.sleep(nanoseconds: 22_000_000)
            }
            self?.revealTask = nil
        }
    }
}
