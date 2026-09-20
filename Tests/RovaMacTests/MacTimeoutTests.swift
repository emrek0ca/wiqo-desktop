import XCTest
@testable import RovaMac

final class MacTimeoutTests: XCTestCase {
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
