import Compression
import Foundation
import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers
import Vision

/// What Wiqo sends for a file the user attached: its content, read on this phone. The file itself
/// never leaves the device. Mirrors the backend's `contracts/fileContent.ts`; change both together.
struct FileContent: Codable, Equatable, Sendable {
    struct Table: Codable, Equatable, Sendable {
        var name: String
        var columns: [String]
        var rows: [[String]]
    }

    enum Kind: String, Codable, Sendable {
        case pdf, docx, xlsx, pptx, csv, text, image, scan
    }

    enum Source: String, Codable, Sendable {
        case text, ocr
    }

    var name: String
    var type: Kind
    var byteCount: Int
    var pageCount: Int?
    var source: Source
    var text: String
    var tables: [Table]
    var truncated: Bool
}

enum FileContentError: LocalizedError {
    case unsupported
    case unreadable
    case empty
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Bu dosya türü desteklenmiyor. PDF, Word, Excel, PowerPoint, CSV, metin veya görsel ekleyebilirsin.")
        case .unreadable: String(localized: "Dosya açılamadı; bozuk ya da parola korumalı olabilir.")
        case .empty: String(localized: "Dosyada okunabilir içerik bulunamadı.")
        case .tooLarge: String(localized: "Dosya 50 MB sınırını aşıyor. Daha küçük bir sürüm ekleyebilirsin.")
        }
    }
}

/// Reads attached files on device with Apple's own frameworks - PDFKit for PDF text, Vision for
/// scans, images and image-only PDF pages, and a small ZIP + XMLParser reader for Office files -
/// then trims the result to the backend's limits. Everything runs off the main actor.
enum FileContentExtractor {
    /// Same limits as the backend schema; the phone cuts, the server only validates.
    static let maxTextCharacters = 400_000
    static let maxTables = 5
    static let maxTableRows = 200
    static let maxTableColumns = 40
    static let maxCells = 6_000
    static let maxCellCharacters = 300
    static let maxSourceBytes = 50 * 1024 * 1024
    static let maxDocumentPages = 200
    static let maxScanPages = 10
    static let maxImagePixelDimension = 2_200
    /// OCR is the slow part; long image-only PDFs are recognized up to this many pages.
    static let maxOCRPages = 30

