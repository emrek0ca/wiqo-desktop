import Foundation

struct CopilotStoredMessage: Codable, Hashable {
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

    init(role: Role, text: String, artifacts: [RovaBackendClient.ArtifactDescriptor]? = nil, attachmentThumbnails: [Data]? = nil) {
        self.role = role
        self.text = text
        self.artifacts = artifacts
        self.attachmentThumbnails = attachmentThumbnails
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
    private static var namespace: String { RovaBackendClient.currentUserID ?? "anon" }
    private static var conversationKey: String { "rova.copilot.conversation-id.\(namespace)" }
    private static var summariesKey: String { "rova.copilot.conversations.\(namespace)" }
    private static var messagesPrefix: String { "rova.copilot.messages.\(namespace)." }
    private static var turnCountPrefix: String { "rova.copilot.turn-count.\(namespace)." }

    static func currentIdentifier() -> String {
        if let existing = UserDefaults.standard.string(forKey: conversationKey), !existing.isEmpty {
            return existing
        }
        return newIdentifier()
    }

    static func newIdentifier() -> String {
        let identifier = UUID().uuidString
        UserDefaults.standard.set(identifier, forKey: conversationKey)
        return identifier
    }

    static func all() -> [CopilotConversationSummary] {
        guard let data = UserDefaults.standard.data(forKey: summariesKey),
              let summaries = try? JSONDecoder().decode([CopilotConversationSummary].self, from: data) else {
            return []
        }
        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func messages(for id: String) -> [CopilotStoredMessage] {
        guard let data = UserDefaults.standard.data(forKey: messagesPrefix + id),
              let messages = try? JSONDecoder().decode([CopilotStoredMessage].self, from: data) else {
            return []
        }
        return messages
    }

    static func turnCount(for id: String) -> Int {
        max(0, UserDefaults.standard.integer(forKey: turnCountPrefix + id))
    }

    static func saveTurnCount(_ count: Int, for id: String) {
        guard !id.isEmpty else { return }
        UserDefaults.standard.set(max(0, count), forKey: turnCountPrefix + id)
    }

    /// Removes a conversation from this device. The id is remembered so the still-open chat view
    /// can't resurrect it when it persists on disappear.
    static func delete(id: String) {
        guard !id.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: messagesPrefix + id)
        UserDefaults.standard.removeObject(forKey: turnCountPrefix + id)
        let remaining = all().filter { $0.id != id }
        if let data = try? JSONEncoder().encode(remaining) {
            UserDefaults.standard.set(data, forKey: summariesKey)
        }
        let deleted = (UserDefaults.standard.stringArray(forKey: deletedKey) ?? []) + [id]
        UserDefaults.standard.set(Array(deleted.suffix(100)), forKey: deletedKey)
    }

    private static var deletedKey: String { "rova.copilot.deleted.\(namespace)" }

    /// Wipes every locally stored conversation of the current account (used on account deletion).
    static func removeAllForCurrentUser() {
        let ns = namespace
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("rova.copilot.") {
            if key.hasSuffix(".\(ns)") || key.contains(".\(ns).") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    static func save(id: String, messages: [CopilotStoredMessage], turnCount: Int) {
        guard !id.isEmpty else { return }
        guard !(UserDefaults.standard.stringArray(forKey: deletedKey) ?? []).contains(id) else { return }
        // A chat that was opened but never used must not clutter the history list.
        guard !messages.isEmpty else { return }
        let boundedMessages = Array(messages.suffix(80)).map {
            CopilotStoredMessage(role: $0.role, text: String($0.text.prefix(12_000)), artifacts: $0.artifacts, attachmentThumbnails: $0.attachmentThumbnails)
        }
        if let data = try? JSONEncoder().encode(boundedMessages) {
            UserDefaults.standard.set(data, forKey: messagesPrefix + id)
        }
        UserDefaults.standard.set(max(0, turnCount), forKey: turnCountPrefix + id)

        let userMessages = boundedMessages.filter { $0.role == .user }
        let title = userMessages.first.map { short($0.text, limit: 42) } ?? "Yeni sohbet"
        let preview = boundedMessages.last.map { short($0.text, limit: 90) } ?? "Boş sohbet"
        var summaries = all().filter { $0.id != id }
        summaries.append(CopilotConversationSummary(
            id: id,
            title: title,
            preview: preview,
            updatedAt: Date(),
            turnCount: max(0, turnCount)
        ))
        summaries = Array(summaries.sorted { $0.updatedAt > $1.updatedAt }.prefix(30))
        if let data = try? JSONEncoder().encode(summaries) {
            UserDefaults.standard.set(data, forKey: summariesKey)
        }
        UserDefaults.standard.set(id, forKey: conversationKey)
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
            UserDefaults.standard.set(data, forKey: summariesKey)
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
        UserDefaults.standard.set(data, forKey: messagesPrefix + id)
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
