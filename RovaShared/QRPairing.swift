import Foundation

public enum RovaQRCodec {
    private static let prefix = "rova-pair:v1:"

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
}

public enum RovaQRError: Error, Equatable {
    case invalidPrefix
    case invalidEncoding
    case invalidPayload
}