    /// Types offered in the file picker.
    static let supportedTypes: [UTType] = {
        var types: [UTType] = [.pdf, .commaSeparatedText, .tabSeparatedText, .plainText, .json, .rtf, .image]
        for ext in ["docx", "xlsx", "pptx", "md"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    static func extract(from url: URL) async throws -> FileContent {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try extractSync(from: url)
        }.value
    }

    /// Pages from the document camera: recognized with Vision into one "scan" file.
    static func extract(scannedPages: [UIImage], name: String, wasTruncated: Bool = false) async throws -> FileContent {
        let selectedPages = scannedPages.prefix(maxScanPages)
        let images = selectedPages.compactMap(\.cgImage)
        let sourceWasTruncated = wasTruncated || scannedPages.count > maxScanPages || images.count < selectedPages.count
        return try await Task.detached(priority: .userInitiated) {
            let pages = images.map { recognizeText(in: $0) }
            let text = pages.enumerated()
                .map { index, page in pages.count > 1 ? "--- Sayfa \(index + 1) ---\n\(page)" : page }
                .joined(separator: "\n\n")
            let content = finalize(name: name, type: .scan, byteCount: 0, pageCount: images.count, source: .ocr, text: text, tables: [], sourceWasTruncated: sourceWasTruncated)
            guard !content.text.isEmpty else { throw FileContentError.empty }
            return content
        }.value
    }

    // MARK: - Dispatch

    private static func extractSync(from url: URL) throws -> FileContent {
        let name = url.lastPathComponent
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let byteCount = values.fileSize, byteCount >= 0 else {
            throw FileContentError.unreadable
        }
        guard byteCount <= maxSourceBytes else { throw FileContentError.tooLarge }
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        let content: FileContent
        switch ext {
        case "pdf":
            content = try readPDF(url: url, name: name, byteCount: byteCount)
        case "docx":
            content = try readDOCX(url: url, name: name, byteCount: byteCount)
        case "xlsx":
            content = try readXLSX(url: url, name: name, byteCount: byteCount)
        case "pptx":
            content = try readPPTX(url: url, name: name, byteCount: byteCount)
        case "csv", "tsv":
            let text = try readText(url: url)
            let parsed = parseDelimited(text, separator: ext == "tsv" ? "\t" : detectSeparator(text), name: name)
            content = finalize(name: name, type: .csv, byteCount: byteCount, pageCount: nil, source: .text, text: "", tables: [parsed.table], sourceWasTruncated: parsed.truncated)
        case "rtf":
            let attributed = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            content = finalize(name: name, type: .text, byteCount: byteCount, pageCount: nil, source: .text, text: attributed.string, tables: [])
        default:
            if type?.conforms(to: .image) == true {
                guard let image = downsampleImage(url: url) else { throw FileContentError.unreadable }
                content = finalize(name: name, type: .image, byteCount: byteCount, pageCount: nil, source: .ocr, text: recognizeText(in: image), tables: [])
            } else if type?.conforms(to: .text) == true || ["txt", "md", "json", "log", "xml", "html"].contains(ext) {
                content = finalize(name: name, type: .text, byteCount: byteCount, pageCount: nil, source: .text, text: try readText(url: url), tables: [])
            } else {
                throw FileContentError.unsupported
            }
        }
        guard !content.text.isEmpty || !content.tables.isEmpty else { throw FileContentError.empty }
        return content
    }

    // MARK: - PDF

    private static func readPDF(url: URL, name: String, byteCount: Int) throws -> FileContent {
        guard let document = PDFDocument(url: url) else { throw FileContentError.unreadable }
        if document.isLocked { throw FileContentError.unreadable }
        var pages: [String] = []
        var usedOCR = false
        var totalCharacters = 0
        var ocrPages = 0
        let pageLimit = min(document.pageCount, maxDocumentPages)
        var sourceWasTruncated = document.pageCount > pageLimit || document.pageCount > 10_000
        for index in 0..<pageLimit {
            guard totalCharacters < maxTextCharacters, let page = document.page(at: index) else {
                sourceWasTruncated = true
                break
            }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A page with (almost) no text layer is a scan: recognize its pixels instead.
            if text.count < 20, ocrPages < maxOCRPages, let image = render(page) {
                let recognized = recognizeText(in: image)
                if recognized.count > text.count {
                    text = recognized
                    usedOCR = true
                }
                ocrPages += 1
            }
            totalCharacters += text.count
            pages.append(document.pageCount > 1 ? "--- Sayfa \(index + 1) ---\n\(text)" : text)
        }
        return finalize(name: name, type: .pdf, byteCount: byteCount, pageCount: min(document.pageCount, 10_000), source: usedOCR ? .ocr : .text, text: pages.joined(separator: "\n\n"), tables: [], sourceWasTruncated: sourceWasTruncated)
    }

    private static func downsampleImage(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImagePixelDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // ~2x of a letter page is enough for Vision's accurate mode without a huge bitmap.
        let scale = min(2.5, 1_700 / max(bounds.width, bounds.height))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox).cgImage
    }

    // MARK: - OCR

