import Foundation

/// The account's sync hub and writer, as one device sees them. Everything stored on the hub is
/// ciphertext (see `ActKeys`); the writer is handed the files of one request and keeps nothing.
public struct ActHub: Sendable {
    public struct Project: Decodable, Sendable { public let id: Int; public let meta: String; public let version: Int; public let updatedAt: String }
    public struct SealedFile: Codable, Sendable {
        public let p: String
        public let b: String?
        public let h: String?
        /// The file was deleted (`b` is a sealed note of which path).
        public let d: Bool?
        public init(p: String, b: String?, h: String?, deleted: Bool = false) { self.p = p; self.b = b; self.h = h; self.d = deleted ? true : nil }
    }
    public struct Snapshot: Decodable, Sendable { public let id: Int; public let meta: String; public let version: Int; public let files: [SealedFile] }
    public struct Version: Decodable, Sendable { public let version: Int; public let summary: String; public let device: String; public let changes: [SealedFile] }
    public enum Changes: Sendable {
        case versions(version: Int, [Version])
        case needsSnapshot(version: Int)
    }
    public struct HistoryEntry: Decodable, Sendable { public let version: Int; public let summary: String; public let device: String; public let createdAt: String }
    public enum PushResult: Sendable {
        case ok(version: Int, merged: Bool)
        case conflict(paths: [String], version: Int)
    }

    // The writer (account token only; the Mac never writes).
    public struct WriterResult: Decodable, Sendable {
        public struct Change: Decodable, Sendable { public let path: String; public let after: String? }
        public let ok: Bool
        public let kind: String
        public let name: String
        public let summary: String
        public let changes: [Change]
        public let needsDeviceCheck: Bool
        public let problems: [String]
    }
    public struct WriterJob: Decodable, Sendable {
        public let id: String
        public let status: String
        public let progress: String
        public let error: String?
        public let result: WriterResult?
        public var finished: Bool { status == "done" || status == "failed" || status == "cancelled" }
    }
    public struct RunResult: Decodable, Sendable { public let exitCode: Int; public let timedOut: Bool; public let stdout: String; public let stderr: String; public let durationMs: Int }

    public enum HubError: LocalizedError, Sendable {
        case server(status: Int, message: String)
        case network(String)
        case notSignedIn
        case badResponse

        public var errorDescription: String? {
            switch self {
            case .server(_, let message): return message
            case .network(let message): return message
            case .notSignedIn: return "Wiqo hesabına bağlı değil."
            case .badResponse: return "Sunucudan geçersiz yanıt geldi."
            }
        }
        public var status: Int? { if case .server(let status, _) = self { return status }; return nil }
    }

