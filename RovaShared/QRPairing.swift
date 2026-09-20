import Foundation

public enum RovaQRCodec {
    private static let prefix = "rova-pair:v1:"
    private static let relayPrefix = "rova-relay:v1:"

    public static func encode(_ payload: PairingPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        return prefix + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ value: String) throws -> PairingPayload {
        guard value.hasPrefix(prefix) else { throw RovaQRError.invalidPrefix }
        var encoded = String(value.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { throw RovaQRError.invalidEncoding }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(PairingPayload.self, from: data)
        guard payload.version == 1, !payload.host.isEmpty, payload.port != 0,
              payload.certificateFingerprint.count == 64,
              payload.certificateFingerprint.allSatisfy({ $0.isHexDigit }),
              payload.pairingCode.count == 6,
              payload.pairingCode.allSatisfy({ $0.isNumber }) else {
            throw RovaQRError.invalidPayload
        }
        return payload
    }

    public static func encode(_ payload: RelayPairingPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        return relayPrefix + encodeBase64(data)
    }

    public static func decodePairingCode(_ value: String) throws -> RovaPairingCode {
        if value.hasPrefix(prefix) { return .local(try decode(value)) }
        guard value.hasPrefix(relayPrefix), let data = decodeBase64(String(value.dropFirst(relayPrefix.count))) else {
            throw RovaQRError.invalidPrefix
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(RelayPairingPayload.self, from: data)
        guard payload.version == 1, !payload.sessionID.isEmpty, payload.secret.count >= 32, payload.expiresAt > Date() else {
            throw RovaQRError.invalidPayload
        }
        return .relay(payload)
    }

    private static func encodeBase64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64(_ value: String) -> Data? {
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded)
    }
}

public enum RovaQRError: Error, Equatable {
    case invalidPrefix
    case invalidEncoding
    case invalidPayload
}
