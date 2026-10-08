import XCTest

final class OwnFoldersTests: XCTestCase {
    private func file(_ path: String) -> CommandPayload { .fileOperation(LocalFileOperationPayload(path: path)) }

    func testDesktopDocumentsAndDownloadsAreRecognisedOnBothPlatforms() {
        for path in ["~/Desktop/rapor.pdf", "~/Downloads", "~/Documents/Eski/fatura.pdf", "/Users/ada/Downloads/x.pdf", "C:\\Users\\ada\\Documents\\x.docx", "d:/Users/ada/Desktop"] {
            XCTAssertTrue(RovaOwnFolders.isOwnFolder(path), path)
        }
        for path in ["~/Library/Mail", "~/Pictures/a.jpg", "/etc/hosts", "/Users/ada", "~/.ssh/config", "~", "/Volumes/Yedek/x.pdf", "~/Desktopx/a", "relative/Desktop/a"] {
            XCTAssertFalse(RovaOwnFolders.isOwnFolder(path), path)
        }
    }

    func testKeyMaterialAndCredentialNamesAreSensitive() {
        for path in ["~/Documents/id_rsa", "~/Desktop/anahtar.pem", "~/Downloads/vault.kdbx", "~/Documents/.env", "~/Documents/.env.production",
                     "~/Documents/parola listesi.txt", "~/Desktop/banka sifre.docx", "~/Downloads/passwords.csv", "~/Documents/.ssh/config", "~/Documents/aws credentials.txt"] {
            XCTAssertTrue(RovaOwnFolders.isSensitive(path), path)
        }
        for path in ["~/Documents/rapor.docx", "~/Desktop/fatura-eylul.pdf", "~/Downloads/sunum.key.pdf.bak", "~/Documents/environment.md"] {
            XCTAssertFalse(RovaOwnFolders.isSensitive(path), path)
        }
    }

    func testOwnFolderReadsSkipApprovalOnlyWhenThePersonSwitchedItOn() {
        let list = file("~/Downloads")
        XCTAssertTrue(RovaCommandAuthority.requiresUserPresence(type: .listFiles, payload: list), "off by default")
        XCTAssertFalse(RovaCommandAuthority.requiresUserPresence(type: .listFiles, payload: list, autoReadOwnFolders: true))
        XCTAssertFalse(RovaCommandAuthority.requiresUserPresence(type: .readFile, payload: file("~/Documents/notlar.txt"), autoReadOwnFolders: true))
        XCTAssertFalse(RovaCommandAuthority.requiresUserPresence(type: .readDocument, payload: .fileName("rapor.pdf"), autoReadOwnFolders: true))
    }

    func testEverythingOutsideTheOwnFoldersAndEveryWriteStillAsks() {
        let asks: [(CommandType, CommandPayload)] = [
            (.listFiles, file("~/Library/Mail")),
            (.readFile, file("/etc/hosts")),
            (.readFile, file("~/Documents/id_rsa")),
            (.readDocument, .fileName("banka parola.docx")),
            (.sendFileToPhone, file("~/Desktop/CV.docx")),
            (.writeFile, file("~/Desktop/a.txt")),
            (.moveFile, .fileOperation(LocalFileOperationPayload(path: "~/Desktop/a.txt", destination: "~/Documents/a.txt"))),
            (.deleteFile, file("~/Desktop/a.txt")),
            (.searchFiles, .fileSearch(FileSearchPayload(query: "fatura", everywhere: true))),
            (.searchFiles, .fileSearch(FileSearchPayload(query: "fatura", folder: "~/Library")))
        ]
        for (type, payload) in asks {
            XCTAssertTrue(RovaCommandAuthority.requiresUserPresence(type: type, payload: payload, autoReadOwnFolders: true), "\(type)")
        }
    }

    func testSearchInTheOwnFoldersIsAutomatic() {
        for search in [FileSearchPayload(query: "fatura"), FileSearchPayload(query: "", kind: "pdf", modifiedWithinDays: 7), FileSearchPayload(query: "kira", folder: "~/Documents", content: true)] {
            XCTAssertFalse(RovaCommandAuthority.requiresUserPresence(type: .searchFiles, payload: .fileSearch(search), autoReadOwnFolders: true))
        }
    }

