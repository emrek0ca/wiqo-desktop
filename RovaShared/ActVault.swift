import CryptoKit
import Foundation

/// The key that makes Act projects private to the person's own devices.
///
/// One random 256-bit key per person. It is made on the first device (the iPhone), kept in that
/// device's Keychain and handed to the others over the local, authenticated connection or typed in as
/// a recovery code. It never goes to the server: the sync hub only ever sees ciphertext, opaque path
/// tokens and content hashes (see backend codeprojects/sealed.ts).
///
/// Three keys are derived from it so one never doubles for another: one seals contents, one makes path
/// tokens, one makes content hashes (the hub uses those to tell "same file changed twice" from "same
/// change twice" without reading anything).
public struct ActKeys: Sendable {
    private let content: SymmetricKey
    private let path: SymmetricKey
    private let hash: SymmetricKey
    public let master: Data

    public init?(master: Data) {
        guard master.count == 32 else { return nil }
        self.master = master
        let root = SymmetricKey(data: master)
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: root, salt: Data("wiqo.act.v1".utf8), info: Data(info.utf8), outputByteCount: 32)
        }
        content = derive("content")
        path = derive("path")
        hash = derive("hash")
    }

    public static func generate() -> ActKeys {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "No secure randomness available")
        return ActKeys(master: Data(bytes))!
    }

    // MARK: Sealing

    /// AES-256-GCM; the result is base64 of nonce + ciphertext + tag, safe to send as text.
    public func seal(_ plaintext: Data) throws -> String {
        let box = try AES.GCM.seal(plaintext, using: content)
        guard let combined = box.combined else { throw ActVaultError.sealFailed }
        return combined.base64EncodedString()
    }

    /// nil when the blob is not ours (wrong key) or was changed.
    public func open(_ blob: String) -> Data? {
        guard let combined = Data(base64Encoded: blob), let box = try? AES.GCM.SealedBox(combined: combined) else { return nil }
        return try? AES.GCM.open(box, using: content)
    }

    public func seal<T: Encodable>(_ value: T) throws -> String { try seal(JSONEncoder().encode(value)) }

    public func open<T: Decodable>(_ blob: String, as type: T.Type) -> T? {
        open(blob).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    // MARK: Tokens the hub can compare without reading

    public func pathToken(_ path: String) -> String { Self.hex(HMAC<SHA256>.authenticationCode(for: Data(path.utf8), using: self.path)) }
    public func contentHash(_ path: String, _ content: String) -> String {
        Self.hex(HMAC<SHA256>.authenticationCode(for: Data((path + "\u{0}" + content).utf8), using: hash))
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }

    // MARK: Recovery code

    /// 55 characters in groups of five, with a checksum: what the person writes down, or types on a Mac.
    public var recoveryCode: String {
        let check = Data(SHA256.hash(data: master).prefix(2))
        let text = ActBase32.encode(master + check)
        return stride(from: 0, to: text.count, by: 5).map { index in
            let start = text.index(text.startIndex, offsetBy: index)
            return String(text[start..<text.index(start, offsetBy: min(5, text.count - index))])
        }.joined(separator: "-")
    }

    public static func fromRecoveryCode(_ code: String) -> ActKeys? {
        let cleaned = code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard let bytes = ActBase32.decode(cleaned), bytes.count == 34 else { return nil }
        let master = bytes.prefix(32)
        guard Data(SHA256.hash(data: master).prefix(2)) == bytes.suffix(2) else { return nil }
        return ActKeys(master: Data(master))
    }
}

public enum ActVaultError: Error { case sealFailed }

/// RFC 4648 base32 without padding (letters and 2-7: easy to read out and to type).
enum ActBase32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func encode(_ data: Data) -> String {
        var output = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { output.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return output
    }

    static func decode(_ text: String) -> Data? {
        var out = Data()
        var buffer = 0
        var bits = 0
        for character in text {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return out
    }
}

/// Where a device keeps the key.
public enum ActKeyStore {
    public static func account(flavor: String = "") -> String { "act-vault-key" + flavor }

    public static func load(flavor: String = "") -> ActKeys? {
        guard let data = try? RovaKeychainStore.load(account: account(flavor: flavor)) else { return nil }
        return ActKeys(master: data)
    }

    public static func save(_ keys: ActKeys, flavor: String = "") throws {
        try RovaKeychainStore.save(keys.master, account: account(flavor: flavor))
    }

    /// The first device makes the key; the others receive it.
    public static func loadOrCreate(flavor: String = "") -> ActKeys {
        if let existing = load(flavor: flavor) { return existing }
        let fresh = ActKeys.generate()
        try? save(fresh, flavor: flavor)
        return fresh
    }
}

// MARK: - What is sealed

/// One file as it is sealed: the path travels inside, so the hub never learns file names.
public struct ActFileEnvelope: Codable, Sendable {
    public let path: String
    public let content: String?
    public init(path: String, content: String?) { self.path = path; self.content = content }
}

/// A project's own details, sealed as the hub's `meta`.
public struct ActProjectMeta: Codable, Sendable, Equatable {
    public var name: String
    /// "web" or "python"
    public var kind: String
    public init(name: String, kind: String) { self.name = name; self.kind = kind }
}
