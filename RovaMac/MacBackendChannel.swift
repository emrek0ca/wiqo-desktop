import Foundation

/// Persistent connection from this Mac to Rova's backend, so a scheduled automation (something
/// the user set up conversationally, e.g. "her sabah 9'da...") can reach this Mac even when no
/// iPhone is around to ask for anything. Authenticates with the same login JWT the iPhone used
/// to sign in to the Rova backend - handed over once via WireMessage.backendToken on the existing
/// local pairing connection, so this needs no separate Mac-side login screen.
///
/// Only ever receives already-vetted, non-destructive steps (the backend filters out anything
/// destructive before it reaches here - see rova-backend/src/automation/scheduler.ts) and runs
/// them through the exact same MacCommandEngine every other command already goes through.
@MainActor
final class MacBackendChannel: NSObject {
    private static let endpoint = URL(string: "wss://84-247-172-213.sslip.io/device/socket")!
    private static let tokenAccount = "rova-backend-token"

    private let engine: MacCommandEngine
    private let runtimeStatus: () -> String
    private var task: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var currentToken: String?

    init(engine: MacCommandEngine, runtimeStatus: @escaping () -> String) {
        self.engine = engine
        self.runtimeStatus = runtimeStatus
    }

    /// Reconnects with a stored token, if any - call once at app launch.
    func connectWithStoredTokenIfAvailable() {
        guard let data = try? RovaKeychainStore.load(account: Self.tokenAccount),
              let token = String(data: data, encoding: .utf8) else { return }
        connect(token: token)
    }

    func connect(token: String) {
        guard token != currentToken || task == nil else { return }
        try? RovaKeychainStore.save(Data(token.utf8), account: Self.tokenAccount)
        currentToken = token
        reconnectAttempt = 0
        open(token: token)
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        currentToken = nil
        try? RovaKeychainStore.delete(account: Self.tokenAccount)
    }

    private func open(token: String) {
        task?.cancel(with: .goingAway, reason: nil)
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default)
        let newTask = session.webSocketTask(with: request)
        task = newTask
        newTask.resume()
        receiveNext(on: newTask)
    }

    private func receiveNext(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.task === task else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handleIncoming(text) }
                    self.reconnectAttempt = 0
                    self.receiveNext(on: task)
                case .failure:
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handleIncoming(_ text: String) {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AutomationRunPayload.self, from: data) else { return }
        Task { [engine, runtimeStatus] in
            for step in payload.steps where Self.canRunUnattended(step) {
                let request = CommandRequest(type: step.type, payload: step.payload)
                _ = await engine.execute(request, runtimeStatus: runtimeStatus())
            }
        }
    }

    private static func canRunUnattended(_ step: AutomationStep) -> Bool {
        guard !step.isDestructive, step.requiresUserPresence != true else { return false }
        switch step.type {
        case .lockMac, .sleepMac, .displaySleep, .quitApplication, .saveTextFile,
             .sendMessage, .createCalendarEvent, .moveDesktopFile, .renameDesktopFile,
             .saveArtifact, .readDocument, .editDocument:
            return false
        default:
            return true
        }
    }

    private func scheduleReconnect() {
        guard let currentToken else { return }
        reconnectTask?.cancel()
        let delays: [UInt64] = [1, 2, 4, 8, 16, 30]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.open(token: currentToken)
        }
    }
}

private struct AutomationRunPayload: Decodable {
    let type: String
    let runId: Int
    let reply: String?
    let steps: [AutomationStep]
}

private struct AutomationStep: Decodable {
    let type: CommandType
    let payload: CommandPayload
    let summary: String
    let isDestructive: Bool
    // Optional so queued runs written by an older backend remain deliverable.
    let requiresUserPresence: Bool?
}
