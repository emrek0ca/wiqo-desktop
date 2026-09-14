import Foundation

public enum RovaValidation {
    // Commands carry structured document metadata and small local read results. Large generated
    // binaries never cross this wire; they are downloaded by the Mac from the authenticated
    // backend artifact endpoint.
    public static let maxFrameSize = 1 * 1024 * 1024
    public static let commandTimeout: Duration = .seconds(10)

    public static func validate(_ request: CommandRequest) -> RovaError? {
        switch request.type {
        case .getSystemStatus, .ping, .lockMac, .sleepMac, .displaySleep, .toggleMute, .listCalendarEvents, .listDesktopFiles:
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
        case .sendMessage:
            guard case .message(let message) = request.payload,
                  isSafeText(message.recipient, maxLength: 320),
                  !message.body.isEmpty, message.body.count <= 10_000,
                  !message.body.contains("\0") else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Mesaj alıcısı veya içeriği geçersiz.")
            }
        case .createCalendarEvent:
            guard case .calendarEvent(let event) = request.payload,
                  isSafeText(event.title, maxLength: 300),
                  event.endAt > event.startAt,
                  event.endAt.timeIntervalSince(event.startAt) <= 7 * 24 * 60 * 60,
                  event.notes.map({ $0.count <= 4_000 && !$0.contains("\0") }) ?? true,
                  event.location.map({ $0.count <= 1_000 && !$0.contains("\0") }) ?? true else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Takvim etkinliği bilgileri geçersiz.")
            }
        case .readDesktopFile:
            guard case .fileName(let filename) = request.payload, isValidDesktopFilename(filename) else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Okunacak dosya adı geçersiz.")
            }
        case .moveDesktopFile, .renameDesktopFile:
            guard case .fileMove(let move) = request.payload,
                  isValidDesktopFilename(move.source), isValidDesktopFilename(move.destination),
                  move.source != move.destination else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Kaynak veya hedef dosya adı geçersiz.")
            }
        case .saveArtifact:
            guard case .artifactFile(let artifact) = request.payload,
                  isValidDesktopFilename(artifact.filename),
                  artifact.artifactID.range(of: "^[0-9a-f-]{20,128}$", options: .regularExpression) != nil,
                  artifact.mimeType.count <= 160, !artifact.mimeType.contains(where: { $0.isWhitespace || $0 == "\0" }),
                  artifact.byteCount.map({ $0 > 0 && $0 <= 25 * 1024 * 1024 }) ?? true,
                  artifact.sha256.map({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) ?? true,
                  isAllowedArtifactURL(artifact.downloadURL) else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Artifact kaydetme isteği geçersiz.")
            }
        case .readDocument:
            guard case .fileName(let filename) = request.payload, isValidDesktopFilename(filename) else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Okunacak belge adı geçersiz.")
            }
        case .editDocument:
            guard case .document(let document) = request.payload,
                  isValidDesktopFilename(document.filename),
                  document.content.count > 0, document.content.count <= 500_000 else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Belge düzenleme isteği geçersiz.")
            }
        }
        return nil
    }

    /// A single path component with no separators or traversal - this is appended directly to
    /// the Desktop folder URL, so it must never be able to escape that directory.
    public static func isValidDesktopFilename(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 255, trimmed != ".", trimmed != ".." else { return false }
        return !trimmed.contains("/") && !trimmed.contains("\\") && !trimmed.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }

    private static func isSafeText(_ value: String, maxLength: Int) -> Bool {
        !value.isEmpty && value.count <= maxLength && !value.contains(where: { $0.isNewline || $0 == "\0" })
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

    public static func isAllowedArtifactURL(_ rawValue: String) -> Bool {
        guard isAllowedURL(rawValue), let host = URLComponents(string: rawValue)?.host?.lowercased() else { return false }
        return host == "84-247-172-213.sslip.io"
    }
}
