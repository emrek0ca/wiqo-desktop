import XCTest

final class ThinkingTraceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testStatusAndActivityForTheSameMomentMakeOneLine() {
        var trace = ThinkingTrace(startedAt: start)
        trace.note("Anlıyorum…", at: at(0))
        // The server sends the plain status line first, then the activity with its real id.
        trace.note("Anlıyorum…", at: at(0.1))
        trace.apply(id: "r:1", phase: "understand", label: "Anlıyorum…", state: .running, at: at(0.1))
        trace.note("Hava durumuna bakıyorum…", at: at(1))
        trace.apply(id: "r:1", phase: "understand", label: "Anlıyorum…", state: .done, at: at(1))
        trace.apply(id: "r:2", phase: "tool", label: "Hava durumuna bakıyorum…", state: .running, at: at(1))

        XCTAssertEqual(trace.steps.map(\.id), ["r:1", "r:2"])
        XCTAssertEqual(trace.steps.map(\.state), [.done, .running])
        XCTAssertEqual(trace.current?.phase, "tool")
        XCTAssertTrue(trace.showsTimeline)
    }

    func testRepeatedPollingLinesDoNotStack() {
        var trace = ThinkingTrace(startedAt: start)
        for second in 0..<5 {
            trace.note("İşlem bağlantıdan bağımsız devam ediyor…", at: at(TimeInterval(second)))
        }
        XCTAssertEqual(trace.steps.count, 1)
        XCTAssertFalse(trace.showsTimeline, "a plain wait is one line, not a timeline")
    }

    func testFinishClosesTheRunningLineAndStopsTheClock() {
        var trace = ThinkingTrace(startedAt: start)
        trace.apply(id: "r:1", phase: "device", label: "PC'de çalıştırıyorum…", state: .running, at: at(0))
        trace.finish(failed: true, at: at(9))

        XCTAssertNil(trace.current)
        XCTAssertEqual(trace.steps.first?.state, .failed)
        XCTAssertEqual(trace.duration(now: at(60)), 9)
        // Nothing can reopen a line after the turn is over.
        trace.note("Geç gelen satır", at: at(10))
        XCTAssertEqual(trace.steps.count, 1)
    }

    func testAFollowUpTurnExtendsTheSameTimeline() {
        var trace = ThinkingTrace(startedAt: start)
        trace.apply(id: "a:1", phase: "device", label: "Dosyayı arıyorum…", state: .running, at: at(0))
        trace.finish(at: at(2))
        trace.reopen(at: at(3))
        trace.apply(id: "b:1", phase: "understand", label: "Anlıyorum…", state: .running, at: at(3))
        trace.finish(at: at(5))

        XCTAssertEqual(trace.steps.map(\.id), ["a:1", "b:1"])
        XCTAssertEqual(trace.summary, "2 adımda tamamlandı · 5 sn")
    }

    func testSettledLabelDropsTheTrailingEllipsis() {
        var trace = ThinkingTrace(startedAt: start)
        trace.note("Web'de araştırıyorum…", at: at(0))
        XCTAssertEqual(trace.steps.first?.settledLabel, "Web'de araştırıyorum")
        XCTAssertEqual(ThinkingTrace.formatDuration(72), "1 dk 12 sn")
    }

    func testTraceSurvivesPersistence() throws {
        var trace = ThinkingTrace(startedAt: start)
        trace.apply(id: "r:1", phase: "plan", label: "Bir plan hazırlıyorum…", state: .running, at: at(0))
        trace.finish(at: at(4))
        let decoded = try JSONDecoder().decode(ThinkingTrace.self, from: JSONEncoder().encode(trace))
        XCTAssertEqual(decoded, trace)
    }
}
