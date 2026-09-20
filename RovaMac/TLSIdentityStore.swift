import CryptoKit
import Foundation
import Security

struct RovaTLSIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let certificateFingerprint: String
}

enum RovaTLSIdentityStore {
    private static let certificateLabel = MacStorage.tlsCertificateLabel
    private static let keyTag = MacStorage.tlsKeyTag

    static func loadOrCreate() throws -> RovaTLSIdentity {
        if let existing = try load() { return existing }
        return try create()
    }

    /// Removes the certificate and its key, so the next start creates a new pair. Phones paired
    /// over the local network must pair again, because they pin the certificate's fingerprint.
    static func reset() {
        for query: [CFString: Any] in [
            [kSecClass: kSecClassCertificate, kSecAttrLabel: certificateLabel],
            [kSecClass: kSecClassKey, kSecAttrApplicationTag: keyTag]
        ] {
            // A Mac that hit an earlier failure can hold several copies.
            var removed = 0
            while removed < 10, SecItemDelete(query as CFDictionary) == errSecSuccess { removed += 1 }
        }
    }

    private static func load() throws -> RovaTLSIdentity? {
        let certQuery: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certificateLabel,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var certResult: CFTypeRef?
        guard SecItemCopyMatching(certQuery as CFDictionary, &certResult) == errSecSuccess,
              let certResult else {
            return nil
        }
        let certificate = certResult as! SecCertificate

        var identity: SecIdentity?
        guard SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess,
              let identity else {
            // The certificate is there but its key is not usable (created by a differently signed
            // build, or deleted). Left alone, every start would add one more certificate and hand
            // the phone a different fingerprint than the one it paired with.
            reset()
            return nil
        }
        let fingerprint = RovaCrypto.sha256Hex(SecCertificateCopyData(certificate) as Data)
        return RovaTLSIdentity(identity: identity, certificateFingerprint: fingerprint)
    }

    private static func create() throws -> RovaTLSIdentity {
        let privateAttributes: [CFString: Any] = [
            kSecAttrIsPermanent: true,
            kSecAttrApplicationTag: keyTag
        ]
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: privateAttributes
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? RovaTLSError.identityCreationFailed
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error?.takeRetainedValue() ?? RovaTLSError.identityCreationFailed
        }

        let now = Date()
        let tbs = try DER.certificateBody(
            serial: try RovaCrypto.randomBytes(count: 16),
            publicKey: publicData,
            notBefore: now.addingTimeInterval(-86_400),
            notAfter: now.addingTimeInterval(31_536_000 * 10)
        )
        guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else {
            throw error?.takeRetainedValue() ?? RovaTLSError.identityCreationFailed
        }
        let certificateData = DER.sequence(tbs, DER.sequence(DER.oid([1, 2, 840, 10045, 4, 3, 2])), DER.bitString(signature))
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw RovaTLSError.identityCreationFailed
        }
        let certQuery: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecAttrLabel: certificateLabel
        ]
        let status = SecItemAdd(certQuery as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw RovaKeychainError.status(status)
        }
        var identity: SecIdentity?
        guard SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess,
              let identity else { throw RovaTLSError.identityCreationFailed }
        return RovaTLSIdentity(identity: identity, certificateFingerprint: RovaCrypto.sha256Hex(certificateData))
    }
}

/// LocalizedError so `error.localizedDescription` (MacServer.swift surfaces this directly as
/// "TLS servisi başlatılamadı: ___" - see MacRuntime.swift) never falls back to Foundation's raw
/// NSError bridging of a plain enum, the same message-quality bug found in IOSConnectionError.
enum RovaTLSError: LocalizedError {
    case identityCreationFailed

    var errorDescription: String? {
        switch self {
        case .identityCreationFailed: return "Yerel eşleştirme sertifikası oluşturulamadı."
        }
    }
}

private enum DER {
    static func length(_ length: Int) -> Data {
        if length < 128 { return Data([UInt8(length)]) }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }

    static func wrap(_ tag: UInt8, _ value: Data) -> Data {
        Data([tag]) + length(value.count) + value
    }

    static func sequence(_ values: Data...) -> Data { wrap(0x30, values.reduce(into: Data(), { $0.append($1) })) }
    static func set(_ values: Data...) -> Data { wrap(0x31, values.reduce(into: Data(), { $0.append($1) })) }
    static func integer(_ bytes: Data) -> Data {
        var value = bytes
        while value.count > 1 && value.first == 0 { value.removeFirst() }
        if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) }
        return wrap(0x02, value)
    }
    static func utf8(_ value: String) -> Data { wrap(0x0c, Data(value.utf8)) }
    static func utc(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return wrap(0x17, Data(formatter.string(from: date).utf8))
    }
    static func oid(_ components: [Int]) -> Data {
        guard components.count >= 2 else { return Data() }
        var bytes = Data([UInt8(components[0] * 40 + components[1])])
        for component in components.dropFirst(2) {
            var value = component
            var encoded = [UInt8(value & 0x7f)]
            value >>= 7
            while value > 0 { encoded.insert(UInt8(value & 0x7f) | 0x80, at: 0); value >>= 7 }
            bytes.append(contentsOf: encoded)
        }
        return wrap(0x06, bytes)
    }
    static func bitString(_ value: Data) -> Data { wrap(0x03, Data([0]) + value) }
    static func octetString(_ value: Data) -> Data { wrap(0x04, value) }

    static func certificateBody(serial: Data, publicKey: Data, notBefore: Date, notAfter: Date) throws -> Data {
        let signatureAlgorithm = sequence(oid([1, 2, 840, 10045, 4, 3, 2]))
        let name = sequence(set(sequence(oid([2, 5, 4, 3]), utf8("Wiqo Local"))))
        let validity = sequence(utc(notBefore), utc(notAfter))
        let publicKeyInfo = sequence(
            sequence(oid([1, 2, 840, 10045, 2, 1]), oid([1, 2, 840, 10045, 3, 1, 7])),
            bitString(publicKey)
        )
        let version = wrap(0xa0, integer(Data([2])))
        return sequence(version, integer(serial), signatureAlgorithm, name, validity, name, publicKeyInfo)
    }
}
