import Foundation

/// One device's copy of a project and how it relates to the hub, with the sync rules in one place so the
/// iPhone and the Mac behave identically (the Mac maps `files` to a folder, the iPhone to its store).
///
/// - `files`: what is here now.
/// - `base`: for every file, the content hash at hub version `version` (what was last in step).
///
/// Local edits are the difference between `files` and `base`. They are pushed on top of `version`;
/// disjoint files merge, the same file changed differently keeps both (the local one is saved next to it).
public struct ActReplica: Codable, Sendable, Equatable {
    public var hubId: Int?
    public var version: Int
    public var meta: ActProjectMeta
    public var files: [String: String]
    public var base: [String: String]

    public init(hubId: Int? = nil, version: Int = 0, meta: ActProjectMeta, files: [String: String] = [:], base: [String: String] = [:]) {
        self.hubId = hubId
        self.version = version
        self.meta = meta
        self.files = files
        self.base = base
    }
}

public struct ActSyncReport: Sendable, Equatable {
    public var pushed = 0
    public var pulled = 0
    public var conflictCopies: [String] = []
    public var changed: Bool { pushed + pulled > 0 || !conflictCopies.isEmpty }
}

public enum ActSync {
    public static let maxFiles = 40
    public static let maxFileBytes = 100 * 1024
    private static let textExtensions: Set<String> = ["html", "htm", "css", "js", "json", "txt", "md", "py", "svg", "csv"]

