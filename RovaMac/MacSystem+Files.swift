import AppKit
import Foundation
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
            return (nil, RovaError(code: "FILE_NOT_FOUND", message: "Masaüstünde bu dosya bulunamadı."))
        }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            guard values.isDirectory != true, values.isRegularFile == true, let size = values.fileSize, size <= 200_000 else {
                return (nil, RovaError(code: "FILE_TOO_LARGE", message: "Yalnızca 200 KB veya daha küçük metin dosyaları okunabilir."))
            }
            let content = try String(contentsOf: url, encoding: .utf8)
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
            return RovaError(code: "FILE_NOT_FOUND", message: "Kaynak dosya masaüstünde bulunamadı.")
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

    static let maxProcessOutputBytes = 50 * 1024

    static let maxScreenshotBytes = 700 * 1024

    static func listFiles(_ payload: LocalFileOperationPayload) -> (data: CommandData?, error: RovaError?) {
        guard let directory = resolvedLocalURL(payload.path), FileManager.default.fileExists(atPath: directory.path) else {
            return (nil, RovaError(code: "FILE_NOT_FOUND", message: "İstenen klasör bulunamadı.", category: "tool_failure"))
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

    static func readFile(_ payload: LocalFileOperationPayload) -> (data: CommandData?, error: RovaError?) {
        guard let file = resolvedLocalURL(payload.path), FileManager.default.fileExists(atPath: file.path) else {
            return (nil, RovaError(code: "FILE_NOT_FOUND", message: "İstenen dosya bulunamadı.", category: "tool_failure"))
        }
        guard !isDirectory(file), isRegularFile(file) else {
            return (nil, RovaError(code: "FILE_NOT_REGULAR", message: "Yalnızca normal dosyalar okunabilir.", category: "tool_failure"))
        }
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size <= maxLocalReadBytes else {
                return (nil, RovaError(code: "FILE_TOO_LARGE", message: "Bu dosya tek yanıt için çok büyük; daha küçük bir dosya veya sayfalı belge okuma kullan.", category: "tool_failure"))
            }
            let bytes = try Data(contentsOf: file, options: [.mappedIfSafe])
            let mimeType = mimeType(for: file)
            if let text = String(data: bytes, encoding: .utf8) {
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
            return RovaError(code: "FILE_NOT_FOUND", message: "Silinecek dosya bulunamadı.", category: "tool_failure")
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

    private static func resolvedLocalURL(_ rawPath: String, allowingMissingLastComponent: Bool = false) -> URL? {
        guard RovaValidation.isValidLocalPath(rawPath) else { return nil }
        let expanded = (rawPath as NSString).expandingTildeInPath
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
