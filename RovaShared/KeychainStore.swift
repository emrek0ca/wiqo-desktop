import Foundation
import Security

public enum RovaKeychainStore {
    private static let service = "com.rova.local"

    public static func saveDevicePairingToken(_ token: String, deviceID: String) throws {
        guard UUID(uuidString: deviceID) != nil, !token.isEmpty else { throw RovaKeychainError.invalidPairingToken }
        try save(Data(token.utf8), account: "ios-device-token:\(deviceID.lowercased())")
    }

    public static func loadDevicePairingToken(deviceID: String) throws -> String? {
        guard UUID(uuidString: deviceID) != nil else { return nil }
        return try load(account: "ios-device-token:\(deviceID.lowercased())")
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func deleteDevicePairingToken(deviceID: String) throws {
        guard UUID(uuidString: deviceID) != nil else { return }
        try delete(account: "ios-device-token:\(deviceID.lowercased())")
    }

    public static func save(_ data: Data, account: String) throws {
        var query = itemQuery(account: account)
        query[kSecValueData] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw RovaKeychainError.status(status)
        }
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(itemQuery(account: account) as CFDictionary, [kSecValueData: data] as CFDictionary)
            guard updateStatus == errSecSuccess else { throw RovaKeychainError.status(updateStatus) }
        }
        #if os(macOS)
        // New data lives in the app-scoped Data Protection Keychain. Remove a stale file-based
        // copy if one remains from an earlier Wiqo version.
        removeLegacyItem(account: account)
        #endif
    }

    public static func load(account: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(itemQuery(account: account, returningData: true) as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return data }
        guard status == errSecItemNotFound else { throw RovaKeychainError.status(status) }

        #if os(macOS)
        // Migrate old file-based items on first use. macOS may show one final legacy access
        // prompt here; all subsequent reads use the signed app access group and avoid ACL prompts.
        var legacyResult: CFTypeRef?
        let legacyStatus = SecItemCopyMatching(legacyItemQuery(account: account, returningData: true) as CFDictionary, &legacyResult)
        if legacyStatus == errSecItemNotFound { return nil }
        guard legacyStatus == errSecSuccess, let legacyData = legacyResult as? Data else {
            throw RovaKeychainError.status(legacyStatus)
        }
        try saveProtected(legacyData, account: account)
        removeLegacyItem(account: account)
        return legacyData
        #else
        return nil
        #endif
    }

    /// Removes every item of this app that was written before `date`. The Keychain outlives an uninstall; items older than the current installation are the previous one's.
    @discardableResult
    public static func deleteItems(createdBefore date: Date) -> Int {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain] = true
        #endif
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[CFString: Any]] else { return 0 }
        var removed = 0
        for item in items {
            guard let account = item[kSecAttrAccount] as? String,
                  let created = item[kSecAttrCreationDate] as? Date, created < date else { continue }
            if (try? delete(account: account)) != nil { removed += 1 }
        }
        return removed
    }

    public static func delete(account: String) throws {
        let status = SecItemDelete(itemQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RovaKeychainError.status(status) }
        #if os(macOS)
        let legacyStatus = SecItemDelete(legacyItemQuery(account: account) as CFDictionary)
        guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
            throw RovaKeychainError.status(legacyStatus)
        }
        #endif
    }

    private static func itemQuery(account: String, returningData: Bool = false) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain] = true
        #endif
        if returningData {
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
        }
        return query
    }

    #if os(macOS)
    private static func legacyItemQuery(account: String, returningData: Bool = false) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        if returningData {
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
        }
        return query
    }

    private static func saveProtected(_ data: Data, account: String) throws {
        var query = itemQuery(account: account)
        query[kSecValueData] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else { throw RovaKeychainError.status(status) }
        let updateStatus = SecItemUpdate(itemQuery(account: account) as CFDictionary, [kSecValueData: data] as CFDictionary)
        guard updateStatus == errSecSuccess else { throw RovaKeychainError.status(updateStatus) }
    }

    private static func removeLegacyItem(account: String) {
        _ = SecItemDelete(legacyItemQuery(account: account) as CFDictionary)
    }
    #endif
}

public enum RovaKeychainError: Error, Equatable {
    case status(OSStatus)
    case invalidPairingToken
}
