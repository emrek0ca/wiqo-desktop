import AppKit
import Foundation
import CryptoKit
import PDFKit
import Vision
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

    static func verifiedDesktopFileResult(filename: String, expectedContent: String? = nil, expectedBytes: Int64? = nil, expectedSHA256: String? = nil) -> (data: CommandData?, message: String, error: RovaError?) {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            let error = RovaError(code: "DESKTOP_UNAVAILABLE", message: "Masaüstü klasörüne erişilemedi.")
            return (nil, error.message, error)
        }
        return verifiedFileResult(path: desktop.appendingPathComponent(filename).path, expectedContent: expectedContent, expectedBytes: expectedBytes, expectedSHA256: expectedSHA256)
    }

    /// Read back the committed file before reporting success. Evidence contains metadata only.
    static func verifiedFileResult(path: String, expectedContent: String? = nil, expectedBytes: Int64? = nil, expectedSHA256: String? = nil) -> (data: CommandData?, message: String, error: RovaError?) {
        let failure = RovaError(code: "FILE_VERIFICATION_FAILED", message: "İşlem uygulandı ancak dosya sonucu doğrulanamadı; otomatik tekrar yapılmadı.", category: "tool_failure")
        guard let url = resolvedLocalURL(path), isRegularFile(url),
              let attributes = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = attributes.fileSize,
              expectedBytes == nil || Int64(size) == expectedBytes else {
            return (nil, failure.message, failure)
        }
        if expectedContent != nil || expectedSHA256 != nil {
            guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe),
                  expectedContent == nil || bytes == Data(expectedContent!.utf8),
                  expectedSHA256 == nil || RovaCrypto.sha256Hex(bytes) == expectedSHA256!.lowercased() else {
                return (nil, failure.message, failure)
            }
        }
        let entry = FileSystemEntry(path: url.path, name: url.lastPathComponent, byteCount: Int64(size), modifiedAt: attributes.contentModificationDate, isDirectory: false, fileType: url.pathExtension)
        return (.files([entry]), "Doğrulandı: \(url.path) · \(size) bayt\(expectedSHA256.map { " · SHA-256: \($0.lowercased())" } ?? "")", nil)
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
    static func saveArtifact(_ payload: ArtifactFilePayload, token: String) async -> (data: CommandData?, message: String, error: RovaError?) {
        func fail(code: String, message: String) -> (data: CommandData?, message: String, error: RovaError?) { (nil, message, RovaError(code: code, message: message)) }
        guard RovaValidation.isAllowedArtifactURL(payload.downloadURL),
              let url = URL(string: payload.downloadURL) else {
            return fail(code: "INVALID_ARTIFACT_URL", message: "Artifact indirme adresi güvenli değil.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 45
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return fail(code: "ARTIFACT_DOWNLOAD_FAILED", message: "Artifact backend'den indirilemedi.")
            }
            if let contentType = http.value(forHTTPHeaderField: "Content-Type"), contentType.lowercased().hasPrefix("application/json") {
                return fail(code: "ARTIFACT_DOWNLOAD_FAILED", message: "Artifact backend'den geçerli bir dosya döndürmedi.")
            }
            if let contentLength = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), contentLength > DocumentEngine.maxFileBytes {
                return fail(code: "ARTIFACT_TOO_LARGE", message: "İndirilen dosya desteklenen boyut sınırını aşıyor.")
            }
            var data = Data()
            data.reserveCapacity(min(Int(payload.byteCount ?? DocumentEngine.maxFileBytes), Int(DocumentEngine.maxFileBytes)))
            for try await byte in bytes {
                if data.count >= Int(DocumentEngine.maxFileBytes) {
                    return fail(code: "ARTIFACT_TOO_LARGE", message: "İndirilen dosya desteklenen boyut sınırını aşıyor.")
                }
                data.append(byte)
            }
            if let expectedByteCount = payload.byteCount, Int64(data.count) != expectedByteCount {
                return fail(code: "ARTIFACT_INTEGRITY_FAILED", message: "İndirilen artifact boyut doğrulamasından geçmedi.")
            }
            if let expectedSHA256 = payload.sha256, RovaCrypto.sha256Hex(data) != expectedSHA256.lowercased() {
                return fail(code: "ARTIFACT_INTEGRITY_FAILED", message: "İndirilen artifact bütünlük doğrulamasından geçmedi.")
            }
            return await Task.detached(priority: .userInitiated) {
                DocumentEngine.commitArtifact(data, filename: payload.filename, overwrite: payload.overwrite, destinationDirectory: payload.destinationDirectory)
            }.value
        } catch is CancellationError {
            return fail(code: "CANCELLED", message: "Artifact indirme iptal edildi.")
        } catch {
            return fail(code: "ARTIFACT_DOWNLOAD_FAILED", message: "Artifact indirilemedi.")
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
        guard let file = resolvedLocalURL(payload.path), FileManager.default.fileExists(atPath: file.path) else {
            return (nil, missingPathError(payload.path, message: "Gönderilecek dosya bulunamadı."))
        }
        guard isRegularFile(file), !isSymbolicLink(file) else {
            return (nil, RovaError(code: "INVALID_FILE", message: "Yalnızca normal dosyalar gönderilebilir; klasör veya sembolik bağlantı seçilemez."))
        }
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return (nil, RovaError(code: "FILE_READ_FAILED", message: "Dosya bilgisi okunamadı. Dosyaya erişim iznini kontrol et."))
        }
        guard size > 0 else {
            return (nil, RovaError(code: "INVALID_FILE", message: "Dosya boş; aktarılacak içerik bulunamadı."))
        }
        guard Int64(size) <= maxPhoneTransferBytes else {
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
            guard let receivedBytes = body["byteCount"] as? Int, receivedBytes == size,
                  let receivedHash = body["sha256"] as? String, receivedHash == sha256 else {
                return (nil, RovaError(code: "TRANSFER_UNVERIFIED", message: "Aktarılan dosyanın boyutu veya bütünlüğü doğrulanamadı."))
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

    /// Each source path owns its retention group; unrelated files cannot evict its history.
    /// Failure stops the overwrite. Existing legacy backups are left untouched.
    static func backUp(_ file: URL) -> RovaError? {
        let manager = FileManager.default
        do {
            let identity = RovaCrypto.sha256Hex(Data(file.standardizedFileURL.path.utf8))
            let directory = backupFolder.appendingPathComponent(identity, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let name = "\(stamp)-\(UUID().uuidString)-\(file.lastPathComponent.prefix(80))"
            let target = directory.appendingPathComponent(name)
            try manager.copyItem(at: file, to: target)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            let siblings = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
                .filter { $0 != target }
                .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            for old in siblings.dropLast(backupsKeptPerFile - 1) { try? manager.removeItem(at: old) }
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
        if source.standardizedFileURL == destination.standardizedFileURL {
            return copy ? RovaError(code: "INVALID_FILE_PATH", message: "Kaynak ve hedef aynı dosya olamaz.", category: "validation") : nil
        }
        if isDirectory(source), destination.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/") {
            return RovaError(code: "NESTED_FOLDER_MOVE", message: "Klasör kendi altına taşınamaz.", category: "validation")
        }
        if isDirectory(source) && !payload.recursive {
            return RovaError(code: "RECURSIVE_REQUIRED", message: "Klasör işlemi için recursive=true açıkça belirtilmeli.", category: "permission")
        }
        var target = destination
        if FileManager.default.fileExists(atPath: destination.path) && !payload.overwrite {
            let extensionPart = destination.pathExtension
            let stem = destination.deletingPathExtension().lastPathComponent
            var available: URL?
            for suffix in 2...10_000 {
                let name = "\(stem) (\(suffix))"
                let base = destination.deletingLastPathComponent().appendingPathComponent(name)
                let candidate = extensionPart.isEmpty ? base : base.appendingPathExtension(extensionPart)
                if !FileManager.default.fileExists(atPath: candidate.path), !isSymbolicLink(candidate) {
                    available = candidate
                    break
                }
            }
            guard let available else {
                return RovaError(code: "FILE_EXISTS", message: "Hedefte boş dosya adı bulunamadı.", category: "tool_failure")
            }
            target = available
        }
        if FileManager.default.fileExists(atPath: destination.path) && payload.overwrite {
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
                try FileManager.default.copyItem(at: source, to: target)
            } else {
                try FileManager.default.moveItem(at: source, to: target)
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
            // Documents the system's own text engine can read need no other program at all.
            if app == "Pages", await MainActor.run(body: { nativeDocumentPDF(source: source, output: output) }) { return nil }
            let candidates: [(name: String, bundleID: String, microsoft: Bool)] = {
                switch app {
                case "Pages": return [("Pages", "com.apple.iWork.Pages", false), ("Microsoft Word", "com.microsoft.Word", true)]
                case "Numbers": return [("Numbers", "com.apple.iWork.Numbers", false), ("Microsoft Excel", "com.microsoft.Excel", true)]
                default: return [("Keynote", "com.apple.iWork.Keynote", false), ("Microsoft PowerPoint", "com.microsoft.Powerpoint", true)]
                }
            }()
            var lastFailure: String?
            for candidate in candidates where NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate.bundleID) != nil {
                let failure = candidate.microsoft
                    ? await exportWithMicrosoftOffice(app: candidate.name, source: source, output: output)
                    : await exportWithIWork(app: candidate.name, source: source, output: output)
                if failure == nil { return nil }
                lastFailure = failure
            }
            return lastFailure ?? "Bu dosyayı PDF'e çevirmek için Pages/Numbers/Keynote, Microsoft Office veya LibreOffice kurulu olmalı."
        }
    }

    /// Word, rich text, OpenDocument and HTML files, laid out by the system's text engine onto
    /// Letter pages. Plain and without a program in the way; tables and images come through, the
    /// fine layout of a designed document does not.
    @MainActor
    private static func nativeDocumentPDF(source: URL, output: URL) -> Bool {
        guard let attributed = try? NSAttributedString(url: source, options: [:], documentAttributes: nil), attributed.length > 0 else { return false }
        let page = NSSize(width: 595, height: 842)
        let margin: CGFloat = 54
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: page.width - margin * 2, height: page.height - margin * 2))
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: page.width - margin * 2, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(attributed)
        textView.sizeToFit()
        let info = NSPrintInfo()
        info.paperSize = page
        info.topMargin = margin; info.bottomMargin = margin; info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation.run()
    }

    private static func exportWithMicrosoftOffice(app: String, source: URL, output: URL) async -> String? {
        func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let body: String
        switch app {
        case "Microsoft Word":
            body = """
            open POSIX file \(quoted(source.path))
            save as active document file name \(quoted(output.path)) file format format PDF
            close active document saving no
            """
        case "Microsoft Excel":
            body = """
            open workbook workbook file name \(quoted(source.path))
            save workbook as active workbook filename \(quoted(output.path)) file format PDF file format
            close active workbook saving no
            """
        default:
            body = """
            open \(quoted(source.path))
            save active presentation in \(quoted(output.path)) as save as PDF
            close active presentation
            """
        }
        let script = "with timeout of 110 seconds\n tell application \(quoted(app))\n\(body)\n end tell\nend timeout"
        let result = await runProcess("/usr/bin/osascript", ["-e", script], timeout: 120)
        if result.status == 0 { return nil }
        return result.stderr.contains("-1743") || result.stderr.contains("not allowed")
            ? "\(app) için Wiqo'ya Otomasyon izni ver (Sistem Ayarları › Gizlilik ve Güvenlik › Otomasyon)."
            : "\(app) dosyayı PDF'e çeviremedi."
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

// MARK: - File chores (fileUtility)

extension MacSystem {
    /// One sentence chores on files: a new folder, a zip, merged PDFs, a smaller picture, the text of a scan, a tidy folder.
    /// Every source and destination goes through the same path resolution as the other file commands (no symlink targets,
    /// Turkish folder names translated), and nothing is ever overwritten: a taken name gets " 2".
    static func fileUtility(_ payload: FileUtilityPayload) async -> (data: CommandData?, message: String, error: RovaError?) {
        let manager = FileManager.default
        func fail(_ code: String, _ message: String, category: String = "tool_failure") -> (data: CommandData?, message: String, error: RovaError?) {
            (nil, message, RovaError(code: code, message: message, category: category))
        }
        func listing(_ urls: [URL]) -> CommandData { .files(urls.compactMap(fileSystemEntry)) }
        func report(_ path: String, _ text: String) -> CommandData {
            .fileData(FileDataContent(path: path, mimeType: "text/plain", text: String(text.prefix(20_000)), truncated: text.count > 20_000))
        }
        func existing(_ raw: String?) -> URL? { raw.flatMap { resolvedLocalURL($0) } }
        func missing(_ raw: String?) -> (data: CommandData?, message: String, error: RovaError?) {
            let error = missingPathError(raw ?? "", message: "\"\(raw ?? "")\" bulunamadı.")
            return (nil, error.message, error)
        }
        func freeURL(_ url: URL) -> URL {
            guard manager.fileExists(atPath: url.path) else { return url }
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            for index in 2...999 {
                let candidate = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
                if !manager.fileExists(atPath: candidate.path) { return candidate }
            }
            return url
        }
        func target(_ raw: String?, fallback: URL) -> URL? {
            guard let raw else { return freeURL(fallback) }
            if let folder = resolvedLocalURL(raw), isDirectory(folder) { return freeURL(folder.appendingPathComponent(fallback.lastPathComponent)) }
            return resolvedLocalURL(raw, allowingMissingLastComponent: true).map(freeURL)
        }
        func regularFiles(in folder: URL, recursive: Bool, cap: Int) -> [URL] {
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            var found: [URL] = []
            if recursive {
                let walker = manager.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let url = walker?.nextObject() as? URL, found.count < cap {
                    if isRegularFile(url), !isSymbolicLink(url) { found.append(url) }
                }
            } else {
                let items = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
                found = Array(items.filter { isRegularFile($0) && !isSymbolicLink($0) }.prefix(cap))
            }
            return found
        }
        func size(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        func human(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        func short(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

        switch payload.action {
        case .inspect:
            guard let raw = payload.path,
                  let url = resolvedLocalURL(raw, allowingMissingLastComponent: true),
                  !isSymbolicLink(url) else {
                return fail("INVALID_PATH", "Kontrol edilecek yol güvenli değil veya üst klasörüne erişilemiyor.", category: "validation")
            }
            var isFolder: ObjCBool = false
            let exists = manager.fileExists(atPath: url.path, isDirectory: &isFolder)
            if !exists { return (listing([]), "Yol bulunamadı.", nil) }
            guard let entry = fileSystemEntry(url) else {
                return fail("INSPECT_FAILED", "Dosya bilgisi doğrulanamadı.")
            }
            return (.files([entry]), isFolder.boolValue ? "Klasör bulundu." : "Dosya bulundu.", nil)
        case .moveDocuments:
            guard let source = existing(payload.path), isDirectory(source), !isSymbolicLink(source),
                  let destination = payload.destination.flatMap({ resolvedLocalURL($0, allowingMissingLastComponent: true) }),
                  let destinationParent = resolvedLocalURL(destination.deletingLastPathComponent().path), isDirectory(destinationParent),
                  (!manager.fileExists(atPath: destination.path) || isDirectory(destination)), !isSymbolicLink(destination),
                  source.standardizedFileURL != destination.standardizedFileURL else {
                return fail("INVALID_FOLDER", "Kaynak klasör ve hedefin üst klasörü var olmalı; hedef ayrı bir klasör olmalı.")
            }
            let documentTypes: Set<String> = ["pdf", "doc", "docx", "rtf", "odt", "pages", "txt", "md"]
            let entries: [URL]
            do {
                entries = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            } catch {
                return fail("LIST_FAILED", "Kaynak klasördeki dosyalar okunamadı.")
            }
            let documents = entries.filter { isRegularFile($0) && !isSymbolicLink($0) && documentTypes.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            guard documents.count <= payload.limit else {
                return fail("TOO_MANY_DOCUMENTS", "\(documents.count) belge bulundu; bu işlem en fazla \(payload.limit) belgeyi tek seferde taşıyabilir. Hiçbir dosya taşınmadı.")
            }
            guard !documents.isEmpty else { return (listing([]), "Taşınacak belge bulunamadı.", nil) }
            guard documents.allSatisfy({ !manager.fileExists(atPath: destination.appendingPathComponent($0.lastPathComponent).path) && !isSymbolicLink(destination.appendingPathComponent($0.lastPathComponent)) }) else {
                return fail("FILE_EXISTS", "Hedefte aynı adlı belge var; hiçbir dosya taşınmadı.", category: "permission")
            }
            if !manager.fileExists(atPath: destination.path) {
                do { try manager.createDirectory(at: destination, withIntermediateDirectories: false) } catch {
                    return fail("CREATE_FOLDER_FAILED", "Hedef klasör oluşturulamadı; hiçbir belge taşınmadı.")
                }
            }
            var moved: [URL] = []
            for document in documents {
                let target = destination.appendingPathComponent(document.lastPathComponent)
                guard !Task.isCancelled, isRegularFile(document), !isSymbolicLink(document), !manager.fileExists(atPath: target.path), !isSymbolicLink(target) else {
                    return (listing(moved), "\(moved.count)/\(documents.count) belge taşındı; kalanların durumu değişti. Otomatik tekrar yapılmadı.", RovaError(code: "PARTIAL_MOVE", message: "Belge listesi işlem sırasında değişti; sonucu kontrol et.", category: "tool_failure"))
                }
                do { try manager.moveItem(at: document, to: target) } catch {
                    return (listing(moved), "\(moved.count)/\(documents.count) belge taşındı; kalanlar taşınamadı. Otomatik tekrar yapılmadı.", RovaError(code: "PARTIAL_MOVE", message: "Bazı belgeler taşınamadı; sonucu kontrol et.", category: "tool_failure"))
                }
                guard isRegularFile(target), !manager.fileExists(atPath: document.path) else {
                    return (listing(moved), "Taşıma sonucu belirsiz; otomatik tekrar yapılmadı.", RovaError(code: "OUTCOME_UNKNOWN", message: "Dosya taşıma sonucu doğrulanamadı.", category: "tool_failure"))
                }
                moved.append(target)
            }
            return (listing(moved), "\(moved.count) belge \(destination.lastPathComponent) klasörüne taşındı ve doğrulandı.", nil)

        case .createFolder:
            guard let raw = payload.path, let url = resolvedLocalURL(raw, allowingMissingLastComponent: true) else {
                return fail("INVALID_PATH", "Klasörün açılacağı yer yok ya da yol geçersiz; üst klasörü kontrol et.")
            }
            if manager.fileExists(atPath: url.path) {
                return isDirectory(url) ? (listing([url]), "\(url.lastPathComponent) klasörü zaten var.", nil) : fail("ALREADY_EXISTS", "Bu adla bir dosya var.")
            }
            do { try manager.createDirectory(at: url, withIntermediateDirectories: false) } catch {
                let failure = localFileError(code: "CREATE_FOLDER_FAILED", fallback: "Klasör oluşturulamadı.", error: error)
                return (nil, failure.message, failure)
            }
            guard isDirectory(url) else { return fail("POSTCONDITION_FAILED", "Klasör oluşturulduğu doğrulanamadı.") }
            return (listing([url]), "\(url.lastPathComponent) klasörü oluşturuldu.", nil)

        case .archive:
            let raws = (payload.paths ?? []) + (payload.path.map { [$0] } ?? [])
            var sources: [URL] = []
            for raw in raws { guard let url = existing(raw) else { return missing(raw) }; sources.append(url) }
            guard let first = sources.first else { return fail("INVALID_PAYLOAD", "Arşivlenecek dosya yok.") }
            let name = sources.count == 1 ? first.deletingPathExtension().lastPathComponent : "Arşiv"
            guard let output = target(payload.destination, fallback: first.deletingLastPathComponent().appendingPathComponent("\(name).zip")) else { return fail("INVALID_PATH", "Arşivin kaydedileceği yer geçersiz. Hedef klasör yoksa önce fileUtility createFolder ile oluştur, sonra işlemi tekrarla.") }
            var input = first
            var scratch: URL?
            if sources.count > 1 {
                let folder = manager.temporaryDirectory.appendingPathComponent("wiqo-zip-\(UUID().uuidString)").appendingPathComponent(name)
                do {
                    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                    for source in sources { try manager.copyItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent)) }
                } catch { return fail("ARCHIVE_FAILED", "Dosyalar arşiv için hazırlanamadı.") }
                input = folder
                scratch = folder.deletingLastPathComponent()
            }
            let result = await runProcess("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", input.path, output.path], timeout: 180)
            if let scratch { try? manager.removeItem(at: scratch) }
            guard result.status == 0, manager.fileExists(atPath: output.path) else { return fail("ARCHIVE_FAILED", "Zip oluşturulamadı.") }
            return (listing([output]), "\(output.lastPathComponent) hazır (\(sources.count) öğe, \(human(size(output)))).", nil)

        case .extract:
            guard let archive = existing(payload.path) else { return missing(payload.path) }
            guard let folder = target(payload.destination, fallback: archive.deletingLastPathComponent().appendingPathComponent(archive.deletingPathExtension().lastPathComponent)) else { return fail("INVALID_PATH", "Açılacak yer geçersiz. Hedef klasör yoksa önce fileUtility createFolder ile oluştur, sonra işlemi tekrarla.") }
            let result = await runProcess("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path], timeout: 180)
            guard result.status == 0, manager.fileExists(atPath: folder.path) else { return fail("EXTRACT_FAILED", "Arşiv açılamadı; zip dosyası mı?") }
            return (listing([folder]), "Arşiv \(folder.lastPathComponent) klasörüne açıldı.", nil)

        case .mergePDF:
            var sources: [URL] = []
            for raw in payload.paths ?? [] { guard let url = existing(raw) else { return missing(raw) }; sources.append(url) }
            let merged = PDFDocument()
            for source in sources {
                guard let document = PDFDocument(url: source) else { return fail("NOT_A_PDF", "\(source.lastPathComponent) PDF olarak açılamadı.") }
                for index in 0..<document.pageCount { if let page = document.page(at: index) { merged.insert(page, at: merged.pageCount) } }
            }
            guard let first = sources.first, let output = target(payload.destination, fallback: first.deletingLastPathComponent().appendingPathComponent("Birleşik.pdf")) else { return fail("INVALID_PATH", "Birleşik PDF'in yeri geçersiz. Hedef klasör yoksa önce fileUtility createFolder ile oluştur, sonra işlemi tekrarla.") }
            guard merged.pageCount > 0, merged.write(to: output) else { return fail("MERGE_FAILED", "PDF'ler birleştirilemedi.") }
            return (listing([output]), "\(sources.count) PDF birleştirildi: \(output.lastPathComponent) (\(merged.pageCount) sayfa).", nil)

        case .splitPDF:
            guard let source = existing(payload.path) else { return missing(payload.path) }
            guard let document = PDFDocument(url: source) else { return fail("NOT_A_PDF", "\(source.lastPathComponent) PDF olarak açılamadı.") }
            guard let folder = target(payload.destination, fallback: source.deletingLastPathComponent().appendingPathComponent("\(source.deletingPathExtension().lastPathComponent) sayfalar")) else { return fail("INVALID_PATH", "Sayfaların yeri geçersiz.") }
            do { try manager.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return fail("SPLIT_FAILED", "Sayfalar için klasör açılamadı.") }
            var outputs: [URL] = []
            for index in 0..<min(document.pageCount, payload.limit) {
                guard let page = document.page(at: index) else { continue }
                let single = PDFDocument()
                single.insert(page, at: 0)
                let url = folder.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-sayfa-\(index + 1).pdf")
                if single.write(to: url) { outputs.append(url) }
            }
            guard !outputs.isEmpty else { return fail("SPLIT_FAILED", "PDF sayfalara ayrılamadı.") }
            return (listing([folder]), "\(outputs.count) sayfa ayrı PDF oldu: \(folder.lastPathComponent).", nil)

        case .compressImage:
            guard let source = existing(payload.path) else { return missing(payload.path) }
            let edge = Int(payload.mode ?? "") ?? 1600
            guard let output = target(payload.destination, fallback: source.deletingLastPathComponent().appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-küçük.jpg")) else { return fail("INVALID_PATH", "Küçük görselin yeri geçersiz.") }
            let result = await runProcess("/usr/bin/sips", ["-Z", String(max(200, min(edge, 8000))), "-s", "format", "jpeg", "-s", "formatOptions", "75", source.path, "--out", output.path], timeout: 60)
            guard result.status == 0, manager.fileExists(atPath: output.path) else { return fail("COMPRESS_FAILED", "Görsel küçültülemedi; bir görsel dosyası mı?") }
            return (listing([output]), "\(output.lastPathComponent): \(human(size(source))) → \(human(size(output))).", nil)

        case .findDuplicates:
            guard let folder = existing(payload.path), isDirectory(folder) else { return missing(payload.path) }
            let files = regularFiles(in: folder, recursive: true, cap: 5_000)
            let bySize = Dictionary(grouping: files.filter { size($0) > 0 }, by: size).filter { $0.value.count > 1 }
            var groups: [[URL]] = []
            for (_, sameSize) in bySize {
                var byHash: [String: [URL]] = [:]
                for url in sameSize {
                    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                    byHash[SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), default: []].append(url)
                }
                groups += byHash.values.filter { $0.count > 1 }
            }
            groups.sort { size($0[0]) * Int64($0.count) > size($1[0]) * Int64($1.count) }
            if groups.isEmpty { return (report(folder.path, "\(files.count) dosyada kopya yok."), "Kopya dosya yok.", nil) }
            let lines = groups.prefix(payload.limit).enumerated().map { index, group in
                "\(index + 1). \(human(size(group[0]))) × \(group.count): " + group.map(short).joined(separator: " | ")
            }
            let wasted = groups.reduce(Int64(0)) { $0 + size($1[0]) * Int64($1.count - 1) }
            return (report(folder.path, lines.joined(separator: "\n")), "\(groups.count) kopya grubu bulundu; silinirse \(human(wasted)) boşalır.", nil)

        case .diskUsage:
            guard let folder = existing(payload.path), isDirectory(folder) else { return missing(payload.path) }
            let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            let free = values?.volumeAvailableCapacityForImportantUsage.map { human($0) } ?? "?"
            let total = values?.volumeTotalCapacity.map { human(Int64($0)) } ?? "?"
            let files = regularFiles(in: folder, recursive: true, cap: 20_000)
            let largest = files.sorted { size($0) > size($1) }.prefix(payload.limit)
            var subfolders: [String: Int64] = [:]
            for file in files {
                let relative = file.path.dropFirst(folder.path.count + 1)
                if let top = relative.split(separator: "/").first, relative.contains("/") { subfolders[String(top), default: 0] += size(file) }
            }
            let topFolders = subfolders.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key): \(human($0.value))" }
            let text = (["Disk: \(free) boş / \(total)", "\(short(folder)) toplam: \(human(files.reduce(0) { $0 + size($1) }))", "En büyük klasörler: " + topFolders.joined(separator: ", "), "En büyük dosyalar:"]
                + largest.map { "- \(short($0)) \(human(size($0)))" }).joined(separator: "\n")
            return (report(folder.path, text), "Disk: \(free) boş.", nil)

        case .recentFiles:
            let home = manager.homeDirectoryForCurrentUser
            let files = ["Desktop", "Documents", "Downloads"].flatMap { regularFiles(in: home.appendingPathComponent($0), recursive: true, cap: 3_000) }
            let recent = Array(files.sorted { modified($0) > modified($1) }.prefix(payload.limit))
            return (listing(recent), "Son değişen \(recent.count) dosya.", nil)

        case .restoreFromTrash:
            let trash = manager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            let items: [URL]
            do { items = try manager.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) } catch {
                let failure = localFileError(code: "TRASH_UNREADABLE", fallback: "Çöp kutusu okunamadı.", error: error)
                return (nil, failure.message, failure)
            }
            let wanted = ApplicationNameMatcher.normalize(payload.name ?? "")
            let ranked = items.map { ($0, ApplicationNameMatcher.score($0.deletingPathExtension().lastPathComponent, query: wanted)) }.sorted { $0.1 > $1.1 }
            guard let best = ranked.first, best.1 >= 0.6 else {
                let names = items.sorted { modified($0) > modified($1) }.prefix(5).map(\.lastPathComponent).joined(separator: ", ")
                return fail("FILE_NOT_FOUND", "Çöpte \"\(payload.name ?? "")\" yok. Son atılanlar: \(names.isEmpty ? "çöp boş" : names).")
            }
            let home = manager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            guard let output = target(payload.destination, fallback: home.appendingPathComponent(best.0.lastPathComponent)) else { return fail("INVALID_PATH", "Geri getirilecek yer geçersiz.") }
            do { try manager.moveItem(at: best.0, to: output) } catch {
                let failure = localFileError(code: "RESTORE_FAILED", fallback: "Dosya çöpten geri getirilemedi.", error: error)
                return (nil, failure.message, failure)
            }
            return (listing([output]), "\(output.lastPathComponent) çöpten \(short(output.deletingLastPathComponent())) klasörüne geri getirildi.", nil)

        case .reveal:
            guard let url = existing(payload.path) else { return missing(payload.path) }
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return (listing([url]), "\(url.lastPathComponent) Finder'da gösterildi.", nil)

        case .openWith:
            guard let url = existing(payload.path) else { return missing(payload.path) }
            let result = await runProcess("/usr/bin/open", ["-a", payload.name ?? "", url.path], timeout: 20)
            guard result.status == 0 else { return fail("APPLICATION_NOT_FOUND", "\"\(payload.name ?? "")\" uygulaması bulunamadı ya da dosyayı açamadı.") }
            return (listing([url]), "\(url.lastPathComponent) \(payload.name ?? "") ile açıldı.", nil)

        case .print:
            guard let url = existing(payload.path) else { return missing(payload.path) }
            let result = await runProcess("/usr/bin/lp", [url.path], timeout: 30)
            guard result.status == 0 else { return fail("PRINT_FAILED", result.stderr.isEmpty ? "Yazdırılamadı; varsayılan yazıcı tanımlı mı?" : "Yazdırılamadı: \(result.stderr.prefix(160))") }
            return (listing([url]), "\(url.lastPathComponent) yazıcıya gönderildi.", nil)

        case .ocr:
            guard let url = existing(payload.path) else { return missing(payload.path) }
            var images: [CGImage] = []
            if url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) {
                for index in 0..<min(document.pageCount, 10) {
                    guard let page = document.page(at: index) else { continue }
                    let bounds = page.bounds(for: .mediaBox)
                    let scale = 2000 / max(bounds.width, bounds.height, 1)
                    if let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil) { images.append(image) }
                }
            } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                images.append(image)
            }
            guard !images.isEmpty else { return fail("OCR_UNSUPPORTED", "Bu dosyadan görüntü alınamadı; PDF ya da görsel olmalı.") }
            var pages: [String] = []
            for image in images {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["tr-TR", "en-US"]
                request.usesLanguageCorrection = true
                try? VNImageRequestHandler(cgImage: image).perform([request])
                pages.append((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
            }
            let text = pages.enumerated().map { pages.count > 1 ? "— Sayfa \($0.offset + 1) —\n\($0.element)" : $0.element }.joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fail("OCR_EMPTY", "Görselde okunabilir yazı bulunamadı.") }
            return (report(url.path, text), "\(url.lastPathComponent) okundu (\(images.count) sayfa).", nil)

        case .setTags:
            guard let url = existing(payload.path) else { return missing(payload.path) }
            do { try (url as NSURL).setResourceValue(payload.tags ?? [], forKey: .tagNamesKey) } catch {
                return fail("TAG_FAILED", "Etiketler yazılamadı.")
            }
            return (listing([url]), "\(url.lastPathComponent) etiketlendi: \((payload.tags ?? []).joined(separator: ", ")).", nil)

        case .organize:
            guard let folder = existing(payload.path), isDirectory(folder) else { return missing(payload.path) }
            let byMonth = payload.mode == "month"
            let groups: [(String, Set<String>)] = [
                ("Belgeler", ["doc", "docx", "pages", "txt", "md", "rtf", "odt"]), ("PDF", ["pdf"]),
                ("Tablolar", ["xls", "xlsx", "csv", "numbers", "ods"]), ("Sunumlar", ["ppt", "pptx", "key", "odp"]),
                ("Görseller", ["png", "jpg", "jpeg", "heic", "gif", "webp", "svg", "tiff"]), ("Videolar", ["mov", "mp4", "m4v", "avi"]),
                ("Sesler", ["mp3", "m4a", "wav", "aiff"]), ("Arşivler", ["zip", "rar", "7z", "dmg", "tar", "gz"])
            ]
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM"
            var moved: [String: Int] = [:]
            for file in regularFiles(in: folder, recursive: false, cap: payload.limit) {
                let bucket = byMonth ? formatter.string(from: modified(file)) : (groups.first { $0.1.contains(file.pathExtension.lowercased()) }?.0 ?? "Diğer")
                let destination = folder.appendingPathComponent(bucket, isDirectory: true)
                do {
                    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
                    try manager.moveItem(at: file, to: freeURL(destination.appendingPathComponent(file.lastPathComponent)))
                    moved[bucket, default: 0] += 1
                } catch { continue }
            }
            guard !moved.isEmpty else { return fail("NOTHING_TO_ORGANIZE", "Düzenlenecek dosya yok (alt klasörlerdekilere dokunulmaz).") }
            let summary = moved.sorted { $0.value > $1.value }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            return (listing(moved.keys.sorted().map { folder.appendingPathComponent($0) }), "\(moved.values.reduce(0, +)) dosya klasörlere ayrıldı: \(summary).", nil)

        case .batchRename:
            guard let folder = existing(payload.path), isDirectory(folder), let pattern = payload.name else { return missing(payload.path) }
            let files = regularFiles(in: folder, recursive: false, cap: payload.limit).sorted { modified($0) < modified($1) }
            let width = String(files.count).count
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            var renamed: [URL] = []
            for (index, file) in files.enumerated() {
                let base = pattern
                    .replacingOccurrences(of: "{n}", with: String(format: "%0\(width)d", index + 1))
                    .replacingOccurrences(of: "{name}", with: file.deletingPathExtension().lastPathComponent)
                    .replacingOccurrences(of: "{date}", with: formatter.string(from: modified(file)))
                guard RovaValidation.isValidDesktopFilename(base) else { return fail("INVALID_NAME", "Ad kalıbı geçerli bir dosya adı üretmiyor.") }
                let destination = freeURL(folder.appendingPathComponent(file.pathExtension.isEmpty ? base : "\(base).\(file.pathExtension)"))
                do { try manager.moveItem(at: file, to: destination); renamed.append(destination) } catch { continue }
            }
            guard !renamed.isEmpty else { return fail("RENAME_FAILED", "Yeniden adlandırılacak dosya yok.") }
            return (listing(Array(renamed.prefix(20))), "\(renamed.count) dosya yeniden adlandırıldı.", nil)
        }
    }
}

