import CryptoKit
import Foundation

/// Keeps the person's Act projects as real folders on this Mac (`~/Wiqo Projeleri/<ad>/`) in step with
/// the account's other devices. The folder is the full local copy: it can be opened in any editor, run
/// and previewed here. The server is only the hub that orders versions.
///
/// - Remote changes are written into the folder.
/// - Edits made in the folder are pushed on top of the version they started from. Different files
///   merge; the same file changed on both sides keeps both (the Mac's copy is saved next to it).
/// - A folder with an `index.html` or `main.py` and no sync record becomes a new synced project.
/// Nothing is ever deleted from the folder because a project disappeared remotely.
actor MacProjectSync {
    struct Remote: Decodable { let id: Int; let name: String; let kind: String; let version: Int }

    private struct Meta: Codable {
        var projectId: Int
        var version: Int
        var hashes: [String: String]
    }

    private struct Snapshot: Decodable {
        struct Header: Decodable { let id: Int; let name: String; let kind: String; let version: Int }
        struct File: Decodable { let path: String; let content: String }
        let project: Header
        let files: [File]
    }

    private struct Changes: Decodable {
        struct Version: Decodable {
            struct Change: Decodable { let path: String; let after: String? }
            let version: Int
            let changes: [Change]
        }
        let version: Int
        let versions: [Version]?
        let needsSnapshot: Bool?
    }

    private struct PushResponse: Decodable {
        let ok: Bool
        let version: Int?
        let merged: Bool?
        let conflict: Bool?
        let paths: [String]?
        let error: String?
    }

    static let metaName = ".wiqo-sync.json"
    private static let maxFiles = 40
    private static let maxFileBytes = 100 * 1024
    private static let textExtensions: Set<String> = ["html", "htm", "css", "js", "json", "txt", "md", "py", "svg", "csv"]

    private let root: URL
    private let apiBase: URL
    private let device: String
    private let token: @Sendable () async -> String?
    private var loop: Task<Void, Never>?
    private(set) var status = "Senkron kapalı"

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Wiqo Projeleri", isDirectory: true),
         apiBase: URL, device: String = "Mac", token: @escaping @Sendable () async -> String?) {
        self.root = root
        self.apiBase = apiBase
        self.device = device
        self.token = token
    }

    var folder: URL { root }

    func start() {
        guard loop == nil else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncOnce()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        status = "Senkron kapalı"
    }

    // MARK: - One pass

    /// One full pass; safe to call at any time. Returns a short status line.
    @discardableResult
    func syncOnce() async -> String {
        guard let accessToken = await token(), !accessToken.isEmpty else {
            status = "Wiqo hesabına bağlı değil"
            return status
        }
        do {
            let remote: [Remote] = try await get("code-projects", token: accessToken, key: "projects")
            var pushed = 0
            var pulled = 0
            var conflicts = 0
            var folders = linkedFolders()
            for project in remote {
                let dir = folders[project.id] ?? newFolder(for: project.name)
                if folders[project.id] == nil { folders[project.id] = dir }
                let outcome = try await syncProject(project, in: dir, token: accessToken)
                pushed += outcome.pushed
                pulled += outcome.pulled
                conflicts += outcome.conflicts
            }
            let imported = try await importNewFolders(known: Set(folders.values.map(\.path)), token: accessToken)
            status = "Eşit · \(remote.count + imported) proje" + (pushed + pulled + imported > 0 ? " · son: ↑\(pushed + imported) ↓\(pulled)" : "") + (conflicts > 0 ? " · \(conflicts) çakışma kopyası" : "")
        } catch {
            status = "Senkron hatası: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
        return status
    }

    private struct Outcome { var pushed = 0; var pulled = 0; var conflicts = 0 }

    private func syncProject(_ project: Remote, in dir: URL, token: String) async throws -> Outcome {
        var outcome = Outcome()
        var latest = project.version
        let fm = FileManager.default
        guard var meta = readMeta(dir) else {
            // First time on this Mac: take the whole project.
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let snap: Snapshot = try await get("code-projects/\(project.id)/snapshot", token: token)
            try write(snap, into: dir)
            outcome.pulled = snap.files.count
            return outcome
        }

        // 1. Local edits first: push them on top of the version they started from.
        let (changes, current) = localChanges(dir, meta: meta)
        if !changes.isEmpty {
            let body: [String: Any] = [
                "baseVersion": meta.version, "summary": "\(device) düzenlemesi", "device": device,
                "changes": changes.map { ["path": $0.path, "after": $0.after as Any? ?? NSNull()] }
            ]
            let (data, status) = try await post("code-projects/\(project.id)/push", body: body, token: token, allowStatus: [409])
            let result = try JSONDecoder().decode(PushResponse.self, from: data)
            if status == 409, result.conflict == true {
                // Keep both: the server's file goes in place, this Mac's version is saved beside it and pushed next pass.
                let snap: Snapshot = try await get("code-projects/\(project.id)/snapshot", token: token)
                let clashing = Set(result.paths ?? [])
                for path in clashing {
                    if let mine = current[path] {
                        let copy = conflictCopyName(path)
                        try writeFile(dir.appendingPathComponent(copy), mine)
                    }
                }
                try write(snap, into: dir)
                outcome.conflicts = clashing.count
                return outcome
            }
            guard result.ok, let version = result.version else { throw SyncError.server(result.error ?? "Değişiklikler gönderilemedi.") }
            // A merged push sits on top of versions this folder has not seen: stay at the old version so the
            // pull below brings them in (our own version comes along too and rewrites identical content).
            if result.merged != true { meta.version = version }
            latest = max(latest, version)
            meta.hashes = current.mapValues { Self.hash($0) }
            for change in changes where change.after == nil { meta.hashes.removeValue(forKey: change.path) }
            writeMeta(dir, meta)
            outcome.pushed = changes.count
        }

        // 2. Remote changes since the version this folder is at.
        if latest > meta.version {
            let since: Changes = try await get("code-projects/\(project.id)/changes?since=\(meta.version)", token: token)
            if since.needsSnapshot == true {
                let snap: Snapshot = try await get("code-projects/\(project.id)/snapshot", token: token)
                try write(snap, into: dir, keepingLocalEdits: true)
                outcome.pulled = snap.files.count
            } else {
                var applied = 0
                for version in since.versions ?? [] {
                    for change in version.changes {
                        let target = dir.appendingPathComponent(change.path)
                        if let content = change.after {
                            try writeFile(target, content)
                            meta.hashes[change.path] = Self.hash(content)
                        } else {
                            try? fm.removeItem(at: target)
                            meta.hashes.removeValue(forKey: change.path)
                        }
                        applied += 1
                    }
                    meta.version = version.version
                }
                writeMeta(dir, meta)
                outcome.pulled = applied
            }
        }
        return outcome
    }

    // MARK: - New folders on the Mac become projects

    private func importNewFolders(known: Set<String>, token: String) async throws -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
        var imported = 0
        for dir in entries where !known.contains(dir.path) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, readMeta(dir) == nil,
                  !dir.lastPathComponent.hasPrefix(".") else { continue }
            let files = scan(dir)
            guard !files.isEmpty, files.keys.contains("index.html") || files.keys.contains("main.py") else { continue }
            let kind = files.keys.contains("index.html") ? "web" : "python"
            let body: [String: Any] = [
                "name": dir.lastPathComponent, "kind": kind, "device": device,
                "files": files.map { ["path": $0.key, "content": $0.value] }
            ]
            let (data, _) = try await post("code-projects/import", body: body, token: token, allowStatus: [])
            struct Imported: Decodable { let id: Int; let version: Int }
            let result = try JSONDecoder().decode(Imported.self, from: data)
            writeMeta(dir, Meta(projectId: result.id, version: result.version, hashes: files.mapValues { Self.hash($0) }))
            imported += 1
        }
        return imported
    }

    // MARK: - Folder helpers

    private func linkedFolders() -> [Int: URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var result: [Int: URL] = [:]
        for dir in entries { if let meta = readMeta(dir) { result[meta.projectId] = dir } }
        return result
    }

    private func newFolder(for name: String) -> URL {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        var candidate = root.appendingPathComponent(cleaned.isEmpty ? "Proje" : cleaned, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(cleaned) \(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    private func readMeta(_ dir: URL) -> Meta? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.metaName)) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    private func writeMeta(_ dir: URL, _ meta: Meta) {
        if let data = try? JSONEncoder().encode(meta) { try? data.write(to: dir.appendingPathComponent(Self.metaName), options: .atomic) }
    }

    /// Text files of a project folder, relative path → content (dot files, big files and other types skipped).
    private func scan(_ dir: URL) -> [String: String] {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }
        var files: [String: String] = [:]
        for case let url as URL in walker {
            guard files.count < Self.maxFiles,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                  (values.fileSize ?? 0) <= Self.maxFileBytes, Self.textExtensions.contains(url.pathExtension.lowercased()),
                  !url.path.contains("/node_modules/"),
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = String(url.path.dropFirst(dir.path.count + 1))
            if relative.split(separator: "/").count <= 4 { files[relative] = content }
        }
        return files
    }

    /// What differs from the last synced state: new or changed files and files that are gone.
    private func localChanges(_ dir: URL, meta: Meta) -> ([(path: String, after: String?)], [String: String]) {
        let current = scan(dir)
        var changes: [(path: String, after: String?)] = []
        for (path, content) in current where meta.hashes[path] != Self.hash(content) { changes.append((path, content)) }
        for path in meta.hashes.keys where current[path] == nil { changes.append((path, nil)) }
        return (changes, current)
    }

    private func write(_ snap: Snapshot, into dir: URL, keepingLocalEdits: Bool = false) throws {
        var hashes: [String: String] = [:]
        for file in snap.files {
            let target = dir.appendingPathComponent(file.path)
            if keepingLocalEdits, let mine = try? String(contentsOf: target, encoding: .utf8), mine != file.content {
                try writeFile(dir.appendingPathComponent(conflictCopyName(file.path)), mine)
            }
            try writeFile(target, file.content)
            hashes[file.path] = Self.hash(file.content)
        }
        writeMeta(dir, Meta(projectId: snap.project.id, version: snap.project.version, hashes: hashes))
    }

    private func writeFile(_ url: URL, _ content: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func conflictCopyName(_ path: String) -> String {
        let ns = path as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        return "\(base) - \(device) kopyası" + (ext.isEmpty ? "" : ".\(ext)")
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - HTTP

    private enum SyncError: LocalizedError {
        case server(String)
        var errorDescription: String? { if case .server(let message) = self { return message }; return nil }
    }

    private func request(_ path: String, token: String, method: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: apiBase)!.absoluteURL, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func get<T: Decodable>(_ path: String, token: String) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request(path, token: token, method: "GET"))
        try check(response, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func get<T: Decodable>(_ path: String, token: String, key: String) async throws -> [T] {
        let (data, response) = try await URLSession.shared.data(for: request(path, token: token, method: "GET"))
        try check(response, data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let inner = object[key],
              let slice = try? JSONSerialization.data(withJSONObject: inner) else { return [] }
        return try JSONDecoder().decode([T].self, from: slice)
    }

    private func post(_ path: String, body: [String: Any], token: String, allowStatus: Set<Int>) async throws -> (Data, Int) {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request(path, token: token, method: "POST", body: payload))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !allowStatus.contains(status) { try check(response, data) }
        return (data, status)
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw SyncError.server("Geçersiz yanıt.") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw SyncError.server(message ?? "Sunucu \(http.statusCode) döndürdü.")
        }
    }
}
