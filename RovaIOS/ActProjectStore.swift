import Foundation

/// How a project relates to the person's other devices.
enum ActPrivacyMode: String, Codable, Sendable {
    /// Sealed copy on the sync hub; only the person's own devices hold the key.
    case devices
    /// Never leaves this phone (except the files of a request, handed to the writer when allowed).
    case deviceOnly

    var title: String { self == .devices ? "Bağlı cihazlarım" : "Yalnız bu cihaz" }
    var systemImage: String { self == .devices ? "lock.icloud" : "iphone" }
}

struct ActHistoryChange: Codable, Sendable {
    let path: String
    let before: String?
    let after: String?
}

struct ActHistoryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let summary: String
    let date: Date
    /// false: the page could not be tried on this phone, or the change came from a program that failed.
    let verified: Bool
    /// "Wiqo", "Geri alma", "Başka cihaz"
    let source: String
    let changes: [ActHistoryChange]
    /// Design notes from trying the page on this phone (small tap targets, low contrast); nil when none.
    var notes: [String]? = nil
}

/// One Act project as it lives on this phone: the full copy (files), the hub bookkeeping (`replica`)
/// and the history that makes undo exact. Stored as a file in the app's own folder.
struct ActLocalProject: Codable, Identifiable, Sendable {
    let id: String
    var mode: ActPrivacyMode
    var replica: ActReplica
    var history: [ActHistoryEntry]
    var updatedAt: Date

    var name: String { replica.meta.name }
    var kind: String { replica.meta.kind }
    var isWeb: Bool { kind != "python" }
    var files: [String: String] { replica.files }
    /// The version shown to the person: the hub's for synced projects, a count for device-only ones.
    var versionNumber: Int { replica.hubId == nil ? history.count : max(replica.version, history.count) }
    var look: ActLook { ActLook.read(from: replica.files) }
    var sortedFiles: [(path: String, content: String)] { replica.files.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }

    /// The page, ready to show: styles, scripts and other pages folded in, built here on the phone.
    var bundle: String? {
        guard isWeb else { return nil }
        return ActBundler.bundleWeb(sortedFiles.map { ActBundler.File(path: $0.path, content: $0.content) })
            .map(ActBundler.ensureViewport)
            .map { ActLook.inject($0, files: files) }
    }
}

enum ActProjectStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let user = RovaBackendClient.currentUserID ?? "anonymous"
        let url = base.appendingPathComponent("ActProjects2", isDirectory: true).appendingPathComponent(user, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    static func all() -> [ActLocalProject] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        return names.compactMap { name -> ActLocalProject? in
            guard name.hasSuffix(".json"), let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
            return try? decoder.decode(ActLocalProject.self, from: data)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func save(_ project: ActLocalProject) {
        guard let data = try? JSONEncoder().encode(project) else { return }
        try? data.write(to: file(project.id), options: [.atomic, .completeFileProtection])
    }

    static func delete(_ id: String) { try? FileManager.default.removeItem(at: file(id)) }

    /// The first version of the app kept plaintext copies keyed by the server's ids; they are no longer used.
    static func removeLegacyCopies() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: base.appendingPathComponent("ActProjects", isDirectory: true))
    }
}
