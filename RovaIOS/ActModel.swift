import Foundation
import SwiftUI

/// The three steps every Act job goes through, in order.
enum ActStage: Int, CaseIterable {
    case writing, verifying, saving

    var title: String {
        switch self {
        case .writing: return "Yazılıyor"
        case .verifying: return "Telefonda deneniyor"
        case .saving: return "Kaydediliyor"
        }
    }
}

struct ActJobState: Equatable {
    var projectID: String?
    var stage: ActStage
    var message: String
    var writerJobID: String?
}

struct ActError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Everything the Act tab does, in one place: projects live on this phone as full copies, are synced to
/// the person's other devices as ciphertext, and are changed by handing the writer the files of one request.
@MainActor
final class ActModel: ObservableObject {
    static let shared = ActModel()

    @Published private(set) var projects: [ActLocalProject] = []
    @Published private(set) var job: ActJobState?
    @Published private(set) var syncNote: String?
    @Published var notice: String?

    private let hub = ActHub(baseURL: RovaBackendConfig.baseURL) { RovaBackendClient.token }
    private var keys: ActKeys { ActKeyStore.loadOrCreate() }
    private var cancelRequested = false
    private var syncing = false
    private var syncingIDs: Set<String> = []

    private static let device = "iPhone"
    private static let consentKey = "act.writer.consent.v1"

    // MARK: Projects

    func project(_ id: String) -> ActLocalProject? { projects.first { $0.id == id } }

    func reload() {
        projects = ActProjectStore.all()
        ActProjectStore.removeLegacyCopies()
    }

    private func store(_ project: ActLocalProject) {
        var saved = project
        saved.updatedAt = Date()
        ActProjectStore.save(saved)
        if let index = projects.firstIndex(where: { $0.id == saved.id }) { projects[index] = saved } else { projects.insert(saved, at: 0) }
        projects.sort { $0.updatedAt > $1.updatedAt }
    }

    private func diff(_ before: [String: String], _ after: [String: String]) -> [ActHistoryChange] {
        var out: [ActHistoryChange] = []
        for (path, content) in after where before[path] != content { out.append(ActHistoryChange(path: path, before: before[path], after: content)) }
        for (path, content) in before where after[path] == nil { out.append(ActHistoryChange(path: path, before: content, after: nil)) }
        return out.sorted { $0.path < $1.path }
    }

    // MARK: Writer consent

    /// The writer is the one place a project's files leave the phone (to the model, for that request only).
    func needsConsent(for project: ActLocalProject?) -> Bool {
        if project?.mode == .deviceOnly { return true }
        return !UserDefaults.standard.bool(forKey: Self.consentKey)
    }

    func recordConsent() { UserDefaults.standard.set(true, forKey: Self.consentKey) }

    // MARK: Project note

    private static let memoryFile = "PROJE.md"

    /// PROJE.md is the project's memory: what it is for and what has been decided. The device keeps it
    /// (one line per change); the writer is shown it first so a request fits what the project already is.
    /// It is an ordinary file, so it syncs and the person can read and edit it.
    private static func remember(_ files: [String: String], name: String, kind: String, goal: String?, line: String) -> [String: String] {
        var result = files
        let entry = "- \(line.replacingOccurrences(of: "\n", with: " ").prefix(140))"
        if let note = files[memoryFile] {
            var lines = note.components(separatedBy: "\n")
            lines.append(entry)
            let bullets = lines.indices.filter { lines[$0].hasPrefix("- ") }
            if bullets.count > 25 { for index in bullets.prefix(bullets.count - 25).reversed() { lines.remove(at: index) } }
            result[memoryFile] = lines.joined(separator: "\n")
        } else {
            result[memoryFile] = "# \(name)\n\nAmaç: \(goal ?? name)\nTür: \(kind == "python" ? "Python programı" : "Web uygulaması")\n\n## Kararlar ve değişiklikler\n\(entry)"
        }
        return result
    }

    // MARK: Create and change

