import XCTest
@testable import RovaMac

final class MacTimeoutTests: XCTestCase {
    func testInteractiveTerminalHasTTYAndAcceptsTurkishInput() async {
        let endpoint = TerminalInputEndpoint()
        let result = await Task.detached {
            MacSystem.runProcess(executable: "/bin/sh", arguments: ["-c", "test -t 0 && test -t 1 || exit 7; printf 'hazır: '; IFS= read -r answer; printf 'ok:%s' \"$answer\""], timeoutSeconds: 5,
                processStarted: { _ in XCTAssertTrue(endpoint.send("Türkçe 123\n")) }, terminalInput: endpoint)
        }.value
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(String(decoding: result.stdout, as: UTF8.self).contains("ok:Türkçe 123"))
        XCTAssertFalse(endpoint.send("late\n"))
    }

    func testNoisyTerminalYieldsToTimeoutAndKeepsRecentOutput() async {
        let result = await Task.detached {
            MacSystem.runProcess(executable: "/bin/sh", arguments: ["-c", "while :; do printf 'new-output-1234567890\n'; done"], timeoutSeconds: 1, outputLimit: 1024)
        }.value
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.truncated)
        XCTAssertLessThanOrEqual(result.stdout.count, 1024)
        XCTAssertLessThan(result.durationMs, 4000)
    }

    func testReturnsTheResultOfFastWork() async {
        let value = await MacTimeout.run(seconds: 2) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testReturnsNilWhenWorkIsTooSlow() async {
        let started = Date()
        let value = await MacTimeout.run(seconds: 0.1) { () -> Int in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return 1
        }
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testAFailedResultIsStillAResult() async {
        let value = await MacTimeout.run(seconds: 2) { () -> Result<Int, MacTimeoutTestError> in .failure(.boom) }
        guard case .some(.failure) = value else { return XCTFail("expected the failure to come through") }
    }
}

private enum MacTimeoutTestError: Error { case boom }
