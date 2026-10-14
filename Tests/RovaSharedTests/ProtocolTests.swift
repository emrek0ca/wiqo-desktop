import XCTest

final class ProtocolTests: XCTestCase {
    func testLargeDesktopObservationPreservesPlannerIdentityAndTargets() throws {
        let targets = (0..<80).map { index in
            DesktopTarget(ref: "d-\(index)", role: index == 79 ? "textarea" : "row",
                name: String(repeating: "Uzun hedef açıklaması ", count: 12),
                frame: DesktopTargetFrame(x: 0.123456789, y: 0.23456789, width: 0.321234567, height: 0.12345678),
                actions: ["click", "double_click", "right_click", "move", "type"], enabled: true, secure: false)
        }
        let source = DesktopControlContent(taskId: UUID().uuidString, action: .observe, snapshotId: UUID().uuidString,
            applicationName: "TextEdit", applicationIdentifier: "com.apple.TextEdit", targets: targets,
            addedTargets: targets, changedTargets: targets, accessGranted: true, changed: false, verified: true,
            evidence: [ActionVerificationEvidence(index: 0, action: "click", ok: false, changed: false, verified: false, errorCode: "DESKTOP_TARGET_NOT_FOUND")])
        XCTAssertGreaterThan(try JSONEncoder().encode(CommandData.computerDesktop(source)).count, 11_500)
        let data = try XCTUnwrap(source.plannerData())
        XCTAssertLessThanOrEqual(data.count, 10_500)
        guard case .computerDesktop(let decoded) = try JSONDecoder().decode(CommandData.self, from: data) else { return XCTFail("Missing desktop envelope") }
        XCTAssertEqual(decoded.taskId, source.taskId)
        XCTAssertEqual(decoded.snapshotId, source.snapshotId)
        XCTAssertEqual(decoded.action, .observe)
        XCTAssertTrue(decoded.accessGranted)
        XCTAssertEqual(decoded.targets.first?.ref, "d-79")
        XCTAssertFalse(decoded.targets.isEmpty)
        XCTAssertTrue(decoded.addedTargets.isEmpty)
        XCTAssertEqual(decoded.evidence.first?.errorCode, "DESKTOP_TARGET_NOT_FOUND")
    }

    func testSpeechPermissionBridgeHandlesBackgroundCompletion() async {
        let task = Task { @MainActor in
            let granted: Bool = await WiqoSpeechPermissionBridge.resolve { completion in
                DispatchQueue.global(qos: .userInitiated).async {
                    completion(true)
                }
            }
            MainActor.preconditionIsolated()
            return granted
        }

        let granted = await task.value
        XCTAssertTrue(granted)
    }

    func testCommandEncodeDecode() throws {
        let request = CommandRequest(type: .openURL, payload: .url("https://example.com"), createdAt: Date(timeIntervalSince1970: 1_000_000))
        let envelope = WireEnvelope(message: .command(request))
        let encoded = try RovaWireCodec.encode(envelope)
        var buffer = Data()
        let frames = try RovaFrameCodec.appendAndExtract(encoded, from: &buffer)
        XCTAssertEqual(frames.count, 1)
        let decoded = try RovaWireCodec.decode(frames[0])
        XCTAssertEqual(decoded, envelope)
    }

    func testUnknownCommandIsRejected() {
        let json = "{\"message\":{\"kind\":\"command\",\"value\":{\"createdAt\":\"2026-01-01T00:00:00Z\",\"id\":\"00000000-0000-0000-0000-000000000001\",\"payload\":{\"kind\":\"none\"},\"type\":\"unsupported\"}},\"requestID\":\"00000000-0000-0000-0000-000000000002\",\"version\":1}"
        XCTAssertThrowsError(try RovaWireCodec.decode(Data(json.utf8)))
    }

    func testInvalidURLAndUnsupportedPayload() {
        let invalid = CommandRequest(type: .openURL, payload: .url("file:///tmp/private"))
        XCTAssertEqual(RovaValidation.validate(invalid)?.code, "INVALID_URL")
        let unsupported = CommandRequest(type: .getSystemStatus, payload: .url("https://example.com"))
        XCTAssertEqual(RovaValidation.validate(unsupported)?.code, "INVALID_PAYLOAD")
    }

    func testExpiredPairingAndInvalidToken() {
        // isPairingPayloadValid checks shape only; expiry is the caller's own, separate check
        // (this split lets callers tell "malformed QR" and "expired QR" apart, see Validation.swift).
        let expired = PairingPayload(host: "192.168.1.2", port: 47831, certificateFingerprint: String(repeating: "a", count: 64), pairingCode: "123456", expiresAt: Date().addingTimeInterval(-1))
        XCTAssertTrue(RovaValidation.isPairingPayloadValid(expired))
        XCTAssertFalse(expired.expiresAt > Date())

        let malformed = PairingPayload(host: "192.168.1.2", port: 47831, certificateFingerprint: "not-a-fingerprint", pairingCode: "123456", expiresAt: Date().addingTimeInterval(300))
        XCTAssertFalse(RovaValidation.isPairingPayloadValid(malformed))

        let id = UUID()
        XCTAssertFalse(RovaValidation.isValidToken("wrong", expected: "right", deviceID: id, expectedDeviceID: id))
    }