    /// A new project from a description. Returns its id.
    @discardableResult
    func create(request: String, mode: ActPrivacyMode) async -> String? {
        guard job == nil else { return nil }
        notice = nil
        job = ActJobState(projectID: nil, stage: .writing, message: "Sırada…")
        cancelRequested = false
        defer { job = nil }
        do {
            let result = try await runWriter(operation: "create", request: request, project: nil)
            return try await commit(result, request: request, project: nil, mode: mode)
        } catch {
            if !cancelRequested { notice = (error as? LocalizedError)?.errorDescription ?? "Proje oluşturulamadı." }
            return nil
        }
    }

    func edit(_ id: String, request: String) async {
        guard job == nil, let project = project(id) else { return }
        notice = nil
        job = ActJobState(projectID: id, stage: .writing, message: "Sırada…")
        cancelRequested = false
        defer { job = nil }
        do {
            let result = try await runWriter(operation: "edit", request: request, project: project)
            _ = try await commit(result, request: request, project: project, mode: project.mode)
        } catch {
            if !cancelRequested { notice = (error as? LocalizedError)?.errorDescription ?? "Değişiklik uygulanamadı; proje değişmedi." }
        }
    }

    /// A request that is only a change to a few design values ("koyu tema", "ana renk mavi", "yazıyı büyüt")
    /// is done right here: no writer, no tokens, nothing leaves the phone. Returns false when it needs the writer.
    @discardableResult
    func quickEdit(_ id: String, request: String) -> Bool {
        guard job == nil, var p = project(id), p.isWeb, let result = ActQuickEdits.apply(request, to: p.files) else { return false }
        let before = p.files
        var files = before
        for (path, content) in result.files { files[path] = content }
        files = Self.remember(files, name: p.name, kind: p.kind, goal: nil, line: result.summary)
        p.replica.files = files
        p.history = Array(([ActHistoryEntry(id: UUID(), summary: result.summary, date: Date(), verified: true, source: "Hızlı düzenleme", changes: diff(before, files))] + p.history).prefix(30))
        notice = nil
        store(p)
        if p.mode == .devices { Task { await sync(id) } }
        return true
    }

    func cancel() async {
        cancelRequested = true
        if let id = job?.writerJobID { try? await hub.cancelWriter(id) }
        notice = "Görev durduruldu; proje değişmedi."
    }

