import XCTest
@testable import RovaMac

final class MacCommandEngineTests: XCTestCase {
    func testArtifactURLAcceptsProductionOriginAndRejectsLookalikes() {
        let path = "/copilot/artifacts/388367df-f586-4540-ba59-5577cbde1b49"
        XCTAssertTrue(RovaValidation.isAllowedArtifactURL("https://api.wiqoai.com" + path))
        XCTAssertTrue(RovaValidation.isAllowedArtifactURL("https://84-247-172-213.sslip.io" + path))
        XCTAssertFalse(RovaValidation.isAllowedArtifactURL("http://api.wiqoai.com" + path))
        XCTAssertFalse(RovaValidation.isAllowedArtifactURL("https://api.wiqoai.com.evil.test" + path))
        XCTAssertFalse(RovaValidation.isAllowedArtifactURL("https://api.wiqoai.com/other/388367df-f586-4540-ba59-5577cbde1b49"))
        XCTAssertFalse(RovaValidation.isAllowedArtifactURL("https://api.wiqoai.com" + path + "?redirect=evil"))
    }

    func testCreateFolderReturnsEvidenceOnlyAfterDirectoryExists() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("wiqo-folder-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("Emre", isDirectory: true)

        let first = await MacSystem.fileUtility(FileUtilityPayload(action: .createFolder, path: folder.path))
        XCTAssertNil(first.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        guard case .files(let entries) = first.data else { return XCTFail("Missing folder evidence") }
        XCTAssertEqual(entries.first?.path, folder.path)

        let second = await MacSystem.fileUtility(FileUtilityPayload(action: .createFolder, path: folder.path))
        XCTAssertNil(second.error)
        XCTAssertEqual(second.message, "Emre klasörü zaten var.")
    }

    func testMoveDocumentsMovesOnlyDirectDocumentsAndVerifiesEveryFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wiqo-documents-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Desktop", isDirectory: true)
        let destination = source.appendingPathComponent("Emre", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("report".utf8).write(to: source.appendingPathComponent("Report.docx"))
        try Data("paper".utf8).write(to: source.appendingPathComponent("Paper.pdf"))
        try Data("secret".utf8).write(to: source.appendingPathComponent("AuthKey.p8"))
        let otherFolder = source.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: otherFolder.appendingPathComponent("Nested.pdf"))

        let result = await MacSystem.fileUtility(FileUtilityPayload(action: .moveDocuments, path: source.path, destination: destination.path, limit: 500))
        XCTAssertNil(result.error)
        XCTAssertTrue(result.message.contains("2 belge"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("Report.docx").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Report.docx").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Paper.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("AuthKey.p8").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherFolder.appendingPathComponent("Nested.pdf").path))
    }

    func testMoveDocumentsStopsBeforeAnyMutationOnNameCollision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wiqo-collision-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Desktop", isDirectory: true)
        let destination = source.appendingPathComponent("Emre", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["A.pdf", "B.docx"] { try Data(name.utf8).write(to: source.appendingPathComponent(name)) }
        try Data("existing".utf8).write(to: destination.appendingPathComponent("B.docx"))

        let result = await MacSystem.fileUtility(FileUtilityPayload(action: .moveDocuments, path: source.path, destination: destination.path))
        XCTAssertEqual(result.error?.code, "FILE_EXISTS")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("A.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("B.docx").path))
    }

    func testMoveDocumentsCreatesMissingDestinationOnlyWhenDocumentsAreReady() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wiqo-create-destination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Emre", isDirectory: true)
        try Data("paper".utf8).write(to: root.appendingPathComponent("Paper.pdf"))
        let result = await MacSystem.fileUtility(FileUtilityPayload(action: .moveDocuments, path: root.path, destination: destination.path))
        XCTAssertNil(result.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Paper.pdf").path))
    }

    func testCommittedFileEvidenceRejectsMissingAndMismatchedContent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wiqo-evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("report.txt")
        try Data("proof".utf8).write(to: file)
        let success = MacSystem.verifiedFileResult(path: file.path, expectedContent: "proof", expectedBytes: 5)
        XCTAssertNil(success.error)
        guard case .files(let files) = success.data else { return XCTFail("Missing file evidence") }
        XCTAssertEqual(files.first?.byteCount, 5)
        XCTAssertEqual(files.first?.path, file.resolvingSymlinksInPath().path)
        XCTAssertEqual(MacSystem.verifiedFileResult(path: file.path, expectedContent: "other").error?.code, "FILE_VERIFICATION_FAILED")
        XCTAssertEqual(MacSystem.verifiedFileResult(path: file.path, expectedBytes: 6).error?.code, "FILE_VERIFICATION_FAILED")
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(MacSystem.verifiedFileResult(path: file.path).error?.code, "FILE_VERIFICATION_FAILED")
    }

    func testDocumentFilenameEvidenceMatchesOutputExtension() {
        XCTAssertEqual(DocumentEngine.filenameWithExtension("report", format: .pdf), "report.pdf")
        XCTAssertEqual(DocumentEngine.filenameWithExtension("report.PDF", format: .pdf), "report.PDF")
    }

    @MainActor
    func testBackendRelayUsesCanonicalProductionHost() {
        let endpoint = MacBackendChannel.endpoint
        let apiBaseURL = MacBackendChannel.apiBaseURL
        XCTAssertEqual(endpoint.scheme, "wss")
        XCTAssertEqual(endpoint.host, "api.wiqoai.com")
        XCTAssertEqual(endpoint.path, "/device/socket")
        XCTAssertEqual(apiBaseURL.absoluteString, "https://api.wiqoai.com")
    }

    @MainActor
    func testResendRegistrationIsANoOpWithoutALiveSocket() {
        // Regression guard: `MacRuntime.broadcastDeviceInfo()` calls this unconditionally after
        // every device scan, including the very first one before any backend connection exists.
        // It must never assume a socket is present.
        let channel = MacBackendChannel(
            engine: MacCommandEngine(ledger: CommandLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("resend-noop-\(UUID().uuidString).json"))),
            runtimeStatus: { "running" },
            deviceInfo: { DeviceInfo(id: UUID(), displayName: "Test Mac", hostname: "test", localIPAddress: "127.0.0.1", port: 47831, serviceStatus: "running", availableApplications: []) },
            pairedDeviceToken: { nil }
        )
        channel.resendRegistration()
    }

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

    func testRestartWithUnfinishedRunningCommandYieldsUnknownWithoutReplay() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rova-ledger-\(UUID().uuidString).json")
        let ledger = CommandLedger(fileURL: url)
        let id = UUID()
        // Simulate a command that was recorded as running before a crash
        ledger.recordRunning(commandID: id, startedAt: Date(), currentCompleted: [:])

        // Engine restarts after the crash
        let restartedEngine = MacCommandEngine(ledger: ledger)
        let retryRequest = CommandRequest(id: id, type: .ping)
        let result = await restartedEngine.execute(retryRequest, runtimeStatus: "running")
        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.error?.code, "OUTCOME_UNKNOWN")
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