    func testFrameLimit() {
        XCTAssertThrowsError(try RovaFrameCodec.frame(Data(repeating: 1, count: RovaValidation.maxFrameSize + 1))) { error in
            XCTAssertEqual(error as? RovaFrameError, .tooLarge)
        }
    }

    func testVolumeAndMediaValidation() throws {
        let validVolume = CommandRequest(type: .setVolume, payload: .volume(75))
        XCTAssertNil(RovaValidation.validate(validVolume))

        let invalidVolume = CommandRequest(type: .setVolume, payload: .volume(150))
        XCTAssertEqual(RovaValidation.validate(invalidVolume)?.code, "INVALID_PAYLOAD")

        let validMedia = CommandRequest(type: .mediaControl, payload: .media(.playPause))
        XCTAssertNil(RovaValidation.validate(validMedia))

        let invalidMedia = CommandRequest(type: .mediaControl, payload: .none)
        XCTAssertEqual(RovaValidation.validate(invalidMedia)?.code, "INVALID_PAYLOAD")

        let validSleep = CommandRequest(type: .sleepMac)
        XCTAssertNil(RovaValidation.validate(validSleep))

        let invalidSleep = CommandRequest(type: .sleepMac, payload: .volume(50))
        XCTAssertEqual(RovaValidation.validate(invalidSleep)?.code, "INVALID_PAYLOAD")
    }

    func testNewCapabilitiesValidation() throws {
        let validDisplaySleep = CommandRequest(type: .displaySleep)
        XCTAssertNil(RovaValidation.validate(validDisplaySleep))

        let invalidDisplaySleep = CommandRequest(type: .displaySleep, payload: .volume(50))
        XCTAssertEqual(RovaValidation.validate(invalidDisplaySleep)?.code, "INVALID_PAYLOAD")

        let validBrightness = CommandRequest(type: .setBrightness, payload: .brightness(80))
        XCTAssertNil(RovaValidation.validate(validBrightness))

        let invalidBrightness = CommandRequest(type: .setBrightness, payload: .brightness(120))
        XCTAssertEqual(RovaValidation.validate(invalidBrightness)?.code, "INVALID_PAYLOAD")

        let validClipboard = CommandRequest(type: .setClipboardText, payload: .clipboardText("Hello Rova"))
        XCTAssertNil(RovaValidation.validate(validClipboard))

        let invalidClipboardEmpty = CommandRequest(type: .setClipboardText, payload: .clipboardText(""))
        XCTAssertEqual(RovaValidation.validate(invalidClipboardEmpty)?.code, "INVALID_PAYLOAD")

        let validQuitApp = CommandRequest(type: .quitApplication, payload: .application(.safari))
        XCTAssertNil(RovaValidation.validate(validQuitApp))

        let invalidQuitApp = CommandRequest(type: .quitApplication, payload: .none)
        XCTAssertEqual(RovaValidation.validate(invalidQuitApp)?.code, "INVALID_PAYLOAD")
    }

    func testNewCapabilityWireRoundTrips() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let requests = [
            CommandRequest(type: .sendMessage, payload: .message(MessagePayload(recipient: "+905551112233", body: "Merhaba")), createdAt: start),
            CommandRequest(type: .createCalendarEvent, payload: .calendarEvent(CalendarEventPayload(title: "Toplantı", startAt: start, endAt: start.addingTimeInterval(3_600), calendarName: "İş", notes: "Not", location: "Ofis")), createdAt: start),
            CommandRequest(type: .readDesktopFile, payload: .fileName("notlar.txt"), createdAt: start),
            CommandRequest(type: .moveDesktopFile, payload: .fileMove(DesktopFileMovePayload(source: "eski.txt", destination: "yeni.txt")), createdAt: start)
        ]

