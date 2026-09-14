import XCTest
@testable import RovaMac

final class MacCommandEngineTests: XCTestCase {
    func testDuplicateCommandIDIsNotExecutedTwice() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rova-ledger-\(UUID().uuidString).json")
        let engine = MacCommandEngine(ledger: CommandLedger(fileURL: url))
        let id = UUID()
        let request = CommandRequest(id: id, type: .ping)
        let first = await engine.execute(request, runtimeStatus: "running")
        let second = await engine.execute(request, runtimeStatus: "running")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.status, .completed)
        try? FileManager.default.removeItem(at: url)
    }

    func testInvalidCommandIsDenied() async {
        let engine = MacCommandEngine(ledger: CommandLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let request = CommandRequest(type: .getSystemStatus, payload: .url("https://example.com"))
        let result = await engine.execute(request, runtimeStatus: "running")
        XCTAssertEqual(result.status, .denied)
        XCTAssertEqual(result.error?.code, "INVALID_PAYLOAD")
    }

    func testNewFileCommandRejectsPathTraversalBeforeExecution() async {
        let engine = MacCommandEngine(ledger: CommandLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let request = CommandRequest(type: .readDesktopFile, payload: .fileName("../private.txt"))
        let result = await engine.execute(request, runtimeStatus: "running")
        XCTAssertEqual(result.status, .denied)
        XCTAssertEqual(result.error?.code, "INVALID_PAYLOAD")
    }

    func testRestartWithUnfinishedRunningCommandYieldsDenied() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rova-ledger-\(UUID().uuidString).json")
        let ledger = CommandLedger(fileURL: url)
        let id = UUID()
        // Simulate a command that was recorded as running before a crash
        ledger.recordRunning(commandID: id, startedAt: Date(), currentCompleted: [:])

        // Engine restarts after the crash
        let restartedEngine = MacCommandEngine(ledger: ledger)
        let retryRequest = CommandRequest(id: id, type: .ping)
        let result = await restartedEngine.execute(retryRequest, runtimeStatus: "running")
        XCTAssertEqual(result.status, .denied)
        XCTAssertEqual(result.error?.code, "DUPLICATE_DENIED")
        try? FileManager.default.removeItem(at: url)
    }

    func testDuplicateWithDifferentPayloadIsStillDeduplicated() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rova-ledger-\(UUID().uuidString).json")
        let engine = MacCommandEngine(ledger: CommandLedger(fileURL: url))
        let id = UUID()
        let firstRequest = CommandRequest(id: id, type: .ping)
        let first = await engine.execute(firstRequest, runtimeStatus: "running")
        XCTAssertEqual(first.status, .completed)

        // Same ID, different type and payload
        let secondRequest = CommandRequest(id: id, type: .openURL, payload: .url("https://example.com"))
        let second = await engine.execute(secondRequest, runtimeStatus: "running")
        XCTAssertEqual(second, first)
        XCTAssertEqual(second.status, .completed)
        try? FileManager.default.removeItem(at: url)
    }

    func testExpiredCommandIsDenied() async {
        let engine = MacCommandEngine(ledger: CommandLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let expired = CommandRequest(type: .ping, createdAt: Date().addingTimeInterval(-700))
        let result = await engine.execute(expired, runtimeStatus: "running")
        XCTAssertEqual(result.status, .denied)
        XCTAssertEqual(result.error?.code, "EXPIRED_REQUEST")
    }
}
