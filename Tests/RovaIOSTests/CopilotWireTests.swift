import XCTest
@testable import RovaIOS

final class CopilotWireTests: XCTestCase {
    // Shape captured from the production request that queued ~/Desktop/Emre on 2026-10-09.
    // Account identifiers and unrelated user data are intentionally omitted.
    private let storedResponse = #"{"reply":"Sıradaki Mac adımı için onayını bekliyorum.","steps":[{"type":"fileUtility","payload":{"kind":"fileUtility","value":{"action":"createFolder","path":"~/Desktop/Emre","paths":null,"destination":null,"name":null,"tags":null,"mode":null,"limit":50}},"summary":"~/Desktop/Emre klasörünü oluştur","isDestructive":false,"requiresUserPresence":true,"id":"852e2c39-070e-38ce-8033-69a069e76009"}],"executionState":"awaiting_local_confirmation","artifacts":[],"backendConfirmations":[],"widgets":[{"type":"task_plan","taskId":"D69D4229-1F79-4BA2-928F-D6ECD1FBA1F7","title":"Görev adımları","version":1,"widgetId":"plan:D69D4229-1F79-4BA2-928F-D6ECD1FBA1F7","state":"active","planSteps":[{"id":"c12ab221-bab8-4f12-a679-2f5b3c34218b","title":"Masaüstünde Emre adında klasör oluştur.","expectedResult":"Masaüstünde Emre adında klasör oluştur.","dependsOn":[],"status":"awaiting_confirmation"}]}],"deviceConnectivity":{"hasPairedDevice":true,"online":true},"executionTarget":"mixed"}"#

    func testProductionFolderPlanDecodesFromDoneAndStatus() throws {
        let done = try RovaBackendClient.decodeCopilotDone(Data("{\"type\":\"done\",\(storedResponse.dropFirst())".utf8))
        let status = try RovaBackendClient.decodeCompletedCopilotStatus(Data("{\"requestId\":\"D69D4229-1F79-4BA2-928F-D6ECD1FBA1F7\",\"status\":\"done\",\"response\":\(storedResponse)}".utf8))
        for result in [done, status] {
            XCTAssertEqual(result.executionState, "awaiting_local_confirmation")
            XCTAssertEqual(result.steps.count, 1)
            XCTAssertEqual(result.steps.first?.id.uuidString.lowercased(), "852e2c39-070e-38ce-8033-69a069e76009")
            XCTAssertTrue(result.steps.first?.requiresUserPresence == true)
            guard case .fileUtility(let utility)? = result.steps.first?.payload else { return XCTFail("Expected file utility") }
            XCTAssertEqual(utility.action, .createFolder)
            XCTAssertEqual(utility.path, "~/Desktop/Emre")
        }
    }

    func testProductionArtifactCanPassLocalCommandValidation() {
        let url = "https://api.wiqoai.com/copilot/artifacts/388367df-f586-4540-ba59-5577cbde1b49"
        XCTAssertTrue(RovaValidation.isAllowedArtifactURL(url))
        XCTAssertFalse(RovaValidation.isAllowedArtifactURL(url.replacingOccurrences(of: "api.wiqoai.com", with: "api.wiqoai.com.attacker.invalid")))
    }

    func testMalformedFolderActionFailsAtThePayloadPath() {
        let malformed = storedResponse.replacingOccurrences(of: "\"action\":\"createFolder\"", with: "\"action\":\"unknownAction\"")
        XCTAssertThrowsError(try RovaBackendClient.decodeCopilotDone(Data("{\"type\":\"done\",\(malformed.dropFirst())".utf8))) { error in
            guard case DecodingError.dataCorrupted(let context) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(context.codingPath.map(\.stringValue).contains("action"))
        }
    }
}