    func testUnattendedAutomationsNeverInheritTheSwitch() {
        for (type, payload) in [(CommandType.listFiles, file("~/Downloads")), (.readFile, file("~/Documents/a.txt")), (.searchFiles, .fileSearch(FileSearchPayload(query: "x")))] {
            XCTAssertFalse(RovaCommandAuthority.permitsUnattended(type: type, payload: payload), "\(type)")
        }
    }

    func testSearchPayloadValidationAndWireCompatibility() {
        func validate(_ search: FileSearchPayload) -> RovaError? {
            RovaValidation.validate(CommandRequest(type: .searchFiles, payload: .fileSearch(search)))
        }
        XCTAssertNil(validate(FileSearchPayload(query: "fatura")))
        XCTAssertNil(validate(FileSearchPayload(query: "", kind: "pdf", modifiedWithinDays: 7)))
        XCTAssertNil(validate(FileSearchPayload(query: "x", cursor: "o:24")))
        XCTAssertNotNil(validate(FileSearchPayload(query: "")), "nothing to search for")
        XCTAssertNotNil(validate(FileSearchPayload(query: "x", kind: "exe")))
        XCTAssertNotNil(validate(FileSearchPayload(query: "x", modifiedWithinDays: 0)))
        XCTAssertNotNil(validate(FileSearchPayload(query: "x", folder: "../etc")))
        XCTAssertNotNil(validate(FileSearchPayload(query: "x", cursor: "o:abc")))

        // A request that sets only the query encodes exactly as before, so old signatures still verify.
        let encoded = try? JSONEncoder().encode(FileSearchPayload(query: "notlar"))
        XCTAssertEqual(encoded.flatMap { String(data: $0, encoding: .utf8) }, #"{"query":"notlar"}"#)
    }

    func testOneTaskApprovalCoversReversibleFileWorkInTheOwnFoldersOnly() {
        func move(_ from: String, _ to: String, overwrite: Bool = false) -> CommandPayload { .fileOperation(LocalFileOperationPayload(path: from, destination: to, overwrite: overwrite)) }
        func utility(_ action: FileUtilityAction, path: String? = nil, paths: [String]? = nil, destination: String? = nil, name: String? = nil) -> CommandPayload {
            .fileUtility(FileUtilityPayload(action: action, path: path, paths: paths, destination: destination, name: name))
        }
        let covered: [(CommandType, CommandPayload)] = [
            (.moveFile, move("~/Downloads/a.pdf", "~/Documents/Faturalar/a.pdf")),
            (.copyFile, move("~/Desktop/a.docx", "~/Documents/a.docx")),
            (.convertFile, .fileOperation(LocalFileOperationPayload(path: "~/Desktop/CV.docx"))),
            (.renameDesktopFile, .fileMove(DesktopFileMovePayload(source: "a.pdf", destination: "b.pdf"))),
            (.fileUtility, utility(.createFolder, path: "~/Desktop/Raporlar")),
            (.fileUtility, utility(.organize, path: "~/Downloads")),
            (.fileUtility, utility(.mergePDF, paths: ["~/Downloads/a.pdf", "~/Downloads/b.pdf"], destination: "~/Downloads/Birleşik.pdf")),
            (.fileUtility, utility(.restoreFromTrash, name: "eski fatura"))
        ]
        for (type, payload) in covered { XCTAssertTrue(RovaOwnFolders.isTaskWritable(type: type, payload: payload), "\(type)") }
        let asks: [(CommandType, CommandPayload)] = [
            (.deleteFile, file("~/Desktop/a.pdf")),
            (.writeFile, file("~/Desktop/a.txt")),
            (.sendFileToPhone, file("~/Desktop/a.pdf")),
            (.moveFile, move("~/Downloads/a.pdf", "~/Documents/a.pdf", overwrite: true)),
            (.moveFile, move("~/Library/Mail/x", "~/Desktop/x")),
            (.moveFile, move("~/Desktop/a.pdf", "/etc/a.pdf")),
            (.copyFile, move("~/Documents/id_rsa", "~/Desktop/id_rsa")),
            (.fileUtility, utility(.print, path: "~/Desktop/a.pdf")),
            (.fileUtility, utility(.createFolder, path: "~/Library/Raporlar")),
            (.fileUtility, utility(.archive, path: "~/Documents/parola listesi.txt")),
            (.executeCode, .none),
            (.controlApplication, .none)
        ]
        for (type, payload) in asks { XCTAssertFalse(RovaOwnFolders.isTaskWritable(type: type, payload: payload), "\(type)") }
    }
}
