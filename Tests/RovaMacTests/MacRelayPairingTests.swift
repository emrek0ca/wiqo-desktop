import XCTest
@testable import RovaMac

@MainActor
final class MacRelayPairingTests: XCTestCase {
    private struct Offline: Error {}

    /// Plays back scripted backend answers; the last answer repeats.
    private final class FakeBackend: @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: [Result<RelayPairingSession, Error>]
        private var polls: [Result<RelayPollOutcome, Error>]
        private var created = 0

        init(sessions: [Result<RelayPairingSession, Error>], polls: [Result<RelayPollOutcome, Error>]) {
            self.sessions = sessions
            self.polls = polls
        }

        var createCalls: Int {
            lock.lock(); defer { lock.unlock() }
            return created
        }

        var api: RelayPairingAPI {
            RelayPairingAPI(
                createSession: { try self.nextSession().get() },
                poll: { _ in try self.nextPoll().get() }
            )
        }

        private func nextSession() -> Result<RelayPairingSession, Error> {
            lock.lock(); defer { lock.unlock() }
            created += 1
            return sessions.count > 1 ? sessions.removeFirst() : sessions[0]
        }

        private func nextPoll() -> Result<RelayPollOutcome, Error> {
            lock.lock(); defer { lock.unlock() }
            return polls.count > 1 ? polls.removeFirst() : polls[0]
        }
    }

    private final class Recorder {
        var states: [RelayPairingState] = []
        var claims: [(pairingToken: String, backendToken: String?, deviceAccessToken: String?, deviceRefreshToken: String?)] = []
    }

    private let fast = MacRelayPairing.Timing(
        pollInterval: .milliseconds(1),
        retryDelay: .milliseconds(1),
        offlineRetryDelay: .milliseconds(20),
        maxConsecutivePollFailures: 3,
        maxSessionAttempts: 2
    )

    private func session(_ id: String) -> RelayPairingSession {
        RelayPairingSession(id: id, secret: String(repeating: "s", count: 43), expiresAt: Date().addingTimeInterval(600))
    }

    private func run(_ backend: FakeBackend, until condition: @MainActor (Recorder) -> Bool) async -> Recorder {
        let recorder = Recorder()
        let pairing = MacRelayPairing(
            api: backend.api,
            timing: fast,
            onState: { recorder.states.append($0) },
            onClaimed: { recorder.claims.append(($0, $1, $2, $3)) }
        )
        pairing.start()
        var waited = 0
        while !condition(recorder), waited < 400 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            waited += 1
        }
        pairing.cancel()
        return recorder
    }

    func testClaimedSessionHandsOverBothTokens() async {
        let backend = FakeBackend(
            sessions: [.success(session("a"))],
            polls: [.success(.waiting), .success(.claimed(pairingToken: "pair", backendToken: "backend", deviceAccessToken: nil, deviceRefreshToken: nil))]
        )
        let recorder = await run(backend) { !$0.claims.isEmpty }
        XCTAssertEqual(recorder.claims.first?.pairingToken, "pair")
        XCTAssertEqual(recorder.claims.first?.backendToken, "backend")
        XCTAssertEqual(recorder.states.first, .preparing)
        guard case .waiting(let payload)? = recorder.states.dropFirst().first else { return XCTFail("the code must be shown once it exists") }
        XCTAssertEqual(payload.sessionID, "a")
    }

    func testExpiredSessionIsReplacedWithANewCode() async {
        let backend = FakeBackend(
            sessions: [.success(session("old")), .success(session("new"))],
            polls: [.success(.expired), .success(.claimed(pairingToken: "p", backendToken: "b", deviceAccessToken: nil, deviceRefreshToken: nil))]
        )
        let recorder = await run(backend) { !$0.claims.isEmpty }
        XCTAssertEqual(backend.createCalls, 2)
        XCTAssertEqual(recorder.states.filter { if case .waiting = $0 { return true } else { return false } }.count, 2)
        XCTAssertEqual(recorder.claims.count, 1)
    }

    func testAFewFailedPollsDoNotEndPairing() async {
        let backend = FakeBackend(
            sessions: [.success(session("a"))],
            polls: [.failure(Offline()), .failure(Offline()), .success(.claimed(pairingToken: "p", backendToken: "b", deviceAccessToken: nil, deviceRefreshToken: nil))]
        )
        let recorder = await run(backend) { !$0.claims.isEmpty }
        XCTAssertEqual(recorder.claims.count, 1)
        XCTAssertFalse(recorder.states.contains(.unavailable))
    }

    func testUnreachableBackendReportsUnavailableAndKeepsTrying() async {
        let backend = FakeBackend(sessions: [.failure(Offline())], polls: [.success(.waiting)])
        let recorder = await run(backend) { $0.states.contains(.unavailable) && backend.createCalls >= 4 }
        XCTAssertTrue(recorder.states.contains(.unavailable))
        XCTAssertGreaterThanOrEqual(backend.createCalls, 4)
        XCTAssertTrue(recorder.claims.isEmpty)
    }

    func testDatesWithFractionalSecondsAreAccepted() throws {
        let json = #"{"sessionId":"abc","secret":"xyz","expiresAt":"2030-01-01T10:00:00.123Z","platform":"macOS"}"#
        let decoded = try RelayPairingWire.decodeSession(Data(json.utf8))
        XCTAssertEqual(decoded.id, "abc")
        XCTAssertEqual(decoded.expiresAt.timeIntervalSince1970, 1_893_492_000.123, accuracy: 0.001)
        XCTAssertNotNil(RelayPairingWire.parseDate("2030-01-01T10:00:00Z"))
    }

    func testPollBodyMapsToOutcomes() throws {
        XCTAssertEqual(try RelayPairingWire.decodePoll(Data(#"{"status":"waiting","expiresAt":"x"}"#.utf8)), .waiting)
        let claimed = #"{"status":"claimed","pairingToken":"p","backendToken":"b","deviceId":"d"}"#
        XCTAssertEqual(try RelayPairingWire.decodePoll(Data(claimed.utf8)), .claimed(pairingToken: "p", backendToken: "b", deviceAccessToken: nil, deviceRefreshToken: nil))
        XCTAssertThrowsError(try RelayPairingWire.decodePoll(Data(#"{"status":"claimed"}"#.utf8)))
    }
}
