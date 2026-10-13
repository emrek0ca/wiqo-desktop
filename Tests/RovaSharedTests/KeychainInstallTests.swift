import XCTest
import Security

final class KeychainInstallTests: XCTestCase {
    func testItemsFromBeforeTheInstallationAreRemovedAndNewerOnesKept() throws {
        try requireMacDataProtectionKeychainWhenNeeded()
        let account = "test.install.\(UUID().uuidString)"
        try RovaKeychainStore.save(Data("secret".utf8), account: account)
        defer { try? RovaKeychainStore.delete(account: account) }

        RovaKeychainStore.deleteItems(createdBefore: Date().addingTimeInterval(-3_600))
        XCTAssertNotNil(try RovaKeychainStore.load(account: account), "an item newer than the installation stays")

        RovaKeychainStore.deleteItems(createdBefore: Date().addingTimeInterval(60))
        XCTAssertNil(try RovaKeychainStore.load(account: account), "an item older than the installation is gone")
    }

    #if os(macOS)
    func testLegacyMacKeychainItemMigratesToDataProtectionKeychain() throws {
        try requireMacDataProtectionKeychainWhenNeeded()
        let account = "test.legacy-migration.\(UUID().uuidString)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.rova.local",
            kSecAttrAccount: account,
            kSecValueData: Data("legacy-secret".utf8)
        ]
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
        defer {
            try? RovaKeychainStore.delete(account: account)
        }

        XCTAssertEqual(try RovaKeychainStore.load(account: account), Data("legacy-secret".utf8))

        var protectedQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.rova.local",
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var protectedResult: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(protectedQuery as CFDictionary, &protectedResult), errSecSuccess)
        XCTAssertEqual(protectedResult as? Data, Data("legacy-secret".utf8))

        protectedQuery.removeValue(forKey: kSecUseDataProtectionKeychain)
        var legacyResult: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(protectedQuery as CFDictionary, &legacyResult), errSecItemNotFound)
    }

    #endif

    private func requireMacDataProtectionKeychainWhenNeeded() throws {
        #if os(macOS)
        let account = "test.dpk-entitlement.\(UUID().uuidString)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.rova.local",
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
            kSecValueData: Data("probe".utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            throw XCTSkip("Unsigned macOS test runners lack the app access-group entitlement required by the Data Protection Keychain.")
        }
        XCTAssertEqual(status, errSecSuccess)
        _ = SecItemDelete(query as CFDictionary)
        #endif
    }
}
