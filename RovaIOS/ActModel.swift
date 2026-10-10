import Foundation
import SwiftUI

/// The three steps every Act job goes through, in order.
enum ActStage: Int, CaseIterable {
    case writing, verifying, saving

    var title: String {
        switch self {
        case .writing: return String(localized: "Yazılıyor")
        case .verifying: return String(localized: "Telefonda deneniyor")
        case .saving: return String(localized: "Kaydediliyor")
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
    var code: String?
    var errorDescription: String? { message }
    init(_ message: String, code: String? = nil) { self.message = message; self.code = code }
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
    private static let deviceOnlyConsentKey = "act.writer.consent.device-only.v1"

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
    /// Asked once for each kind of project (shared, device-only), then remembered: the notice no longer comes with every request.
    func needsConsent(for project: ActLocalProject?) -> Bool { needsConsent(mode: project?.mode ?? .devices) }

    func needsConsent(mode: ActPrivacyMode) -> Bool {
        !UserDefaults.standard.bool(forKey: mode == .deviceOnly ? Self.deviceOnlyConsentKey : Self.consentKey)
    }

    func recordConsent(mode: ActPrivacyMode = .devices) {
        UserDefaults.standard.set(true, forKey: mode == .deviceOnly ? Self.deviceOnlyConsentKey : Self.consentKey)
    }

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
        job = ActJobState(projectID: nil, stage: .writing, message: String(localized: "Sırada…"))
        cancelRequested = false
        defer { job = nil }
        do {
            let result = try await runWriter(operation: "create", request: request, project: nil)
            return try await commit(result, request: request, project: nil, mode: mode)
        } catch {
            if !cancelRequested { notice = (error as? LocalizedError)?.errorDescription ?? String(localized: "Proje oluşturulamadı.") }
            return nil
        }
    }

    /// `errors`: the page's console errors from this phone, sent with the request as diagnostics (one fix request, not several).
    func edit(_ id: String, request: String, errors: [(level: String, text: String)] = []) async {
        guard job == nil, let project = project(id) else { return }
        notice = nil
        job = ActJobState(projectID: id, stage: .writing, message: String(localized: "Sırada…"))
        cancelRequested = false
        defer { job = nil }
        do {
            let result = try await runWriter(operation: "edit", request: request, project: project, errors: errors)
            _ = try await commit(result, request: request, project: project, mode: project.mode)
        } catch {
            if !cancelRequested { notice = (error as? LocalizedError)?.errorDescription ?? String(localized: "Değişiklik uygulanamadı; proje değişmedi.") }
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
        p.history = Array(([ActHistoryEntry(id: UUID(), summary: result.summary, date: Date(), verified: true, source: String(localized: "Hızlı düzenleme"), changes: diff(before, files))] + p.history).prefix(30))
        notice = nil
        store(p)
        if p.mode == .devices { Task { await sync(id) } }
        return true
    }

    func cancel() async {
        cancelRequested = true
        if let id = job?.writerJobID { try? await hub.cancelWriter(id) }
        notice = String(localized: "Görev durduruldu; proje değişmedi.")
    }

    /// What a writer refusal or failure code means when the server sent no sentence with it.
    private static func describe(code: String?) -> String? {
        switch code {
        case "VALIDATION_FAILED": return String(localized: "Üretilen kod doğrulamadan geçemedi; isteği biraz değiştirip yeniden dene.")
        case "RUN_CAPACITY", "PACKAGE_CAPACITY": return String(localized: "Python çalıştırma kapasitesi şu an dolu; biraz sonra tekrar dene.")
        case "UNSUPPORTED_PACKAGE": return String(localized: "İstenen Python paketi veya sürümü desteklenmiyor.")
        case "PACKAGE_UNAVAILABLE": return String(localized: "Paket şu an kurulamıyor; biraz sonra tekrar dene.")
        case "RETRYABLE_RESTART": return String(localized: "Sunucu yeniden başladı; isteği yeniden gönderebilirsin.")
        default: return nil
        }
    }

    /// Sends the request (and the files it needs) to the stateless writer and follows it to its answer.
    /// A full queue (WRITER_BUSY) is waited out, a server restart is retried once; both are visible on the job card.
    private func runWriter(operation: String, request: String, project: ActLocalProject?, errors: [(level: String, text: String)] = [], restarted: Bool = false) async throws -> ActHub.WriterResult {
        let files = (project?.sortedFiles ?? []).map { (path: $0.path, content: $0.content) }
        var writerID = ""
        var waits = 0
        while true {
            if cancelRequested { throw ActError(String(localized: "Görev durduruldu.")) }
            do {
                writerID = try await hub.startWriter(operation: operation, request: request, files: files, kind: project?.kind ?? "web", name: project?.name, errors: errors)
                break
            } catch let error as ActHub.HubError {
                guard error.code == "WRITER_BUSY", waits < 6 else { throw ActError(error.errorDescription ?? String(localized: "Yazara ulaşılamadı."), code: error.code) }
                waits += 1
                let wait = min(max(error.retryAfter ?? 5, 2), 20)
                job?.message = String(localized: "Yazar şu an dolu; \(wait) sn sonra yeniden denenecek (\(waits)/6).")
                try? await Task.sleep(for: .seconds(wait))
            } catch {
                throw ActError((error as? LocalizedError)?.errorDescription ?? String(localized: "Yazara ulaşılamadı."))
            }
        }
        job?.writerJobID = writerID
        var failures = 0
        for _ in 0..<150 {
            if cancelRequested { throw ActError(String(localized: "Görev durduruldu.")) }
            do {
                let state = try await hub.writerJob(writerID)
                failures = 0
                if state.finished {
                    await hub.acknowledgeWriter(writerID)
                    if state.errorCode == "RETRYABLE_RESTART", !restarted {
                        job?.message = String(localized: "Sunucu yeniden başladı; istek yeniden gönderiliyor.")
                        return try await runWriter(operation: operation, request: request, project: project, errors: errors, restarted: true)
                    }
                    guard state.status == "done", let result = state.result else {
                        let reason = (state.error?.isEmpty == false ? state.error : nil) ?? Self.describe(code: state.errorCode) ?? String(localized: "Değişiklik üretilemedi.")
                        throw ActError(reason, code: state.errorCode)
                    }
                    return result
                }
                job?.message = state.status == "queued" ? String(localized: "Sırada; yazar boşalınca başlayacak.") : state.progress
            } catch let error as ActError {
                throw error
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if (error as? ActHub.HubError)?.status == 404 { throw ActError(String(localized: "Görev sunucuda kalmadı; isteği yeniden gönder.")) }
                failures += 1
                if failures >= 15 { throw ActError(String(localized: "Sunucuya ulaşılamadı: \(message)")) }
                if failures >= 3 { job?.message = String(localized: "Bağlantı zayıf, yeniden deneniyor…") }
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
        throw ActError(String(localized: "Görev beklenenden uzun sürdü; biraz sonra tekrar dene."))
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
            job?.message = String(localized: "Sayfa bu telefonun tarayıcısında açılıp deneniyor.")
            let list = files.sorted { $0.key < $1.key }.map { ActBundler.File(path: $0.key, content: $0.value) }
            guard let raw = ActBundler.bundleWeb(list).map(ActBundler.ensureViewport) else { throw ActError(String(localized: "Projede açılacak bir sayfa yok.")) }
            // A page that uses packages is tried with the device's verified copies; without them it is not verified.
            var page = raw
            var packageProblem: String?
            do {
                try await ActPackages.shared.prepare(raw) { [hub] in try await hub.packages() }
                let packaged = ActPackages.shared.inlineCached(raw)
                if packaged.missing.isEmpty { page = packaged.html } else { packageProblem = ActPackageError("\(packaged.missing.joined(separator: ", ")) cihazda yok").errorDescription }
            } catch let error as ActPackageError {
                packageProblem = error.errorDescription
            }
            if let packageProblem {
                verified = false
                warning = String(localized: "\(packageProblem). Değişiklik kaydedildi ama sayfa doğrulanmadı.")
            } else {
                switch await ActWebVerifier().verify(page) {
                case .passed: break
                case .passedWithNotes(let found): notes = found
                case .problems(let problems): throw ActError(problems.first ?? String(localized: "Sayfa doğrulanamadı; proje değişmedi."))
                case .unavailable:
                    verified = false
                    warning = String(localized: "Telefonda denenemedi; değişiklik kaydedildi. Çalışmıyorsa geri alabilirsin.")
                }
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
        let summary = useCopy ? String(localized: "Çakışmada kopya seçildi: \(original)") : String(localized: "Çakışma kopyası silindi: \(copy)")
        p.history = Array(([ActHistoryEntry(id: UUID(), summary: summary, date: Date(), verified: true, source: String(localized: "Çakışma"), changes: diff(before, files))] + p.history).prefix(30))
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
            history: [ActHistoryEntry(id: UUID(), summary: String(localized: "Dosyalardan içe aktarıldı"), date: Date(), verified: true, source: String(localized: "İçe aktarma"), changes: diff([:], files))],
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
            replica: ActReplica(meta: ActProjectMeta(name: String((String(localized: "\(source.name) kopyası")).prefix(60)), kind: source.kind), files: source.files),
            history: [ActHistoryEntry(id: UUID(), summary: String(localized: "“\(source.name)” projesinin kopyası"), date: Date(), verified: true, source: String(localized: "Kopya"), changes: diff([:], source.files))],
            updatedAt: Date()
        )
        store(copy)
        if copy.mode == .devices { Task { await sync(copy.id) } }
        return copy.id
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
        p.history = Array(([ActHistoryEntry(id: UUID(), summary: summary, date: Date(), verified: true, source: String(localized: "Elle düzenleme"), changes: diff(before, files))] + p.history).prefix(30))
        notice = nil
        store(p)
        if p.mode == .devices { Task { await sync(id) } }
        if p.isWeb { Task { await checkPage(id) } }
    }

    /// After a hand edit: try the page on this phone and say so when it no longer works (the edit stays; undo is one tap).
    private func checkPage(_ id: String) async {
        guard let current = project(id) else { return }
        let page: String
        do { page = try await readyPage(for: current) } catch {
            notice = String(localized: "\((error as? LocalizedError)?.errorDescription ?? "Sayfa hazırlanamadı"). Sayfa doğrulanmadı.")
            return
        }
        if case .problems(let problems) = await ActWebVerifier().verify(page) {
            notice = String(localized: "Kaydedildi ama sayfa hata veriyor: ") + (problems.first ?? String(localized: "açılamadı")) + String(localized: " Geri alabilirsin.")
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
        p.history = Array(([ActHistoryEntry(id: UUID(), summary: String(localized: "Sürüme dönüldü: \(p.history[index].summary)"), date: Date(), verified: true, source: String(localized: "Geri yükleme"), changes: diff(before, files))] + p.history).prefix(30))
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
        let entry = ActHistoryEntry(id: UUID(), summary: String(localized: "Geri alındı: \(last.summary)"), date: Date(), verified: true, source: String(localized: "Geri alma"), changes: diff(before, files))
        p.history = Array(([entry] + p.history).prefix(30))
        store(p)
        if p.mode == .devices { Task { await sync(id) } }
    }

    func delete(_ id: String) async {
        guard let p = project(id) else { return }
        if p.mode == .devices, let hubID = p.replica.hubId {
            do { try await hub.deleteProject(id: hubID) }
            catch {
                notice = String(localized: "Silinemedi (bağlantıyı kontrol et); proje diğer cihazlarda geri gelirdi.")
                return
            }
        }
        ActProjectStore.delete(id)
        projects.removeAll { $0.id == id }
    }

    func setMode(_ id: String, to mode: ActPrivacyMode) async {
        guard var p = project(id), p.mode != mode else { return }
        if mode == .deviceOnly, let hubID = p.replica.hubId {
            do { try await hub.deleteProject(id: hubID) } catch { notice = String(localized: "Sunucudaki şifreli kopya silinemedi; bağlantıyı kontrol et."); return }
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
                let entry = ActHistoryEntry(id: UUID(), summary: String(localized: "Başka cihazdan alındı"), date: Date(), verified: true, source: String(localized: "Başka cihaz"), changes: diff([:], files))
                store(ActLocalProject(id: UUID().uuidString, mode: .devices, replica: replica, history: [entry], updatedAt: Date()))
            }
            let remoteIDs = Set(remote.map(\.id))
            for p in projects where p.mode == .devices {
                if let hubID = p.replica.hubId, !remoteIDs.contains(hubID) {
                    ActProjectStore.delete(p.id)
                    projects.removeAll { $0.id == p.id }
                }
            }
            syncNote = foreign > 0 ? String(localized: "\(foreign) proje başka bir anahtarla şifrelenmiş; kurtarma kodunu girmeden açılamaz.") : nil
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
                    let summary = report.conflictCopies.isEmpty ? String(localized: "Başka cihazdan gelen değişiklik") : String(localized: "Çakışma: bu cihazın kopyası yanına kaydedildi")
                    p.history = Array(([ActHistoryEntry(id: UUID(), summary: summary, date: Date(), verified: true, source: String(localized: "Başka cihaz"), changes: changes)] + p.history).prefix(30))
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
        guard let p = project(id) else { throw ActError(String(localized: "Proje bulunamadı.")) }
        return try await hub.run(files: p.sortedFiles.map { (path: $0.path, content: $0.content) })
    }

    /// The page with its JavaScript packages put in from the device's verified cache (downloaded and checked first when
    /// they are not there yet). Throws `ActPackageError` (DEVICE_PACKAGE_MISSING) when that cannot be done.
    func readyPage(for project: ActLocalProject) async throws -> String {
        guard let raw = project.bundle else { throw ActError(String(localized: "Projede açılacak bir sayfa (index.html) yok.")) }
        try await ActPackages.shared.prepare(raw) { [hub] in try await hub.packages() }
        let packaged = ActPackages.shared.inlineCached(raw)
        guard packaged.missing.isEmpty else { throw ActPackageError("\(packaged.missing.joined(separator: ", ")) cihazda yok") }
        return packaged.html
    }

    /// A program's text as a file (a single .py as it is, several joined with headers).
    func exportURL(_ id: String) throws -> URL {
        guard let p = project(id) else { throw ActError(String(localized: "Proje bulunamadı.")) }
        let files = p.sortedFiles
        guard let first = files.first else { throw ActError(String(localized: "Projede dosya yok.")) }
        let single = files.count == 1
        let url = try Self.exportFolder().appendingPathComponent(single ? URL(fileURLWithPath: first.path).lastPathComponent : "\(Self.stem(p.name)).py")
        let text = single ? first.content : files.map { "# --- \($0.path) ---\n\($0.content)" }.joined(separator: "\n\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func stem(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "[/\\:*?\"<>|]", with: "-", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? String(localized: "Proje") : cleaned).prefix(60))
    }

    private static func exportFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wiqo-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// One export of the project as a file for the share sheet. The source ZIP is built here from the project's own files
    /// (paths normalised; the sync format and package code are never in it). A single HTML carries the verified packages
    /// and is refused (DEVICE_PACKAGE_MISSING) rather than shared incomplete. PDF and picture come from the page as this
    /// device shows it (packages from the device cache, the two public CDNs still allowed).
    func export(_ kind: ActExportKind, id: String, width: Int) async throws -> URL {
        guard let p = project(id) else { throw ActError(String(localized: "Proje bulunamadı.")) }
        let name = Self.stem(p.name)
        let dir = try Self.exportFolder()
        switch kind {
        case .zip:
            let entries = p.sortedFiles.map { (path: $0.path, data: Data($0.content.utf8)) }
            let data = ActArchive.zip(entries)
            guard entries.contains(where: { ActArchive.normalizedPath($0.path) != nil }) else { throw ActError(String(localized: "Projede dışa aktarılacak dosya yok.")) }
            let url = dir.appendingPathComponent("\(name).zip")
            try data.write(to: url, options: .atomic)
            return url
        case .html:
            guard p.isWeb else { throw ActError(String(localized: "Tek HTML yalnız web projeleri için.")) }
            let page = try await readyPage(for: p)
            let url = dir.appendingPathComponent("\(name).html")
            try page.write(to: url, atomically: true, encoding: .utf8)
            return url
        case .pdf, .png:
            guard p.isWeb else { throw ActError(String(localized: "PDF ve ekran görüntüsü yalnız web projeleri için.")) }
            let page = try await readyPage(for: p)
            let html = WiqoHTMLDocument.wrap(page, viewportWidth: width, reduceMotion: true)
            let data = try await ActPageCapture.capture(html: html, projectKey: p.id, width: width, output: kind == .pdf ? .pdf : .png)
            let url = dir.appendingPathComponent("\(name).\(kind == .pdf ? "pdf" : "png")")
            try data.write(to: url, options: .atomic)
            return url
        }
    }

    /// Hands one of the fixed actions to the paired Mac and follows it to its answer.
    func handOff(_ id: String, action: String, progress: @escaping (String) -> Void) async -> (ok: Bool, text: String) {
        guard let hubID = project(id)?.replica.hubId else { return (false, String(localized: "Bu proje yalnız bu cihazda; Mac'e göndermek için 'Bağlı cihazlarım' gizliliğine geç.")) }
        do {
            await sync(id)
            let task = try await hub.startPcTask(projectId: hubID, action: action)
            for _ in 0..<40 {
                try? await Task.sleep(for: .seconds(2))
                let current = try await hub.pcTask(task.id)
                if current.finished { return (current.status == "done", current.output) }
                progress(String(localized: "Mac'in yanıtı bekleniyor…"))
            }
            return (false, String(localized: "Mac yanıt vermedi; açık ve internete bağlı mı?"))
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
                let entry = ActHistoryEntry(id: UUID(), summary: String(localized: "Önceki sürümden aktarıldı"), date: Date(), verified: true, source: "Wiqo", changes: diff([:], files))
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
