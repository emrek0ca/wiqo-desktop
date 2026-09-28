import AppKit
import Foundation
import CryptoKit
import UniformTypeIdentifiers

/// Reading, writing and moving files and documents on this Mac.
extension MacSystem {
    static func saveTextFile(_ payload: TextFilePayload) -> RovaError? {
        guard RovaValidation.isValidDesktopFilename(payload.filename) else {
            return RovaError(code: "INVALID_FILENAME", message: "Dosya adı geçersiz.")
        }
        guard let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            return RovaError(code: "DESKTOP_UNAVAILABLE", message: "Masaüstü klasörüne erişilemedi.")
        }
        let fileURL = desktopURL.appendingPathComponent(payload.filename)
        guard isDirectDesktopEntry(fileURL, desktop: desktopURL),
              !FileManager.default.fileExists(atPath: fileURL.path) else {
            return RovaError(code: "FILE_EXISTS", message: "Aynı adlı dosya zaten var; üzerine yazılmadı.")
        }
        do {
            try payload.content.write(to: fileURL, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return RovaError(code: "FILE_WRITE_FAILED", message: "Dosya yazılamadı.")
        }
    }

    static func readDocument(_ filename: String) -> (data: CommandData?, error: RovaError?) {
        let outcome = DocumentEngine.read(filename: filename)
        return (outcome.data.map(CommandData.documentContent), outcome.error)
    }

    static func editDocument(_ payload: DocumentPayload) -> RovaError? {
        DocumentEngine.write(payload)
    }

