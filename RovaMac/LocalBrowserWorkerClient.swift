import Foundation

/// Owns one lazy JSONL worker process. The worker opens a fresh, visible Playwright context for
/// each task id; no browser profile or cookie jar is persisted between tasks.
final class LocalBrowserWorkerClient: @unchecked Sendable {
    private struct Request: Encodable {
        let id: String
        let action: String
        let taskId: String
        var url: String? = nil
        var targetBy: String? = nil
        var target: String? = nil
        var role: String? = nil
        var value: String? = nil
        var direction: String? = nil
        var cancelRequestId: String? = nil
    }

    private struct Result: Decodable {
        let taskId: String?
        let action: String?
        let url: String?
        let title: String?
        let text: String?
        let truncated: Bool?
        let verified: Bool?
        let closed: Bool?
    }

    private struct WorkerError: Decodable {
        let code: String
        let message: String
    }

    private struct Envelope: Decodable {
        let id: String
        let ok: Bool
        let result: Result?
        let error: WorkerError?
    }

    private enum WorkerFailure: LocalizedError {
        case unavailable
        case terminated
        case invalidResponse
        case rejected(String, String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Yerel tarayıcı bileşeni başlatılamadı."
            case .terminated: return "Yerel tarayıcı işlemi beklenmedik biçimde durdu."
            case .invalidResponse: return "Yerel tarayıcıdan güvenli bir sonuç alınamadı."
            case .rejected(_, let message): return message
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputBuffer = Data()
    private var pending: [String: CheckedContinuation<Envelope, Error>] = [:]

    func perform(_ payload: ComputerBrowserPayload) async -> (BrowserContent?, String, RovaError?) {
        let request = Request(
            id: UUID().uuidString.lowercased(),
            action: payload.action,
            taskId: payload.taskId,
            url: payload.url,
            targetBy: payload.targetBy,
            target: payload.target,
            role: payload.role,
            value: payload.value,
            direction: payload.direction
        )
        do {
            let envelope = try await send(request)
            guard envelope.ok, let result = envelope.result, let taskId = result.taskId else {
                if let error = envelope.error { throw WorkerFailure.rejected(error.code, error.message) }
                throw WorkerFailure.invalidResponse
            }
            return (
                BrowserContent(taskId: taskId, action: result.action, url: result.url, title: result.title, text: result.text, truncated: result.truncated, verified: result.verified),
                "Tarayıcı işlemi tamamlandı ve sonucu doğrulandı.",
                nil
            )
        } catch {
            let (code, message, category) = safeError(error)
            return (nil, message, RovaError(code: code, message: message, category: category))
        }
    }

    func close(taskId: String) async -> (BrowserContent?, String, RovaError?) {
        let request = Request(id: UUID().uuidString.lowercased(), action: "closeTask", taskId: taskId)
        do {
            let envelope = try await send(request)
            guard envelope.ok, let result = envelope.result, let id = result.taskId else {
                if let error = envelope.error { throw WorkerFailure.rejected(error.code, error.message) }
                throw WorkerFailure.invalidResponse
            }
            return (BrowserContent(taskId: id, closed: result.closed ?? true), "Göreve özel tarayıcı oturumu kapatıldı.", nil)
        } catch {
            let (code, message, category) = safeError(error)
            return (nil, message, RovaError(code: code, message: message, category: category))
        }
    }

    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard let process, process.isRunning, let input else { return }
        let request = Request(id: UUID().uuidString.lowercased(), action: "shutdown", taskId: UUID().uuidString.lowercased())
        guard var data = try? JSONEncoder().encode(request) else { return }
        data.append(0x0A)
        try? input.write(contentsOf: data)
        self.process = nil
        self.input = nil
        self.output?.readabilityHandler = nil
        self.output = nil
    }

