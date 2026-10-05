import Foundation

/// Every Act project lives on this phone as a full local copy (files, version and the page ready to
/// open), so it opens and previews with no connection. The account's server is the hub that orders
/// versions for the other devices (Mac, Windows); this store only ever pulls from it.
struct ActLocalProject: Codable, Sendable {
    struct File: Codable, Sendable { let path: String; let content: String }
    let id: Int
    let name: String
    let kind: String
    let version: Int
    let files: [File]
    /// The page with its styles, scripts and other pages folded in (web projects).
    let bundle: String?
}

enum ActProjectStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let user = RovaBackendClient.currentUserID ?? "anonymous"
        let url = base.appendingPathComponent("ActProjects", isDirectory: true).appendingPathComponent(user, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(_ id: Int) -> URL { directory.appendingPathComponent("\(id).json") }

    static func load(_ id: Int) -> ActLocalProject? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? JSONDecoder().decode(ActLocalProject.self, from: data)
    }

    static func localVersion(_ id: Int) -> Int? { load(id)?.version }

    static func save(_ project: ActLocalProject) {
        guard let data = try? JSONEncoder().encode(project) else { return }
        try? data.write(to: file(project.id), options: [.atomic, .completeFileProtection])
    }

    /// Every project copy on this phone, newest version first per id order - the list when offline.
    static func all() -> [ActLocalProject] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { name in
            guard name.hasSuffix(".json"), let id = Int(name.dropLast(5)) else { return nil }
            return load(id)
        }.sorted { $0.id > $1.id }
    }

    static func delete(_ id: Int) { try? FileManager.default.removeItem(at: file(id)) }

    /// Brings the local copy of one project up to the server's version. Returns the copy now on the phone
    /// (nil when there is none and the server could not be reached).
    @discardableResult
    static func pull(_ id: Int, knownServerVersion: Int? = nil) async -> ActLocalProject? {
        let local = load(id)
        if let local, let knownServerVersion, local.version >= knownServerVersion { return local }
        do {
            let snapshot = try await RovaBackendClient.fetchCodeProjectSnapshot(id: id)
            let bundle = snapshot.project.kind == "web" ? try? await RovaBackendClient.fetchCodeProjectBundle(id: id) : nil
            let fresh = ActLocalProject(
                id: id, name: snapshot.project.name, kind: snapshot.project.kind, version: snapshot.project.version,
                files: snapshot.files.map { ActLocalProject.File(path: $0.path, content: $0.content) }, bundle: bundle
            )
            save(fresh)
            return fresh
        } catch {
            return local
        }
    }

    /// After the project list loads: pull what is new, and drop copies of projects that no longer exist.
    static func sync(with projects: [RovaBackendClient.CodeProject]) async {
        let known = Set(projects.map(\.id))
        if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names where name.hasSuffix(".json") {
                if let id = Int(name.dropLast(5)), !known.contains(id) { delete(id) }
            }
        }
        for project in projects where localVersion(project.id) != project.version {
            await pull(project.id, knownServerVersion: project.version)
        }
    }
}
