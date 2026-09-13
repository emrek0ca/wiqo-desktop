import CryptoKit
import Foundation
import Security

public enum RovaCrypto {
    public static func randomBytes(count: Int) throws -> Data {
        var data = Data(repeating: 0, count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw RovaCryptoError.randomFailure }
        return data
    }

    public static func randomToken() throws -> String {
        try randomBytes(count: 32).base64URLEncodedString()
    }

    public static func randomPairingCode() throws -> String {
        let maxLimit = UInt32.max - (UInt32.max % 1_000_000)
        while true {
            let data = try randomBytes(count: 4)
            let rawValue = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if rawValue < maxLimit {
                let value = rawValue % 1_000_000
                return String(format: "%06u", value)
            }
        }
    }

    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hmacSHA256Hex(key: String, message: String) -> String {
        let symmetricKey = SymmetricKey(data: Data(key.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symmetricKey)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum RovaCryptoError: Error, Equatable {
    case randomFailure
}