    private static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["tr-TR", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let observations = request.results else { return "" }
        // Vision returns lines top to bottom in reading order.
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    // MARK: - Office (ZIP + XML)

    private static func readDOCX(url: URL, name: String, byteCount: Int) throws -> FileContent {
        guard let archive = ZipArchive(url: url), let xml = archive.read("word/document.xml") else { throw FileContentError.unreadable }
        let parser = DocxTextParser()
        guard parser.parse(xml) else { throw FileContentError.unreadable }
        return finalize(name: name, type: .docx, byteCount: byteCount, pageCount: nil, source: .text, text: parser.text, tables: [])
    }

    private static func readPPTX(url: URL, name: String, byteCount: Int) throws -> FileContent {
        guard let archive = ZipArchive(url: url) else { throw FileContentError.unreadable }
        let slides = archive.paths
            .compactMap { path -> (Int, String)? in
                guard path.hasPrefix("ppt/slides/slide"), path.hasSuffix(".xml"),
                      let number = Int(path.dropFirst("ppt/slides/slide".count).dropLast(4)) else { return nil }
                return (number, path)
            }
            .sorted { $0.0 < $1.0 }
        let selectedSlides = Array(slides.prefix(maxDocumentPages))
        var sourceWasTruncated = slides.count > selectedSlides.count || slides.count > 10_000
        var parts: [String] = []
        for (number, path) in selectedSlides {
            guard let xml = archive.read(path) else {
                sourceWasTruncated = true
                continue
            }
            let parser = ParagraphTextParser(textElement: "a:t", paragraphElement: "a:p")
            guard parser.parse(xml) else {
                sourceWasTruncated = true
                continue
            }
            parts.append("--- Slayt \(number) ---\n\(parser.text)")
        }
        return finalize(name: name, type: .pptx, byteCount: byteCount, pageCount: min(slides.count, 10_000), source: .text, text: parts.joined(separator: "\n\n"), tables: [], sourceWasTruncated: sourceWasTruncated)
    }

    private static func readXLSX(url: URL, name: String, byteCount: Int) throws -> FileContent {
        guard let archive = ZipArchive(url: url), let workbookXML = archive.read("xl/workbook.xml") else { throw FileContentError.unreadable }
        let sharedStrings: [String]
        if archive.contains("xl/sharedStrings.xml") {
            guard let xml = archive.read("xl/sharedStrings.xml") else { throw FileContentError.unreadable }
            let parser = SharedStringsParser()
            guard parser.parse(xml) else { throw FileContentError.unreadable }
            sharedStrings = parser.strings
        } else {
            sharedStrings = []
        }
        let workbook = WorkbookParser()
        guard workbook.parse(workbookXML) else { throw FileContentError.unreadable }
        let relationships: [String: String]
        if archive.contains("xl/_rels/workbook.xml.rels") {
            guard let xml = archive.read("xl/_rels/workbook.xml.rels") else { throw FileContentError.unreadable }
            let parser = RelationshipsParser()
            guard parser.parse(xml) else { throw FileContentError.unreadable }
            relationships = parser.targets
        } else {
            relationships = [:]
        }
        var tables: [FileContent.Table] = []
        let selectedSheets = Array(workbook.sheets.prefix(maxTables))
        var sourceWasTruncated = workbook.sheets.count > selectedSheets.count || workbook.sheets.count > 10_000
        for (index, sheet) in selectedSheets.enumerated() {
            let target = relationships[sheet.relationshipID].map { $0.hasPrefix("/") ? String($0.dropFirst()) : "xl/\($0)" }
                ?? "xl/worksheets/sheet\(index + 1).xml"
            guard let xml = archive.read(target) else { throw FileContentError.unreadable }
            let parser = SheetParser(sharedStrings: sharedStrings, maxRows: maxTableRows + 1, maxColumns: maxTableColumns)
            let parsed = parser.parse(xml)
            guard parsed || parser.sourceWasTruncated else { throw FileContentError.unreadable }
            sourceWasTruncated = sourceWasTruncated || parser.sourceWasTruncated
            let rows = parser.rows.filter { row in row.contains { !$0.isEmpty } }
            guard let header = rows.first else { continue }
            tables.append(FileContent.Table(name: sheet.name, columns: header, rows: Array(rows.dropFirst())))
        }
        return finalize(name: name, type: .xlsx, byteCount: byteCount, pageCount: min(workbook.sheets.count, 10_000), source: .text, text: "", tables: tables, sourceWasTruncated: sourceWasTruncated)
    }

    // MARK: - Text and CSV

    private static func readText(url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if let text = String(data: data, encoding: .utf8) { return text }
        // UTF-16 only with a byte-order mark; otherwise Turkish Windows exports are Windows-1254.
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .windowsCP1254) { return text }
        throw FileContentError.unreadable
    }