    func testConcurrentCommandsCompleteAndHistoryStaysBounded() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rova-ledger-\(UUID().uuidString).json")
        let engine = MacCommandEngine(ledger: CommandLedger(fileURL: url))

        await withTaskGroup(of: CommandResult.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await engine.execute(CommandRequest(type: .ping), runtimeStatus: "running")
                }
            }
            for await result in group {
                XCTAssertEqual(result.status, .completed)
            }
        }

        for _ in 0..<90 {
            _ = await engine.execute(CommandRequest(type: .ping), runtimeStatus: "running")
        }
        let persisted = await engine.persistedResults()
        XCTAssertEqual(persisted.count, 128)
        try? FileManager.default.removeItem(at: url)
    }

    func testCapabilitySettingsStayWithinSharedCommandManifest() {
        let settingsCapabilities = Set(RovaCapabilityCatalog.groups.flatMap(\.capabilities))
        let toggleableCapabilities = RovaCommandAuthority.allCapabilities.subtracting(["runtime.status"])
        XCTAssertEqual(settingsCapabilities, toggleableCapabilities)
    }
}

final class ApplicationResolutionTests: XCTestCase {
    func testNormalizationDropsGrammarAndFiller() {
        XCTAssertEqual(ApplicationNameMatcher.normalize("Safari'yi"), "safari")
        XCTAssertEqual(ApplicationNameMatcher.normalize("Chrome’u"), "chrome")
        XCTAssertEqual(ApplicationNameMatcher.normalize("Safari uygulamasını"), "safari")
        XCTAssertEqual(ApplicationNameMatcher.normalize("SAFARİ"), "safari")
        XCTAssertEqual(ApplicationNameMatcher.normalize("Notes.app"), "notes")
        XCTAssertEqual(ApplicationNameMatcher.normalize("Sistem Ayarları"), "sistem ayarlari")
        XCTAssertEqual(ApplicationNameMatcher.normalize("  VS-Code "), "vs code")
    }

