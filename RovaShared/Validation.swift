import Foundation

public enum RovaValidation {
    // Commands carry structured document metadata and small local read results. Large generated
    // binaries never cross this wire; they are downloaded by the Mac from the authenticated
    // backend artifact endpoint.
    public static let maxFrameSize = 1 * 1024 * 1024
    public static let commandTimeout: Duration = .seconds(10)

    public static func validate(_ request: CommandRequest) -> RovaError? {
        switch request.type {
        case .getSystemStatus, .ping, .lockMac, .sleepMac, .displaySleep, .toggleMute, .listCalendarEvents, .listDesktopFiles, .listReminders, .getClipboardText, .getClipboardHistory:
            guard request.payload == .none else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Bu komut payload kabul etmiyor.")
            }
        case .openApplication:
            guard case .application = request.payload else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Uygulama seçimi geçersiz.")
            }
        case .openApplicationByName:
            guard case .applicationQuery(let query) = request.payload,
                  isSafeText(query, maxLength: 200) else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Uygulama arama adı geçersiz.")
            }
        case .controlApplication:
            guard case .applicationControl(let application) = request.payload,
                  isSafeText(application.target, maxLength: 200),
                  application.bundleIdentifier.map(isValidBundleIdentifier) ?? true,
                  !application.force || application.action == .quit else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Uygulama eylemi veya hedefi geçersiz.", category: "validation")
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
        case .createNote:
            guard case .note(let note) = request.payload,
                  isSafeText(note.title, maxLength: 300),
                  note.body.count <= 50_000, !note.body.contains("\0"),
                  note.folderName.map({ isSafeText($0, maxLength: 200) }) ?? true else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Not bilgileri geçersiz.")
            }
        case .sendEmail:
            guard case .email(let email) = request.payload,
                  isSafeText(email.to, maxLength: 320), email.to.contains("@"),
                  isSafeText(email.subject, maxLength: 300),
                  !email.body.isEmpty, email.body.count <= 50_000, !email.body.contains("\0") else {
                return RovaError(code: "INVALID_PAYLOAD", message: "E-posta alıcısı, konusu veya içeriği geçersiz.")
            }
        case .createReminder:
            guard case .reminder(let reminder) = request.payload,
                  isSafeText(reminder.title, maxLength: 300),
                  reminder.notes.map({ $0.count <= 4_000 && !$0.contains("\0") }) ?? true,
                  reminder.listName.map({ isSafeText($0, maxLength: 200) }) ?? true else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Hatırlatıcı bilgileri geçersiz.")
            }
        case .completeReminder:
            guard case .completeReminder(let payload) = request.payload,
                  !payload.identifier.isEmpty, payload.identifier.count <= 300 else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Hatırlatıcı kimliği geçersiz.")
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
        case .listFiles, .readFile:
            guard case .fileOperation(let operation) = request.payload,
                  isValidLocalPath(operation.path),
                  operation.page >= 0, operation.page <= 10_000,
                  operation.pageSize > 0, operation.pageSize <= 500 else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Dosya yolu veya listeleme aralığı geçersiz.")
            }
        case .writeFile:
            guard case .fileOperation(let operation) = request.payload,
                  isValidLocalPath(operation.path),
                  let content = operation.content,
                  content.count <= 500_000, !content.contains("\0") else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Dosya yazma isteği geçersiz.")
            }
        case .moveFile, .copyFile:
            guard case .fileOperation(let operation) = request.payload,
                  isValidLocalPath(operation.path),
                  let destination = operation.destination,
                  isValidLocalPath(destination),
                  operation.path != destination else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Kaynak veya hedef dosya yolu geçersiz.")
            }
        case .deleteFile:
            guard case .fileOperation(let operation) = request.payload,
                  isValidLocalPath(operation.path) else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Silinecek dosya yolu geçersiz.")
            }
        case .executeCode:
            guard case .codeExecution(let execution) = request.payload,
                  ["python", "javascript", "shell"].contains(execution.language.lowercased()),
                  !execution.code.isEmpty, execution.code.count <= 100_000,
                  execution.arguments.count <= 20,
                  execution.arguments.allSatisfy({ !$0.isEmpty && $0.count <= 200 && !$0.contains("\0") }),
                  (1...30).contains(execution.timeoutSeconds) else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Kod çalıştırma isteği geçersiz.")
            }
        case .captureScreen:
            guard case .screenCapture(let capture) = request.payload,
                  (400...2_400).contains(capture.maxWidth) else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Ekran görüntüsü ayarları geçersiz.")
            }
        case .runShortcut:
            guard case .shortcut(let shortcut) = request.payload,
                  (1...30).contains(shortcut.timeoutSeconds) else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Shortcut isteği veya zaman aşımı geçersiz.")
            }
        case .controlUIElement:
            guard case .uiElement(let element) = request.payload,
                  isValidBundleIdentifier(element.bundleIdentifier),
                  isSafeText(element.label, maxLength: 240),
                  element.windowTitle.map({ isSafeText($0, maxLength: 240) }) ?? true,
                  element.role.map({ isSafeText($0, maxLength: 120) }) ?? true,
                  element.value.map({ isSafeText($0, maxLength: 2_000) }) ?? true,
                  element.expectedValue.map({ isSafeText($0, maxLength: 2_000) }) ?? true,
                  element.action != .setValue || element.value != nil else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Accessibility hedefi veya değeri geçersiz.")
            }
        case .clickScreen:
            guard case .screenClick(let click) = request.payload,
                  (0.0...1.0).contains(click.normalizedX),
                  (0.0...1.0).contains(click.normalizedY),
                  (400...2_400).contains(click.screenshotWidth),
                  (400...2_400).contains(click.screenshotHeight),
                  click.expectedTarget.map({ isSafeText($0, maxLength: 240) }) ?? false else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Ekran tıklaması koordinat veya hedef doğrulamasından geçmedi.")
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

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        value.count <= 200 && value.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil
    }

    /// Shared with the Mac's AX layer and intentionally small. A matching label makes a generic
    /// UI action presence-gated even when a caller incorrectly marks it as harmless.
    public static let destructiveUIKeywords = [
        "sil", "kaldır", "format", "sıfırla", "delete", "remove", "erase", "reset"
    ]

    public static func uiElementRequiresUserPresence(_ payload: UIElementPayload) -> Bool {
        let normalized = normalizeUIComparisonText(payload.label)
        return destructiveUIKeywords.contains { normalizeUIComparisonText($0).isEmpty == false && normalized.contains(normalizeUIComparisonText($0)) }
    }

    private static func normalizeUIComparisonText(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "ı", with: "i")
    }

    /// Local paths are intentionally absolute (or home-relative with `~/`). The Mac resolves
    /// symlinks and validates the resulting URL again; rejecting dot segments here closes the
    /// obvious traversal form before it reaches the companion.
    public static func isValidLocalPath(_ rawPath: String) -> Bool {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.count <= 2_048,
              (path.hasPrefix("/") || path.hasPrefix("~/")),
              !path.contains("\0"),
              !path.contains(where: { $0.isNewline }),
              !path.split(separator: "/").contains("..") else { return false }
        return true
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

/// The single local authority policy shared by iOS confirmation and unattended Mac execution.
/// Backend flags are advisory; callers must always combine them with this payload-aware policy.
public enum RovaCommandAuthority {
    public static func capability(for type: CommandType, payload: CommandPayload) -> String {
        switch type {
        case .getSystemStatus, .ping: return "runtime.status"
        case .openApplication: return "device.app.open"
        case .openApplicationByName: return "device.app.open_by_name"
        case .quitApplication: return "device.app.quit"
        case .controlApplication:
            guard case .applicationControl(let application) = payload else { return "device.app.control" }
            return application.action == .quit ? "device.app.quit" : "device.app.control"
        case .openURL: return "device.url.open"
        case .setVolume, .toggleMute: return "device.audio"
        case .setBrightness: return "device.display"
        case .mediaControl: return "device.media"
        case .setClipboardText: return "device.clipboard"
        case .lockMac, .sleepMac, .displaySleep: return "device.system.power"
        case .sendMessage: return "device.messaging.send"
        case .listCalendarEvents: return "calendar.read"
        case .createCalendarEvent: return "calendar.write"
        case .listReminders: return "reminders.read"
        case .createReminder: return "reminders.write"
        case .completeReminder: return "reminders.write"
        case .getClipboardText, .getClipboardHistory: return "device.clipboard"
        case .createNote: return "notes.write"
        case .sendEmail: return "mail.send"
        case .listDesktopFiles, .listFiles: return "device.files.list"
        case .readDesktopFile, .readFile: return "device.files.read"
        case .saveTextFile, .writeFile: return "device.files.write"
        case .moveDesktopFile, .renameDesktopFile, .moveFile: return "device.files.move"
        case .copyFile: return "device.files.copy"
        case .deleteFile: return "device.files.delete"
        case .saveArtifact: return "artifact.save"
        case .readDocument: return "document.read"
        case .editDocument: return "document.edit"
        case .executeCode: return "device.code.execute"
        case .captureScreen: return "device.screen.capture"
        case .runShortcut: return "device.shortcut.run"
        case .controlUIElement: return "device.ui.control"
        case .clickScreen: return "device.screen.click"
        }
    }

    /// Every capability a fully-featured companion can ever advertise, derived from
    /// `CommandType.allCases` rather than hand-typed - the Mac's own advertised list (see
    /// MacRuntime.deviceInfo) reads this instead of keeping a second copy in sync by hand. `.none`
    /// is a safe stand-in payload here: the couple of types whose capability actually varies by
    /// payload content (controlApplication) still resolve to one of their real capabilities, and
    /// every other CommandType that produces the *other* variant (e.g. quitApplication for
    /// device.app.quit) contributes it independently, so the full set comes out complete either way.
    public static let allCapabilities: Set<String> = Set(CommandType.allCases.map { capability(for: $0, payload: .none) })

    public static func isDestructive(type: CommandType, payload: CommandPayload) -> Bool {
        switch type {
        case .lockMac, .sleepMac, .displaySleep, .sendMessage, .sendEmail, .createNote,
             .createCalendarEvent, .createReminder, .completeReminder, .moveDesktopFile, .renameDesktopFile, .saveArtifact,
             .editDocument, .writeFile, .moveFile, .copyFile, .deleteFile, .executeCode,
             .clickScreen, .runShortcut:
            return true
        case .controlApplication:
            guard case .applicationControl(let application) = payload else { return true }
            return application.force
        case .controlUIElement:
            guard case .uiElement(let element) = payload else { return true }
            return RovaValidation.uiElementRequiresUserPresence(element)
        default:
            return false
        }
    }

    public static func requiresUserPresence(type: CommandType, payload: CommandPayload) -> Bool {
        if isDestructive(type: type, payload: payload) { return true }
        switch type {
        case .saveTextFile, .readDocument, .editDocument, .saveArtifact,
             .listFiles, .readFile, .writeFile, .moveFile, .copyFile, .deleteFile,
             .executeCode, .captureScreen, .controlUIElement, .clickScreen,
             .controlApplication, .getClipboardText, .getClipboardHistory:
            return true
        default:
            return false
        }
    }

    /// Background automations never inherit an interactive grant. Private reads, UI observation,
    /// code execution and every destructive/write action remain presence-gated even if a malformed
    /// backend step claims otherwise.
    public static func permitsUnattended(type: CommandType, payload: CommandPayload) -> Bool {
        if requiresUserPresence(type: type, payload: payload) { return false }
        switch type {
        case .readDocument, .listFiles, .readFile, .captureScreen, .controlUIElement, .clickScreen:
            return false
        case .controlApplication, .quitApplication, .runShortcut:
            return false
        default:
            return true
        }
    }
}
