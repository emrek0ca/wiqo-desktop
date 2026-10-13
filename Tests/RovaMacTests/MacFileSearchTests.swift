import XCTest
@testable import RovaMac

final class MacFileSearchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wiqo-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func make(_ relative: String, daysAgo: Double = 0, bytes: Int = 10) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
        return url
    }

    private func spec(_ query: String = "", alternatives: [String] = [], kind: String? = nil, days: Int? = nil, recent: Bool = false) -> MacFileSearch.Spec {
        let groups = ([MacFileSearch.tokens(from: query)] + alternatives.map(MacFileSearch.tokens(from:))).filter { !$0.isEmpty }
        return MacFileSearch.Spec(
            tokens: MacFileSearch.tokens(from: query),
            groups: groups,
            limit: 400,
            roots: [root],
            kind: kind,
            since: days.map { Date().addingTimeInterval(-Double($0) * 86_400) },
            content: false,
            recent: recent
        )
    }

    private func names(_ entries: [FileSystemEntry]) -> [String] { entries.map(\.name) }

    // MARK: The Spotlight expression

    func testAWordDocumentBecomesAPDFWithoutAnyOfficeProgram() async throws {
        let text = NSAttributedString(string: "Merhaba dünya. Bu bir deneme raporudur.\n\nİkinci paragraf.")
        let docx = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let url = root.appendingPathComponent("rapor.docx")
        try docx.write(to: url)
        let outcome = await MacSystem.convertFile(LocalFileOperationPayload(path: url.path))
        XCTAssertNil(outcome.error?.message)
        guard case .files(let entries)? = outcome.data, let entry = entries.first else { return XCTFail("no file card") }
        XCTAssertEqual(entry.name, "rapor.pdf")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: entry.path))
        XCTAssertEqual(String(decoding: bytes.prefix(4), as: UTF8.self), "%PDF")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the original stays")
    }

    private func wordDocument(named name: String) throws -> URL {
        let text = NSAttributedString(string: "Plan deneme belgesi.")
        let docx = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let url = root.appendingPathComponent(name)
        try docx.write(to: url)
        return url
    }

    func testAPlanFindsConvertsAndStopsAtTheFirstFailure() async throws {
        _ = try wordDocument(named: "plan-raporu.docx")
        let plan = FilePlanPayload(steps: [
            FilePlanStep(id: "s1", op: "search", query: "plan-raporu", folder: root.path),
            FilePlanStep(id: "s2", op: "convert", path: "$s1")
        ])
        XCTAssertNil(RovaValidation.filePlanError(plan))
        let outcome = await MacSystem.runFilePlan(plan, transferToken: nil)
        XCTAssertNil(outcome.error?.message)
        guard case .planResult(let result)? = outcome.data else { return XCTFail("no plan result") }
        XCTAssertEqual(result.steps.map(\.status), ["completed", "completed"])
        XCTAssertEqual(result.steps[1].files?.first?.name, "plan-raporu.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("plan-raporu.pdf").path))

        let missing = FilePlanPayload(steps: [
            FilePlanStep(id: "s1", op: "search", query: "böyle-bir-dosya-yok", folder: root.path),
            FilePlanStep(id: "s2", op: "convert", path: "$s1"),
            FilePlanStep(id: "s3", op: "send", path: "$s2", transferId: UUID().uuidString)
        ])
        let stopped = await MacSystem.runFilePlan(missing, transferToken: nil)
        XCTAssertNotNil(stopped.error)
        guard case .planResult(let halted)? = stopped.data else { return XCTFail("no plan result") }
        XCTAssertEqual(halted.steps.map(\.status), ["completed", "failed", "skipped"])
    }

    func testAPlanCanMoveEveryFileItFoundIntoAFolder() async throws {
        _ = try wordDocument(named: "a-rapor.docx")
        _ = try wordDocument(named: "b-rapor.docx")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("arsiv"), withIntermediateDirectories: true)
        let plan = FilePlanPayload(steps: [
            FilePlanStep(id: "s1", op: "search", query: "rapor", kind: "document", folder: root.path),
            FilePlanStep(id: "s2", op: "move", path: "$s1*", destination: root.appendingPathComponent("arsiv").path + "/")
        ])
        XCTAssertNil(RovaValidation.filePlanError(plan))
        let outcome = await MacSystem.runFilePlan(plan, transferToken: nil)
        XCTAssertNil(outcome.error?.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("arsiv/a-rapor.docx").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("arsiv/b-rapor.docx").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a-rapor.docx").path))
        XCTAssertNotNil(RovaValidation.filePlanError(FilePlanPayload(steps: [FilePlanStep(id: "s1", op: "search", query: "x"), FilePlanStep(id: "s2", op: "move", path: "$s1*", destination: "~/Desktop/arsiv")])), "a folder destination must end with /")
        XCTAssertNotNil(RovaValidation.filePlanError(FilePlanPayload(steps: [FilePlanStep(id: "s1", op: "search", query: "x"), FilePlanStep(id: "s2", op: "send", path: "$s1*", transferId: UUID().uuidString)])), "no fan-out for send")
    }

    @MainActor
    func testATaskGrantCoversFileWorkInItsFoldersOnly() throws {
        let store = AgentAccessStore.shared
        let previousFullAccess = store.isEnabled
        store.setEnabled(false)
        defer { store.setEnabled(previousFullAccess) }
        store.revokeTaskGrant()
        func request(_ type: CommandType, _ payload: CommandPayload) -> CommandRequest { CommandRequest(type: type, payload: payload) }
        let inside = root.appendingPathComponent("a.pdf").path
        XCTAssertNotNil(store.denial(for: request(.readFile, .fileOperation(LocalFileOperationPayload(path: inside)))), "no grant, no agent")
        store.grant(minutes: 5, folders: [root.path], label: "deneme")
        defer { store.revokeTaskGrant() }
        XCTAssertTrue(store.isActive)
        XCTAssertNil(store.denial(for: request(.readFile, .fileOperation(LocalFileOperationPayload(path: inside)))))
        XCTAssertNil(store.denial(for: request(.moveFile, .fileOperation(LocalFileOperationPayload(path: inside, destination: root.appendingPathComponent("b.pdf").path)))))
        XCTAssertNotNil(store.denial(for: request(.readFile, .fileOperation(LocalFileOperationPayload(path: "/etc/hosts")))), "outside the folders")
        XCTAssertNotNil(store.denial(for: request(.moveFile, .fileOperation(LocalFileOperationPayload(path: inside, destination: "/tmp/x.pdf")))), "destination outside")
        XCTAssertNotNil(store.denial(for: request(.deleteFile, .fileOperation(LocalFileOperationPayload(path: inside)))), "never a delete")
        XCTAssertNotNil(store.denial(for: request(.controlApplication, .applicationControl(ApplicationControlPayload(action: .quit, target: "Safari")))), "no apps under a file grant")
        XCTAssertNil(store.denial(for: request(.searchFiles, .fileSearch(FileSearchPayload(query: "x", folder: root.path)))))
        XCTAssertNotNil(store.denial(for: request(.searchFiles, .fileSearch(FileSearchPayload(query: "x")))), "a search without a folder would reach Desktop, Documents and Downloads")
        store.revokeTaskGrant()
        XCTAssertFalse(store.isActive)
        XCTAssertNotNil(RovaValidation.validate(CommandRequest(type: .grantAgentAccess, payload: .agentGrant(AgentGrantPayload(minutes: 90, folders: [root.path], label: "x")))), "at most 30 minutes")
        XCTAssertNil(RovaValidation.validate(CommandRequest(type: .grantAgentAccess, payload: .agentGrant(AgentGrantPayload(minutes: 10, folders: ["~/Desktop"], label: "deneme")))))
    }

    func testAPlanThatCouldHideAnActionIsRefused() {
        func error(_ steps: [FilePlanStep]) -> String? { RovaValidation.filePlanError(FilePlanPayload(steps: steps)) }
        XCTAssertNotNil(error([]))
        XCTAssertNotNil(error([FilePlanStep(id: "s1", op: "delete", path: "~/Desktop/a.pdf")]), "no delete in a plan")
        XCTAssertNotNil(error([FilePlanStep(id: "s1", op: "convert", path: "$s2")]), "a binding must point at an earlier step")
        XCTAssertNotNil(error([FilePlanStep(id: "s1", op: "send", path: "$s1", transferId: UUID().uuidString)]), "a step cannot bind to itself")
        XCTAssertNotNil(error([FilePlanStep(id: "s1", op: "move", path: "~/Desktop/a.pdf", destination: "$s2")]), "only the path may be bound")
        XCTAssertNotNil(error([FilePlanStep(id: "s1", op: "read", path: "~/Desktop/a.txt"), FilePlanStep(id: "s2", op: "send", path: "$s1", transferId: UUID().uuidString)]), "read gives no file to bind")
        XCTAssertNotNil(error([FilePlanStep(id: "s1", op: "search", query: "fatura", kind: "pdf"), FilePlanStep(id: "s2", op: "send", path: "$s1")]), "a send needs its transfer id")
        XCTAssertNil(error([FilePlanStep(id: "s1", op: "search", query: "fatura", kind: "pdf"), FilePlanStep(id: "s2", op: "send", path: "$s1", transferId: UUID().uuidString)]))
    }

    func testAnAlternativeWordMatchesAndTheExpressionOrsTheGroups() throws {
        try make("kira_kontrat_2024.pdf")
        try make("fatura.pdf")
        let found = MacFileSearch.walk(spec("sözleşme", alternatives: ["kontrat", "anlaşma"]))
        XCTAssertEqual(names(found), ["kira_kontrat_2024.pdf"])
        let predicate = MacFileSearch.spotlightPredicate(spec("sözleşme", alternatives: ["kontrat"]))
        XCTAssertTrue(predicate.contains("*sözleşme*") && predicate.contains("*kontrat*") && predicate.contains("||"), predicate)
    }

    func testWordsAreCleanedSoTheyCannotChangeTheExpression() {
        XCTAssertEqual(MacFileSearch.tokens(from: #"fatura "*" (eylül) kMDItemFSName == x"#), ["fatura", "eylül", "kMDItemFSName", "x"])
        XCTAssertEqual(MacFileSearch.tokens(from: "  \"\" ** "), [])
        XCTAssertEqual(MacFileSearch.tokens(from: "a b c d e f g h i j").count, 8)
    }

    func testPredicateMatchesNamesLooselyAndCombinesFilters() {
        XCTAssertEqual(MacFileSearch.spotlightPredicate(spec("rapor")), #"kMDItemDisplayName == "*rapor*"cd"#)
        XCTAssertEqual(
            MacFileSearch.spotlightPredicate(spec("mart rapor", kind: "pdf")),
            #"kMDItemDisplayName == "*mart*"cd && kMDItemDisplayName == "*rapor*"cd && (kMDItemContentTypeTree == "com.adobe.pdf")"#
        )
        var content = spec("kira")
        content.content = true
        XCTAssertEqual(MacFileSearch.spotlightPredicate(content), #"(kMDItemDisplayName == "*kira*"cd || kMDItemTextContent == "*kira*"cd)"#)
        let dated = MacFileSearch.spotlightPredicate(spec(kind: "spreadsheet", days: 7))
        XCTAssertTrue(dated.contains("kMDItemFSContentChangeDate >= $time.iso("), dated)
        XCTAssertTrue(dated.contains("org.openxmlformats.spreadsheetml.sheet"), dated)
        XCTAssertTrue(MacFileSearch.spotlightPredicate(spec(days: 3)).contains(#"kMDItemContentType != "public.folder""#), "a date-only search is about files, not folders")
    }

    // MARK: Ranking

    func testTheNameThatIsTheQueryOutranksLongerNamesAndDeepPaths() throws {
        let exact = FileSystemEntry(path: "/u/Desktop/fatura.pdf", name: "fatura.pdf", byteCount: 1, modifiedAt: Date(timeIntervalSince1970: 100), isDirectory: false, fileType: "pdf")
        let longer = FileSystemEntry(path: "/u/Desktop/fatura-eylul-2026.pdf", name: "fatura-eylul-2026.pdf", byteCount: 1, modifiedAt: Date(timeIntervalSince1970: 900), isDirectory: false, fileType: "pdf")
        let buried = FileSystemEntry(path: "/u/Documents/a/b/c/d/fatura.pdf", name: "fatura.pdf", byteCount: 1, modifiedAt: Date(timeIntervalSince1970: 500), isDirectory: false, fileType: "pdf")
        let ranked = MacFileSearch.rank([longer, buried, exact], spec: spec("fatura"))
        XCTAssertEqual(ranked.map(\.path), [exact.path, buried.path, longer.path])
        let recent = MacFileSearch.rank([exact, longer, buried], spec: spec("fatura", recent: true))
        XCTAssertEqual(recent.first?.path, longer.path, "newest first when asked")
    }

    func testDiacriticsDoNotHideAMatch() {
        XCTAssertGreaterThan(MacFileSearch.score(name: "Rapör.docx", path: "/u/Desktop/Rapör.docx", tokens: ["rapor"]), 0)
        XCTAssertGreaterThan(MacFileSearch.score(name: "İşlem Özeti.pdf", path: "/u/Desktop/İşlem Özeti.pdf", tokens: ["islem", "ozeti"]), 2)
    }

    // MARK: Walking the folders (the fallback)

    func testWalkFindsByNameKindAndDateAndSkipsOtherProgramsFiles() throws {
        try make("rapor-mart.pdf", daysAgo: 2)
        try make("rapor-ocak.pdf", daysAgo: 60)
        try make("Alt/rapor.docx", daysAgo: 1)
        try make("notlar.txt", daysAgo: 0)
        try make("proje/node_modules/paket/rapor.pdf")
        try make("proje/DerivedData/x/rapor.pdf")
        try make(".gizli/rapor.pdf")

        XCTAssertEqual(Set(names(MacFileSearch.walk(spec("rapor")))), ["rapor-mart.pdf", "rapor-ocak.pdf", "rapor.docx"])
        XCTAssertEqual(Set(names(MacFileSearch.walk(spec("rapor", kind: "pdf")))), ["rapor-mart.pdf", "rapor-ocak.pdf"])
        XCTAssertEqual(Set(names(MacFileSearch.walk(spec("rapor", days: 7)))), ["rapor-mart.pdf", "rapor.docx"])
        XCTAssertEqual(Set(names(MacFileSearch.walk(spec(kind: "text", days: 1)))), ["notlar.txt"])
        XCTAssertEqual(names(MacFileSearch.walk(spec("mart ra"))), ["rapor-mart.pdf"], "every word must be in the name")
    }

    func testKeyMaterialStaysOutOfEverySearch() throws {
        try make("anahtar/id_rsa")
        try make("banka parola.txt")
        try make("kubernetes.pem")
        try make("rapor.pdf")
        XCTAssertEqual(names(MacFileSearch.walk(spec("", kind: "pdf"))), ["rapor.pdf"])
        XCTAssertTrue(names(MacFileSearch.walk(spec("id_rsa"))).isEmpty)
        XCTAssertTrue(names(MacFileSearch.walk(spec("parola"))).isEmpty)
        XCTAssertTrue(names(MacFileSearch.walk(spec("parola"))).isEmpty)
    }

    func testCredentialFilesAreBlockedAtDirectReadAndTransferBoundaries() async throws {
        let key = try make("AuthKey_TEST123.p8", bytes: 64)
        let read = MacSystem.readFile(LocalFileOperationPayload(path: key.path))
        XCTAssertEqual(read.error?.code, "SENSITIVE_FILE_BLOCKED")
        XCTAssertEqual(MacSystem.readDesktopFile("AuthKey_TEST123.p8").error?.code, "SENSITIVE_FILE_BLOCKED")
        XCTAssertEqual(MacSystem.readDocument("AuthKey_TEST123.p8").error?.code, "SENSITIVE_FILE_BLOCKED")
        let transfer = await MacSystem.sendFileToPhone(LocalFileOperationPayload(path: key.path), commandID: UUID(), accessToken: "test")
        XCTAssertEqual(transfer.error?.code, "SENSITIVE_FILE_BLOCKED")
    }

    // MARK: The whole request

    func testTheRequestReportsWhereItLookedAndHowToContinue() async throws {
        let outcome = await MacFileSearch.search(FileSearchPayload(query: "zzz-hicbir-dosya-\(UUID().uuidString.prefix(8))", folder: root.path))
        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.message.contains("bulunamadı"), outcome.message)
        let missing = await MacFileSearch.search(FileSearchPayload(query: "x", folder: root.appendingPathComponent("yok").path))
        XCTAssertEqual(missing.error?.code, "FILE_NOT_FOUND")
        let stale = await MacFileSearch.search(FileSearchPayload(query: "x", cursor: UUID().uuidString))
        XCTAssertEqual(stale.error?.code, "INVALID_CURSOR")
    }
}
