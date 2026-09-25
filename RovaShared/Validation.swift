import Foundation

public enum RovaValidation {
    // Commands carry structured document metadata and small local read results. Large generated
    // binaries never cross this wire; they are downloaded by the Mac from the authenticated
    // backend artifact endpoint.
    public static let maxFrameSize = 1 * 1024 * 1024
    public static let commandTimeout: Duration = .seconds(10)

    public static func validate(_ request: CommandRequest) -> RovaError? {
        switch request.type {
        case .getSystemStatus, .ping, .lockMac, .sleepMac, .displaySleep, .toggleMute, .listCalendarEvents, .listDesktopFiles, .listReminders, .getClipboardText, .getClipboardHistory, .listRunningApplications:
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
        case .sendFileToPhone:
            guard case .fileOperation(let operation) = request.payload,
                  isValidLocalPath(operation.path) || isValidWindowsLocalPath(operation.path) else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Dosya yolu geçersiz.")
            }
        case .searchFiles:
            guard case .fileSearch(let search) = request.payload,
                  isSafeText(search.query, maxLength: 120),
                  search.cursor.map({ UUID(uuidString: $0) != nil }) ?? true else {
                return RovaError(code: "INVALID_PAYLOAD", message: "Dosya arama isteği geçersiz.")
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
                  (1...30).contains(execution.timeoutSeconds),
                  ["sandbox", "computer"].contains(execution.scope.lowercased()),
                  execution.shell.map({ ["default", "zsh", "bash", "powershell", "cmd"].contains($0.lowercased()) }) ?? true,
                  execution.workingDirectory.map(isValidTerminalWorkingDirectory) ?? true else {
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

    private static func isValidTerminalWorkingDirectory(_ value: String) -> Bool {
        guard isSafeText(value, maxLength: 2_000), !value.contains("\r"), !value.contains("\n") else { return false }
        #if os(Windows)
        return value.count >= 3 && value[value.index(value.startIndex, offsetBy: 1)] == ":"
        #else
        return value.hasPrefix("/")
        #endif
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

    public static func isValidWindowsLocalPath(_ rawPath: String) -> Bool {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.count >= 3, path.count <= 2_048,
              path.first?.isASCII == true,
              path.first?.isLetter == true,
              path.dropFirst().first == ":",
              path.dropFirst(2).first == "\\" || path.dropFirst(2).first == "/",
              !path.contains("\0"), !path.contains(where: { $0.isNewline }),
              !path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..") else { return false }
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
        case .listDesktopFiles, .listFiles, .searchFiles: return "device.files.list"
        case .readDesktopFile, .readFile, .sendFileToPhone: return "device.files.read"
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
        case .listRunningApplications: return "device.app.list"
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
             .listFiles, .searchFiles, .readFile, .sendFileToPhone, .writeFile, .moveFile, .copyFile, .deleteFile,
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
        case .readDocument, .listFiles, .searchFiles, .readFile, .sendFileToPhone, .captureScreen, .controlUIElement, .clickScreen:
            return false
        case .controlApplication, .quitApplication, .runShortcut:
            return false
        default:
            return true
        }
    }
}

/// Terminal sessions on the paired Mac (backend tools/terminalTools.ts mirrors the command rules).
/// The phone signs a time-boxed grant - folder, mode, expiry - with the pairing token; the backend
/// relays it but can neither create nor widen one. The Mac checks the signature, the expiry, that
/// the working folder resolves inside the granted folder, and these command rules on every command.
public enum RovaTerminalPolicy {
    public static let feature = "terminal-session-v1"

    public static func grantMessage(grantId: String, rootDirectory: String, mode: String, expiresAt: Int) -> String {
        "wiqo-terminal-grant:v1:\(grantId.lowercased()):\(rootDirectory):\(mode):\(expiresAt)"
    }

    public static func signGrant(grantId: String, rootDirectory: String, mode: String, expiresAt: Int, token: String) -> String {
        RovaCrypto.hmacSHA256Hex(key: token, message: grantMessage(grantId: grantId, rootDirectory: rootDirectory, mode: mode, expiresAt: expiresAt))
    }

    public static func verifyGrant(grantId: String, rootDirectory: String, mode: String, expiresAt: Int, signature: String, token: String, now: Date = Date()) -> Bool {
        guard mode == "read" || mode == "full", expiresAt > Int(now.timeIntervalSince1970), expiresAt <= Int(now.timeIntervalSince1970) + 2 * 60 * 60 else { return false }
        let expected = signGrant(grantId: grantId, rootDirectory: rootDirectory, mode: mode, expiresAt: expiresAt, token: token)
        return RovaCrypto.constantTimeEquals(signature.lowercased(), expected)
    }

    private static let readOnlyPrograms: Set<String> = [
        "ls", "pwd", "cat", "head", "tail", "wc", "grep", "egrep", "rg", "find", "file", "stat", "du", "df", "tree", "which", "whereis",
        "type", "echo", "date", "uname", "sw_vers", "whoami", "ps", "sort", "uniq", "cut", "jq", "diff", "cmp", "basename", "dirname",
        "realpath", "md5", "shasum", "lsof", "uptime", "hostname", "xcodebuild", "system_profiler"
    ]
    private static let versionOnlyPrograms: Set<String> = ["node", "npm", "npx", "python", "python3", "pip", "pip3", "brew", "java", "swift", "go", "cargo", "ruby", "git", "docker", "pnpm", "yarn"]
    private static let gitReadSubcommands: Set<String> = ["status", "log", "diff", "show", "branch", "remote", "rev-parse", "ls-files", "blame", "describe", "tag", "shortlog", "config"]
    private static let packageReadSubcommands: [String: Set<String>] = [
        "npm": ["ls", "list", "outdated", "view"], "pnpm": ["ls", "list", "outdated"], "yarn": ["list", "outdated", "info"],
        "pip": ["list", "show", "freeze"], "pip3": ["list", "show", "freeze"], "brew": ["list", "info", "outdated", "search"],
        "docker": ["ps", "images", "version", "info"]
    ]
    private static let forbiddenPatterns: [String] = [
        #"(^|[\s;&|(])sudo(\s|$)"#,
        #"(^|[\s;&|(])su(\s|$)"#,
        #"\brm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+)+(/|~|\$HOME|\*)(\s|$|/\s|/\*)"#,
        #"\b(mkfs|fdisk|diskutil\s+(erase|partition|zero)|dd\s+if=)"#,
        #"\b(shutdown|reboot|halt|launchctl|csrutil|nvram|spctl|kextload)\b"#,
        #"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?)\b"#,
        #"\bchmod\s+-R\s+[0-7]{3,4}\s+(/|~)(\s|$)"#,
        #"\bchown\s+-R\b[^;&|]*\s(/|~)(\s|$)"#,
        #":\(\)\s*\{\s*:\|:&\s*\};:"#,
        #"\bsecurity\s+(dump-keychain|find-generic-password|find-internet-password)"#,
        #"\bosascript\b"#,
        #"\bcrontab\s+-r\b"#
    ]

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    public static func isForbidden(_ command: String) -> Bool {
        forbiddenPatterns.contains { matches($0, command) }
    }

    /// Conservative: anything that is not clearly an inspection needs a "full" grant.
    public static func isReadOnly(_ command: String) -> Bool {
        let withoutStderrMerge = command.replacingOccurrences(of: "2>&1", with: "")
        if matches(#"[`<]|\$\(|>(?!&1|\s*/dev/null)|(^|[^&])&($|[^&])"#, withoutStderrMerge) { return false }
        let segments = command
            .replacingOccurrences(of: "||", with: "\n").replacingOccurrences(of: "&&", with: "\n")
            .replacingOccurrences(of: ";", with: "\n").replacingOccurrences(of: "|", with: "\n")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { segment in
            let words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = words.first else { return false }
            let program = (first as NSString).lastPathComponent
            let rest = Array(words.dropFirst())
            if program == "find" { return !rest.contains { $0.range(of: #"^-(delete|exec|execdir|ok|okdir|fprint)"#, options: .regularExpression) != nil } }
            if program == "git" {
                guard let sub = rest.first, gitReadSubcommands.contains(sub) else { return false }
                if sub == "config" { return rest.contains("--get") || rest.contains("--list") || rest.contains("-l") }
                if sub == "branch" { return !rest.contains { $0.range(of: #"^-[dDmM]"#, options: .regularExpression) != nil } }
                if sub == "tag" { return !rest.contains { $0.range(of: #"^-[ad]"#, options: .regularExpression) != nil } }
                return true
            }
            if let allowed = packageReadSubcommands[program], let sub = rest.first, allowed.contains(sub) { return true }
            if versionOnlyPrograms.contains(program) { return rest.count == 1 && ["-v", "--version", "-V", "version"].contains(rest[0]) }
            return readOnlyPrograms.contains(program)
        }
    }

    /// "~/a" → the real, symlink-resolved folder; nil for relative paths or "..".
    public static func resolveDirectory(_ path: String, home: String = NSHomeDirectory()) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.split(separator: "/").contains("..") else { return nil }
        let expanded: String
        if trimmed == "~" { expanded = home }
        else if trimmed.hasPrefix("~/") { expanded = home + String(trimmed.dropFirst(1)) }
        else if trimmed.hasPrefix("/") { expanded = trimmed }
        else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func isWithin(_ directory: String, root: String) -> Bool {
        directory == root || directory.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private static let secretPatterns: [String] = [
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
        #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#,
        #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#,
        #"\bsk-[A-Za-z0-9_-]{20,}\b"#,
        #"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#,
        #"\bAIza[0-9A-Za-z_-]{30,}\b"#,
        #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#
    ]

    /// Masks credentials before command output leaves the Mac: known token formats, private keys,
    /// and the value side of KEY=, TOKEN=, SECRET=, PASSWORD= style assignments.
    public static func redactSecrets(_ text: String) -> String {
        var result = text
        for pattern in secretPatterns {
            result = result.replacingOccurrences(of: pattern, with: "[gizli bilgi gizlendi]", options: .regularExpression)
        }
        result = result.replacingOccurrences(
            of: #"(?im)^(\s*(?:export\s+)?[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTHORIZATION)[A-Z0-9_]*\s*[=:]\s*)\S.*$"#,
            with: "$1[gizli bilgi gizlendi]",
            options: .regularExpression
        )
        return result
    }
}