    /// Sends the request (and the files it needs) to the stateless writer and follows it to its answer.
    private func runWriter(operation: String, request: String, project: ActLocalProject?) async throws -> ActHub.WriterResult {
        let files = (project?.sortedFiles ?? []).map { (path: $0.path, content: $0.content) }
        let writerID: String
        do {
            writerID = try await hub.startWriter(operation: operation, request: request, files: files, kind: project?.kind ?? "web", name: project?.name)
        } catch {
            throw ActError((error as? LocalizedError)?.errorDescription ?? "Yazara ulaşılamadı.")
        }
        job?.writerJobID = writerID
        var failures = 0
        for _ in 0..<150 {
            if cancelRequested { throw ActError("Görev durduruldu.") }
            do {
                let state = try await hub.writerJob(writerID)
                failures = 0
                if state.finished {
                    await hub.acknowledgeWriter(writerID)
                    guard state.status == "done", let result = state.result else { throw ActError(state.error ?? "Değişiklik üretilemedi.") }
                    return result
                }
                job?.message = state.progress
            } catch let error as ActError {
                throw error
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if (error as? ActHub.HubError)?.status == 404 { throw ActError("Görev sunucuda kalmadı; isteği yeniden gönder.") }
                failures += 1
                if failures >= 15 { throw ActError("Sunucuya ulaşılamadı: \(message)") }
                if failures >= 3 { job?.message = "Bağlantı zayıf, yeniden deneniyor…" }
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
        throw ActError("Görev beklenenden uzun sürdü; biraz sonra tekrar dene.")
    }

    /// Tries a page on this phone, then saves the change (or refuses it) as the new version.
    private func commit(_ result: ActHub.WriterResult, request: String, project: ActLocalProject?, mode: ActPrivacyMode) async throws -> String {
        var files = project?.files ?? [:]
        let before = files
        for change in result.changes {
            if let after = change.after { files[change.path] = after } else { files.removeValue(forKey: change.path) }
        }
        var verified = true
        var warning: String?
        var notes: [String]?
        if result.needsDeviceCheck && result.kind != "python" {
            job?.stage = .verifying
            job?.message = "Sayfa bu telefonun tarayıcısında açılıp deneniyor."
            let list = files.sorted { $0.key < $1.key }.map { ActBundler.File(path: $0.key, content: $0.value) }
            guard let page = ActBundler.bundleWeb(list).map(ActBundler.ensureViewport) else { throw ActError("Projede açılacak bir sayfa yok.") }
            switch await ActWebVerifier().verify(page) {
            case .passed: break
            case .passedWithNotes(let found): notes = found
            case .problems(let problems): throw ActError(problems.first ?? "Sayfa doğrulanamadı; proje değişmedi.")
            case .unavailable:
                verified = false
                warning = "Telefonda denenemedi; değişiklik kaydedildi. Çalışmıyorsa geri alabilirsin."
            }
        }
        job?.stage = .saving
        job?.message = ""
        let summaryLine = result.summary.isEmpty ? String(request.prefix(80)) : result.summary
        files = Self.remember(files, name: project?.name ?? result.name, kind: result.kind, goal: project == nil ? request : nil, line: summaryLine)
        let entry = ActHistoryEntry(id: UUID(), summary: result.summary.isEmpty ? String(request.prefix(80)) : result.summary, date: Date(), verified: verified, source: "Wiqo", changes: diff(before, files), notes: notes)
        var saved: ActLocalProject
        if var existing = project {
            existing.replica.files = files
            existing.history = Array(([entry] + existing.history).prefix(30))
            saved = existing
        } else {
            saved = ActLocalProject(
                id: UUID().uuidString, mode: mode,
                replica: ActReplica(meta: ActProjectMeta(name: result.name, kind: result.kind), files: files),
                history: [entry], updatedAt: Date()
            )
        }
        store(saved)
        if let warning { notice = warning }
        if saved.mode == .devices { Task { await sync(saved.id) } }
        return saved.id
    }

    // MARK: Conflict copies

    /// Files a sync saved next to the hub's version when two devices changed the same file: "x - iPhone kopyası.css" → "x.css".
    static func conflictOriginal(of path: String) -> String? {
        guard let range = path.range(of: #" - [^/.]+ kopyası(?=\.[^./]+$|$)"#, options: .regularExpression) else { return nil }
        return path.replacingCharacters(in: range, with: "")
    }

    func conflictCopies(_ id: String) -> [(copy: String, original: String)] {
        (project(id)?.files.keys.sorted() ?? []).compactMap { path in Self.conflictOriginal(of: path).map { (path, $0) } }
    }

    /// Keeps the copy (it replaces the original) or drops it; either way the copy file goes away.
    func resolveConflict(_ id: String, copy: String, useCopy: Bool) {
        guard var p = project(id), let original = Self.conflictOriginal(of: copy), let content = p.files[copy] else { return }
        let before = p.files
        var files = before
        if useCopy { files[original] = content }
        files.removeValue(forKey: copy)
        p.replica.files = files
        let summary = useCopy ? "Çakışmada kopya seçildi: \(original)" : "Çakışma kopyası silindi: \(copy)"
        p.history = Array(([ActHistoryEntry(id: UUID(), summary: summary, date: Date(), verified: true, source: "Çakışma", changes: diff(before, files))] + p.history).prefix(30))
        store(p)
        if p.mode == .devices { Task { await sync(id) } }
    }

    // MARK: Import, copy

    /// A project from files picked in the Files app (text files only). A single page not named index.html becomes index.html.
    func importProject(name: String, files picked: [String: String], mode: ActPrivacyMode) -> String? {
        var files = picked
        guard !files.isEmpty else { return nil }
        let pages = files.keys.filter { $0.lowercased().hasSuffix(".html") || $0.lowercased().hasSuffix(".htm") }
        if pages.count == 1, !files.keys.contains("index.html"), let page = pages.first, let content = files.removeValue(forKey: page) { files["index.html"] = content }
        let isPython = pages.isEmpty && files.keys.contains { $0.lowercased().hasSuffix(".py") }
        let project = ActLocalProject(
            id: UUID().uuidString, mode: mode,
            replica: ActReplica(meta: ActProjectMeta(name: String(name.prefix(60)), kind: isPython ? "python" : "web"), files: files),
            history: [ActHistoryEntry(id: UUID(), summary: "Dosyalardan içe aktarıldı", date: Date(), verified: true, source: "İçe aktarma", changes: diff([:], files))],
            updatedAt: Date()
        )
        store(project)
        if mode == .devices { Task { await sync(project.id) } }
        return project.id
    }

    /// A separate copy to try things on; it syncs as its own project.
    func duplicate(_ id: String) -> String? {
        guard let source = project(id) else { return nil }
        let copy = ActLocalProject(
            id: UUID().uuidString, mode: source.mode,
            replica: ActReplica(meta: ActProjectMeta(name: String(("\(source.name) kopyası").prefix(60)), kind: source.kind), files: source.files),
            history: [ActHistoryEntry(id: UUID(), summary: "“\(source.name)” projesinin kopyası", date: Date(), verified: true, source: "Kopya", changes: diff([:], source.files))],
            updatedAt: Date()
        )
        store(copy)
        if copy.mode == .devices { Task { await sync(copy.id) } }
        return copy.id
    }

    // MARK: Look

    /// Sets how the project looks (`gorunum.json`). Taps in a row on the look panel become one history entry,
    /// so the history is not flooded by someone trying colours.
    func setLook(_ id: String, _ look: ActLook, summary: String) {
        guard job == nil, var p = project(id) else { return }
        let before = p.files
        var files = before
        if let content = look.fileContent() { files[ActLook.fileName] = content } else { files.removeValue(forKey: ActLook.fileName) }
        guard files != before else { return }
        p.replica.files = files
        var history = p.history
        var original = before
        if let latest = history.first, latest.source == "Görünüm", Date().timeIntervalSince(latest.date) < 120 {
            for change in latest.changes {
                if let restored = change.before { original[change.path] = restored } else { original.removeValue(forKey: change.path) }
            }
            history.removeFirst()
        }
        let changes = diff(original, files)
        if !changes.isEmpty {
            history.insert(ActHistoryEntry(id: UUID(), summary: summary, date: Date(), verified: true, source: "Görünüm", changes: changes), at: 0)
        }
        p.history = Array(history.prefix(30))
        notice = nil
        store(p)
        if p.mode == .devices { Task { await sync(id) } }
    }

    // MARK: Manual edits

    /// Saves what was changed by hand in the code editor (edited, new, renamed or deleted files) as one history entry.
    func saveFiles(_ id: String, set: [String: String] = [:], remove: [String] = [], summary: String) {
        guard job == nil, var p = project(id) else { return }
        let before = p.files
        var files = before
        for (path, content) in set { files[path] = content }
        for path in remove where set[path] == nil { files.removeValue(forKey: path) }
        guard files != before else { return }
        p.replica.files = files
        p.history = Array(([ActHistoryEntry(id: UUID(), summary: summary, date: Date(), verified: true, source: "Elle düzenleme", changes: diff(before, files))] + p.history).prefix(30))
        notice = nil
        store(p)
        if p.mode == .devices { Task { await sync(id) } }
        if p.isWeb { Task { await checkPage(id) } }
    }

    /// After a hand edit: try the page on this phone and say so when it no longer works (the edit stays; undo is one tap).
    private func checkPage(_ id: String) async {
        guard let page = project(id)?.bundle else { return }
        if case .problems(let problems) = await ActWebVerifier().verify(page) {
            notice = "Kaydedildi ama sayfa hata veriyor: " + (problems.first ?? "açılamadı") + " Geri alabilirsin."
        }
    }

    /// Takes the project back to how it was right after `entryID` (everything newer is undone, as one new history entry).
    func restore(_ id: String, to entryID: UUID) {
        guard job == nil, var p = project(id), let index = p.history.firstIndex(where: { $0.id == entryID }), index > 0 else { return }
        let before = p.files
        var files = before
        for entry in p.history[..<index] {
            for change in entry.changes {
                if let restored = change.before { files[change.path] = restored } else { files.removeValue(forKey: change.path) }
            }
        }
        guard files != before else { return }
        p.replica.files = files
        p.history = Array(([ActHistoryEntry(id: UUID(), summary: "Sürüme dönüldü: \(p.history[index].summary)", date: Date(), verified: true, source: "Geri yükleme", changes: diff(before, files))] + p.history).prefix(30))
        store(p)
        if p.mode == .devices { Task { await sync(id) } }
    }

    // MARK: Undo, delete, privacy

    func canUndo(_ id: String) -> Bool { (project(id)?.history.count ?? 0) >= 2 }

    func undo(_ id: String) {
        guard var p = project(id), p.history.count >= 2, let last = p.history.first else { return }
        var files = p.files
        let before = files
        for change in last.changes {
            if let restored = change.before { files[change.path] = restored } else { files.removeValue(forKey: change.path) }
        }
        p.replica.files = files
        let entry = ActHistoryEntry(id: UUID(), summary: "Geri alındı: \(last.summary)", date: Date(), verified: true, source: "Geri alma", changes: diff(before, files))
        p.history = Array(([entry] + p.history).prefix(30))
        store(p)
        if p.mode == .devices { Task { await sync(id) } }
    }

    func delete(_ id: String) async {
        guard let p = project(id) else { return }
        if p.mode == .devices, let hubID = p.replica.hubId {
            do { try await hub.deleteProject(id: hubID) }
            catch {
                notice = "Silinemedi (bağlantıyı kontrol et); proje diğer cihazlarda geri gelirdi."
                return
            }
        }
        ActProjectStore.delete(id)
        projects.removeAll { $0.id == id }
    }

    func setMode(_ id: String, to mode: ActPrivacyMode) async {
        guard var p = project(id), p.mode != mode else { return }
        if mode == .deviceOnly, let hubID = p.replica.hubId {
            do { try await hub.deleteProject(id: hubID) } catch { notice = "Sunucudaki şifreli kopya silinemedi; bağlantıyı kontrol et."; return }
            p.replica.hubId = nil
            p.replica.version = 0
            p.replica.base = [:]
        }
        p.mode = mode
        store(p)
        if mode == .devices { await sync(id) }
    }

    // MARK: Sync

    func syncAll() async {
        guard RovaBackendClient.isAuthenticated, !syncing else { return }
        syncing = true
        defer { syncing = false }
        await purgeEmptyProjects()
        await migrateLegacyIfNeeded()
        do {
            let remote = try await hub.projects()
            let known = Set(projects.compactMap { $0.replica.hubId })
            var foreign = 0
            // An entry with no version has nothing in it yet (another device is mid-way); it is picked up once it has.
            for hubProject in remote where !known.contains(hubProject.id) && hubProject.version > 0 {
                guard let replica = try await ActSync.download(hubProject: hubProject, hub: hub, keys: keys) else { foreign += 1; continue }
                let files = replica.files
                let entry = ActHistoryEntry(id: UUID(), summary: "Başka cihazdan alındı", date: Date(), verified: true, source: "Başka cihaz", changes: diff([:], files))
                store(ActLocalProject(id: UUID().uuidString, mode: .devices, replica: replica, history: [entry], updatedAt: Date()))
            }
            let remoteIDs = Set(remote.map(\.id))
            for p in projects where p.mode == .devices {
                if let hubID = p.replica.hubId, !remoteIDs.contains(hubID) {
                    ActProjectStore.delete(p.id)
                    projects.removeAll { $0.id == p.id }
                }
            }
            syncNote = foreign > 0 ? "\(foreign) proje başka bir anahtarla şifrelenmiş; kurtarma kodunu girmeden açılamaz." : nil
            for p in projects where p.mode == .devices { await sync(p.id) }
        } catch {
            syncNote = (error as? LocalizedError)?.errorDescription
        }
    }

    /// While the Act tab is on screen: wakes up the moment another device changes a project.
    func watchChanges() async {
        var stamp = -1
        while !Task.isCancelled {
            guard RovaBackendClient.isAuthenticated else { try? await Task.sleep(for: .seconds(10)); continue }
            do {
                let next = try await hub.waitForChange(since: stamp)
                if next != stamp && stamp != -1 { await syncAll() }
                stamp = next
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func sync(_ id: String) async {
        // One pass per project at a time: overlapping passes (a save, the tab opening, a change notice) each
        // created their own hub entry for a project that had none yet, and every new entry woke the others.
        guard var p = project(id), p.mode == .devices, job?.projectID != id, !syncingIDs.contains(id) else { return }
        syncingIDs.insert(id)
        defer { syncingIDs.remove(id) }
        let before = p.files
        var replica = p.replica
        do {
            let report = try await ActSync.syncOnce(&replica, hub: hub, keys: keys, device: Self.device)
            p.replica = replica
            if report.pulled > 0 || !report.conflictCopies.isEmpty {
                let changes = diff(before, replica.files)
                if !changes.isEmpty {
                    let summary = report.conflictCopies.isEmpty ? "Başka cihazdan gelen değişiklik" : "Çakışma: bu cihazın kopyası yanına kaydedildi"
                    p.history = Array(([ActHistoryEntry(id: UUID(), summary: summary, date: Date(), verified: true, source: "Başka cihaz", changes: changes)] + p.history).prefix(30))
                }
            }
            if report.changed { store(p) } else if p.replica != project(id)?.replica { ActProjectStore.save(p); if let i = projects.firstIndex(where: { $0.id == id }) { projects[i] = p } }
            syncNote = nil
        } catch {
            // A hub entry made before the failure must be remembered, or the next pass makes another one.
            if replica.hubId != nil, replica.hubId != p.replica.hubId, var current = project(id) {
                current.replica.hubId = replica.hubId
                ActProjectStore.save(current)
                if let i = projects.firstIndex(where: { $0.id == id }) { projects[i] = current }
            }
            syncNote = (error as? LocalizedError)?.errorDescription
        }
    }

    // MARK: Run, export, hand-off

    func runPython(_ id: String) async throws -> ActHub.RunResult {
        guard let p = project(id) else { throw ActError("Proje bulunamadı.") }
        return try await hub.run(files: p.sortedFiles.map { (path: $0.path, content: $0.content) })
    }

    /// The project as a file for the share sheet: one HTML page, or the program's text.
    func exportURL(_ id: String) throws -> URL {
        guard let p = project(id) else { throw ActError("Proje bulunamadı.") }
        let safe = p.name.replacingOccurrences(of: "/", with: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wiqo-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if p.isWeb, let bundle = p.bundle {
            let url = dir.appendingPathComponent("\(safe).html")
            try bundle.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let files = p.sortedFiles
        guard let first = files.first else { throw ActError("Projede dosya yok.") }
        let single = files.count == 1
        let url = dir.appendingPathComponent(single ? URL(fileURLWithPath: first.path).lastPathComponent : "\(safe).py")
        let text = single ? first.content : files.map { "# --- \($0.path) ---\n\($0.content)" }.joined(separator: "\n\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Hands one of the fixed actions to the paired Mac and follows it to its answer.
    func handOff(_ id: String, action: String, progress: @escaping (String) -> Void) async -> (ok: Bool, text: String) {
        guard let hubID = project(id)?.replica.hubId else { return (false, "Bu proje yalnız bu cihazda; Mac'e göndermek için 'Bağlı cihazlarım' gizliliğine geç.") }
        do {
            await sync(id)
            let task = try await hub.startPcTask(projectId: hubID, action: action)
            for _ in 0..<40 {
                try? await Task.sleep(for: .seconds(2))
                let current = try await hub.pcTask(task.id)
                if current.finished { return (current.status == "done", current.output) }
                progress("Mac'in yanıtı bekleniyor…")
            }
            return (false, "Mac yanıt vermedi; açık ve internete bağlı mı?")
        } catch {
            return (false, (error as? LocalizedError)?.errorDescription ?? "Mac'e iletilemedi.")
        }
    }

    // MARK: Key

    var recoveryCode: String { keys.recoveryCode }

    /// Another device's recovery code: the projects of that key become readable here.
    func useRecoveryCode(_ code: String) -> Bool {
        guard let imported = ActKeys.fromRecoveryCode(code) else { return false }
        try? ActKeyStore.save(imported)
        return true
    }

    /// Sends the key to the paired Mac over the local, authenticated connection (see IOSConnectionModel).
    var keyForPairedMac: String { keys.master.base64EncodedString() }

    // MARK: One-time move from the first, plaintext version

    private var migratedKey: String { "act.legacy.migrated.\(RovaBackendClient.currentUserID ?? "anonymous")" }
    /// Server ids already brought over (so a retry never makes a second copy).
    private var movedKey: String { "act.legacy.moved.\(RovaBackendClient.currentUserID ?? "anonymous")" }
    private var migrating = false

    /// Projects made before projects were end-to-end encrypted: downloaded once, sealed, and removed from the
    /// server. Idempotent: each server project is moved at most once, empty ones are just dropped.
    private func migrateLegacyIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: migratedKey), !migrating else { return }
        migrating = true
        defer { migrating = false }
        guard let legacy = try? await RovaBackendClient.fetchCodeProjects() else { return }
        var moved = Set((UserDefaults.standard.array(forKey: movedKey) as? [Int]) ?? [])
        var allDone = true
        for item in legacy {
            if moved.contains(item.id) {
                if (try? await RovaBackendClient.deleteCodeProject(id: item.id)) == nil { allDone = false }
                continue
            }
            guard let snapshot = try? await RovaBackendClient.fetchCodeProjectSnapshot(id: item.id) else { allDone = false; continue }
            var files: [String: String] = [:]
            for file in snapshot.files { files[file.path] = file.content }
            if !files.isEmpty {
                let entry = ActHistoryEntry(id: UUID(), summary: "Önceki sürümden aktarıldı", date: Date(), verified: true, source: "Wiqo", changes: diff([:], files))
                let local = ActLocalProject(id: UUID().uuidString, mode: .devices, replica: ActReplica(meta: ActProjectMeta(name: snapshot.project.name, kind: snapshot.project.kind), files: files), history: [entry], updatedAt: Date())
                store(local)
                // Remember the move before anything else can run again.
                moved.insert(item.id)
                UserDefaults.standard.set(Array(moved), forKey: movedKey)
                await sync(local.id)
                guard let synced = project(local.id), synced.replica.hubId != nil, synced.replica.version >= 1 else { allDone = false; continue }
            }
            // An empty server project (a create that never finished) has nothing to move.
            if (try? await RovaBackendClient.deleteCodeProject(id: item.id)) != nil { moved.insert(item.id); UserDefaults.standard.set(Array(moved), forKey: movedKey) } else { allDone = false }
        }
        if allDone { UserDefaults.standard.set(true, forKey: migratedKey) }
    }

    /// Projects without a single file (left by an unfinished create or an earlier bug) are removed, here and on the hub.
    func purgeEmptyProjects() async {
        for p in projects where p.files.isEmpty && job?.projectID != p.id {
            if p.mode == .devices, let hubID = p.replica.hubId { try? await hub.deleteProject(id: hubID) }
            ActProjectStore.delete(p.id)
            projects.removeAll { $0.id == p.id }
        }
    }
}
