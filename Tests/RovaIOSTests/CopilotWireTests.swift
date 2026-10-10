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

    // MARK: Clarification cards (backend d39241f)

    private func card(task: String = "3f9d1c52-8a47-4c0e-b6a1-5e1f2a9b7d10", question: String = "q-8f31a2c4b7d9", options: [String]? = ["Eylül", "Ekim"]) throws -> RovaBackendClient.CopilotResultWidget {
        var object: [String: Any] = [
            "type": "clarification", "taskId": task, "questionId": question, "question": "Hangi ayın raporu?",
            "widgetId": "question:\(question)", "version": 1, "state": "active"
        ]
        if let options { object["options"] = options }
        return try JSONDecoder().decode(RovaBackendClient.CopilotResultWidget.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func bubbles(_ widgets: [RovaBackendClient.CopilotResultWidget], thenUser: Bool = false) -> [ChatBubble] {
        var list = [ChatBubble(role: .user, text: "raporu hazırla"), ChatBubble(role: .assistant, text: "Hangi ayın raporu?", widgets: widgets)]
        if thenUser { list.append(ChatBubble(role: .user, text: "Eylül")) }
        return list
    }

    func testClarificationWidgetDecodesWithQuestionAndOptions() throws {
        let widget = try card()
        XCTAssertEqual(widget.type, .clarification)
        XCTAssertEqual(widget.question, "Hangi ayın raporu?")
        XCTAssertEqual(widget.options, ["Eylül", "Ekim"])
        XCTAssertEqual(widget.questionId, "q-8f31a2c4b7d9")
        XCTAssertEqual(CopilotWidgetCatalog.normalized([widget]).count, 1, "a clarification card is kept, not dropped like the transient approval card")
        XCTAssertNil(try card(options: nil).options)
    }

    func testAnswerKeepsTheCardsTaskAndQuestionIdsVerbatim() throws {
        let widget = try card(task: "3F9D1C52-8A47-4C0E-B6A1-5E1F2A9B7D10")
        let active = WiqoClarification.activeQuestionID(in: bubbles([widget]))
        let answer = try XCTUnwrap(WiqoClarification.answer(for: widget, text: "  Eylül ", activeQuestionID: active, alreadySent: []))
        XCTAssertEqual(answer.text, "Eylül")
        var body: [String: Any] = [:]
        RovaBackendClient.applyTaskIdentity(to: &body, taskID: UUID(), clarification: answer.ids)
        XCTAssertEqual(body["taskId"] as? String, "3F9D1C52-8A47-4C0E-B6A1-5E1F2A9B7D10", "no new task id, and the card's own spelling")
        XCTAssertEqual(body["questionId"] as? String, "q-8f31a2c4b7d9")
        var plain: [String: Any] = [:]
        let task = UUID()
        RovaBackendClient.applyTaskIdentity(to: &plain, taskID: task, clarification: nil)
        XCTAssertEqual(plain["taskId"] as? String, task.uuidString)
        XCTAssertNil(plain["questionId"])
    }

    func testTheSameAnswerIsNotSentTwice() throws {
        let widget = try card()
        let active = WiqoClarification.activeQuestionID(in: bubbles([widget]))
        XCTAssertNotNil(WiqoClarification.answer(for: widget, text: "Eylül", activeQuestionID: active, alreadySent: []))
        XCTAssertNil(WiqoClarification.answer(for: widget, text: "Eylül", activeQuestionID: active, alreadySent: ["q-8f31a2c4b7d9"]))
        XCTAssertNil(WiqoClarification.answer(for: widget, text: "   ", activeQuestionID: active, alreadySent: []), "an empty answer is not sent")
    }

    func testAnsweredOrReplacedCardsAreNotActive() throws {
        let first = try card(task: "11111111-1111-4111-8111-111111111111", question: "q-first-0001")
        let second = try card(task: "22222222-2222-4222-8222-222222222222", question: "q-second-0002")
        XCTAssertEqual(WiqoClarification.activeQuestionID(in: bubbles([first])), "q-first-0001")
        XCTAssertNil(WiqoClarification.activeQuestionID(in: bubbles([first], thenUser: true)), "after the person wrote something the card is read-only")
        // A newer task asked its own question: the older card cannot be answered any more.
        let both = bubbles([first], thenUser: true) + [ChatBubble(role: .assistant, text: "Hangi klasör?", widgets: [second])]
        XCTAssertEqual(WiqoClarification.activeQuestionID(in: both), "q-second-0002")
        XCTAssertNil(WiqoClarification.answer(for: first, text: "Eylül", activeQuestionID: WiqoClarification.activeQuestionID(in: both), alreadySent: []))
        XCTAssertNil(WiqoClarification.activeQuestionID(in: []), "a new chat has no open question")
    }

    func testAPendingCardIsActiveAgainWhenTheChatIsReopened() throws {
        // The conversation comes back from storage with its widgets: the unanswered card is the last message, so it can be answered.
        let restored = bubbles([try card()])
        XCTAssertEqual(WiqoClarification.activeQuestionID(in: restored), "q-8f31a2c4b7d9")
    }

    // MARK: Voice commands

    func testShortSpokenCommandsAreRecognisedWhateverTheCaseOrPunctuation() {
        XCTAssertEqual(WiqoVoiceIntent.parse("Geri al!"), .undo)
        XCTAssertEqual(WiqoVoiceIntent.parse("  DURDUR. "), .stop)
        XCTAssertEqual(WiqoVoiceIntent.parse("tam ekran"), .fullscreen)
        XCTAssertEqual(WiqoVoiceIntent.parse("Koyu tema"), .theme(.dark))
        XCTAssertEqual(WiqoVoiceIntent.parse("Yazıyı büyüt"), .textSize(1))
        XCTAssertEqual(WiqoVoiceIntent.parse("evet"), .confirm)
        XCTAssertEqual(WiqoVoiceIntent.parse("Tekrar yap"), .repeatLast)
    }

    func testALongRequestIsNeverTakenForACommand() {
        XCTAssertEqual(WiqoVoiceIntent.parse("kodu düzelt ve butonu büyüt"), .apply("kodu düzelt ve butonu büyüt"))
        XCTAssertEqual(WiqoVoiceIntent.parse("geri al butonunu mavi yap"), .apply("geri al butonunu mavi yap"))
    }

    func testRiskyRequestsAreTheOnesThatRemoveOrOverwrite() {
        XCTAssertTrue(WiqoVoiceIntent.isRisky("tüm dosyaları sil"))
        XCTAssertTrue(WiqoVoiceIntent.isRisky("index.html üzerine yaz"))
        XCTAssertTrue(WiqoVoiceIntent.isRisky("Hepsini kaldır"))
        XCTAssertFalse(WiqoVoiceIntent.isRisky("butonu mavi yap"))
        XCTAssertFalse(WiqoVoiceIntent.isRisky("silüet çiz"), "a word that merely contains a risky one is not risky")
    }
}