    public static func isSafePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.contains("\\") && !path.contains("\0") && parts.count <= 4
            && parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
    }

    /// Files the hub accepts (text, small, a few folders deep).
    public static func isSyncable(path: String, content: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return isSafePath(path) && textExtensions.contains(ext) && content.utf8.count <= maxFileBytes && path.split(separator: "/").count <= 4
            && !path.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// New and changed files, and deleted ones (`nil`), compared with the last state in step.
    public static func localChanges(_ replica: ActReplica, keys: ActKeys) -> [(path: String, content: String?)] {
        var changes: [(path: String, content: String?)] = []
        for (path, content) in replica.files.sorted(by: { $0.key < $1.key }) where replica.base[path] != keys.contentHash(path, content) {
            changes.append((path, content))
        }
        for path in replica.base.keys.sorted() where replica.files[path] == nil { changes.append((path, nil)) }
        return changes
    }

    public static func conflictCopyName(_ path: String, device: String) -> String {
        let ns = path as NSString
        let ext = ns.pathExtension
        return "\(ns.deletingPathExtension) - \(device) kopyası" + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// Makes the project exist on the hub (once) and returns its id.
    public static func ensureOnHub(_ replica: inout ActReplica, hub: ActHub, keys: ActKeys) async throws {
        guard replica.hubId == nil else { return }
        replica.hubId = try await hub.createProject(meta: keys.seal(replica.meta))
        replica.version = 0
        replica.base = [:]
    }

    /// One full pass: push local edits, then take whatever is newer on the hub.
    @discardableResult
    public static func syncOnce(_ replica: inout ActReplica, hub: ActHub, keys: ActKeys, device: String, summary: String = "değişiklik") async throws -> ActSyncReport {
        var report = ActSyncReport()
        // A project with nothing in it is not worth a hub entry (and an unfinished create must never leave one behind).
        if replica.hubId == nil && replica.files.isEmpty { return report }
        try await ensureOnHub(&replica, hub: hub, keys: keys)
        guard let id = replica.hubId else { return report }

        let local = localChanges(replica, keys: keys).filter { change in
            change.content.map { isSyncable(path: change.path, content: $0) } ?? true
        }
        if !local.isEmpty {
            let sealed = try local.map { change -> ActHub.SealedFile in
                let token = keys.pathToken(change.path)
                guard let content = change.content else { return ActHub.SealedFile(p: token, b: try keys.seal(ActFileEnvelope(path: change.path, content: nil)), h: nil, deleted: true) }
                return ActHub.SealedFile(p: token, b: try keys.seal(ActFileEnvelope(path: change.path, content: content)), h: keys.contentHash(change.path, content))
            }
            switch try await hub.push(id: id, baseVersion: replica.version, changes: sealed, summary: try keys.seal(["text": summary]), device: device) {
            case .ok(let version, let merged):
                for change in local {
                    if let content = change.content { replica.base[change.path] = keys.contentHash(change.path, content) }
                    else { replica.base.removeValue(forKey: change.path) }
                }
                // A merged push sits on versions this copy has not seen: stay at the old version so they are pulled below.
                if !merged { replica.version = version }
                report.pushed = local.count
            case .conflict(let paths, _):
                let clashing = Set(paths)
                let snapshot = try await hub.snapshot(id: id)
                let opened = try open(snapshot.files, keys: keys)
                var copies: [String] = []
                for change in local {
                    guard clashing.contains(keys.pathToken(change.path)), let mine = change.content else { continue }
                    let original = conflictCopyName(change.path, device: device)
                    var copy = original
                    var index = 2
                    while replica.files[copy] != nil || opened[copy] != nil {
                        let ns = original as NSString
                        copy = "\(ns.deletingPathExtension) \(index)" + (ns.pathExtension.isEmpty ? "" : ".\(ns.pathExtension)")
                        index += 1
                    }
                    replica.files[copy] = mine
                    copies.append(copy)
                }
                adopt(opened, version: snapshot.version, into: &replica, keys: keys, onlyClashing: clashing)
                report.conflictCopies = copies
                return report
            }
        }

        switch try await hub.changes(id: id, since: replica.version) {
        case .versions(let hubVersion, let versions):
            if hubVersion > replica.version {
                for version in versions {
                    for change in version.changes {
                        guard let blob = change.b, let envelope = keys.open(blob, as: ActFileEnvelope.self),
                              isSafePath(envelope.path), change.p == keys.pathToken(envelope.path) else { throw ActVaultError.sealFailed }
                        if let content = envelope.content {
                            guard isSyncable(path: envelope.path, content: content), change.h == keys.contentHash(envelope.path, content) else { throw ActVaultError.sealFailed }
                            replica.files[envelope.path] = content
                            replica.base[envelope.path] = keys.contentHash(envelope.path, content)
                        } else {
                            replica.files.removeValue(forKey: envelope.path)
                            replica.base.removeValue(forKey: envelope.path)
                        }
                        report.pulled += 1
                    }
                    replica.version = version.version
                }
                replica.version = max(replica.version, hubVersion)
            }
        case .needsSnapshot:
            let snapshot = try await hub.snapshot(id: id)
            let opened = try open(snapshot.files, keys: keys)
            adopt(opened, version: snapshot.version, into: &replica, keys: keys, onlyClashing: nil)
            report.pulled = opened.count
        }
        return report
    }

    /// A brand-new copy of a hub project.
    public static func download(hubProject: ActHub.Project, hub: ActHub, keys: ActKeys) async throws -> ActReplica? {
        guard let meta = keys.open(hubProject.meta, as: ActProjectMeta.self) else { return nil }
        let snapshot = try await hub.snapshot(id: hubProject.id)
        var replica = ActReplica(hubId: hubProject.id, version: 0, meta: meta)
        adopt(try open(snapshot.files, keys: keys), version: snapshot.version, into: &replica, keys: keys, onlyClashing: nil)
        return replica
    }

    // MARK: Helpers

    private static func open(_ files: [ActHub.SealedFile], keys: ActKeys) throws -> [String: String] {
        var result: [String: String] = [:]
        for file in files {
            guard let blob = file.b, let envelope = keys.open(blob, as: ActFileEnvelope.self), let content = envelope.content,
                  isSyncable(path: envelope.path, content: content), file.p == keys.pathToken(envelope.path), file.h == keys.contentHash(envelope.path, content),
                  result[envelope.path] == nil, result.count < maxFiles else { throw ActVaultError.sealFailed }
            result[envelope.path] = content
        }
        return result
    }

    /// Takes the hub's files as the new base. Files edited here and not touched on the hub stay as local edits.
    private static func adopt(_ hubFiles: [String: String], version: Int, into replica: inout ActReplica, keys: ActKeys, onlyClashing: Set<String>?) {
        for (path, content) in hubFiles {
            let locallyEdited = replica.base[path] != nil && replica.files[path] != nil && replica.base[path] != keys.contentHash(path, replica.files[path]!)
            let clashing = onlyClashing?.contains(keys.pathToken(path)) ?? true
            if clashing || !locallyEdited { replica.files[path] = content }
            if clashing || !locallyEdited || replica.files[path] == content { replica.base[path] = keys.contentHash(path, content) }
        }
        // Gone from the hub: gone here too unless it was edited here.
        for path in Array(replica.base.keys) where hubFiles[path] == nil {
            let edited = replica.files[path].map { replica.base[path] != keys.contentHash(path, $0) } ?? false
            if !edited { replica.files.removeValue(forKey: path) }
            replica.base.removeValue(forKey: path)
        }
        replica.version = version
    }
}