    /// Downloads a backend-produced artifact over the authenticated Mac channel and commits it
    /// to Desktop only after the complete response has arrived. The URL is allow-listed by the
    /// shared validator, so a model-produced URL cannot turn this into an arbitrary downloader.
    static func saveArtifact(_ payload: ArtifactFilePayload, token: String) async -> RovaError? {
        guard RovaValidation.isAllowedArtifactURL(payload.downloadURL),
              let url = URL(string: payload.downloadURL) else {
            return RovaError(code: "INVALID_ARTIFACT_URL", message: "Artifact indirme adresi güvenli değil.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 45
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return RovaError(code: "ARTIFACT_DOWNLOAD_FAILED", message: "Artifact backend'den indirilemedi.")
            }
            if let contentType = http.value(forHTTPHeaderField: "Content-Type"), contentType.lowercased().hasPrefix("application/json") {
                return RovaError(code: "ARTIFACT_DOWNLOAD_FAILED", message: "Artifact backend'den geçerli bir dosya döndürmedi.")
            }
            if let contentLength = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), contentLength > DocumentEngine.maxFileBytes {
                return RovaError(code: "ARTIFACT_TOO_LARGE", message: "İndirilen dosya desteklenen boyut sınırını aşıyor.")
            }
            var data = Data()
            data.reserveCapacity(min(Int(payload.byteCount ?? DocumentEngine.maxFileBytes), Int(DocumentEngine.maxFileBytes)))
            for try await byte in bytes {
                if data.count >= Int(DocumentEngine.maxFileBytes) {
                    return RovaError(code: "ARTIFACT_TOO_LARGE", message: "İndirilen dosya desteklenen boyut sınırını aşıyor.")
                }
                data.append(byte)
            }
            if let expectedByteCount = payload.byteCount, Int64(data.count) != expectedByteCount {
                return RovaError(code: "ARTIFACT_INTEGRITY_FAILED", message: "İndirilen artifact boyut doğrulamasından geçmedi.")
            }
            if let expectedSHA256 = payload.sha256, RovaCrypto.sha256Hex(data) != expectedSHA256.lowercased() {
                return RovaError(code: "ARTIFACT_INTEGRITY_FAILED", message: "İndirilen artifact bütünlük doğrulamasından geçmedi.")
            }
            return DocumentEngine.commitArtifact(data, filename: payload.filename, overwrite: payload.overwrite)
        } catch is CancellationError {
            return RovaError(code: "CANCELLED", message: "Artifact indirme iptal edildi.")
        } catch {
            return RovaError(code: "ARTIFACT_DOWNLOAD_FAILED", message: "Artifact indirilemedi.")
        }
    }

    static func listDesktopFiles() -> (data: CommandData?, error: RovaError?) {
        guard let desktopURL = desktopURL() else {
            return (nil, RovaError(code: "DESKTOP_UNAVAILABLE", message: "Masaüstü klasörüne erişilemedi."))
        }
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: desktopURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
            let files = urls.compactMap { url -> DesktopFileInfo? in
                guard isDirectDesktopEntry(url, desktop: desktopURL) else { return nil }
                guard RovaValidation.isValidDesktopFilename(url.lastPathComponent),
                      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { return nil }
                return DesktopFileInfo(filename: url.lastPathComponent, byteCount: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate, isDirectory: values.isDirectory ?? false)
            }.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
            return (.desktopFiles(Array(files.prefix(100))), nil)
        } catch {
            return (nil, RovaError(code: "DESKTOP_LIST_FAILED", message: "Masaüstü dosyaları listelenemedi."))
        }
    }

    static func readDesktopFile(_ filename: String) -> (data: CommandData?, error: RovaError?) {
        guard let desktop = desktopURL(), let url = safeDesktopURL(filename),
              isDirectDesktopEntry(url, desktop: desktop), FileManager.default.fileExists(atPath: url.path) else {
            return (nil, missingPathError("~/Desktop/\(filename)", message: "Masaüstünde \"\(filename)\" bulunamadı."))
        }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            guard values.isDirectory != true, values.isRegularFile == true, let size = values.fileSize, size <= 200_000 else {
                return (nil, RovaError(code: "FILE_TOO_LARGE", message: "Yalnızca 200 KB veya daha küçük metin dosyaları okunabilir."))
            }
            let content = try readText(at: url)
            return (.fileContent(DesktopFileContent(filename: filename, content: content)), nil)
        } catch {
            return (nil, RovaError(code: "FILE_READ_FAILED", message: "Dosya okunamadı."))
        }
    }

    static func moveDesktopFile(_ payload: DesktopFileMovePayload) -> RovaError? {
        guard let desktop = desktopURL(),
              let source = safeDesktopURL(payload.source), let destination = safeDesktopURL(payload.destination),
              isDirectDesktopEntry(source, desktop: desktop), isDirectDesktopEntry(destination, desktop: desktop),
              FileManager.default.fileExists(atPath: source.path) else {
            return missingPathError("~/Desktop/\(payload.source)", message: "Masaüstünde \"\(payload.source)\" bulunamadı.")
        }
        guard let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]),
              values.isDirectory != true, values.isRegularFile == true else {
            return RovaError(code: "FILE_NOT_REGULAR", message: "Yalnızca normal dosyalar taşınabilir.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return RovaError(code: "FILE_EXISTS", message: "Hedef dosya zaten var; üzerine yazılmadı.")
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return nil
        } catch {
            return RovaError(code: "FILE_MOVE_FAILED", message: "Dosya taşınamadı veya yeniden adlandırılamadı.")
        }
    }

    private static let maxLocalReadBytes = 512 * 1024
    private static let maxPhoneTransferBytes: Int64 = 25 * 1024 * 1024

    static let maxProcessOutputBytes = 50 * 1024

    static let maxScreenshotBytes = 700 * 1024

    static func listFiles(_ payload: LocalFileOperationPayload) -> (data: CommandData?, error: RovaError?) {
        guard let directory = resolvedLocalURL(payload.path), FileManager.default.fileExists(atPath: directory.path) else {
            return (nil, missingPathError(payload.path, message: "\"\(payload.path)\" klasörü bulunamadı."))
        }
        guard isDirectory(directory) else {
            return (nil, RovaError(code: "NOT_A_DIRECTORY", message: "İstenen yol bir klasör değil.", category: "tool_failure"))
        }
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
                .filter { !$0.lastPathComponent.isEmpty }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let start = min(max(payload.page, 0) * max(payload.pageSize, 1), urls.count)
            let page = urls.dropFirst(start).prefix(max(payload.pageSize, 1)).compactMap(fileSystemEntry)
            return (.files(Array(page)), nil)
        } catch {
            return (nil, localFileError(code: "FILE_LIST_FAILED", fallback: "Klasör içeriği listelenemedi.", error: error))
        }
    }

    static func searchFiles(_ payload: FileSearchPayload) async -> (data: CommandData?, message: String, error: RovaError?) {
        await MacSearchRegistry.shared.search(payload)
    }

    static func sendFileToPhone(_ payload: LocalFileOperationPayload, commandID: UUID, accessToken: String) async -> (data: CommandData?, error: RovaError?) {
        guard let file = resolvedLocalURL(payload.path), isRegularFile(file), !isSymbolicLink(file),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, Int64(size) <= maxPhoneTransferBytes else {
            return (nil, RovaError(code: "FILE_TOO_LARGE", message: "Yalnızca 25 MB veya daha küçük normal dosyalar gönderilebilir."))
        }
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var digest = SHA256()
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                if Task.isCancelled { throw CancellationError() }
                digest.update(data: chunk)
            }
            let sha256 = digest.finalize().map { String(format: "%02x", $0) }.joined()
            let baseURL = await MainActor.run { MacBackendChannel.apiBaseURL }
            var request = URLRequest(url: baseURL.appendingPathComponent("file-transfers/\(commandID.uuidString)"))
            request.httpMethod = "PUT"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "dosya", forHTTPHeaderField: "X-File-Name")
            request.setValue(sha256, forHTTPHeaderField: "X-File-SHA256")
            request.timeoutInterval = 120
            let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
            guard let http = response as? HTTPURLResponse, http.statusCode == 201,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let artifactID = body["artifactId"] as? String else {
                return (nil, RovaError(code: "TRANSFER_FAILED", message: "Dosya telefona iletilemedi."))
            }
            return (.fileTransfer(artifactID), nil)
        } catch is CancellationError {
            return (nil, RovaError(code: "CANCELLED", message: "Dosya aktarımı iptal edildi."))
        } catch {
            return (nil, RovaError(code: "TRANSFER_FAILED", message: "Dosya telefona iletilemedi."))
        }
    }

    static func readFile(_ payload: LocalFileOperationPayload) -> (data: CommandData?, error: RovaError?) {
        guard let file = resolvedLocalURL(payload.path), FileManager.default.fileExists(atPath: file.path) else {
            return (nil, missingPathError(payload.path, message: "\"\(payload.path)\" bulunamadı."))
        }
        guard !isDirectory(file), isRegularFile(file) else {
            return (nil, RovaError(code: "FILE_NOT_REGULAR", message: "Yalnızca normal dosyalar okunabilir.", category: "tool_failure"))
        }
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size <= maxLocalReadBytes else {
                return (nil, RovaError(code: "FILE_TOO_LARGE", message: "Bu dosya tek yanıt için çok büyük; daha küçük bir dosya veya sayfalı belge okuma kullan.", category: "tool_failure"))
            }
            let mimeType = mimeType(for: file)
            // PDF/Word/Excel came back as base64, which the backend drops before the model sees
            // it - "şu PDF'i oku" then answered from nothing. Extract the text instead.
            if let format = DocumentEngine.format(for: file.pathExtension), ([.pdf, .doc, .docx, .xlsx] as [DocumentFormat]).contains(format) {
                let extracted = DocumentEngine.extractText(from: file, displayName: file.lastPathComponent)
                if let document = extracted.data {
                    let limit = 200_000
                    let text = document.text.count > limit ? String(document.text.prefix(limit)) : document.text
                    return (.fileData(FileDataContent(path: file.path, mimeType: mimeType, text: text, truncated: document.text.count > limit)), nil)
                }
                return (nil, extracted.error)
            }
            let bytes = try Data(contentsOf: file, options: [.mappedIfSafe])
            if let text = String(data: bytes, encoding: .utf8) ?? (isLikelyText(file) ? try? readText(at: file) : nil) {
                return (.fileData(FileDataContent(path: file.path, mimeType: mimeType, text: text, truncated: false)), nil)
            }
            return (.fileData(FileDataContent(path: file.path, mimeType: mimeType, base64: bytes.base64EncodedString(), truncated: false)), nil)
        } catch {
            return (nil, localFileError(code: "FILE_READ_FAILED", fallback: "Dosya okunamadı.", error: error))
        }
    }

    static func writeFile(_ payload: LocalFileOperationPayload) -> RovaError? {
        guard let content = payload.content,
              let destination = resolvedLocalURL(payload.path, allowingMissingLastComponent: true),
              let parent = resolvedLocalURL(destination.deletingLastPathComponent().path),
              isDirectory(parent) else {
            return RovaError(code: "INVALID_FILE_PATH", message: "Dosya yolu veya hedef klasör geçersiz.", category: "tool_failure")
        }
        guard !isSymbolicLink(destination) else {
            return RovaError(code: "SYMLINK_REJECTED", message: "Sembolik bağlantının üzerine yazılmadı.", category: "permission")
        }
        if FileManager.default.fileExists(atPath: destination.path) && !payload.overwrite {
            return RovaError(code: "FILE_EXISTS", message: "Aynı dosya zaten var; üzerine yazma onayı verilmedi.", category: "permission")
        }
        do {
            try Data(content.utf8).write(to: destination, options: [.atomic])
            return nil
        } catch {
            return localFileError(code: "FILE_WRITE_FAILED", fallback: "Dosya yazılamadı.", error: error)
        }
    }

    static func moveFile(_ payload: LocalFileOperationPayload) -> RovaError? {
        transferFile(payload, copy: false)
    }

    static func copyFile(_ payload: LocalFileOperationPayload) -> RovaError? {
        transferFile(payload, copy: true)
    }

    private static func transferFile(_ payload: LocalFileOperationPayload, copy: Bool) -> RovaError? {
        guard let source = resolvedLocalURL(payload.path),
              let destination = payload.destination.flatMap({ resolvedLocalURL($0, allowingMissingLastComponent: true) }),
              FileManager.default.fileExists(atPath: source.path),
              let parent = resolvedLocalURL(destination.deletingLastPathComponent().path),
              isDirectory(parent) else {
            return RovaError(code: "INVALID_FILE_PATH", message: "Kaynak, hedef veya hedef klasör geçersiz.", category: "tool_failure")
        }
        guard !isSymbolicLink(source), !isSymbolicLink(destination) else {
            return RovaError(code: "SYMLINK_REJECTED", message: "Sembolik bağlantılar üzerinden dosya işlemi yapılmadı.", category: "permission")
        }
        if isDirectory(source) && !payload.recursive {
            return RovaError(code: "RECURSIVE_REQUIRED", message: "Klasör işlemi için recursive=true açıkça belirtilmeli.", category: "permission")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            guard payload.overwrite else {
                return RovaError(code: "FILE_EXISTS", message: "Hedef zaten var; üzerine yazma onayı verilmedi.", category: "permission")
            }
            do {
                try FileManager.default.removeItem(at: destination)
            } catch {
                return localFileError(code: "FILE_REPLACE_FAILED", fallback: "Mevcut hedef değiştirilemedi.", error: error)
            }
        }
        do {
            if copy {
                try FileManager.default.copyItem(at: source, to: destination)
            } else {
                try FileManager.default.moveItem(at: source, to: destination)
            }
            return nil
        } catch {
            return localFileError(code: copy ? "FILE_COPY_FAILED" : "FILE_MOVE_FAILED", fallback: copy ? "Dosya kopyalanamadı." : "Dosya taşınamadı.", error: error)
        }
    }

    static func deleteFile(_ payload: LocalFileOperationPayload) -> RovaError? {
        guard let target = resolvedLocalURL(payload.path), FileManager.default.fileExists(atPath: target.path) else {
            return missingPathError(payload.path, message: "Silinecek \"\(payload.path)\" bulunamadı.")
        }
        let normalized = target.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard normalized != "/", normalized != home, normalized != "/Users" else {
            return RovaError(code: "PROTECTED_PATH", message: "Sistem veya kullanıcı kök klasörü silinemez.", category: "permission")
        }
        guard !isSymbolicLink(target) else {
            return RovaError(code: "SYMLINK_REJECTED", message: "Sembolik bağlantı silinmedi.", category: "permission")
        }
        guard !isDirectory(target) || payload.recursive else {
            return RovaError(code: "RECURSIVE_REQUIRED", message: "Klasör silmek için recursive=true açıkça belirtilmeli.", category: "permission")
        }
        do {
            try FileManager.default.removeItem(at: target)
            return nil
        } catch {
            return localFileError(code: "FILE_DELETE_FAILED", fallback: "Dosya silinemedi.", error: error)
        }
    }

    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static func fileSystemEntry(_ url: URL) -> FileSystemEntry? {
        guard !isSymbolicLink(url) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { return nil }
        return FileSystemEntry(path: url.standardizedFileURL.path, name: url.lastPathComponent, byteCount: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate, isDirectory: values.isDirectory == true)
    }

    /// The model writes the folder names the user sees on a Turkish Mac ("~/Masaüstü/rapor.pdf")
    /// or guesses a home folder ("/Users/emre/Desktop"); on disk they are ~/Desktop and the real
    /// home. Only the first folder under home is translated; everything else stays verbatim.
    static func canonicalUserPath(_ rawPath: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var path = (rawPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.count >= 2, components[0] == "Users",
           "/Users/\(components[1])" != home,
           !FileManager.default.fileExists(atPath: "/Users/\(components[1])") {
            path = ([home] + components.dropFirst(2)).joined(separator: "/")
        }
        guard path.hasPrefix(home + "/") else { return path }
        var rest = String(path.dropFirst(home.count + 1)).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = rest.first else { return path }
        let folders: [String: String] = [
            "masaustu": "Desktop", "belgeler": "Documents", "dokumanlar": "Documents", "dokumanlarim": "Documents",
            "indirilenler": "Downloads", "indirmeler": "Downloads", "resimler": "Pictures", "fotograflar": "Pictures",
            "muzik": "Music", "filmler": "Movies", "videolar": "Movies"
        ]
        let key = ApplicationNameMatcher.normalize(first).replacingOccurrences(of: " ", with: "")
        if let english = folders[key], !FileManager.default.fileExists(atPath: home + "/" + first) {
            rest[0] = english
        }
        return ([home] + rest).joined(separator: "/")
    }

    /// "Not found" that helps the next attempt: the folder that was searched and the closest
    /// names in it, so the model can retry with the real file name instead of giving up.
    static func missingPathError(_ rawPath: String, message: String) -> RovaError {
        let url = URL(fileURLWithPath: canonicalUserPath(rawPath))
        let parent = url.deletingLastPathComponent()
        let wanted = ApplicationNameMatcher.normalize(url.deletingPathExtension().lastPathComponent)
        var detail = message
        if let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) {
            let suggestions = names
                .filter { !$0.hasPrefix(".") }
                .map { ($0, ApplicationNameMatcher.score(($0 as NSString).deletingPathExtension, query: wanted)) }
                .filter { $0.1 >= 0.5 }
                .sorted { $0.1 > $1.1 }
                .prefix(3)
                .map(\.0)
            let folder = (parent.path as NSString).abbreviatingWithTildeInPath
            detail += suggestions.isEmpty
                ? " (\(folder) içinde bu adla bir öğe yok; önce klasörü listele.)"
                : " \(folder) içindeki benzer adlar: \(suggestions.joined(separator: ", "))."
        } else {
            detail += " (\((parent.path as NSString).abbreviatingWithTildeInPath) klasörü de yok.)"
        }
        return RovaError(code: "FILE_NOT_FOUND", message: detail, category: "tool_failure")
    }

    private static func isLikelyText(_ url: URL) -> Bool {
        ["txt", "md", "csv", "tsv", "log", "json", "xml", "html", "htm", "yml", "yaml", "ini", "srt", "swift", "py", "js", "ts"].contains(url.pathExtension.lowercased())
    }

    /// Reads text the way people save it on a Turkish Mac: UTF-8 first, then what the file
    /// declares, then Windows-1254/Latin-1 so an old .txt does not fail as "okunamadı".
    static func readText(at url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        var detected = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &detected) { return text }
        let turkish = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsLatin5.rawValue)))
        if let text = try? String(contentsOf: url, encoding: turkish) { return text }
        return try String(contentsOf: url, encoding: .isoLatin1)
    }

    private static func resolvedLocalURL(_ rawPath: String, allowingMissingLastComponent: Bool = false) -> URL? {
        guard RovaValidation.isValidLocalPath(rawPath) else { return nil }
        let expanded = canonicalUserPath(rawPath)
        guard expanded.hasPrefix("/") else { return nil }
        let rawURL = URL(fileURLWithPath: expanded).standardizedFileURL
        if FileManager.default.fileExists(atPath: rawURL.path) {
            guard !isSymbolicLink(rawURL) else { return nil }
            // Resolve existing parent aliases (for example macOS's /var alias), but never
            // follow a symlink at the requested final entry. This prevents a model-produced
            // path from silently operating on a symlink target while keeping legitimate system
            // path aliases usable.
            return rawURL.resolvingSymlinksInPath().standardizedFileURL
        }
        guard allowingMissingLastComponent else { return nil }
        let parent = rawURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path), !isSymbolicLink(parent), isDirectory(parent) else { return nil }
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
        guard !isSymbolicLink(resolvedParent), isDirectory(resolvedParent) else { return nil }
        return resolvedParent.appendingPathComponent(rawURL.lastPathComponent, isDirectory: false)
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    static func localFileError(code: String, fallback: String, error: Error) -> RovaError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && [257, 513, NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code) {
            return RovaError(code: "FULL_DISK_ACCESS_REQUIRED", message: "Wiqo'nun bu klasöre erişmesi için Sistem Ayarları > Gizlilik ve Güvenlik > Tam Disk Erişimi bölümünden izin verin. Ayarlar: x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles", category: "permission")
        }
        return RovaError(code: code, message: fallback, category: "tool_failure")
    }

    private static func desktopURL() -> URL? {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    private static func isDirectDesktopEntry(_ url: URL, desktop: URL) -> Bool {
        let resolvedDesktop = desktop.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        return resolvedURL.deletingLastPathComponent().path == resolvedDesktop
    }

    private static func safeDesktopURL(_ filename: String) -> URL? {
        guard RovaValidation.isValidDesktopFilename(filename), let desktop = desktopURL() else { return nil }
        return desktop.appendingPathComponent(filename, isDirectory: false)
    }
}

