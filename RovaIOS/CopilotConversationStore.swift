import Foundation

struct CopilotStoredMessage: Codable, Hashable, Sendable {
    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    let role: Role
    let text: String
    /// Optional (not defaulted) so decoding an entry saved before this field existed - already on
    /// disk for every account - succeeds with nil rather than failing the whole conversation load.
    let artifacts: [RovaBackendClient.ArtifactDescriptor]?
    /// Small JPEG thumbnails (see ChatBubble.attachmentThumbnails) - same nil-on-missing-key
    /// backward compatibility as `artifacts` above. Defaulted so call sites that never have
    /// thumbnails (server-fetched history) don't need to pass it explicitly.
    let attachmentThumbnails: [Data]?
    /// The reply's thinking timeline - same nil-on-missing-key compatibility as above.
    let thinking: ThinkingTrace?

    init(role: Role, text: String, artifacts: [RovaBackendClient.ArtifactDescriptor]? = nil, attachmentThumbnails: [Data]? = nil, thinking: ThinkingTrace? = nil) {
        self.role = role
        self.text = text
        self.artifacts = artifacts
        self.attachmentThumbnails = attachmentThumbnails
        self.thinking = thinking
    }
}

struct CopilotConversationSummary: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    var preview: String
    var updatedAt: Date
    var turnCount: Int
}

/// Every key here is namespaced per signed-in account (see RovaBackendClient.currentUserID) - a
/// device shared by more than one Wiqo account must never let one account see another's chat
/// history. "anon" is only ever hit in the narrow window before a token exists, so it can't
/// collide with a real account's data.
enum CopilotConversationStore {
    /// The storage keys of one account. A pending write captures these when it is queued, so a
    /// write that lands after a sign-out still goes to the account it belongs to.
    private struct Keys: Sendable {
        let namespace: String

        var conversation: String { "rova.copilot.conversation-id.\(namespace)" }
        var summaries: String { "rova.copilot.conversations.\(namespace)" }
        var messagesPrefix: String { "rova.copilot.messages.\(namespace)." }
        var turnCountPrefix: String { "rova.copilot.turn-count.\(namespace)." }
        var deleted: String { "rova.copilot.deleted.\(namespace)" }
    }

    private static var keys: Keys { Keys(namespace: RovaBackendClient.currentUserID ?? "anon") }

    // MARK: - Reads

    static func currentIdentifier() -> String {
        if let existing = UserDefaults.standard.string(forKey: keys.conversation), !existing.isEmpty {
            return existing
        }
        return newIdentifier()
    }

    static func newIdentifier() -> String {
        let identifier = UUID().uuidString
        UserDefaults.standard.set(identifier, forKey: keys.conversation)
        return identifier
    }

    static func all() -> [CopilotConversationSummary] {
        flushPending()
        return readSummaries(keys)
    }

