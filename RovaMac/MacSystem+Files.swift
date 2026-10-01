import AppKit
import Foundation
import CryptoKit
import UniformTypeIdentifiers

/// Reading, writing and moving files and documents on this Mac.
extension MacSystem {
    static func localAnalysis(_ payload: LocalAnalysisPayload) -> (data: CommandData?, error: RovaError?) {
        if payload.action == .workspaceDiff {
            guard let path = payload.path, let directory = resolvedLocalURL(path), isDirectory(directory) else {
                return (nil, RovaError(code: "LOCAL_PATH_INVALID", message: "Çalışma alanı klasörü bulunamadı.", category: "validation"))
            }
            let changed = LocalWorkspaceSnapshotStore.shared.diff(directory: directory, limit: payload.limit)
            let content = LocalAnalysisContent(action: payload.action, adapter: "filesystem", available: true, text: changed.initial ? "Çalışma alanı başlangıç durumu kaydedildi." : nil, changedFiles: changed.files, truncated: changed.truncated)
            return (.localAnalysis(content), nil)
        }

        var path: String?
        if let rawPath = payload.path {
            guard let url = resolvedLocalURL(rawPath), !isSymbolicLink(url) else {
                return (nil, RovaError(code: "LOCAL_PATH_INVALID", message: "Yerel analiz yolu bulunamadı veya güvenli değil.", category: "validation"))
            }
            path = url.path
        }
        let cacheKey = LocalAnalysisResultCache.key(for: payload, resolvedPath: path)
        if let cacheKey, let cached = LocalAnalysisResultCache.shared.value(for: cacheKey) {
            return (.localAnalysis(cached), nil)
        }
        let request: [String: Any] = [
            "action": payload.action.rawValue,
            "path": path.map { $0 as Any } ?? NSNull(),
            "query": payload.query.map { $0 as Any } ?? NSNull(),
            "expression": payload.expression.map { $0 as Any } ?? NSNull(),
            "variables": payload.variables.map { $0 as Any } ?? NSNull(),
            "limit": payload.limit
        ]
        guard JSONSerialization.isValidJSONObject(request),
              let requestData = try? JSONSerialization.data(withJSONObject: request) else {
            return (nil, RovaError(code: "LOCAL_ANALYSIS_INVALID", message: "Yerel analiz parametreleri hazırlanamadı.", category: "validation"))
        }
        let snapshot = runProcess(
            executable: "/usr/bin/env",
            arguments: ["python3", "-c", localAnalysisPython, requestData.base64EncodedString()],
            timeoutSeconds: 45,
            environment: [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": NSHomeDirectory(),
                "USER": NSUserName(),
                "LANG": "en_US.UTF-8"
            ]
        )
        if snapshot.timedOut {
            return (nil, RovaError(code: "LOCAL_ANALYSIS_TIMEOUT", message: "Yerel analiz için ayrılan süre doldu.", category: "timeout"))
        }
        guard snapshot.exitCode == 0,
              let response = try? JSONDecoder().decode(LocalAnalysisWorkerResponse.self, from: snapshot.stdout) else {
            return (nil, RovaError(code: "LOCAL_ANALYSIS_FAILED", message: "Yerel analiz tamamlanamadı.", category: "tool_failure"))
        }
        if response.ok != true {
            let code = response.errorCode ?? (response.available == false ? "DEPENDENCY_MISSING" : "LOCAL_ANALYSIS_FAILED")
            return (nil, RovaError(code: code, message: response.errorMessage ?? "Yerel analiz bağımlılığı kullanılamıyor.", category: "tool_failure"))
        }
        let dependencies = (response.dependencies ?? [:]).map { LocalDependencyStatus(name: $0.key, available: $0.value) }.sorted { $0.name < $1.name }
        let content = LocalAnalysisContent(
            action: payload.action,
            adapter: response.adapter ?? "python",
            available: response.available ?? true,
            text: response.text,
            columns: response.columns ?? [],
            rows: response.rows ?? [],
            dependencies: dependencies,
            truncated: response.truncated ?? snapshot.truncated
        )
        if let cacheKey { LocalAnalysisResultCache.shared.insert(content, for: cacheKey) }
        return (.localAnalysis(content), nil)
    }