private actor MacSearchRegistry {
    static let shared = MacSearchRegistry()

    private final class Session {
        let query: String
        var enumerator: FileManager.DirectoryEnumerator?
        var skipped = 0
        var expiresAt = Date().addingTimeInterval(10 * 60)

        init?(query: String) {
            self.query = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: "/", isDirectory: true),
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsPackageDescendants],
                errorHandler: { [weak self] _, _ in
                    self?.skipped += 1
                    return true
                }
            ) else { return nil }
            self.enumerator = enumerator
        }
    }

    private var sessions: [String: Session] = [:]

    func search(_ payload: FileSearchPayload) -> (data: CommandData?, message: String, error: RovaError?) {
        sessions = sessions.filter { $0.value.expiresAt > Date() }
        let id: String
        let session: Session
        if let cursor = payload.cursor {
            guard let existing = sessions[cursor], existing.query == payload.query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) else {
                return (nil, "Arama sürdürülemedi.", RovaError(code: "INVALID_CURSOR", message: "Aramayı yeniden başlat."))
            }
            id = cursor
            session = existing
        } else {
            guard sessions.count < 5 else {
                return (nil, "Çok fazla arama açık.", RovaError(code: "SEARCH_LIMIT", message: "Biraz sonra tekrar dene."))
            }
            id = UUID().uuidString
            guard let created = Session(query: payload.query) else {
                return (nil, "Dosyalar aranamadı.", RovaError(code: "SEARCH_FAILED", message: "Dosyalar aranamadı."))
            }
            session = created
            sessions[id] = session
        }
        var matches: [FileSystemEntry] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(15)
        while let url = session.enumerator?.nextObject() as? URL {
            if Task.isCancelled {
                sessions.removeValue(forKey: id)
                return (nil, "Arama iptal edildi.", RovaError(code: "CANCELLED", message: "Arama iptal edildi."))
            }
            visited += 1
            if ["/dev", "/proc", "/System/Volumes/Preboot", "/System/Volumes/VM"].contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) {
                session.enumerator?.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) else {
                session.skipped += 1
                continue
            }
            if values.isSymbolicLink == true { session.enumerator?.skipDescendants(); continue }
            if values.isRegularFile == true && url.path.count <= 500 &&
                url.lastPathComponent.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(session.query) {
                matches.append(FileSystemEntry(path: url.standardizedFileURL.path, name: url.lastPathComponent,
                    byteCount: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate,
                    isDirectory: false, fileType: url.pathExtension.lowercased()))
            }
            if matches.count >= 12 || visited >= 25_000 || Date() >= deadline {
                session.expiresAt = Date().addingTimeInterval(10 * 60)
                return (.files(matches), "Kısmi sonuç; devam kodu \(id). Erişilemeyen öğe: \(session.skipped).", nil)
            }
        }
        sessions.removeValue(forKey: id)
        return (.files(matches), "Arama tamamlandı. Erişilemeyen öğe: \(session.skipped).", nil)
    }
}
