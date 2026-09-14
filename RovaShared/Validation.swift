import Foundation

public enum RovaValidation {
    public static let maxFrameSize = 64 * 1024
    public static let commandTimeout: Duration = .seconds(10)

    public static func validate(_ request: CommandRequest) -> RovaError? {
        switch request.type {
        case .getSystemStatus, .ping, .lockMac, .sleepMac, .displaySleep, .toggleMute:
            guard request.payload == .none else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Bu komut payload kabul etmiyor.")
            }
        case .openApplication:
            guard case .application = request.payload else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Uygulama seçimi geçersiz.")
            }
        case .quitApplication:
            guard case .application = request.payload else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Kapatılacak uygulama seçimi geçersiz.")
            }
        case .openURL:
            guard case .url(let value) = request.payload, isAllowedURL(value) else {
                return RovaError(code: "INVALID_URL", message: "Yalnızca geçerli http veya https URL’leri açılabilir.")
            }
        case .setVolume:
            guard case .volume(let level) = request.payload, (0...100).contains(level) else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Ses seviyesi 0 ile 100 arasında olmalıdır.")
            }
        case .setBrightness:
            guard case .brightness(let level) = request.payload, (0...100).contains(level) else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Parlaklık 0 ile 100 arasında olmalıdır.")
            }
        case .setClipboardText:
            guard case .clipboardText(let text) = request.payload, !text.isEmpty, text.count <= 10_000 else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Pano metni 1 ile 10.000 karakter arasında olmalıdır.")
            }
        case .mediaControl:
            guard case .media = request.payload else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Medya komutu geçersiz.")
            }
        case .saveTextFile:
            guard case .textFile(let file) = request.payload, isValidDesktopFilename(file.filename),
                  !file.content.isEmpty, file.content.count <= 200_000 else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Dosya adı veya içeriği geçersiz.")
            }
        }
        return nil
    }

    /// A single path component with no separators or traversal - this is appended directly to
    /// the Desktop folder URL, so it must never be able to escape that directory.
    public static func isValidDesktopFilename(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 255, trimmed != ".", trimmed != ".." else { return false }
        return !trimmed.contains("/") && !trimmed.contains("\\") && !trimmed.contains("\0")
    }

    public static func isRequestTimestampValid(_ createdAt: Date, now: Date = Date(), maxSkewSeconds: TimeInterval = 600) -> Bool {
        abs(now.timeIntervalSince(createdAt)) <= maxSkewSeconds
    }

    public static func signRequest(id: UUID, type: CommandType, nonce: String, token: String) -> String {
        let message = "\(id.uuidString):\(type.rawValue):\(nonce)"
        return RovaCrypto.hmacSHA256Hex(key: token, message: message)
    }

    public static func verifyRequestSignature(request: CommandRequest, token: String) -> Bool {
        guard let signature = request.signature, !signature.isEmpty,
              let nonce = request.nonce, !nonce.isEmpty else {
            return false
        }
        let message = "\(request.id.uuidString):\(request.type.rawValue):\(nonce)"
        let expected = RovaCrypto.hmacSHA256Hex(key: token, message: message)
        return RovaCrypto.constantTimeEquals(signature, expected)
    }

    /// Checks the payload's *shape* only (well-formed host/port/fingerprint/code) - deliberately
    /// independent of `expiresAt` so callers can distinguish "malformed QR" from "expired QR"
    /// and show the right message instead of a generic "invalid" for both.
    public static func isPairingPayloadValid(_ payload: PairingPayload) -> Bool {
        payload.version == 1 && payload.pairingCode.count == 6 &&
            payload.pairingCode.allSatisfy({ $0.isNumber }) && payload.port != 0 && !payload.host.isEmpty &&
            payload.certificateFingerprint.count == 64 &&
            payload.certificateFingerprint.allSatisfy({ $0.isHexDigit })
    }

    public static func isValidToken(_ candidate: String, expected: String, deviceID: UUID, expectedDeviceID: UUID) -> Bool {
        deviceID == expectedDeviceID && !candidate.isEmpty && RovaCrypto.constantTimeEquals(candidate, expected)
    }

    public static func isAllowedURL(_ rawValue: String) -> Bool {
        guard rawValue.count <= 2048,
              !rawValue.contains(where: { $0.isNewline || $0.isWhitespace && $0 != " " }) else {
            return false
        }
        guard let components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            return false
        }
        return true
    }
}
