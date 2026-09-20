import Foundation

/// Runs work that can block (keychain access, system scans) without letting it hold up the caller.
enum MacTimeout {
    /// The result of `operation`, or nil when it has not finished after `seconds`. Work stuck in a
    /// call that cannot be cancelled keeps running in the background; the caller just stops
    /// waiting for it.
    static func run<T: Sendable>(
        seconds: TimeInterval,
        priority: TaskPriority = .userInitiated,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withCheckedContinuation { continuation in
            let gate = Gate<T>(continuation)
            gate.setTimer(Task.detached(priority: priority) {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                gate.finish(nil)
            })
            Task.detached(priority: priority) { gate.finish(await operation()) }
        }
    }

    /// Resumes the caller exactly once: with the first result, or with nil when the timer wins.
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var timer: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<T?, Never>) {
            self.continuation = continuation
        }

        func setTimer(_ timer: Task<Void, Never>) {
            lock.lock(); defer { lock.unlock() }
            self.timer = timer
        }

        func finish(_ value: T?) {
            lock.lock()
            let pending = continuation
            let timer = timer
            continuation = nil
            self.timer = nil
            lock.unlock()
            timer?.cancel()
            pending?.resume(returning: value)
        }
    }
}
