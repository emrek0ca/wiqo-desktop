import XCTest

/// The backend's real responses (contracts/api/*.json, written by the backend's `npm run contracts:api`) decoded with the app's own models:
/// a field renamed or dropped on one side fails here, not on a customer's phone.
final class APIContractTests: XCTestCase {
    private func sample(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/api/\(name).json")
        return try Data(contentsOf: url)
    }

    func testSubscriptionSnapshotDecodesWithEveryFieldTheAppReads() throws {
        let info = try JSONDecoder().decode(SubscriptionInfo.self, from: sample("billing-subscription"))
        XCTAssertEqual(info.tier, "free")
        XCTAssertGreaterThan(info.usage.messages.limit, 0)
        XCTAssertGreaterThan(info.usage.images.limit, 0)
        XCTAssertNotNil(info.usage.act, "Act usage is part of the snapshot")
        XCTAssertNotNil(info.resetDate, "resetsAt parses as the ISO date the server writes")
    }

    func testPlansDecodeAndOnlyProIsSoldInTheApp() throws {
        struct Response: Decodable { let plans: [WiqoPlan]; let proProductId: String }
        let response = try JSONDecoder().decode(Response.self, from: sample("billing-plans"))
        XCTAssertEqual(response.plans.map(\.id), ["free", "pro", "business"])
        XCTAssertEqual(response.plans.filter(\.purchasableInApp).map(\.id), ["pro"])
        XCTAssertTrue(response.plans.allSatisfy { $0.actJobsPerDay != nil }, "every plan lists its Act allowance")
        XCTAssertEqual(response.proProductId, WiqoProduct.proMonthly, "the product the backend verifies is the one the app sells")
    }
}
