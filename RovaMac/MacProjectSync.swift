import AppKit
import Foundation

/// Keeps the person's Act projects as real folders on this Mac (`~/Wiqo Projeleri/<ad>/`) in step with
/// their other devices, privately: everything that reaches the sync hub is sealed with a key only the
/// person's devices hold (see `ActKeys`), so the hub cannot read a file name or a file.
///
/// The folder is the full local copy: open it in any editor, run it, preview it here. The rules (push local
/// edits on top of a version, merge disjoint files, keep both sides on a conflict) are `ActSync`'s, shared
/// with the iPhone. Nothing is ever deleted from a folder because a project disappeared remotely.
actor MacProjectSync {
    /// What is written next to the files so the next pass knows where this folder stands.
    private struct Link: Codable {
        var hubId: Int
        var version: Int
        var meta: ActProjectMeta
        var base: [String: String]
    }

    static let metaName = ".wiqo-sync.json"
    private static let previewName = ".wiqo-preview.html"

    private let root: URL
    private let hub: ActHub
    private let device: String
    private let flavor: String
    private let allowRun: @Sendable () -> Bool
    private var loop: Task<Void, Never>?
    private(set) var status = "Senkron kapalı"

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Wiqo Projeleri", isDirectory: true),
         apiBase: URL, device: String = "Mac", flavor: String = "", allowRun: @escaping @Sendable () -> Bool = { false },
         token: @escaping @Sendable () async -> String?) {
        self.root = root
        self.hub = ActHub(baseURL: apiBase, token: token)
        self.device = device
        self.flavor = flavor
        self.allowRun = allowRun
    }

    var folder: URL { root }

    func start() {
        guard loop == nil else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let events = Self.folderEvents(root)
        loop = Task { [weak self] in
            var stamp = -1
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncOnce()
                stamp = await self.waitForSomething(stamp: stamp, events: events)
            }
        }
    }

    /// Waits until another device changed something, a file in the folder changed, or a minute passed.
    private func waitForSomething(stamp: Int, events: AsyncStream<Void>) async -> Int {
        await withTaskGroup(of: Int?.self) { group in
            group.addTask { [hub] in (try? await hub.waitForChange(since: stamp)) ?? stamp }
            group.addTask {
                for await _ in events { return nil }
                return nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(60)); return nil }
            var next = stamp
            if let first = await group.next() { next = first ?? stamp }
            group.cancelAll()
            // A change here is pushed right away; give the editor a moment to finish writing.
            try? await Task.sleep(for: .milliseconds(600))
            return next
        }
    }

    /// One tick for every burst of file changes under the projects folder (FSEvents, 0.8 s latency).
    private static func folderEvents(_ root: URL) -> AsyncStream<Void> {
        AsyncStream { continuation in
            final class Box { let continuation: AsyncStream<Void>.Continuation; init(_ c: AsyncStream<Void>.Continuation) { continuation = c } }
            let box = Unmanaged.passRetained(Box(continuation))
            var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().continuation.yield()
            }
            guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.8, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else {
                box.release()
                continuation.finish()
                return
            }
            let queue = DispatchQueue(label: "wiqo.project-folder-events")
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            nonisolated(unsafe) let handle = stream
            nonisolated(unsafe) let retained = box
            continuation.onTermination = { _ in
                FSEventStreamStop(handle)
                FSEventStreamInvalidate(handle)
                FSEventStreamRelease(handle)
                retained.release()
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
        guard let keys = ActKeyStore.load(flavor: flavor) else {
            status = "Proje anahtarı yok: iPhone'la aynı ağda bağlan ya da kurtarma kodunu gir"
            return status
        }
        do {
            let remote = try await hub.projects()
            var linked = linkedFolders()
            var pushed = 0
            var pulled = 0
            var copies = 0
            var foreign = 0
            for project in remote {
                if let dir = linked[project.id] {
                    let report = try await syncFolder(dir, keys: keys)
                    pushed += report.pushed
                    pulled += report.pulled
                    copies += report.conflictCopies.count
                } else if let replica = try await ActSync.download(hubProject: project, hub: hub, keys: keys) {
                    let dir = newFolder(for: replica.meta.name)
                    try write(replica, into: dir, previous: nil)
                    linked[project.id] = dir
                    pulled += replica.files.count
                } else {
                    foreign += 1
                }
            }
            let imported = try await importNewFolders(known: Set(linked.values.map(\.path)), keys: keys)
            await handlePcTasks(folders: linked)
            status = "Eşit · \(remote.count + imported) proje" + (pushed + pulled + imported > 0 ? " · son: ↑\(pushed + imported) ↓\(pulled)" : "")
                + (copies > 0 ? " · \(copies) çakışma kopyası" : "")
                + (foreign > 0 ? " · \(foreign) proje başka anahtarla şifreli" : "")
        } catch {
            status = "Senkron hatası: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
        return status
    }

    private func syncFolder(_ dir: URL, keys: ActKeys) async throws -> ActSyncReport {
        guard let link = readLink(dir) else { return ActSyncReport() }
        let before = scan(dir)
        var replica = ActReplica(hubId: link.hubId, version: link.version, meta: link.meta, files: before, base: link.base)
        let report = try await ActSync.syncOnce(&replica, hub: hub, keys: keys, device: device, summary: "\(device) düzenlemesi")
        try write(replica, into: dir, previous: before)
        return report
    }

    /// New folders with a page or a program become synced projects.
    private func importNewFolders(known: Set<String>, keys: ActKeys) async throws -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
        var imported = 0
        for dir in entries where !known.contains(dir.path) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, readLink(dir) == nil, !dir.lastPathComponent.hasPrefix(".") else { continue }
            let files = scan(dir)
            guard files.keys.contains("index.html") || files.keys.contains("main.py") else { continue }
            let kind = files.keys.contains("index.html") ? "web" : "python"
            var replica = ActReplica(meta: ActProjectMeta(name: dir.lastPathComponent, kind: kind), files: files)
            try await ActSync.syncOnce(&replica, hub: hub, keys: keys, device: device, summary: "\(device): içe aktarıldı")
            try write(replica, into: dir, previous: files)
            imported += 1
        }
        return imported
    }

    // MARK: - Tasks handed over from the phone

    /// Picks up what the phone handed to this Mac and answers with the outcome. A failure is the task's answer.
    private func handlePcTasks(folders: [Int: URL]) async {
        guard let tasks = try? await hub.pendingPcTasks() else { return }
        for task in tasks {
            let (ok, output) = await perform(task, folder: folders[task.projectId])
            await hub.finishPcTask(id: task.id, ok: ok, output: output)
        }
    }

    private static let editorBundles = [
        "Visual Studio Code": "com.microsoft.VSCode", "Cursor": "com.todesktop.230313mzl4w4u92", "Xcode": "com.apple.dt.Xcode",
        "Sublime Text": "com.sublimetext.4", "TextEdit": "com.apple.TextEdit"
    ]

    private func perform(_ task: ActHub.PendingPcTask, folder: URL?) async -> (Bool, String) {
        guard let folder, FileManager.default.fileExists(atPath: folder.path) else { return (false, "Proje klasörü bu Mac'te yok; senkron bitince tekrar dene.") }
        switch task.action {
        case "open_folder":
            await MainActor.run { _ = NSWorkspace.shared.open(folder) }
            return (true, "Klasör Mac'te açıldı: \(folder.path)")
        case "open_editor":
            let opened = await MainActor.run { () -> Bool in
                for name in ["Visual Studio Code", "Cursor", "Xcode", "Sublime Text", "TextEdit"] {
                    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.editorBundles[name] ?? "") {
                        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                        return true
                    }
                }
                return false
            }
            if !opened { await MainActor.run { _ = NSWorkspace.shared.open(folder) } }
            return (true, opened ? "Klasör editörde açıldı." : "Editör bulunamadı; klasör Finder'da açıldı.")
        case "open_preview":
            // Built here from the folder: the page never has to leave this Mac.
            let files = scan(folder).sorted { $0.key < $1.key }.map { ActBundler.File(path: $0.key, content: $0.value) }
            guard let page = ActBundler.bundleWeb(files).map(ActBundler.ensureViewport) else { return (false, "Bu projede önizlenecek bir sayfa (index.html) yok.") }
            let url = folder.appendingPathComponent(Self.previewName)
            do { try page.write(to: url, atomically: true, encoding: .utf8) } catch { return (false, "Önizleme dosyası yazılamadı.") }
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            return (true, "Sayfa Mac'in tarayıcısında açıldı.")
        case "run":
            guard allowRun() else { return (false, "Mac'te çalıştırma kapalı. Mac'te Wiqo Ayarları > Projeler'den 'Telefondan gelen Python projelerini bu Mac'te çalıştır'ı aç.") }
            return await runPython(in: folder)
        default:
            return (false, "Bilinmeyen görev.")
        }
    }

    /// Runs the project's `main.py` with this Mac's Python (30 s limit, output capped). Only when the person allowed it.
    private func runPython(in folder: URL) async -> (Bool, String) {
        let entry = FileManager.default.fileExists(atPath: folder.appendingPathComponent("main.py").path) ? "main.py"
            : ((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.first { $0.hasSuffix(".py") })
        guard let entry else { return (false, "Projede çalıştırılacak .py dosyası yok.") }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["python3", entry]
                process.currentDirectoryURL = folder
                process.environment = ["PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin", "HOME": NSHomeDirectory(), "PYTHONIOENCODING": "utf-8"]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = out
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: (false, "Python başlatılamadı: \(error.localizedDescription)"))
                    return
                }
                var timedOut = false
                let timer = DispatchWorkItem { timedOut = true; process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                let text = String(decoding: data.prefix(8_000), as: UTF8.self)
                if timedOut { continuation.resume(returning: (false, text + "\nProgram 30 saniyede bitmedi; durduruldu.")) }
                else { continuation.resume(returning: (process.terminationStatus == 0, text.isEmpty ? "(çıktı yok)" : text)) }
            }
        }
    }

    // MARK: - Folder helpers

    private func linkedFolders() -> [Int: URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var result: [Int: URL] = [:]
        for dir in entries { if let link = readLink(dir) { result[link.hubId] = dir } }
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

    private func readLink(_ dir: URL) -> Link? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.metaName)) else { return nil }
        return try? JSONDecoder().decode(Link.self, from: data)
    }

    /// Text files of a project folder, relative path → content (dot files, big files and other types skipped).
    private func scan(_ dir: URL) -> [String: String] {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }
        var files: [String: String] = [:]
        for case let url as URL in walker {
            guard files.count < ActSync.maxFiles,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                  !url.path.contains("/node_modules/"),
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = String(url.path.dropFirst(dir.path.count + 1))
            if ActSync.isSyncable(path: relative, content: content) { files[relative] = content }
        }
        return files
    }

    /// Makes the folder match the replica: changed and new files written, files that were in step and are gone removed.
    private func write(_ replica: ActReplica, into dir: URL, previous: [String: String]?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (path, content) in replica.files where previous?[path] != content {
            let target = dir.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target, atomically: true, encoding: .utf8)
        }
        for path in (previous ?? [:]).keys where replica.files[path] == nil { try? fm.removeItem(at: dir.appendingPathComponent(path)) }
        guard let hubId = replica.hubId else { return }
        let link = Link(hubId: hubId, version: replica.version, meta: replica.meta, base: replica.base)
        try JSONEncoder().encode(link).write(to: dir.appendingPathComponent(Self.metaName), options: .atomic)
    }
}
