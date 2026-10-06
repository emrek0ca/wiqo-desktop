import XCTest

/// The device-side package pipeline and the source ZIP: archives are read only after their SHA-512 matches, a package is
/// cached under id + version + integrity, a page gets the verified code and never a CDN, and what is missing is refused.
final class ActPackagesTests: XCTestCase {
    /// A tiny npm-style tarball holding package/dist/chart.umd.js.
    private static let tgzBase64 = "H4sIAGq2xGoAA+2YTW/TMBjHs0kIUc5w4vBIO6TrutTOi9NqFKlMkzZpCNim8SaYTOo0oS/JEq/LhPgYSNw5IK58N+44Wcto2VYqNQVR/yTHseOXx4n+9l/RjkLqtGmLKfmBELItC7KcnOeCYY6QbhqALZ1gbBgiB4QNyyAKoBxj+slJzGkkQmHdiLUDh17V7tRjrHPNOKOLgtkHmhM37t5UlhXlEXXg8T48hwFpnXJLJF2kY5HS8uc/G7JxcLA3uE17fBLp9liTpYv6O07Q1WgYdpgWRkGf9WjPYcrSsvL945uvwbcv92awSMlVPKHJNqNNFlXy2wcm6h+jMf2LgqlAkkMsv7Hg+jcQdLnfZXVs17BuE2Ihjdg6sqq6SQqWDbs7Dxt7m9s7h1taQjmPtMvkWm883WnUXh6y42drZ2FyWjBrsC867b64rtMvGi/87fewqAxUX8lzjkn6Twtj579hC/1beQY1ZMH1P/z+2lHTj3k+c0zv/0wLYen/5oL0fwvNUP8XPnD2+8D0/o/oui393zy43P8ZVhXbVen//n+G+k9Vn5cJnN7/mcIASv83D0a+v3bkeDTi2km3qb2LZzaHeB/ENKfxf8S25f+/+SD930Izov8LEzjTfWCi/sf9n44sXf7/mwuX+z9CSI3gqvR//z0j+s/l9J+sf0u3x89/i8jzfy5USuDSNoPs04MbRMA9BiwJA1GMWcdd5yzmUKoU3JOew/2gB5tp06LDkzI4bmv1PfRpBA7UQVRpLcY3gx5nCS+qelNd3cieNtOnbktrUk6zS8x4/Aq9zu7Pm3iDATzmtzy+AY7m+p3OPj/rMPFEXdEtYrC36gY0NRHlFnW84jCiYr/sizDOe+wxhxfFgbIGfomgshh3HfolowymKIgbEdGH1ZHh6+oKxljN6kTodRWbYQIx7cXrMYt8Vx22PshWlS0fgjbcr8RO5If8gWjrMrUMWMyASTqB3M4kEsm/zw9lEn5BACQAAA=="
    private static let tgzIntegrity = "sha512-jmmOp/v4keeITRT9wdm2XQJHYDz/5lBfUyhCSG++KuCaL3IUHD1CSUciR2hpXeblETUADYfBg+Hy/YpqtkQoiQ=="
    private static let entry = "package/dist/chart.umd.js"
    private var tgz: Data { Data(base64Encoded: Self.tgzBase64)! }