// MARK: - System chores (systemUtility)

extension MacSystem {
    static func systemUtility(_ payload: SystemUtilityPayload) async -> (data: CommandData?, message: String, error: RovaError?) {
        func fail(_ code: String, _ message: String, category: String = "tool_failure") -> (data: CommandData?, message: String, error: RovaError?) {
            (nil, message, RovaError(code: code, message: message, category: category))
        }
        func report(_ title: String, _ text: String) -> CommandData { .fileData(FileDataContent(path: title, mimeType: "text/plain", text: String(text.prefix(8_000)))) }
        func appleScript(_ source: String) async -> String? {
            await MainActor.run {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else { return "Betik hazırlanamadı." }
                _ = script.executeAndReturnError(&error)
                guard let error else { return nil }
                return (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -1743
                    ? "Wiqo'ya Otomasyon/Erişilebilirlik izni ver (Sistem Ayarları › Gizlilik ve Güvenlik)."
                    : (error[NSAppleScript.errorMessage] as? String ?? "İşlem yapılamadı.")
            }
        }
        switch payload.action {
        case .darkMode:
            let value = payload.mode == "on" ? "true" : payload.mode == "off" ? "false" : "not dark mode"
            if let error = await appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)") {
                return fail("AUTOMATION_PERMISSION", error, category: "permission")
            }
            return (nil, payload.mode == "on" ? "Koyu mod açıldı." : payload.mode == "off" ? "Açık mod açıldı." : "Görünüm değiştirildi.", nil)

        case .topProcesses:
            let result = await runProcess("/bin/ps", ["-Aceo", "pid,pcpu,pmem,comm", "-r"], timeout: 10)
            let lines = (String(data: result.stdout, encoding: .utf8) ?? "").split(separator: "\n").prefix(payload.limit + 1).joined(separator: "\n")
            guard result.status == 0, !lines.isEmpty else { return fail("PROCESS_LIST_FAILED", "Süreçler okunamadı.") }
            return (report("top-processes", lines), "En çok kaynak kullanan \(payload.limit) süreç.", nil)

        case .battery:
            let power = await runProcess("/usr/bin/pmset", ["-g", "batt"], timeout: 10)
            let registry = await runProcess("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"], timeout: 10)
            let summary = String(data: power.stdout, encoding: .utf8) ?? ""
            let details = String(data: registry.stdout, encoding: .utf8) ?? ""
            func value(_ key: String) -> Int? {
                guard let range = details.range(of: "\"\(key)\" = ") else { return nil }
                return Int(details[range.upperBound...].prefix { $0.isNumber })
            }
            var lines = [summary.trimmingCharacters(in: .whitespacesAndNewlines)]
            if let cycles = value("CycleCount") { lines.append("Döngü sayısı: \(cycles)") }
            if let maximum = value("AppleRawMaxCapacity") ?? value("NominalChargeCapacity"), let design = value("DesignCapacity"), design > 0 {
                lines.append("Pil sağlığı: %\(Int(Double(maximum) / Double(design) * 100))")
            }
            guard !summary.isEmpty else { return fail("BATTERY_UNAVAILABLE", "Pil bilgisi okunamadı (masaüstü Mac olabilir).") }
            return (report("battery", lines.joined(separator: "\n")), "Pil durumu okundu.", nil)

