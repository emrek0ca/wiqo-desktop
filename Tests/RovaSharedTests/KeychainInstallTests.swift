import XCTest

final class KeychainInstallTests: XCTestCase {
    func testItemsFromBeforeTheInstallationAreRemovedAndNewerOnesKept() throws {
        let account = "test.install.\(UUID().uuidString)"
        try RovaKeychainStore.save(Data("secret".utf8), account: account)
        defer { try? RovaKeychainStore.delete(account: account) }

        RovaKeychainStore.deleteItems(createdBefore: Date().addingTimeInterval(-3_600))
        XCTAssertNotNil(try RovaKeychainStore.load(account: account), "an item newer than the installation stays")

        RovaKeychainStore.deleteItems(createdBefore: Date().addingTimeInterval(60))
        XCTAssertNil(try RovaKeychainStore.load(account: account), "an item older than the installation is gone")
    }
}