    private static func package(integrity: String = ActPackagesTests.tgzIntegrity) -> ActWebPackage {
        ActWebPackage(id: "chartjs", version: "4.5.0", path: "act-vendor/chartjs-4.5.0.js", global: "Chart", archiveEntry: Self.entry,
                      archiveUrl: "https://registry.npmjs.org/chart.js/-/chart.js-4.5.0.tgz", integrity: integrity)
    }
    private static func catalog(_ integrity: String = ActPackagesTests.tgzIntegrity) -> ActPackageCatalog { ActPackageCatalog(version: 1, web: [package(integrity: integrity)], python: []) }
    private let page = "<html><body><canvas id=c></canvas><script src=\"act-vendor/chartjs-4.5.0.js\"></script><script>new Chart(1)</script></body></html>"

    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("act-packages-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Archive

    func testIntegrityMatchesTheKnownSha512OfAbc() {
        XCTAssertEqual(ActArchive.sri512(Data("abc".utf8)), "sha512-3a81oZNherrMQXNJriBBMRLm+k6JqX6iCp7u5ktV05ohkpkqJ0/BqDa6PCOj/uu9RU1EI2Q86A4qmslPpUyknw==")
        XCTAssertTrue(ActArchive.matches(Data("abc".utf8), integrity: "sha512-3a81oZNherrMQXNJriBBMRLm+k6JqX6iCp7u5ktV05ohkpkqJ0/BqDa6PCOj/uu9RU1EI2Q86A4qmslPpUyknw=="))
        XCTAssertFalse(ActArchive.matches(Data("abd".utf8), integrity: "sha512-3a81oZNherrMQXNJriBBMRLm+k6JqX6iCp7u5ktV05ohkpkqJ0/BqDa6PCOj/uu9RU1EI2Q86A4qmslPpUyknw=="))
        XCTAssertFalse(ActArchive.matches(Data("abc".utf8), integrity: "sha256-xyz"))
    }

    func testTheWantedEntryIsReadFromTheTarball() throws {
        XCTAssertTrue(ActArchive.matches(tgz, integrity: Self.tgzIntegrity))
        let tar = try ActArchive.gunzip(tgz)
        let code = try XCTUnwrap(ActArchive.tarEntry(tar, named: Self.entry))
        XCTAssertTrue(String(decoding: code, as: UTF8.self).contains("function Chart"))
        XCTAssertNil(ActArchive.tarEntry(tar, named: "package/dist/missing.js"))
    }

    func testCorruptOrForeignDataIsRefused() {
        var broken = tgz
        broken[broken.count / 2] ^= 0xff
        XCTAssertThrowsError(try ActArchive.gunzip(broken))
        XCTAssertThrowsError(try ActArchive.gunzip(Data("not a gzip".utf8)))
        XCTAssertFalse(ActArchive.matches(broken, integrity: Self.tgzIntegrity))
    }

    func testArchivePathsAreMadeSafe() {
        XCTAssertEqual(ActArchive.normalizedPath("a/b.js"), "a/b.js")
        XCTAssertEqual(ActArchive.normalizedPath("/a//b.js"), "a/b.js")
        XCTAssertEqual(ActArchive.normalizedPath("./a.js"), "a.js")
        for unsafe in ["../a", "a/../b", ".git/x", "a\\b", "", "a/.env"] { XCTAssertNil(ActArchive.normalizedPath(unsafe), unsafe) }
    }

    func testSourceZipHasTheProjectFilesOnly() throws {
        let zip = ActArchive.zip([("index.html", Data("<h1>Merhaba ğüşiöç</h1>".utf8)), ("js/app.js", Data("let a = 1".utf8)), ("../evil.txt", Data("x".utf8)),
                                  (".wiqo-sync.json", Data("{}".utf8)), ("index.html", Data("duplicate".utf8)), ("data.csv", Data(repeating: 65, count: 5000))])
        let bytes = [UInt8](zip)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24 }
        let end = bytes.count - 22
        XCTAssertEqual(u32(end), 0x06054b50)
        XCTAssertEqual(u16(end + 10), 3)
        var offset = Int(u32(end + 16))
        var names: [String] = []
        for _ in 0..<3 {
            XCTAssertEqual(u32(offset), 0x02014b50)
            let crc = u32(offset + 16), size = Int(u32(offset + 24)), nameLength = u16(offset + 28)
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            let local = Int(u32(offset + 42))
            XCTAssertEqual(u32(local), 0x04034b50)
            let dataStart = local + 30 + u16(local + 26) + u16(local + 28)
            XCTAssertEqual(ActArchive.crc32(Data(bytes[dataStart..<(dataStart + size)])), crc, name)
            names.append(name)
            offset += 46 + nameLength + u16(offset + 30) + u16(offset + 32)
        }
        XCTAssertEqual(names, ["index.html", "js/app.js", "data.csv"])
    }

    // MARK: Packages

    func testAPageIsGivenTheVerifiedCodeAndNoCdn() async throws {
        let packages = ActPackages(directory: temporaryFolder(), downloader: { [tgz] _ in tgz })
        XCTAssertEqual(ActPackages.referencedPaths(in: page), ["act-vendor/chartjs-4.5.0.js"])
        XCTAssertEqual(packages.inlineCached(page).missing, ["act-vendor/chartjs-4.5.0.js"])
        try await packages.prepare(page) { Self.catalog() }
        let ready = packages.inlineCached(page)
        XCTAssertTrue(ready.missing.isEmpty)
        XCTAssertTrue(ready.html.contains("data-act-package=\"chartjs@4.5.0\""))
        XCTAssertFalse(ready.html.contains("src=\"act-vendor"))
        XCTAssertFalse(ready.html.contains("http"), "no network source may be left in the page")
        XCTAssertEqual(ready.html.components(separatedBy: "</script").count - 1, 2, "code inside the package must not close the tag early")
    }

    func testAWrongIntegrityIsRefusedAndNothingIsCached() async {
        let packages = ActPackages(directory: temporaryFolder(), downloader: { [tgz] _ in tgz })
        do { try await packages.prepare(page) { Self.catalog("sha512-AAAA") }; XCTFail("accepted") } catch let error as ActPackageError {
            XCTAssertTrue(error.errorDescription?.contains(ActPackageError.code) == true)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(packages.inlineCached(page).missing.count, 1)
    }

    func testAPackageIsDownloadedOnceAndWorksOfflineAfterARestart() async throws {
        let folder = temporaryFolder()
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let packages = ActPackages(directory: folder, downloader: { [tgz] _ in counter.value += 1; return tgz })
        try await packages.prepare(page) { Self.catalog() }
        try await packages.prepare(page) { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(counter.value, 1)
        let restarted = ActPackages(directory: folder, downloader: { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertTrue(restarted.inlineCached(page).missing.isEmpty)
    }

    func testATamperedCacheIsNotUsed() async throws {
        let folder = temporaryFolder()
        let packages = ActPackages(directory: folder, downloader: { [tgz] _ in tgz })
        try await packages.prepare(page) { Self.catalog() }
        let cached = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension == "js" })
        try Data("evil()".utf8).write(to: cached)
        let offline = ActPackages(directory: folder, downloader: { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(offline.inlineCached(page).missing.count, 1)
        do { try await offline.prepare(page) { throw URLError(.notConnectedToInternet) }; XCTFail("used a tampered file") } catch is ActPackageError {}
    }

    func testAPackageOutsideTheCatalogIsRefused() async {
        let packages = ActPackages(directory: temporaryFolder(), downloader: { [tgz] _ in tgz })
        do { try await packages.prepare("<script src=\"act-vendor/evil.js\"></script>") { Self.catalog() }; XCTFail("accepted") } catch is ActPackageError {} catch { XCTFail("\(error)") }
    }
}
