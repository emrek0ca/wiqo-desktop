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

    private func spec(_ query: String = "", kind: String? = nil, days: Int? = nil, recent: Bool = false, hidesSensitive: Bool = true) -> MacFileSearch.Spec {
        MacFileSearch.Spec(
            tokens: MacFileSearch.tokens(from: query),
            roots: [root],
            kind: kind,
            since: days.map { Date().addingTimeInterval(-Double($0) * 86_400) },
            content: false,
            recent: recent,
            hidesSensitive: hidesSensitive
        )
    }

    private func names(_ entries: [FileSystemEntry]) -> [String] { entries.map(\.name) }

    // MARK: The Spotlight expression

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

    func testKeyMaterialStaysOutOfAutomaticSearchesButNotOutOfAnApprovedOne() throws {
        try make("anahtar/id_rsa")
        try make("banka parola.txt")
        try make("kubernetes.pem")
        try make("rapor.pdf")
        XCTAssertEqual(names(MacFileSearch.walk(spec("", kind: "pdf"))), ["rapor.pdf"])
        XCTAssertTrue(names(MacFileSearch.walk(spec("id_rsa"))).isEmpty)
        XCTAssertTrue(names(MacFileSearch.walk(spec("parola"))).isEmpty)
        XCTAssertEqual(names(MacFileSearch.walk(spec("parola", hidesSensitive: false))), ["banka parola.txt"])
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
