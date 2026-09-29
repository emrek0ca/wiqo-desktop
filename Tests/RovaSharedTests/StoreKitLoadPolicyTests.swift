import XCTest

final class StoreKitLoadPolicyTests: XCTestCase {
    func testStartupUsesThreeBoundedAttemptsAtZeroOneAndThreeSeconds() {
        XCTAssertEqual(StoreKitLoadPolicy.delays(for: .startup), [0, 1, 3])
    }

    func testInteractiveTriggersUseOneAttempt() {
        XCTAssertEqual(StoreKitLoadPolicy.delays(for: .paywall), [0])
        XCTAssertEqual(StoreKitLoadPolicy.delays(for: .foreground), [0])
        XCTAssertEqual(StoreKitLoadPolicy.delays(for: .manual), [0])
    }

    func testForegroundRetryWaitsThirtySecondsAfterFailure() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(StoreKitLoadPolicy.shouldRetryOnForeground(lastFailure: now.addingTimeInterval(-29.9), now: now))
        XCTAssertTrue(StoreKitLoadPolicy.shouldRetryOnForeground(lastFailure: now.addingTimeInterval(-30), now: now))
        XCTAssertFalse(StoreKitLoadPolicy.shouldRetryOnForeground(lastFailure: nil, now: now))
    }
}
