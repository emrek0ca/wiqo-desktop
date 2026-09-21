import Foundation

/// What the pairing window shows for pairing over the internet.
enum RelayPairingState: Equatable {
    /// A new code is being requested; no code is shown so a stale one can never be scanned.
    case preparing
    /// The code is valid and this Mac is watching for the phone to claim it.
    case waiting(RelayPairingPayload)
    case paired
    /// The backend cannot be reached; the local-network code still works.
    case unavailable
}

struct RelayPairingSession: Equatable, Sendable {
    let id: String
    let secret: String
    let expiresAt: Date
}

enum RelayPollOutcome: Equatable, Sendable {
    case waiting
    case claimed(pairingToken: String, backendToken: String, deviceAccessToken: String?, deviceRefreshToken: String?)
    /// Expired, or replaced by a newer session for this PC.
    case expired
}

enum RelayPairingError: Error {
    case requestFailed
}

/// The two backend calls that pairing over the internet needs.
struct RelayPairingAPI: Sendable {
    var createSession: @Sendable () async throws -> RelayPairingSession
    var poll: @Sendable (RelayPairingSession) async throws -> RelayPollOutcome

    static func live(baseURL: URL, deviceID: UUID, displayName: String, urlSession: URLSession = .shared) -> RelayPairingAPI {
        RelayPairingAPI(
            createSession: {
                var request = URLRequest(url: baseURL.appendingPathComponent("device-pairing/sessions"), timeoutInterval: 10)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "deviceId": deviceID.uuidString,
                    "displayName": displayName,
                    "platform": "macOS"
                ])
                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw RelayPairingError.requestFailed
                }
                return try RelayPairingWire.decodeSession(data)
            },
            poll: { session in
                var components = URLComponents(url: baseURL.appendingPathComponent("device-pairing/sessions/\(session.id)"), resolvingAgainstBaseURL: false)
                components?.queryItems = [URLQueryItem(name: "secret", value: session.secret)]
                guard let url = components?.url else { throw RelayPairingError.requestFailed }
                let (data, response) = try await urlSession.data(for: URLRequest(url: url, timeoutInterval: 10))
                guard let http = response as? HTTPURLResponse else { throw RelayPairingError.requestFailed }
                switch http.statusCode {
                case 200..<300: return try RelayPairingWire.decodePoll(data)
                case 429: return .waiting
                case 404, 410: return .expired
                default: throw RelayPairingError.requestFailed
                }
            }
        )
    }
}

/// The backend's JSON. Dates arrive as `2026-01-01T10:00:00.123Z`; `JSONDecoder`'s `.iso8601`
/// strategy rejects the fractional seconds, which used to make every session look like a failure.
enum RelayPairingWire {
    private struct SessionBody: Decodable {
        let sessionId: String
        let secret: String
        let expiresAt: String
    }

    private struct PollBody: Decodable {
        let status: String
        let pairingToken: String?
        let backendToken: String?
        let deviceAccessToken: String?
        let deviceRefreshToken: String?
    }

    static func decodeSession(_ data: Data) throws -> RelayPairingSession {
        let body = try JSONDecoder().decode(SessionBody.self, from: data)
        guard let expiresAt = parseDate(body.expiresAt) else { throw RelayPairingError.requestFailed }
        return RelayPairingSession(id: body.sessionId, secret: body.secret, expiresAt: expiresAt)
    }

    static func decodePoll(_ data: Data) throws -> RelayPollOutcome {
        let body = try JSONDecoder().decode(PollBody.self, from: data)
        guard body.status == "claimed" else { return .waiting }
        guard let pairingToken = body.pairingToken, let backendToken = body.backendToken else { throw RelayPairingError.requestFailed }
        return .claimed(pairingToken: pairingToken, backendToken: backendToken, deviceAccessToken: body.deviceAccessToken, deviceRefreshToken: body.deviceRefreshToken)
    }

    static func parseDate(_ value: String) -> Date? {
        (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(value, strategy: Date.ISO8601FormatStyle()))
    }
}

/// Keeps a pairing code available while this Mac is unpaired: asks the backend for one, watches
/// for the phone to claim it, and quietly asks for a new one when it expires or the network drops.
@MainActor
final class MacRelayPairing {
    struct Timing: Sendable {
        var pollInterval: Duration = .seconds(1)
        var retryDelay: Duration = .seconds(3)
        var offlineRetryDelay: Duration = .seconds(15)
        var maxConsecutivePollFailures = 5
        var maxSessionAttempts = 3
    }

    private enum WatchResult {
        case claimed(pairingToken: String, backendToken: String, deviceAccessToken: String?, deviceRefreshToken: String?)
        case expired
        case offline
        case cancelled
    }

    private let api: RelayPairingAPI
    private let timing: Timing
    private let onState: @MainActor (RelayPairingState) -> Void
    private let onClaimed: @MainActor (_ pairingToken: String, _ backendToken: String, _ deviceAccessToken: String?, _ deviceRefreshToken: String?) async -> Void
    private var task: Task<Void, Never>?

    init(
        api: RelayPairingAPI,
        timing: Timing = Timing(),
        onState: @escaping @MainActor (RelayPairingState) -> Void,
        onClaimed: @escaping @MainActor (_ pairingToken: String, _ backendToken: String, _ deviceAccessToken: String?, _ deviceRefreshToken: String?) async -> Void
    ) {
        self.api = api
        self.timing = timing
        self.onState = onState
        self.onClaimed = onClaimed
    }

    /// Starts over with a fresh code. The old code is dropped first: the backend discards it as
    /// soon as the new session exists, so leaving it on screen would let the phone scan a dead one.
    func start() {
        task?.cancel()
        onState(.preparing)
        task = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        while !Task.isCancelled {
            guard let session = await createSession() else {
                if Task.isCancelled { return }
                onState(.unavailable)
                try? await Task.sleep(for: timing.offlineRetryDelay)
                continue
            }
            onState(.waiting(RelayPairingPayload(sessionID: session.id, secret: session.secret, expiresAt: session.expiresAt)))
            switch await watch(session) {
            case .claimed(let pairingToken, let backendToken, let deviceAccessToken, let deviceRefreshToken):
                await onClaimed(pairingToken, backendToken, deviceAccessToken, deviceRefreshToken)
                return
            case .expired:
                onState(.preparing)
            case .offline:
                onState(.unavailable)
                try? await Task.sleep(for: timing.offlineRetryDelay)
            case .cancelled:
                return
            }
        }
    }

    private func createSession() async -> RelayPairingSession? {
        for attempt in 0..<timing.maxSessionAttempts {
            if Task.isCancelled { return nil }
            if let session = try? await api.createSession() { return session }
            if attempt + 1 < timing.maxSessionAttempts { try? await Task.sleep(for: timing.retryDelay) }
        }
        return nil
    }

    private func watch(_ session: RelayPairingSession) async -> WatchResult {
        var failures = 0
        while Date() < session.expiresAt {
            if Task.isCancelled { return .cancelled }
            do {
                switch try await api.poll(session) {
                case .claimed(let pairingToken, let backendToken, let deviceAccessToken, let deviceRefreshToken): return .claimed(pairingToken: pairingToken, backendToken: backendToken, deviceAccessToken: deviceAccessToken, deviceRefreshToken: deviceRefreshToken)
                case .expired: return .expired
                case .waiting: failures = 0
                }
            } catch {
                if Task.isCancelled { return .cancelled }
                failures += 1
                if failures >= timing.maxConsecutivePollFailures { return .offline }
            }
            try? await Task.sleep(for: timing.pollInterval)
        }
        return Task.isCancelled ? .cancelled : .expired
    }
}