    func testExactBeatsLongerNames() {
        let query = ApplicationNameMatcher.normalize("Mail")
        XCTAssertEqual(ApplicationNameMatcher.score("Mail", query: query), 1.0)
        XCTAssertLessThan(ApplicationNameMatcher.score("Mailplane", query: query), 1.0)
    }

    /// The live failure: Safari is a hidden symlink into the cryptex on current macOS.
    func testResolvesSystemAppsOnThisMac() {
        let expectations: [(String, String)] = [
            ("Safari", "com.apple.Safari"),
            ("Safari'yi", "com.apple.Safari"),
            ("safari uygulamasını", "com.apple.Safari"),
            ("Terminal", "com.apple.Terminal"),
            ("Notes", "com.apple.Notes"),
            ("Notlar", "com.apple.Notes"),
            ("Takvim", "com.apple.iCal"),
            ("Calendar", "com.apple.iCal"),
            ("Sistem Ayarları", "com.apple.systempreferences"),
            ("Activity Monitor", "com.apple.ActivityMonitor"),
            ("Hesap Makinesi", "com.apple.calculator"),
            ("Finder", "com.apple.finder")
        ]
        for (target, bundle) in expectations {
            guard case .resolved(let application) = MacSystem.resolveApplication(target: target, bundleIdentifier: nil).outcome else {
                XCTFail("\(target) çözümlenemedi")
                continue
            }
            XCTAssertEqual(application.bundleIdentifier, bundle, target)
            XCTAssertNotNil(application.path, target)
        }
    }

    func testInventedBundleFallsBackToName() {
        guard case .resolved(let application) = MacSystem.resolveApplication(target: "Safari", bundleIdentifier: "com.invented.safari").outcome else {
            return XCTFail("Safari çözümlenemedi")
        }
        XCTAssertEqual(application.bundleIdentifier, "com.apple.Safari")
    }

    func testUnknownAppIsNotFound() {
        guard case .notFound = MacSystem.resolveApplication(target: "Qzxv Wplk", bundleIdentifier: nil).outcome else {
            return XCTFail("uydurma uygulama çözümlenmemeli")
        }
    }

    func testCatalogCarriesSafariAndAliasesWithinBackendLimit() {
        let catalog = MacSystem.applicationTargets()
        XCTAssertLessThanOrEqual(catalog.count, 200)
        XCTAssertTrue(catalog.contains { $0.bundleIdentifier == "com.apple.Safari" })
        let names = Set(catalog.map { ApplicationNameMatcher.normalize($0.name) })
        XCTAssertTrue(names.contains("notes") && names.contains("notlar"))
        XCTAssertEqual(names.count, catalog.count, "katalogda aynı ad iki kez olmamalı")
    }
}
