import AppKit

/// Polls the general pasteboard's `changeCount` (there's no push notification for clipboard
/// changes on macOS) and keeps a small in-memory ring buffer of recent text copies - never
/// written to disk, cleared on every relaunch. `getClipboardHistory` (see MacSystem.swift) is
/// presence-gated exactly like reading a file, since a clipboard can easily hold something
/// sensitive.
@MainActor
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    private let maxEntries = 20
    private let maxEntryLength = 4_000
    private var monitorTask: Task<Void, Never>?
    private(set) var entries: [ClipboardHistoryEntry] = []

    private init() {}

    func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            var lastChangeCount = await Self.snapshot().changeCount
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }

                let snapshot = await Self.snapshot()
                guard snapshot.changeCount != lastChangeCount else { continue }
                lastChangeCount = snapshot.changeCount
                guard let self, let text = snapshot.text, !text.isEmpty else { continue }
                self.record(text)
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func record(_ text: String) {
        // A no-op copy of the exact same text (common when re-selecting the same line) shouldn't
        // duplicate the most recent entry.
        if entries.first?.text == text { return }
        entries.insert(ClipboardHistoryEntry(text: String(text.prefix(maxEntryLength)), copiedAt: Date()), at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
    }

    private struct Snapshot: Sendable {
        let changeCount: Int
        let text: String?
    }

    private nonisolated static func snapshot() async -> Snapshot {
        await Task.detached(priority: .utility) {
            let pasteboard = NSPasteboard.general
            return Snapshot(
                changeCount: pasteboard.changeCount,
                text: pasteboard.string(forType: .string)
            )
        }.value
    }
}