    private func send(_ request: Request) async throws -> Envelope {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                do {
                    try ensureWorkerLocked()
                    guard let input else { throw WorkerFailure.unavailable }
                    pending[request.id] = continuation
                    var data = try JSONEncoder().encode(request)
                    data.append(0x0A)
                    try input.write(contentsOf: data)
                    lock.unlock()
                } catch {
                    pending.removeValue(forKey: request.id)
                    lock.unlock()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            self.cancel(requestID: request.id, taskID: request.taskId)
        }
    }

    private func ensureWorkerLocked() throws {
        if process?.isRunning == true { return }
        guard let workerURL = Bundle.main.resourceURL?.appendingPathComponent("RovaBrowserWorker/index.mjs"),
              FileManager.default.fileExists(atPath: workerURL.path) else {
            throw WorkerFailure.unavailable
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Wiqo/BrowserWorker", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let child = Process()
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = existingPath + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        guard let node = nodeExecutable(path: environment["PATH"] ?? existingPath, preferred: environment["WIQO_NODE_EXECUTABLE"]) else {
            throw WorkerFailure.unavailable
        }
        child.executableURL = URL(fileURLWithPath: node)
        child.arguments = [workerURL.path]
        environment["WIQO_BROWSER_WORKER_PACKAGE_ROOT"] = support.path
        environment["PLAYWRIGHT_BROWSERS_PATH"] = support.appendingPathComponent(".browsers", isDirectory: true).path
        child.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] _ in self?.workerTerminated() }
        do { try child.run() } catch { throw WorkerFailure.unavailable }

        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        outputBuffer.removeAll(keepingCapacity: true)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.workerTerminated()
            } else {
                self?.receive(data)
            }
        }
    }

    private func receive(_ data: Data) {
        var messages: [Data] = []
        lock.lock()
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            messages.append(outputBuffer.prefix(upTo: newline))
            outputBuffer.removeSubrange(outputBuffer.startIndex..<outputBuffer.index(after: newline))
        }
        lock.unlock()

        for message in messages {
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: message) else { continue }
            lock.lock()
            let continuation = pending.removeValue(forKey: envelope.id)
            lock.unlock()
            continuation?.resume(returning: envelope)
        }
    }

    private func cancel(requestID: String, taskID: String) {
        lock.lock()
        let continuation = pending.removeValue(forKey: requestID)
        if process?.isRunning == true, let input {
            let cancel = Request(id: UUID().uuidString.lowercased(), action: "cancel", taskId: taskID, cancelRequestId: requestID)
            if var data = try? JSONEncoder().encode(cancel) {
                data.append(0x0A)
                try? input.write(contentsOf: data)
            }
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func workerTerminated() {
        lock.lock()
        process = nil
        input = nil
        output = nil
        let continuations = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume(throwing: WorkerFailure.terminated) }
    }

    private func safeError(_ error: Error) -> (String, String, String) {
        if let failure = error as? WorkerFailure {
            switch failure {
            case .rejected(let code, let message):
                let category = code.contains("TIMEOUT") ? "timeout" : code.contains("BLOCKED") || code.contains("UNSAFE") ? "permission" : "tool_failure"
                return (code, message, category)
            case .unavailable:
                return ("BROWSER_RUNTIME_MISSING", "Yerel tarayıcı bileşeni başlatılamadı.", "unavailable")
            case .terminated:
                return ("BROWSER_FAILED", "Yerel tarayıcı işlemi beklenmedik biçimde durdu.", "tool_failure")
            case .invalidResponse:
                return ("BROWSER_FAILED", "Tarayıcıdan güvenli bir sonuç alınamadı.", "tool_failure")
            }
        }
        if error is CancellationError { return ("BROWSER_CANCELLED", "Tarayıcı işlemi iptal edildi.", "cancelled") }
        return ("BROWSER_FAILED", "Tarayıcı işlemi tamamlanamadı.", "tool_failure")
    }

    private func nodeExecutable(path: String, preferred: String?) -> String? {
        let candidates = [preferred].compactMap { $0 } + path.split(separator: ":").map { String($0) + "/node" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