        case .arrangeWindows:
            guard let screen = await MainActor.run(body: { NSScreen.main.map { ($0.frame, $0.visibleFrame) } }) else { return fail("NO_SCREEN", "Ekran bulunamadı.") }
            let (frame, visible) = screen
            let top = Int(frame.maxY - visible.maxY), left = Int(visible.minX), width = Int(visible.width), height = Int(visible.height)
            let owners = ((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [])
                .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
                .compactMap { $0[kCGWindowOwnerName as String] as? String }
                .filter { $0 != "Wiqo" }
            var apps: [String] = []
            for owner in owners where !apps.contains(owner) { apps.append(owner) }
            guard let first = apps.first else { return fail("NO_WINDOW", "Düzenlenecek açık pencere yok.") }
            func place(_ app: String, x: Int, w: Int) -> String {
                "tell application \"System Events\" to tell process \"\(app.replacingOccurrences(of: "\"", with: ""))\" to tell front window to set {position, size} to {{\(x), \(top)}, {\(w), \(height)}}"
            }
            if payload.mode == "maximize" {
                if let error = await appleScript(place(first, x: left, w: width)) { return fail("ACCESSIBILITY_PERMISSION", error, category: "permission") }
                return (nil, "\(first) penceresi ekranı kapladı.", nil)
            }
            guard apps.count >= 2 else { return fail("ONE_WINDOW", "Yan yana koymak için iki uygulama penceresi açık olmalı.") }
            if let error = await appleScript(place(first, x: left, w: width / 2)) { return fail("ACCESSIBILITY_PERMISSION", error, category: "permission") }
            if let error = await appleScript(place(apps[1], x: left + width / 2, w: width / 2)) { return fail("ACCESSIBILITY_PERMISSION", error, category: "permission") }
            return (nil, "\(first) ve \(apps[1]) yan yana dizildi.", nil)

        case .speak:
            let manager = FileManager.default
            let input = manager.temporaryDirectory.appendingPathComponent("wiqo-say-\(UUID().uuidString).txt")
            let stamp = ISO8601DateFormatter().string(from: Date()).prefix(16).replacingOccurrences(of: ":", with: ".")
            let output = manager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Wiqo ses \(stamp).m4a")
            do { try (payload.text ?? "").write(to: input, atomically: true, encoding: .utf8) } catch { return fail("SPEAK_FAILED", "Metin hazırlanamadı.") }
            let result = await runProcess("/usr/bin/say", ["-f", input.path, "-o", output.path, "--file-format=m4af"], timeout: 180)
            try? manager.removeItem(at: input)
            guard result.status == 0, manager.fileExists(atPath: output.path) else { return fail("SPEAK_FAILED", "Ses dosyası oluşturulamadı.") }
            return (.files([fileSystemEntry(output)].compactMap { $0 }), "Ses dosyası masaüstüne kaydedildi: \(output.lastPathComponent).", nil)
        }
    }
}