        for request in requests {
            let envelope = WireEnvelope(requestID: request.id, message: .command(request))
            var buffer = Data()
            let frames = try RovaFrameCodec.appendAndExtract(RovaWireCodec.encode(envelope), from: &buffer)
            XCTAssertEqual(frames.count, 1)
            let decoded = try RovaWireCodec.decode(frames[0])
            XCTAssertEqual(decoded, envelope)
        }
    }

    func testTerminalPayloadDefaultsRemainBackwardCompatible() throws {
        let legacy = """
        {"kind":"codeExecution","value":{"language":"shell","code":"pwd","arguments":[],"timeoutSeconds":30,"allowNetwork":false}}
        """
        let decoded = try JSONDecoder().decode(CommandPayload.self, from: Data(legacy.utf8))
        guard case .codeExecution(let payload) = decoded else {
            return XCTFail("Legacy code execution payload did not decode")
        }
        XCTAssertEqual(payload.scope, "sandbox")
        XCTAssertNil(payload.workingDirectory)

        let computer = CodeExecutionPayload(language: "shell", code: "pwd", scope: "computer", shell: "default", workingDirectory: "/tmp")
        let request = CommandRequest(type: .executeCode, payload: .codeExecution(computer))
        XCTAssertNil(RovaValidation.validate(request))
        let encoded = try JSONEncoder().encode(request.payload)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("computer"))
    }

    func testNewCapabilityValidationRejectsUnsafeInputs() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let validMessage = CommandRequest(type: .sendMessage, payload: .message(MessagePayload(recipient: "user@example.com", body: "Merhaba")))
        XCTAssertNil(RovaValidation.validate(validMessage))

        let invalidMessage = CommandRequest(type: .sendMessage, payload: .message(MessagePayload(recipient: "user@example.com\n", body: "Merhaba")))
        XCTAssertEqual(RovaValidation.validate(invalidMessage)?.code, "INVALID_PAYLOAD")

        let invalidEvent = CommandRequest(type: .createCalendarEvent, payload: .calendarEvent(CalendarEventPayload(title: "Toplantı", startAt: start, endAt: start)))
        XCTAssertEqual(RovaValidation.validate(invalidEvent)?.code, "INVALID_PAYLOAD")

        let traversal = CommandRequest(type: .readDesktopFile, payload: .fileName("../gizli.txt"))
        XCTAssertEqual(RovaValidation.validate(traversal)?.code, "INVALID_PAYLOAD")

        let invalidMove = CommandRequest(type: .moveDesktopFile, payload: .fileMove(DesktopFileMovePayload(source: "a.txt", destination: "a.txt")))
        XCTAssertEqual(RovaValidation.validate(invalidMove)?.code, "INVALID_PAYLOAD")
    }

    func testLegacyDeviceInfoDefaultsToMacOSPlatform() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "displayName": "Mac",
          "hostname": "mac.local",
          "localIPAddress": "192.168.1.10",
          "port": 47831,
          "serviceStatus": "running",
          "availableApplications": []
        }
        """
        let decoded = try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.platform, "macOS")
    }

    func testCellularPathPrefersRelayOverRememberedLocalEndpoint() {
        XCTAssertTrue(RovaConnectionRoutePolicy.shouldPreferRelay(isPaired: true, pathUsesCellular: true))
        XCTAssertFalse(RovaConnectionRoutePolicy.shouldPreferRelay(isPaired: true, pathUsesCellular: false))
        XCTAssertFalse(RovaConnectionRoutePolicy.shouldPreferRelay(isPaired: false, pathUsesCellular: true))
    }

    func testRelayProbeDoesNotDuplicateLiveDirectConnection() {
        XCTAssertTrue(RovaConnectionRoutePolicy.shouldProbeRelay(isPaired: true, directConnected: false, relayConnected: false, probeInFlight: false))
        XCTAssertFalse(RovaConnectionRoutePolicy.shouldProbeRelay(isPaired: true, directConnected: true, relayConnected: false, probeInFlight: false))
        XCTAssertFalse(RovaConnectionRoutePolicy.shouldProbeRelay(isPaired: true, directConnected: false, relayConnected: true, probeInFlight: false))
        XCTAssertFalse(RovaConnectionRoutePolicy.shouldProbeRelay(isPaired: true, directConnected: false, relayConnected: false, probeInFlight: true))
    }

    func testOperationManifestIsCompleteAndDeterministic() throws {
        XCTAssertEqual(RovaOperationManifest.entries.count, CommandType.allCases.count)
        XCTAssertEqual(Set(RovaOperationManifest.entries.map(\.operation)).count, CommandType.allCases.count)
        XCTAssertEqual(
            RovaOperationManifest.advertisedCapabilities(for: .macOS),
            RovaOperationManifest.advertisedCapabilities(for: .macOS).sorted()
        )
        XCTAssertFalse(RovaOperationManifest.supports(.runShortcut, on: .windows))
        XCTAssertFalse(RovaOperationManifest.supports(.executeCode, on: .windows))
        XCTAssertTrue(RovaOperationManifest.supports(.openURL, on: .windows))
        let encoded = try RovaOperationManifest.encodedManifest()
        XCTAssertFalse(encoded.isEmpty)
    }

    func testHMACSignatureAndTimestampValidation() throws {
        let token = "test-secret-token-1234567890abcdef"
        let id = UUID()
        let now = Date()
        let nonce = "nonce-123"
        let signedRequest = RovaValidation.signedRequest(id: id, type: .ping, payload: .none, createdAt: now, nonce: nonce, token: token)
        XCTAssertTrue(RovaValidation.verifyRequestSignature(request: signedRequest, token: token))

        let tamperedRequest = CommandRequest(id: id, type: .lockMac, payload: .none, createdAt: now, signatureVersion: 2, createdAtEpochMs: signedRequest.createdAtEpochMs, signature: signedRequest.signature, nonce: nonce)
        XCTAssertFalse(RovaValidation.verifyRequestSignature(request: tamperedRequest, token: token))

        let expiredDate = now.addingTimeInterval(-700)
        XCTAssertFalse(RovaValidation.isRequestTimestampValid(expiredDate, now: now))
        XCTAssertTrue(RovaValidation.isRequestTimestampValid(now, now: now))
    }
}
