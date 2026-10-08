import AppKit
import CoreText
import Foundation
import Darwin
import PDFKit

/// Local document adapter for the Mac companion.
///
/// The engine deliberately accepts only one file name inside Desktop. It never scans arbitrary
/// paths and never overwrites an existing file unless the request explicitly opts in. Office
/// conversion is delegated to the user's installed `textutil`/LibreOffice process through
/// `Process` arguments (never a shell command), with a hard timeout and safe error mapping.
enum DocumentEngine {
    static let maxTextCharacters = 500_000
    static let maxFileBytes: Int64 = 25 * 1024 * 1024
    private static let processTimeout: TimeInterval = 30

    static func read(filename: String) -> (data: DocumentContent?, error: RovaError?) {
        guard let desktop = desktopURL(),
              let fileURL = safeDesktopURL(filename, desktop: desktop),
              isDirectDesktopEntry(fileURL, desktop: desktop),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return (nil, MacSystem.missingPathError("~/Desktop/\(filename)", message: "Masaüstünde \"\(filename)\" belgesi bulunamadı."))
        }
        return extractText(from: fileURL, displayName: filename)
    }

    /// Text of a document at an already-validated location (Desktop or a resolved local path).
    static func extractText(from fileURL: URL, displayName filename: String) -> (data: DocumentContent?, error: RovaError?) {
        do {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            guard values.isDirectory != true, values.isRegularFile == true else {
                return (nil, makeError("DOCUMENT_NOT_REGULAR", "Yalnızca normal belge dosyaları okunabilir."))
            }
            guard let byteCount = values.fileSize, Int64(byteCount) <= maxFileBytes else {
                return (nil, makeError("DOCUMENT_TOO_LARGE", "Belge desteklenen boyut sınırını aşıyor."))
            }
            guard let format = format(for: fileURL.pathExtension) else {
                return (nil, makeError("DOCUMENT_UNSUPPORTED", "Bu belge biçimi henüz desteklenmiyor."))
            }

            let text: String
            switch format {
            case .txt, .md, .csv, .html:
                text = try MacSystem.readText(at: fileURL)
            case .doc, .docx:
                text = try convertWordToText(fileURL)
            case .xlsx:
                text = try convertSpreadsheetToCSV(fileURL)
            case .pdf:
                guard let document = PDFDocument(url: fileURL) else {
                    return (nil, makeError("DOCUMENT_PARSE_FAILED", "PDF belgesi açılamadı."))
                }
                text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return (nil, makeError("DOCUMENT_OCR_REQUIRED", "Bu PDF taranmış görünüyor; metin katmanı bulunamadı. Görseli Gemini Vision ile analiz etmek için belgeyi görsel olarak ekleyin."))
                }
            }

            guard text.count <= maxTextCharacters else {
                return (nil, makeError("DOCUMENT_TEXT_TOO_LARGE", "Belgeden çıkarılan metin desteklenen sınırı aşıyor."))
            }
            return (DocumentContent(filename: filename, format: format, text: text), nil)
        } catch let failure as DocumentFailure {
            return (nil, failure.error)
        } catch {
            return (nil, makeError("DOCUMENT_READ_FAILED", "Belge okunamadı."))
        }
    }

    static func write(_ payload: DocumentPayload) -> RovaError? {
        guard RovaValidation.isValidDesktopFilename(payload.filename) else {
            return makeError("INVALID_FILENAME", "Belge dosya adı geçersiz.")
        }
        guard !payload.content.isEmpty, payload.content.count <= maxTextCharacters else {
            return makeError("INVALID_DOCUMENT_CONTENT", "Belge içeriği boş veya desteklenen sınırın dışında.")
        }
        guard let desktop = desktopURL() else {
            return makeError("DESKTOP_UNAVAILABLE", "Masaüstü klasörüne erişilemedi.")
        }

        let filename = filenameWithExtension(payload.filename, format: payload.format)
        guard let destination = safeDesktopURL(filename, desktop: desktop),
              isDirectDesktopEntry(destination, desktop: desktop) else {
            return makeError("INVALID_FILENAME", "Belge dosya adı geçersiz.")
        }

        do {
            let temporaryDirectory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
            let generated = try createOutput(payload: payload, filename: filename, temporaryDirectory: temporaryDirectory)
            try commit(generated, to: destination, overwrite: payload.overwrite)
            return nil
        } catch let failure as DocumentFailure {
            return failure.error
        } catch {
            return makeError("DOCUMENT_WRITE_FAILED", "Belge yazılamadı.")
        }
    }

    /// Used by the artifact downloader after the backend has authenticated the request.
    /// Folder descriptors prevent a symlink swap from redirecting the final write.
    static func commitArtifact(_ data: Data, filename: String, overwrite: Bool, destinationDirectory: String? = nil) -> (data: CommandData?, message: String, error: RovaError?) {
        func fail(_ code: String, _ message: String) -> (data: CommandData?, message: String, error: RovaError?) { (nil, message, makeError(code, message)) }
        guard !data.isEmpty, Int64(data.count) <= maxFileBytes,
              RovaValidation.isValidDesktopFilename(filename),
              RovaValidation.isValidArtifactDirectory(destinationDirectory), let desktop = desktopURL() else {
            return fail("INVALID_ARTIFACT_TARGET", "Dosya veya hedef klasör geçersiz.")
        }
        var directoryFD = open(desktop.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { return fail("DESKTOP_UNAVAILABLE", "Masaüstüne erişilemedi.") }
        defer { close(directoryFD) }
        var directory = desktop
        for component in (destinationDirectory ?? "").split(separator: "/") {
            let name = String(component)
            if mkdirat(directoryFD, name, 0o700) != 0 && errno != EEXIST {
                return fail("DIRECTORY_CREATE_FAILED", "Hedef klasör oluşturulamadı.")
            }
            let next = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { return fail("UNSAFE_ARTIFACT_TARGET", "Hedef klasör bir bağlantı veya erişilemeyen bir konum.") }
            close(directoryFD)
            directoryFD = next
            directory.appendPathComponent(name, isDirectory: true)
        }
        let temporary = ".rova-\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return fail("FILE_WRITE_FAILED", "Geçici dosya oluşturulamadı.") }
        defer { close(fd); unlinkat(directoryFD, temporary, 0) }
        let wrote = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return fsync(fd) == 0
        }
        guard wrote else { return fail("FILE_WRITE_FAILED", "Dosya bütünüyle yazılamadı.") }
        var info = stat()
        let exists = fstatat(directoryFD, filename, &info, AT_SYMLINK_NOFOLLOW) == 0
        if exists {
            guard overwrite else { return fail("FILE_EXISTS", "Aynı adlı dosya zaten var; üzerine yazılmadı.") }
            guard (info.st_mode & S_IFMT) == S_IFREG else { return fail("UNSAFE_ARTIFACT_TARGET", "Hedef normal bir dosya değil.") }
            // Atomic exchange retains the exact displaced file under the temporary name.
            guard renameatx_np(directoryFD, temporary, directoryFD, filename, UInt32(RENAME_SWAP)) == 0 else {
                return fail("FILE_WRITE_FAILED", "Dosya değiştirilemedi; önceki sürüm korundu.")
            }
            let backup = ".wiqo-backup-\(UUID().uuidString)"
            guard renameat(directoryFD, temporary, directoryFD, backup) == 0 else {
                // Undo the exchange while both names are still pinned to this directory.
                _ = renameatx_np(directoryFD, temporary, directoryFD, filename, UInt32(RENAME_SWAP))
                return fail("BACKUP_FAILED", "Yedek saklanamadı; işlem tamamlandı sayılmadı.")
            }
        } else {
            // linkat is exclusive: a competing writer never gets overwritten.
            guard linkat(directoryFD, temporary, directoryFD, filename, 0) == 0 else {
                return fail(errno == EEXIST ? "FILE_EXISTS" : "FILE_WRITE_FAILED", "Dosya kaydedilemedi; mevcut dosyanın üzerine yazılmadı.")
            }
        }
        let checkFD = openat(directoryFD, filename, O_RDONLY | O_NOFOLLOW)
        guard checkFD >= 0 else { return fail("FILE_VERIFICATION_FAILED", "Dosya tekrar okunamadı; otomatik tekrar yapılmadı.") }
        let handle = FileHandle(fileDescriptor: checkFD, closeOnDealloc: true)
        do {
            guard try handle.readToEnd() == data else { return fail("FILE_VERIFICATION_FAILED", "Kaydedilen içerik doğrulanamadı.") }
        } catch { return fail("FILE_VERIFICATION_FAILED", "Kaydedilen içerik okunamadı.") }
        let digest = RovaCrypto.sha256Hex(data)
        let destination = directory.appendingPathComponent(filename)
        let entry = FileSystemEntry(path: destination.path, name: filename, byteCount: Int64(data.count), modifiedAt: nil, isDirectory: false, fileType: destination.pathExtension)
        return (.files([entry]), "Doğrulandı: \(destination.path) · \(data.count) bayt · SHA-256: \(digest)", nil)
    }

    private static func createOutput(payload: DocumentPayload, filename: String, temporaryDirectory: URL) throws -> URL {
        switch payload.format {
        case .txt, .md, .csv, .html:
            let output = temporaryDirectory.appendingPathComponent(filename, isDirectory: false)
            guard isDirectChild(output, of: temporaryDirectory) else { throw failure("INVALID_FILENAME", "Belge dosya adı geçersiz.") }
            try payload.content.write(to: output, atomically: true, encoding: .utf8)
            return output
        case .doc, .docx:
            guard let executable = executable(named: "textutil") else {
                throw failure("DOCUMENT_ENGINE_UNAVAILABLE", "Word belgesi yazmak için macOS textutil bulunamadı.")
            }
            let source = temporaryDirectory.appendingPathComponent("source.txt", isDirectory: false)
            let output = temporaryDirectory.appendingPathComponent(filename, isDirectory: false)
            try payload.content.write(to: source, atomically: true, encoding: .utf8)
            let result = run(executable: executable, arguments: ["-convert", payload.format.rawValue, "-output", output.path, source.path])
            guard result.status == 0, FileManager.default.fileExists(atPath: output.path) else {
                throw failure("DOCUMENT_CONVERSION_FAILED", "Word belgesi dönüştürülemedi.")
            }
            return output
        case .xlsx:
            guard let executable = libreOfficeExecutable() else {
                throw failure("DOCUMENT_ENGINE_UNAVAILABLE", "Excel belgesi yazmak için LibreOffice kurulmalı.")
            }
            let source = temporaryDirectory.appendingPathComponent("source.csv", isDirectory: false)
            try csvContent(from: payload.content).write(to: source, atomically: true, encoding: .utf8)
            let result = run(executable: executable, arguments: ["--headless", "--convert-to", "xlsx", "--outdir", temporaryDirectory.path, source.path])
            let generated = temporaryDirectory.appendingPathComponent("source.xlsx", isDirectory: false)
            guard result.status == 0, FileManager.default.fileExists(atPath: generated.path) else {
                throw failure("DOCUMENT_CONVERSION_FAILED", "Excel belgesi dönüştürülemedi.")
            }
            let output = temporaryDirectory.appendingPathComponent(filename, isDirectory: false)
            try FileManager.default.moveItem(at: generated, to: output)
            return output
        case .pdf:
            let output = temporaryDirectory.appendingPathComponent(filename, isDirectory: false)
            try writePDF(payload.content, title: filename, to: output)
            return output
        }
    }

    private static func convertWordToText(_ url: URL) throws -> String {
        guard let executable = executable(named: "textutil") else {
            throw failure("DOCUMENT_ENGINE_UNAVAILABLE", "Word belgesi okumak için macOS textutil bulunamadı.")
        }
        let result = run(executable: executable, arguments: ["-convert", "txt", "-stdout", url.path])
        guard result.status == 0, let text = String(data: result.stdout, encoding: .utf8) else {
            throw failure("DOCUMENT_PARSE_FAILED", "Word belgesi okunamadı.")
        }
        return text
    }

    private static func convertSpreadsheetToCSV(_ url: URL) throws -> String {
        guard let executable = libreOfficeExecutable() else {
            throw failure("DOCUMENT_ENGINE_UNAVAILABLE", "Excel belgesi okumak için LibreOffice kurulmalı.")
        }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = run(executable: executable, arguments: ["--headless", "--convert-to", "csv", "--outdir", directory.path, url.path])
        guard result.status == 0 else {
            throw failure("DOCUMENT_PARSE_FAILED", "Excel belgesi okunamadı.")
        }
        let expected = directory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".csv")
        let csvURL: URL
        if FileManager.default.fileExists(atPath: expected.path) {
            csvURL = expected
        } else if let first = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first(where: { $0.pathExtension.lowercased() == "csv" }) {
            csvURL = first
        } else {
            throw failure("DOCUMENT_PARSE_FAILED", "Excel belgesinden tablo çıkarılamadı.")
        }
        return try String(contentsOf: csvURL, encoding: .utf8)
    }

    private static func csvContent(from content: String) throws -> String {
        guard let data = content.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return content
        }

        if let object = value as? [String: Any], let rows = object["rows"] as? [[Any]] {
            var allRows = rows
            if let headers = object["headers"] as? [Any] { allRows.insert(headers, at: 0) }
            return allRows.map(csvRow).joined(separator: "\n")
        }
        if let rows = value as? [[Any]] {
            return rows.map(csvRow).joined(separator: "\n")
        }
        return content
    }

    private static func csvRow(_ row: [Any]) -> String {
        row.map { value in
            let text: String
            if let string = value as? String {
                text = string
            } else if JSONSerialization.isValidJSONObject([value]),
                      let data = try? JSONSerialization.data(withJSONObject: value),
                      let encoded = String(data: data, encoding: .utf8) {
                text = encoded
            } else {
                text = String(describing: value)
            }
            guard !text.contains(where: { $0 == "," || $0 == "\n" || $0 == "\r" || $0 == "\"" }) else {
                return "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return text
        }.joined(separator: ",")
    }

    private static func writePDF(_ content: String, title: String, to url: URL) throws {
        let mutableData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        guard let consumer = CGDataConsumer(data: mutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw failure("PDF_CREATE_FAILED", "PDF motoru başlatılamadı.")
        }

        let font = CTFontCreateWithName("Arial" as CFString, 11, nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let margin: CGFloat = 48
        let lineHeight: CGFloat = 18
        let maxWidth = mediaBox.width - margin * 2
        let lines = wrappedLines(content, attributes: attributes, maxWidth: maxWidth)
        var lineIndex = 0
        repeat {
            context.beginPDFPage(nil)
            var y = mediaBox.height - margin - lineHeight
            if lineIndex == 0 {
                let titleLine = NSAttributedString(string: title, attributes: [.font: CTFontCreateWithName("Arial-Bold" as CFString, 16, nil)])
                let titleLineRef = CTLineCreateWithAttributedString(titleLine)
                context.textPosition = CGPoint(x: margin, y: mediaBox.height - margin)
                CTLineDraw(titleLineRef, context)
                y -= 28
            }
            while lineIndex < lines.count, y >= margin {
                let line = NSAttributedString(string: lines[lineIndex], attributes: attributes)
                let lineRef = CTLineCreateWithAttributedString(line)
                context.textPosition = CGPoint(x: margin, y: y)
                CTLineDraw(lineRef, context)
                lineIndex += 1
                y -= lineHeight
            }
            context.endPDFPage()
        } while lineIndex < lines.count
        context.closePDF()
        try (mutableData as Data).write(to: url, options: .atomic)
    }

    private static func wrappedLines(_ text: String, attributes: [NSAttributedString.Key: Any], maxWidth: CGFloat) -> [String] {
        var result: [String] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init) {
            if rawLine.isEmpty {
                result.append("")
                continue
            }
            var current = ""
            for word in rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
                let candidate = current.isEmpty ? word : "\(current) \(word)"
                let width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: candidate, attributes: attributes)), nil, nil, nil)
                if width > Double(maxWidth), !current.isEmpty {
                    result.append(current)
                    current = word
                } else {
                    current = candidate
                }
            }
            if !current.isEmpty { result.append(current) }
        }
        return result.isEmpty ? [""] : result
    }

    private static func commit(_ source: URL, to destination: URL, overwrite: Bool) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw failure("DOCUMENT_WRITE_FAILED", "Belge çıktısı oluşturulamadı.")
        }
        if FileManager.default.fileExists(atPath: destination.path), !overwrite {
            throw failure("FILE_EXISTS", "Aynı adlı dosya zaten var; üzerine yazılmadı.")
        }
        let expected = try Data(contentsOf: source, options: .mappedIfSafe)
        guard !expected.isEmpty, Int64(expected.count) <= maxFileBytes else {
            throw failure("DOCUMENT_WRITE_FAILED", "Belge çıktısı boş veya desteklenen boyut sınırının dışında.")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            if let error = MacSystem.backUp(destination) { throw DocumentFailure(error: error) }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        guard try Data(contentsOf: destination, options: .mappedIfSafe) == expected else {
            throw failure("FILE_VERIFICATION_FAILED", "Belge yazıldı ancak içerik doğrulanamadı; otomatik tekrar yapılmadı.")
        }
    }

    private static func commit(_ data: Data, to destination: URL, overwrite: Bool) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".rova-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        do {
            try commit(temporary, to: destination, overwrite: overwrite)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rova-document-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func executable(named name: String) -> String? {
        if name == "textutil", FileManager.default.isExecutableFile(atPath: "/usr/bin/textutil") { return "/usr/bin/textutil" }
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return pathEntries
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private static func libreOfficeExecutable() -> String? {
        if let path = executable(named: "soffice") { return path }
        let candidates = [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/Applications/LibreOfficeDev.app/Contents/MacOS/soffice"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private struct ProcessOutput {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    private static func run(executable: String, arguments: [String]) -> ProcessOutput {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return ProcessOutput(status: -1, stdout: Data(), stderr: Data())
        }
        let deadline = Date().addingTimeInterval(processTimeout)
        while process.isRunning {
            if Task.isCancelled || Date() >= deadline {
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        return ProcessOutput(status: process.terminationStatus, stdout: stdout.fileHandleForReading.readDataToEndOfFile(), stderr: stderr.fileHandleForReading.readDataToEndOfFile())
    }

    static func format(for extensionName: String) -> DocumentFormat? {
        switch extensionName.lowercased() {
        case "txt": return .txt
        case "md", "markdown": return .md
        case "csv": return .csv
        case "html", "htm": return .html
        case "doc": return .doc
        case "docx": return .docx
        case "xls", "xlsx", "ods": return .xlsx
        case "pdf": return .pdf
        default: return nil
        }
    }

    static func filenameWithExtension(_ filename: String, format: DocumentFormat) -> String {
        let suffix = ".\(format.rawValue)"
        return filename.lowercased().hasSuffix(suffix) ? filename : filename + suffix
    }

    private static func desktopURL() -> URL? {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    private static func safeDesktopURL(_ filename: String, desktop: URL) -> URL? {
        guard RovaValidation.isValidDesktopFilename(filename) else { return nil }
        return desktop.appendingPathComponent(filename, isDirectory: false)
    }

    private static func isDirectDesktopEntry(_ url: URL, desktop: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent().path == desktop.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isDirectChild(_ url: URL, of directory: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == directory.standardizedFileURL.path
    }

    private static func makeError(_ code: String, _ message: String) -> RovaError {
        let category: String
        switch code {
        case "FILE_EXISTS", "INVALID_FILENAME", "FULL_DISK_ACCESS_REQUIRED":
            category = "permission"
        case "DOCUMENT_ENGINE_UNAVAILABLE", "DESKTOP_UNAVAILABLE":
            category = "tool_failure"
        default:
            category = "tool_failure"
        }
        return RovaError(code: code, message: message, category: category)
    }

    private struct DocumentFailure: Error {
        let error: RovaError
    }

    private static func failure(_ code: String, _ message: String) -> DocumentFailure {
        DocumentFailure(error: makeError(code, message))
    }
}