    private let baseURL: URL
    private let token: @Sendable () async -> String?
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared, token: @escaping @Sendable () async -> String?) {
        self.baseURL = baseURL
        self.session = session
        self.token = token
    }

    // MARK: Projects

    public func projects() async throws -> [Project] {
        struct Response: Decodable { let projects: [Project] }
        return try await get("code-sync/projects", as: Response.self).projects
    }

    public func createProject(meta: String) async throws -> Int {
        struct Response: Decodable { let id: Int }
        return try await send("POST", "code-sync/projects", body: ["meta": meta], as: Response.self).id
    }

    public func setMeta(id: Int, meta: String) async throws {
        _ = try await send("PUT", "code-sync/projects/\(id)/meta", body: ["meta": meta], as: Ok.self)
    }

    public func deleteProject(id: Int) async throws {
        _ = try await send("DELETE", "code-sync/projects/\(id)", body: nil, as: Ok.self)
    }

    public func snapshot(id: Int) async throws -> Snapshot { try await get("code-sync/projects/\(id)/snapshot", as: Snapshot.self) }

    public func changes(id: Int, since: Int) async throws -> Changes {
        struct Response: Decodable { let version: Int; let versions: [Version]?; let needsSnapshot: Bool? }
        let response = try await get("code-sync/projects/\(id)/changes?since=\(since)", as: Response.self)
        return response.needsSnapshot == true ? .needsSnapshot(version: response.version) : .versions(version: response.version, response.versions ?? [])
    }

    public func history(id: Int) async throws -> [HistoryEntry] {
        struct Response: Decodable { let versions: [HistoryEntry] }
        return try await get("code-sync/projects/\(id)/history", as: Response.self).versions
    }

    /// The ciphertext a version replaced (so a device holding the key can undo it).
    public func versionBefore(id: Int, version: Int) async throws -> [SealedFile] {
        struct Response: Decodable { let files: [SealedFile] }
        return try await get("code-sync/projects/\(id)/versions/\(version)/before", as: Response.self).files
    }

    public func push(id: Int, baseVersion: Int, changes: [SealedFile], summary: String, device: String) async throws -> PushResult {
        struct Response: Decodable { let ok: Bool; let version: Int?; let merged: Bool?; let conflict: Bool?; let paths: [String]?; let error: String? }
        let payload: [String: Any] = [
            "baseVersion": baseVersion, "summary": summary, "device": device,
            "changes": changes.map { ["p": $0.p, "b": $0.b as Any? ?? NSNull(), "h": $0.h as Any? ?? NSNull(), "d": $0.d == true] }
        ]
        let (data, status) = try await raw("POST", "code-sync/projects/\(id)/push", body: payload, acceptable: [409])
        let response = try decode(Response.self, data)
        if status == 409, response.conflict == true { return .conflict(paths: response.paths ?? [], version: response.version ?? baseVersion) }
        guard response.ok, let version = response.version else { throw HubError.server(status: status, message: response.error ?? "Değişiklikler gönderilemedi.") }
        return .ok(version: version, merged: response.merged ?? false)
    }

    // MARK: Writer

    public func startWriter(operation: String, request: String, files: [(path: String, content: String)], kind: String, name: String?) async throws -> String {
        struct Response: Decodable { let jobId: String }
        var body: [String: Any] = ["operation": operation, "request": request, "kind": kind, "files": files.map { ["path": $0.path, "content": $0.content] }]
        if let name { body["name"] = name }
        return try await send("POST", "code-sync/writer/jobs", body: body, as: Response.self).jobId
    }

    public func writerJob(_ id: String) async throws -> WriterJob { try await get("code-sync/writer/jobs/\(id)", as: WriterJob.self) }
    public func cancelWriter(_ id: String) async throws { _ = try await send("POST", "code-sync/writer/jobs/\(id)/cancel", body: [:], as: Ok.self) }
    /// The device has the result; the server forgets it.
    public func acknowledgeWriter(_ id: String) async { _ = try? await send("DELETE", "code-sync/writer/jobs/\(id)", body: nil, as: Ok.self) }

    /// Runs a Python project in the server's sandbox for this one request.
    public func run(files: [(path: String, content: String)]) async throws -> RunResult {
        try await send("POST", "code-sync/run", body: ["files": files.map { ["path": $0.path, "content": $0.content] }], as: RunResult.self, timeout: 60)
    }

    // MARK: Tasks for the person's computer

    public struct PcTask: Decodable, Sendable {
        public let id: Int
        public let status: String
        public let output: String
        public var finished: Bool { status == "done" || status == "failed" }
    }

    public func startPcTask(projectId: Int, action: String) async throws -> PcTask {
        try await send("POST", "code-sync/projects/\(projectId)/pc-tasks", body: ["action": action], as: PcTask.self)
    }

    public func pcTask(_ id: Int) async throws -> PcTask { try await get("code-sync/pc-tasks/\(id)", as: PcTask.self) }

    // The computer's side: pick up what was handed over, answer with the outcome.
    public struct PendingPcTask: Decodable, Sendable { public let id: Int; public let projectId: Int; public let action: String }

    public func pendingPcTasks() async throws -> [PendingPcTask] {
        struct Response: Decodable { let tasks: [PendingPcTask] }
        return try await get("code-sync/pc-tasks/pending", as: Response.self).tasks
    }

    public func finishPcTask(id: Int, ok: Bool, output: String) async {
        _ = try? await send("POST", "code-sync/pc-tasks/\(id)/result", body: ["ok": ok, "output": output], as: Ok.self)
    }

    // MARK: HTTP

    private struct Ok: Decodable { let ok: Bool }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let (data, _) = try await raw("GET", path, body: nil, acceptable: [])
        return try decode(T.self, data)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any]?, as type: T.Type, timeout: TimeInterval = 30) async throws -> T {
        let (data, _) = try await raw(method, path, body: body, acceptable: [], timeout: timeout)
        return try decode(T.self, data)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw HubError.badResponse }
    }

    private func raw(_ method: String, _ path: String, body: [String: Any]?, acceptable: Set<Int>, timeout: TimeInterval = 30) async throws -> (Data, Int) {
        guard let accessToken = await token(), !accessToken.isEmpty else { throw HubError.notSignedIn }
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw HubError.badResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw HubError.network((error as? URLError)?.localizedDescription ?? "Sunucuya ulaşılamadı.") }
        guard let http = response as? HTTPURLResponse else { throw HubError.badResponse }
        guard (200..<300).contains(http.statusCode) || acceptable.contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw HubError.server(status: http.statusCode, message: message ?? "Sunucu \(http.statusCode) döndürdü.")
        }
        return (data, http.statusCode)
    }
}
