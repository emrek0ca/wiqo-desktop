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
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let lookup: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account
            ]
            let updateStatus = SecItemUpdate(lookup as CFDictionary, [kSecValueData: data] as CFDictionary)
            guard updateStatus == errSecSuccess else { throw RovaKeychainError.status(updateStatus) }
        } else if status != errSecSuccess {
            throw RovaKeychainError.status(status)
        }
    }

    public static func load(account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RovaKeychainError.status(status)
        }
        return data
    }

    public static func delete(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RovaKeychainError.status(status)
        }
    }
}

public enum RovaKeychainError: Error, Equatable {
    case status(OSStatus)
    case invalidPairingToken
}
