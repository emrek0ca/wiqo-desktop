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
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private(set) var entries: [ClipboardHistoryEntry] = []

    private init() {}

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer?.tolerance = 0.5
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        // A no-op copy of the exact same text (common when re-selecting the same line) shouldn't
        // duplicate the most recent entry.
        if entries.first?.text == text { return }
        entries.insert(ClipboardHistoryEntry(text: String(text.prefix(maxEntryLength)), copiedAt: Date()), at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
    }
}