    private static func readSummaries(_ keys: Keys) -> [CopilotConversationSummary] {
        guard let data = UserDefaults.standard.data(forKey: keys.summaries),
              let summaries = try? JSONDecoder().decode([CopilotConversationSummary].self, from: data) else {
            return []
        }
        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func messages(for id: String) -> [CopilotStoredMessage] {
        flushPending()
        guard let data = UserDefaults.standard.data(forKey: keys.messagesPrefix + id),
              let messages = try? JSONDecoder().decode([CopilotStoredMessage].self, from: data) else {
            return []
        }
        return messages
    }

    static func turnCount(for id: String) -> Int {
        max(0, UserDefaults.standard.integer(forKey: keys.turnCountPrefix + id))
    }

    static func saveTurnCount(_ count: Int, for id: String) {
        guard !id.isEmpty else { return }
        UserDefaults.standard.set(max(0, count), forKey: keys.turnCountPrefix + id)
    }

    // MARK: - Deleting

    /// Removes a conversation from this device. The id is remembered so the still-open chat view
    /// can't resurrect it when it persists on disappear.
    static func delete(id: String) {
        guard !id.isEmpty else { return }
        let keys = keys
        UserDefaults.standard.removeObject(forKey: keys.messagesPrefix + id)
        UserDefaults.standard.removeObject(forKey: keys.turnCountPrefix + id)
        let remaining = readSummaries(keys).filter { $0.id != id }
        if let data = try? JSONEncoder().encode(remaining) {
            UserDefaults.standard.set(data, forKey: keys.summaries)
        }
        let deleted = (UserDefaults.standard.stringArray(forKey: keys.deleted) ?? []) + [id]
        UserDefaults.standard.set(Array(deleted.suffix(100)), forKey: keys.deleted)
    }

    /// Wipes every locally stored conversation of the current account (used on account deletion).
    static func removeAllForCurrentUser() {
        pendingSaves.discardAll()
        // A write that was already in flight must finish before the wipe, or it would bring the
        // deleted account's chat back.
        writeQueue.sync {}
        let ns = keys.namespace
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("rova.copilot.") {
            if key.hasSuffix(".\(ns)") || key.contains(".\(ns).") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    // MARK: - Writes

    /// A save waiting to be written. Encoding a long chat with images is the expensive part, so it
    /// happens off the main thread and several saves in a row collapse into the latest one.
    private final class PendingSaves: @unchecked Sendable {
        struct Entry {
            let messages: [CopilotStoredMessage]
            let turnCount: Int
            let keys: Keys
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        private var isDrainScheduled = false

        /// Returns true when the caller must schedule the drain.
        func put(_ entry: Entry, for id: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            entries[id] = entry
            if isDrainScheduled { return false }
            isDrainScheduled = true
            return true
        }

        func take() -> [String: Entry] {
            lock.lock()
            defer { lock.unlock() }
            let taken = entries
            entries = [:]
            isDrainScheduled = false
            return taken
        }

        func discardAll() {
            lock.lock()
            defer { lock.unlock() }
            entries = [:]
        }
    }

    private static let pendingSaves = PendingSaves()
    private static let writeQueue = DispatchQueue(label: "com.wiqo.conversation-store", qos: .utility)

    /// Persists shortly instead of now: the view calls this after every step of a turn, and each
    /// call used to encode the whole conversation on the main thread.
    static func saveSoon(id: String, messages: [CopilotStoredMessage], turnCount: Int) {
        guard !id.isEmpty else { return }
        let entry = PendingSaves.Entry(messages: messages, turnCount: turnCount, keys: keys)
        if pendingSaves.put(entry, for: id) {
            writeQueue.asyncAfter(deadline: .now() + 0.6) { drainPendingSaves() }
        }
    }

    /// Writes whatever is still waiting. Reads call this first so they never see stale data, and
    /// the app calls it when it leaves the foreground.
    static func flushPending() {
        writeQueue.sync { drainPendingSaves() }
    }

    private static func drainPendingSaves() {
        for (id, entry) in pendingSaves.take() {
            write(id: id, messages: entry.messages, turnCount: entry.turnCount, keys: entry.keys)
        }
    }

    private static func write(id: String, messages: [CopilotStoredMessage], turnCount: Int, keys: Keys) {
        guard !id.isEmpty else { return }
        guard !(UserDefaults.standard.stringArray(forKey: keys.deleted) ?? []).contains(id) else { return }
        // A chat that was opened but never used must not clutter the history list.
        guard !messages.isEmpty else { return }
        let boundedMessages = Array(messages.suffix(80)).map {
            CopilotStoredMessage(role: $0.role, text: String($0.text.prefix(12_000)), artifacts: $0.artifacts, attachmentThumbnails: $0.attachmentThumbnails, thinking: $0.thinking)
        }
        if let data = try? JSONEncoder().encode(boundedMessages) {
            UserDefaults.standard.set(data, forKey: keys.messagesPrefix + id)
        }
        UserDefaults.standard.set(max(0, turnCount), forKey: keys.turnCountPrefix + id)

        let userMessages = boundedMessages.filter { $0.role == .user }
        let title = userMessages.first.map { short($0.text, limit: 42) } ?? "Yeni sohbet"
        let preview = boundedMessages.last.map { short($0.text, limit: 90) } ?? "Boş sohbet"
        var summaries = readSummaries(keys).filter { $0.id != id }
        summaries.append(CopilotConversationSummary(
            id: id,
            title: title,
            preview: preview,
            updatedAt: Date(),
            turnCount: max(0, turnCount)
        ))
        summaries = Array(summaries.sorted { $0.updatedAt > $1.updatedAt }.prefix(30))
        if let data = try? JSONEncoder().encode(summaries) {
            UserDefaults.standard.set(data, forKey: keys.summaries)
        }
        UserDefaults.standard.set(id, forKey: keys.conversation)
    }

    /// The backend stores `updated_at` as SQLite's `datetime('now')` format - not ISO 8601 - so
    /// this matches that exact shape instead of relying on a decoder's ISO 8601 strategy.
    private static let remoteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// Folds freshly fetched server summaries into the local list and returns the merged result -
    /// the server is durable (every successful `/copilot/chat` call persists there) so a remote
    /// summary always overwrites its local counterpart; anything local-only stays untouched. This
    /// is what brings history back after a reinstall or a new device, on top of the existing
    /// instant local cache the sidebar already shows before this resolves.
    static func mergeRemoteSummaries(_ remote: [RovaBackendClient.RemoteConversationSummary]) -> [CopilotConversationSummary] {
        guard !remote.isEmpty else { return all() }
        let keys = keys
        var byID = Dictionary(uniqueKeysWithValues: all().map { ($0.id, $0) })
        for item in remote {
            byID[item.id] = CopilotConversationSummary(
                id: item.id,
                title: item.title.isEmpty ? "Yeni sohbet" : item.title,
                preview: item.preview.isEmpty ? "Boş sohbet" : item.preview,
                updatedAt: remoteDateFormatter.date(from: item.updatedAt) ?? Date(),
                turnCount: item.turnCount
            )
        }
        let merged = Array(byID.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(30))
        if let data = try? JSONEncoder().encode(merged) {
            UserDefaults.standard.set(data, forKey: keys.summaries)
        }
        return merged
    }

    /// Caches a conversation's messages fetched from the backend (used the first time this device
    /// opens a conversation it has no local copy of) and returns them decoded, ready for the view.
    @discardableResult
    static func saveRemoteMessages(_ remote: [RovaBackendClient.RemoteConversationMessage], for id: String) -> [CopilotStoredMessage] {
        let stored = remote.compactMap { item -> CopilotStoredMessage? in
            guard let role = CopilotStoredMessage.Role(rawValue: item.role) else { return nil }
            return CopilotStoredMessage(role: role, text: item.content, artifacts: item.artifacts)
        }
        guard !id.isEmpty, let data = try? JSONEncoder().encode(stored) else { return stored }
        UserDefaults.standard.set(data, forKey: keys.messagesPrefix + id)
        return stored
    }

    private static func short(_ value: String, limit: Int) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(max(1, limit - 1))) + "…"
    }
}