    private static let localAnalysisPython = #"""
import base64, importlib.util, json, os, re, sys

def emit(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")))

request = json.loads(base64.b64decode(sys.argv[1]).decode("utf-8"))
action = request.get("action")
limit = max(1, min(int(request.get("limit") or 100), 500))
modules = {"markitdown": "markitdown", "duckdb": "duckdb", "sympy": "sympy"}

if action == "dependencyStatus":
    emit({"ok": True, "adapter": "python", "available": True, "dependencies": {name: importlib.util.find_spec(module) is not None for name, module in modules.items()}})
    raise SystemExit(0)

required = {"extractDocument": "markitdown", "queryData": "duckdb", "solveSymbolic": "sympy"}.get(action)
if not required or importlib.util.find_spec(modules[required]) is None:
    emit({"ok": False, "available": False, "errorCode": "DEPENDENCY_MISSING", "errorMessage": f"{required or 'İstenen'} yerel analiz bağımlılığı kurulu değil."})
    raise SystemExit(0)

try:
    if action == "extractDocument":
        from markitdown import MarkItDown
        result = MarkItDown().convert(request["path"])
        text = (getattr(result, "text_content", "") or "").strip()
        ceiling = min(limit * 100, 50000)
        emit({"ok": True, "adapter": "markitdown", "available": True, "text": text[:ceiling], "truncated": len(text) > ceiling})
    elif action == "queryData":
        import duckdb
        query = (request.get("query") or "").strip()
        if not re.match(r"^(select|with)\b", query, re.I) or ";" in query or re.search(r"\b(attach|copy|create|delete|drop|export|import|insert|install|load|pragma|update|call|read_[a-z0-9_]*|[a-z0-9_]*scan|httpfs|sqlite|postgres|glob|secret)\b", query, re.I):
            raise ValueError("unsafe query")
        path = request["path"]
        escaped = path.replace("'", "''")
        extension = os.path.splitext(path)[1].lower()
        readers = {".csv": "read_csv_auto", ".tsv": "read_csv_auto", ".json": "read_json_auto", ".jsonl": "read_json_auto", ".parquet": "read_parquet"}
        reader = readers.get(extension)
        if not reader:
            raise ValueError("unsupported data format")
        con = duckdb.connect(database=":memory:")
        con.execute(f"CREATE VIEW data AS SELECT * FROM {reader}('{escaped}')")
        cursor = con.execute(query)
        columns = [item[0] for item in (cursor.description or [])]
        values = cursor.fetchmany(limit + 1)
        rows = [["" if value is None else str(value) for value in row] for row in values[:limit]]
        emit({"ok": True, "adapter": "duckdb", "available": True, "columns": columns, "rows": rows, "truncated": len(values) > limit})
    elif action == "solveSymbolic":
        import sympy as sp
        expression = (request.get("expression") or "").strip()
        if not re.match(r"^[A-Za-z0-9+*/^=(), \t.-]+$", expression) or "__" in expression:
            raise ValueError("unsafe expression")
        names = request.get("variables") or sorted(set(re.findall(r"\b[A-Za-z][A-Za-z0-9]{0,31}\b", expression)) - {"sin", "cos", "tan", "sqrt", "exp", "log", "Abs"})
        symbols = {name: sp.Symbol(name) for name in names}
        locals_map = {**symbols, "sin": sp.sin, "cos": sp.cos, "tan": sp.tan, "sqrt": sp.sqrt, "exp": sp.exp, "log": sp.log, "Abs": sp.Abs}
        if "=" in expression:
            left, right = expression.split("=", 1)
            parsed = sp.Eq(sp.sympify(left.replace("^", "**"), locals=locals_map), sp.sympify(right.replace("^", "**"), locals=locals_map))
        else:
            parsed = sp.sympify(expression.replace("^", "**"), locals=locals_map)
        result = sp.solve(parsed, list(symbols.values()), dict=True) if symbols else sp.simplify(parsed)
        emit({"ok": True, "adapter": "sympy", "available": True, "text": str(result)[:50000], "truncated": len(str(result)) > 50000})
except Exception:
    emit({"ok": False, "available": True, "errorCode": "LOCAL_ANALYSIS_FAILED", "errorMessage": "Yerel analiz girdisi işlenemedi."})
"""#

    private struct LocalAnalysisWorkerResponse: Decodable {
        let ok: Bool?
        let adapter: String?
        let available: Bool?
        let text: String?
        let columns: [String]?
        let rows: [[String]]?
        let dependencies: [String: Bool]?
        let truncated: Bool?
        let errorCode: String?
        let errorMessage: String?
    }
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
        await MacFileSearch.search(payload)
    }

    /// A folder the person named ("~/Downloads", an absolute path): it must exist and be a folder.
    static func resolvedLocalFolder(_ rawPath: String) -> URL? {
        guard let url = resolvedLocalURL(rawPath), isDirectory(url) else { return nil }
        return url
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
        if FileManager.default.fileExists(atPath: destination.path), let failure = backUp(destination) {
            return failure
        }
        do {
            try Data(content.utf8).write(to: destination, options: [.atomic])
            return nil
        } catch {
            return localFileError(code: "FILE_WRITE_FAILED", fallback: "Dosya yazılamadı.", error: error)
        }
    }

    /// Where the previous version of a file goes before Wiqo replaces it, so an edit can be undone.
    static var backupFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wiqo/Backups", isDirectory: true)
    }

    private static let backupsKeptPerFile = 10

    /// Copies `file` to `Backups/<name>.<yyyyMMdd-HHmmss>.<ext>` and trims older copies of it.
    /// Failing to back up stops the overwrite: a replaced file must stay recoverable.
    private static func backUp(_ file: URL) -> RovaError? {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: backupFolder, withIntermediateDirectories: true)
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let base = file.deletingPathExtension().lastPathComponent
            let ext = file.pathExtension
            let name = "\(base).\(stamp.string(from: Date()))" + (ext.isEmpty ? "" : ".\(ext)")
            try manager.copyItem(at: file, to: backupFolder.appendingPathComponent(name))
            let siblings = ((try? manager.contentsOfDirectory(atPath: backupFolder.path)) ?? [])
                .filter { $0.hasPrefix("\(base).") && $0.hasSuffix(ext.isEmpty ? "" : ".\(ext)") }
                .sorted()
            for old in siblings.dropLast(backupsKeptPerFile) {
                try? manager.removeItem(at: backupFolder.appendingPathComponent(old))
            }
            return nil
        } catch {
            return localFileError(code: "BACKUP_FAILED", fallback: "Eski sürümün yedeği alınamadı, dosya değiştirilmedi.", error: error)
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
            if !isDirectory(destination), let failure = backUp(destination) {
                return failure
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

private final class LocalAnalysisResultCache: @unchecked Sendable {
    static let shared = LocalAnalysisResultCache()
    private let lock = NSLock()
    private var values: [String: LocalAnalysisContent] = [:]
    private var order: [String] = []
    private let capacity = 32

    static func key(for payload: LocalAnalysisPayload, resolvedPath: String?) -> String? {
        guard payload.action != .dependencyStatus && payload.action != .workspaceDiff else { return nil }
        var fileStamp = ""
        if let resolvedPath {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath) else { return nil }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            fileStamp = "\(resolvedPath)|\(size)|\(Int64(modified * 1_000))"
        }
        return [
            payload.action.rawValue,
            fileStamp,
            payload.query ?? "",
            payload.expression ?? "",
            (payload.variables ?? []).joined(separator: ","),
            String(payload.limit)
        ].joined(separator: "\u{1F}")
    }

    func value(for key: String) -> LocalAnalysisContent? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return value
    }

    func insert(_ value: LocalAnalysisContent, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }
}

private final class LocalWorkspaceSnapshotStore: @unchecked Sendable {
    static let shared = LocalWorkspaceSnapshotStore()
    private let lock = NSLock()
    private var snapshots: [String: [String: String]] = [:]

    func diff(directory: URL, limit: Int) -> (files: [String], initial: Bool, truncated: Bool) {
        let current = snapshot(directory)
        lock.lock()
        defer { lock.unlock() }
        let previous = snapshots[directory.path]
        snapshots[directory.path] = current
        guard let previous else { return ([], true, false) }
        let names = Set(previous.keys).union(current.keys)
        let changed = names.filter { previous[$0] != current[$0] }.sorted()
        let ceiling = max(1, min(limit, 500))
        return (Array(changed.prefix(ceiling)), false, changed.count > ceiling)
    }

    private func snapshot(_ directory: URL) -> [String: String] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }
        var result: [String: String] = [:]
        let base = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        let deadline = Date().addingTimeInterval(1.0)
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 20_000 || Date() >= deadline { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let relative = url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.lastPathComponent
            let stamp = Int64((values.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1_000)
            result[relative] = "\(values.fileSize ?? 0):\(stamp)"
        }
        return result
    }
}

// MARK: - Convert to PDF

extension MacSystem {
    /// Turns a file into a PDF next to it (or at the requested path) and returns the new file as a
    /// one-entry listing, so the result shows up as the same file card a search produces. The
    /// original is never touched. Images use `sips`, plain text `cupsfilter`; Word, Excel and
    /// PowerPoint files go through LibreOffice when it is installed, otherwise through Pages,
    /// Numbers or Keynote, which open those formats and export a faithful PDF.
    static func convertFile(_ payload: LocalFileOperationPayload) async -> (data: CommandData?, message: String, error: RovaError?) {
        let manager = FileManager.default
        guard let source = resolvedLocalURL(payload.path), manager.fileExists(atPath: source.path),
              !isDirectory(source), !isSymbolicLink(source),
              let engine = RovaFileConversion.engine(for: source.path) else {
            return (nil, "Dosya bulunamadı veya PDF'e çevrilemez.", RovaError(code: "INVALID_FILE_PATH", message: "Bu dosya PDF'e çevrilemez ya da bulunamadı.", category: "tool_failure"))
        }
        let requested = payload.destination.flatMap { resolvedLocalURL($0, allowingMissingLastComponent: true) }
        if payload.destination != nil, requested == nil {
            return (nil, "Hedef yol geçersiz.", RovaError(code: "INVALID_FILE_PATH", message: "PDF'in kaydedileceği yol geçersiz.", category: "tool_failure"))
        }
        let preferred = requested ?? source.deletingPathExtension().appendingPathExtension("pdf")
        guard isDirectory(preferred.deletingLastPathComponent()) else {
            return (nil, "Hedef klasör yok.", RovaError(code: "INVALID_FILE_PATH", message: "PDF'in kaydedileceği klasör bulunamadı.", category: "tool_failure"))
        }
        let destination = uniqueConversionURL(preferred, overwrite: payload.overwrite)
        // Engines write to a scratch folder first, so a half-written PDF never appears next to the original.
        let scratch = manager.temporaryDirectory.appendingPathComponent("wiqo-convert-\(UUID().uuidString)", isDirectory: true)
        do { try manager.createDirectory(at: scratch, withIntermediateDirectories: true) } catch {
            return (nil, "Geçici klasör açılamadı.", RovaError(code: "CONVERT_FAILED", message: "Dönüştürme başlatılamadı.", category: "tool_failure"))
        }
        defer { try? manager.removeItem(at: scratch) }
        let produced = scratch.appendingPathComponent("out.pdf")
        let failure: String? = await runConversion(engine, source: source, output: produced, scratch: scratch)
        guard failure == nil,
              let size = (try? manager.attributesOfItem(atPath: produced.path))?[.size] as? Int64, size > 0 else {
            let reason = failure ?? "PDF üretilemedi."
            return (nil, reason, RovaError(code: "CONVERT_FAILED", message: reason, category: "tool_failure"))
        }
        do {
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.moveItem(at: produced, to: destination)
        } catch {
            return (nil, "PDF kaydedilemedi.", RovaError(code: "FILE_WRITE_FAILED", message: "PDF hedef klasöre kaydedilemedi.", category: "tool_failure"))
        }
        let entry = FileSystemEntry(path: destination.standardizedFileURL.path, name: destination.lastPathComponent, byteCount: size, modifiedAt: Date(), isDirectory: false, fileType: "pdf")
        return (.files([entry]), "PDF hazır: \(destination.lastPathComponent)", nil)
    }

    private static func uniqueConversionURL(_ url: URL, overwrite: Bool) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path), !overwrite else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        for index in 2...99 {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(index)).pdf")
            if !manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    /// Returns nil on success, otherwise a sentence for the person.
    private static func runConversion(_ engine: RovaFileConversion.Engine, source: URL, output: URL, scratch: URL) async -> String? {
        switch engine {
        case .image:
            let result = await runProcess("/usr/bin/sips", ["-s", "format", "pdf", source.path, "--out", output.path], timeout: 60)
            return result.status == 0 ? nil : "Görsel PDF'e çevrilemedi."
        case .text:
            let result = await runProcess("/usr/sbin/cupsfilter", ["-m", "application/pdf", source.path], timeout: 60)
            guard result.status == 0, !result.stdout.isEmpty else { return "Metin PDF'e çevrilemedi." }
            return (try? result.stdout.write(to: output)) != nil ? nil : "PDF yazılamadı."
        case .office(let app):
            if let soffice = libreOfficeExecutable() {
                let result = await runProcess(soffice, ["--headless", "--convert-to", "pdf", "--outdir", scratch.path, source.path], timeout: 120)
                let converted = scratch.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".pdf")
                if result.status == 0, (try? FileManager.default.moveItem(at: converted, to: output)) != nil { return nil }
            }
            return await exportWithIWork(app: app, source: source, output: output)
        }
    }

    private static func libreOfficeExecutable() -> String? {
        ["/Applications/LibreOffice.app/Contents/MacOS/soffice", "/opt/homebrew/bin/soffice", "/usr/local/bin/soffice"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func exportWithIWork(app: String, source: URL, output: URL) async -> String? {
        let bundleIDs = ["Pages": "com.apple.iWork.Pages", "Numbers": "com.apple.iWork.Numbers", "Keynote": "com.apple.iWork.Keynote"]
        guard let bundleID = bundleIDs[app], NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            return "Bu dosyayı PDF'e çevirmek için \(app) veya LibreOffice kurulu olmalı."
        }
        func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let script = """
        with timeout of 110 seconds
            tell application \(quoted(app))
                set theDocument to open POSIX file \(quoted(source.path))
                export theDocument to POSIX file \(quoted(output.path)) as PDF
                close theDocument saving no
            end tell
        end timeout
        """
        let result = await runProcess("/usr/bin/osascript", ["-e", script], timeout: 120)
        if result.status == 0 { return nil }
        return result.stderr.contains("-1743") || result.stderr.contains("not allowed")
            ? "\(app) için Wiqo'ya Otomasyon izni ver (Sistem Ayarları › Gizlilik ve Güvenlik › Otomasyon)."
            : "\(app) dosyayı PDF'e çeviremedi."
    }

    private struct ProcessResult { let status: Int32; let stdout: Data; let stderr: String }

    private static func runProcess(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch {
                    continuation.resume(returning: ProcessResult(status: -1, stdout: Data(), stderr: "başlatılamadı"))
                    return
                }
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler { if process.isRunning { process.terminate() } }
                timer.resume()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errorData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                continuation.resume(returning: ProcessResult(status: process.terminationStatus, stdout: data, stderr: String(data: errorData, encoding: .utf8) ?? ""))
            }
        }
    }
}