    private static func detectSeparator(_ text: String) -> Character {
        let firstLine = text.prefix(while: { $0 != "\n" })
        let candidates: [Character] = [";", ",", "\t"]
        return candidates.max { lhs, rhs in firstLine.filter { $0 == lhs }.count < firstLine.filter { $0 == rhs }.count } ?? ","
    }

    /// RFC 4180: quoted fields may contain the separator, quotes ("") and line breaks.
    private static func parseDelimited(_ text: String, separator: Character, name: String) -> (table: FileContent.Table, truncated: Bool) {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var sourceWasTruncated = false
        var iterator = text.makeIterator()
        var pending: Character?
        func next() -> Character? {
            if let value = pending { pending = nil; return value }
            return iterator.next()
        }
        while let character = next() {
            if rows.count > maxTableRows {
                sourceWasTruncated = true
                break
            }
            if quoted {
                if character == "\"" {
                    if let following = next() {
                        if following == "\"" { field.append("\"") } else { quoted = false; pending = following }
                    } else { quoted = false }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                quoted = true
            } else if character == separator {
                row.append(field); field = ""
            } else if character == "\n" || character == "\r\n" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else if character != "\r" {
                field.append(character)
            }
        }
        if rows.count <= maxTableRows {
            if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        } else if !field.isEmpty || !row.isEmpty {
            sourceWasTruncated = true
        }
        let header = rows.first ?? []
        return (
            FileContent.Table(name: (name as NSString).deletingPathExtension, columns: header, rows: Array(rows.dropFirst())),
            sourceWasTruncated
        )
    }

    // MARK: - Limits

    private static func finalize(name: String, type: FileContent.Kind, byteCount: Int, pageCount: Int?, source: FileContent.Source, text: String, tables: [FileContent.Table], sourceWasTruncated: Bool = false) -> FileContent {
        var truncated = sourceWasTruncated
        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count > maxTextCharacters {
            normalized = String(normalized.prefix(maxTextCharacters))
            truncated = true
        }
        var cellBudget = maxCells
        var limitedTables: [FileContent.Table] = []
        for table in tables.prefix(maxTables) {
            let columnCount = min(maxTableColumns, max(table.columns.count, table.rows.map(\.count).max() ?? 0))
            guard columnCount > 0, cellBudget > columnCount else { truncated = truncated || !table.rows.isEmpty; break }
            func clip(_ row: [String]) -> [String] {
                (0..<columnCount).map { index in
                    let value = index < row.count ? row[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    if value.count > maxCellCharacters { truncated = true }
                    return String(value.prefix(maxCellCharacters))
                }
            }
            let columns = clip(table.columns)
            cellBudget -= columns.count
            let rowLimit = min(maxTableRows, cellBudget / columnCount)
            let rows = table.rows.prefix(rowLimit).map(clip)
            cellBudget -= rows.count * columnCount
            if table.rows.count > rows.count || table.columns.count > columnCount || table.rows.contains(where: { $0.count > columnCount }) { truncated = true }
            limitedTables.append(FileContent.Table(name: String(table.name.prefix(100)), columns: columns, rows: rows))
        }
        if tables.count > maxTables { truncated = true }
        return FileContent(
            name: String(name.prefix(255)),
            type: type,
            byteCount: byteCount,
            pageCount: pageCount,
            source: source,
            text: normalized,
            tables: limitedTables,
            truncated: truncated
        )
    }
}

// MARK: - ZIP (stored and deflated entries, which is all OOXML uses)

private struct ZipArchive {
    private struct Entry {
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private let entries: [String: Entry]
    /// A single XML part larger than this is not a document we should be reading on the phone.
    private static let maxEntryBytes = 32 * 1024 * 1024

    var paths: [String] { Array(entries.keys) }
    func contains(_ path: String) -> Bool { entries[path] != nil }

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 22 else { return nil }
        self.data = data
        // The end-of-central-directory record sits in the last 64 KB + 22 bytes.
        let searchStart = max(0, data.count - 65_557)
        var eocd = -1
        var index = data.count - 22
        while index >= searchStart {
            if Self.u32(data, index) == 0x0605_4b50 { eocd = index; break }
            index -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = Self.u16(data, eocd + 10)
        var offset = Self.u32(data, eocd + 16)
        var entries: [String: Entry] = [:]
        for _ in 0..<count {
            guard offset + 46 <= data.count, Self.u32(data, offset) == 0x0201_4b50 else { return nil }
            let method = Self.u16(data, offset + 10)
            let compressed = Self.u32(data, offset + 20)
            let uncompressed = Self.u32(data, offset + 24)
            let nameLength = Self.u16(data, offset + 28)
            let extraLength = Self.u16(data, offset + 30)
            let commentLength = Self.u16(data, offset + 32)
            let local = Self.u32(data, offset + 42)
            guard offset + 46 + nameLength <= data.count else { return nil }
            let nameData = data.subdata(in: (data.startIndex + offset + 46)..<(data.startIndex + offset + 46 + nameLength))
            if let name = String(data: nameData, encoding: .utf8) {
                entries[name] = Entry(method: method, compressedSize: compressed, uncompressedSize: uncompressed, localHeaderOffset: local)
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    func read(_ path: String) -> Data? {
        guard let entry = entries[path], entry.uncompressedSize <= Self.maxEntryBytes else { return nil }
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, Self.u32(data, header) == 0x0403_4b50 else { return nil }
        let start = header + 30 + Self.u16(data, header + 26) + Self.u16(data, header + 28)
        guard start + entry.compressedSize <= data.count else { return nil }
        let compressed = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        switch entry.method {
        case 0:
            return compressed
        case 8:
            guard entry.uncompressedSize > 0 else { return Data() }
            var output = Data(count: entry.uncompressedSize)
            let written = output.withUnsafeMutableBytes { destination in
                compressed.withUnsafeBytes { source in
                    // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), exactly what ZIP stores.
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!, entry.uncompressedSize,
                        source.bindMemory(to: UInt8.self).baseAddress!, entry.compressedSize,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            return written == entry.uncompressedSize ? output : nil
        default:
            return nil
        }
    }

    private static func u16(_ data: Data, _ offset: Int) -> Int {
        guard offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return Int(data[base]) | Int(data[base + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return Int(data[base]) | Int(data[base + 1]) << 8 | Int(data[base + 2]) << 16 | Int(data[base + 3]) << 24
    }
}

// MARK: - OOXML parsers

/// Each parser declares XMLParserDelegate itself: Objective-C only finds the optional delegate
/// methods on the class that declares the conformance.
private protocol XMLPartParser: XMLParserDelegate {}

extension XMLPartParser {
    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        return parser.parse()
    }
}

/// Word body text: paragraphs become lines, table cells tabs and rows lines, headings get "#".
private final class DocxTextParser: NSObject, XMLPartParser {
    private(set) var text = ""
    private var paragraph = ""
    private var capturing = false
    private var tableDepth = 0
    private var headingLevel = 0

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch element {
        case "w:t": capturing = true
        case "w:tab": paragraph.append("\t")
        case "w:br", "w:cr": paragraph.append("\n")
        case "w:tbl": tableDepth += 1
        case "w:pStyle":
            let style = (attributes["w:val"] ?? "").lowercased()
            if style.hasPrefix("heading") || style.hasPrefix("baslik") || style.hasPrefix("başlık") || style == "title" {
                headingLevel = Int(style.filter(\.isNumber)) ?? 1
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { paragraph.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "w:t": capturing = false
        case "w:p":
            let line = paragraph.trimmingCharacters(in: .whitespaces)
            if tableDepth > 0 {
                if !line.isEmpty { text.append(line + " ") }
            } else {
                let prefix = headingLevel > 0 && !line.isEmpty ? String(repeating: "#", count: min(headingLevel, 4)) + " " : ""
                text.append(prefix + line + "\n")
            }
            paragraph = ""
            headingLevel = 0
        case "w:tc": text.append("\t")
        case "w:tr": text.append("\n")
        case "w:tbl":
            tableDepth = max(0, tableDepth - 1)
            text.append("\n")
        default: break
        }
    }
}

/// Text runs grouped by paragraph (PowerPoint slides).
private final class ParagraphTextParser: NSObject, XMLPartParser {
    private let textElement: String
    private let paragraphElement: String
    private(set) var text = ""
    private var capturing = false

    init(textElement: String, paragraphElement: String) {
        self.textElement = textElement
        self.paragraphElement = paragraphElement
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if element == textElement { capturing = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { text.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == textElement { capturing = false }
        if element == paragraphElement { text.append("\n") }
    }
}

private final class SharedStringsParser: NSObject, XMLPartParser {
    private(set) var strings: [String] = []
    private var current = ""
    private var capturing = false

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if element == "si" { current = "" }
        if element == "t" { capturing = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { current.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == "t" { capturing = false }
        if element == "si" { strings.append(current) }
    }
}

private final class WorkbookParser: NSObject, XMLPartParser {
    struct Sheet { let name: String; let relationshipID: String }
    private(set) var sheets: [Sheet] = []

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        guard element == "sheet" else { return }
        sheets.append(Sheet(name: attributes["name"] ?? String(localized: "Sayfa\(sheets.count + 1)"), relationshipID: attributes["r:id"] ?? ""))
    }
}

private final class RelationshipsParser: NSObject, XMLPartParser {
    private(set) var targets: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        guard element == "Relationship", let id = attributes["Id"], let target = attributes["Target"] else { return }
        targets[id] = target
    }
}

/// One worksheet as rows of display strings; cells are placed by their A1 column.
private final class SheetParser: NSObject, XMLPartParser {
    private let sharedStrings: [String]
    private let maxRows: Int
    private let maxColumns: Int
    private(set) var rows: [[String]] = []
    private(set) var sourceWasTruncated = false
    private var row: [String] = []
    private var cellColumn = 0
    private var cellType = ""
    private var value = ""
    private var capturing = false

    init(sharedStrings: [String], maxRows: Int, maxColumns: Int) {
        self.sharedStrings = sharedStrings
        self.maxRows = maxRows
        self.maxColumns = maxColumns
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch element {
        case "row":
            if rows.count >= maxRows {
                sourceWasTruncated = true
                parser.abortParsing()
                return
            }
            row = []
        case "c":
            cellType = attributes["t"] ?? ""
            cellColumn = Self.columnIndex(attributes["r"] ?? "") ?? row.count
            value = ""
        case "v", "t":
            capturing = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { value.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "v", "t":
            capturing = false
        case "c":
            guard cellColumn < maxColumns else {
                sourceWasTruncated = true
                return
            }
            let display: String
            switch cellType {
            case "s": display = Int(value).flatMap { $0 < sharedStrings.count ? sharedStrings[$0] : nil } ?? ""
            case "b": display = value == "1" ? "DOĞRU" : "YANLIŞ"
            default: display = value
            }
            if row.count <= cellColumn { row.append(contentsOf: repeatElement("", count: cellColumn - row.count + 1)) }
            row[cellColumn] = display
        case "row":
            rows.append(row)
        default: break
        }
    }

    /// "C12" -> 2
    private static func columnIndex(_ reference: String) -> Int? {
        var index = 0
        var found = false
        for scalar in reference.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { break }
            index = index * 26 + Int(scalar.value - 64)
            found = true
        }
        return found ? index - 1 : nil
    }
}
