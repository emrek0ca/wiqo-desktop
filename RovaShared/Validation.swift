import CoreFoundation
import Foundation

private final class RovaRequestNonceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String: Date] = [:]

    func claim(token: String, nonce: String, now: Date) -> Bool {
        let tokenHash = RovaCrypto.sha256Hex(Data(token.utf8))
        let nonceHash = RovaCrypto.sha256Hex(Data(nonce.utf8))
        let key = tokenHash + ":" + nonceHash
        lock.lock()
        defer { lock.unlock() }
        seen = seen.filter { now.timeIntervalSince($0.value) <= 600 }
        guard seen[key] == nil else { return false }
        if seen.count >= 20_000, let oldest = seen.min(by: { $0.value < $1.value })?.key { seen.removeValue(forKey: oldest) }
        seen[key] = now
        return true
    }
}

public enum RovaCanonicalJSON {
    public static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
        return Data(try serialize(object).utf8)
    }

    /// The canonical form of JSON exactly as it arrived (JSONSerialization output), without passing through this build's models: a field a
    /// newer sender added is part of what it signed, and a re-encoded model would have dropped it.
    public static func data(jsonObject: Any) throws -> Data {
        Data(try serialize(jsonObject).utf8)
    }

    private static func serialize(_ value: Any) throws -> String {
        if value is NSNull { return "null" }
        if let string = value as? String {
            let encoded = try JSONSerialization.data(withJSONObject: [string], options: [.fragmentsAllowed, .withoutEscapingSlashes])
            guard let text = String(data: encoded, encoding: .utf8), text.count >= 2 else { throw RovaCanonicalJSONError.invalidValue }
            return String(text.dropFirst().dropLast())
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            // RFC 8785 parses every JSON number as IEEE-754 binary64 before serialization.
            return try canonicalNumber(number.doubleValue)
        }
        if let array = value as? [Any] {
            return "[" + (try array.map(serialize).joined(separator: ",")) + "]"
        }
        if let object = value as? [String: Any] {
            let keys = object.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            let members = try keys.map { key in
                "\(try serialize(key)):\(try serialize(object[key]!))"
            }
            return "{" + members.joined(separator: ",") + "}"
        }
        throw RovaCanonicalJSONError.invalidValue
    }

    /// RFC 8785 uses ECMAScript's shortest finite number format. Swift's shortest round-trip
    /// digits are converted to the same decimal/exponent layout, including -0 => 0.
    private static func canonicalNumber(_ value: Double) throws -> String {
        guard value.isFinite else { throw RovaCanonicalJSONError.invalidValue }
        if value == 0 { return "0" }
        let negative = value < 0
        let raw = String(abs(value)).lowercased()
        let parts = raw.split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false)
        let mantissa = String(parts[0])
        let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        let integerDigits = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count
        var digits = mantissa.filter(\.isNumber)
        var decimalPosition = integerDigits + exponent
        while digits.first == "0" { digits.removeFirst(); decimalPosition -= 1 }
        while digits.last == "0" { digits.removeLast() }
        guard !digits.isEmpty else { return "0" }
        let sign = negative ? "-" : ""
        if decimalPosition > 0 && decimalPosition <= 21 {
            if digits.count <= decimalPosition {
                return sign + digits + String(repeating: "0", count: decimalPosition - digits.count)
            }
            let split = digits.index(digits.startIndex, offsetBy: decimalPosition)
            return sign + String(digits[..<split]) + "." + String(digits[split...])
        }
        if decimalPosition <= 0 && decimalPosition > -6 {
            return sign + "0." + String(repeating: "0", count: -decimalPosition) + digits
        }
        let scientificExponent = decimalPosition - 1
        let coefficient = digits.count == 1 ? digits : String(digits.first!) + "." + String(digits.dropFirst())
        return sign + coefficient + "e" + (scientificExponent >= 0 ? "+" : "") + String(scientificExponent)
    }
}

public enum RovaCanonicalJSONError: Error {
    case invalidValue
}

public enum RovaValidation {
    private static let requestNonceCache = RovaRequestNonceCache()
    // Commands carry structured document metadata and small local read results. Large generated
    // binaries never cross this wire; they are downloaded by the Mac from the authenticated
    // backend artifact endpoint.
    public static let maxFrameSize = 1 * 1024 * 1024
    public static let commandTimeout: Duration = .seconds(10)

    public static func validate(_ request: CommandRequest) -> RovaError? {
        switch request.type {
        case .getSystemStatus, .ping, .lockMac, .sleepMac, .displaySleep, .toggleMute, .listCalendarEvents, .listDesktopFiles, .listReminders, .getClipboardText, .getClipboardHistory, .listRunningApplications:
            guard request.payload == .none else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Bu komut payload kabul etmiyor."))
            }
        case .openApplication:
            guard case .application = request.payload else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Uygulama seçimi geçersiz."))
            }
        case .openApplicationByName:
            guard case .applicationQuery(let query) = request.payload,
                  isSafeText(query, maxLength: 200) else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Uygulama arama adı geçersiz."))
            }
        case .controlApplication:
            guard case .applicationControl(let application) = request.payload,
                  isSafeText(application.target, maxLength: 200),
                  application.bundleIdentifier.map(isValidBundleIdentifier) ?? true,
                  !application.force || application.action == .quit else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Uygulama eylemi veya hedefi geçersiz."), category: "validation")
            }
        case .quitApplication:
            guard case .application = request.payload else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Kapatılacak uygulama seçimi geçersiz."))
            }
        case .openURL:
            guard case .url(let value) = request.payload, isAllowedURL(value) else {
                return RovaError(code: "INVALID_URL", message: String(localized: "Yalnızca geçerli http veya https URL’leri açılabilir."))
            }
        case .setVolume:
            guard case .volume(let level) = request.payload, (0...100).contains(level) else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Ses seviyesi 0 ile 100 arasında olmalıdır."))
            }
        case .setBrightness:
            guard case .brightness(let level) = request.payload, (0...100).contains(level) else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Parlaklık 0 ile 100 arasında olmalıdır."))
            }
        case .setClipboardText:
            guard case .clipboardText(let text) = request.payload, !text.isEmpty, text.count <= 10_000 else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Pano metni 1 ile 10.000 karakter arasında olmalıdır."))
            }
        case .mediaControl:
            guard case .media = request.payload else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Medya komutu geçersiz."))
            }
        case .saveTextFile:
            guard case .textFile(let file) = request.payload, isValidDesktopFilename(file.filename),
                  !file.content.isEmpty, file.content.count <= 200_000 else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Dosya adı veya içeriği geçersiz."))
            }
        case .sendMessage:
            guard case .message(let message) = request.payload,
                  isSafeText(message.recipient, maxLength: 320),
                  !message.body.isEmpty, message.body.count <= 10_000,
                  !message.body.contains("\0") else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Mesaj alıcısı veya içeriği geçersiz."))
            }
        case .createCalendarEvent:
            guard case .calendarEvent(let event) = request.payload,
                  isSafeText(event.title, maxLength: 300),
                  event.endAt > event.startAt,
                  event.endAt.timeIntervalSince(event.startAt) <= 7 * 24 * 60 * 60,
                  event.notes.map({ $0.count <= 4_000 && !$0.contains("\0") }) ?? true,
                  event.location.map({ $0.count <= 1_000 && !$0.contains("\0") }) ?? true else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Takvim etkinliği bilgileri geçersiz."))
            }
        case .createNote:
            guard case .note(let note) = request.payload,
                  isSafeText(note.title, maxLength: 300),
                  note.body.count <= 50_000, !note.body.contains("\0"),
                  note.folderName.map({ isSafeText($0, maxLength: 200) }) ?? true else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Not bilgileri geçersiz."))
            }
        case .sendEmail:
            guard case .email(let email) = request.payload,
                  isSafeText(email.to, maxLength: 320), email.to.contains("@"),
                  isSafeText(email.subject, maxLength: 300),
                  !email.body.isEmpty, email.body.count <= 50_000, !email.body.contains("\0") else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "E-posta alıcısı, konusu veya içeriği geçersiz."))
            }
        case .createReminder:
            guard case .reminder(let reminder) = request.payload,
                  isSafeText(reminder.title, maxLength: 300),
                  reminder.notes.map({ $0.count <= 4_000 && !$0.contains("\0") }) ?? true,
                  reminder.listName.map({ isSafeText($0, maxLength: 200) }) ?? true else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Hatırlatıcı bilgileri geçersiz."))
            }
        case .completeReminder:
            guard case .completeReminder(let payload) = request.payload,
                  !payload.identifier.isEmpty, payload.identifier.count <= 300 else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Hatırlatıcı kimliği geçersiz."))
            }
        case .readDesktopFile:
            guard case .fileName(let filename) = request.payload, isValidDesktopFilename(filename) else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Okunacak dosya adı geçersiz."))
            }
        case .moveDesktopFile, .renameDesktopFile:
            guard case .fileMove(let move) = request.payload,
                  isValidDesktopFilename(move.source), isValidDesktopFilename(move.destination),
                  move.source != move.destination else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Kaynak veya hedef dosya adı geçersiz."))
            }
        case .saveArtifact:
            guard case .artifactFile(let artifact) = request.payload,
                  isValidDesktopFilename(artifact.filename),
                  isValidArtifactDirectory(artifact.destinationDirectory),
                  artifact.artifactID.range(of: "^[0-9a-f-]{20,128}$", options: .regularExpression) != nil,
                  artifact.mimeType.count <= 160, !artifact.mimeType.contains(where: { $0.isWhitespace || $0 == "\0" }),
                  artifact.byteCount.map({ $0 > 0 && $0 <= 25 * 1024 * 1024 }) ?? true,
                  artifact.sha256.map({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) ?? true,
                  isAllowedArtifactURL(artifact.downloadURL) else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Artifact kaydetme isteği geçersiz."))
            }
        case .readDocument:
            guard case .fileName(let filename) = request.payload, isValidDesktopFilename(filename) else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Okunacak belge adı geçersiz."))
            }
        case .editDocument:
            guard case .document(let document) = request.payload,
                  isValidDesktopFilename(document.filename),
                  document.content.count > 0, document.content.count <= 500_000 else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Belge düzenleme isteği geçersiz."))
            }
        case .listFiles, .readFile:
            guard case .fileOperation(let operation) = request.payload,
                  isValidLocalPath(operation.path),
                  operation.page >= 0, operation.page <= 10_000,
                  operation.pageSize > 0, operation.pageSize <= 500 else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Dosya yolu veya listeleme aralığı geçersiz."))
            }
        case .sendFileToPhone:
            guard case .fileOperation(let operation) = request.payload,
                  isValidLocalPath(operation.path) || isValidWindowsLocalPath(operation.path) else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Dosya yolu geçersiz."))
            }
        case .searchFiles:
            guard case .fileSearch(let search) = request.payload,
                  search.query.isEmpty || isSafeText(search.query, maxLength: 120),
                  !search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || search.hasFilter || search.survey == true,
                  (search.alternatives ?? []).count <= FileSearchPayload.maxAlternatives,
                  (search.alternatives ?? []).allSatisfy({ isSafeText($0, maxLength: 60) }),
                  search.survey != true || search.everywhere != true,
                  search.cursor.map({ UUID(uuidString: $0) != nil || $0.range(of: #"^o:\d{1,5}$"#, options: .regularExpression) != nil }) ?? true,
                  search.folder.map({ isValidLocalPath($0) || isValidWindowsLocalPath($0) }) ?? true,
                  search.kind.map({ FileSearchPayload.kinds.contains($0) }) ?? true,
                  search.modifiedWithinDays.map({ (1...3_650).contains($0) }) ?? true,
                  search.sort.map({ FileSearchPayload.sorts.contains($0) }) ?? true else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Dosya arama isteği geçersiz."))
            }
        case .writeFile:
            guard case .fileOperation(let operation) = request.payload,
                  isValidLocalPath(operation.path),
                  let content = operation.content,
                  content.count <= 500_000, !content.contains("\0") else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Dosya yazma isteği geçersiz."))
            }
        case .grantAgentAccess:
            guard case .agentGrant(let grant) = request.payload,
                  (0...AgentGrantPayload.maxMinutes).contains(grant.minutes),
                  grant.folders.count <= AgentGrantPayload.maxFolders,
                  grant.minutes == 0 || !grant.folders.isEmpty,
                  grant.folders.allSatisfy(isValidLocalPath),
                  grant.label.count <= 160, !grant.label.contains(where: { $0.isNewline || $0 == "\0" }) else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Görev izni geçersiz: en çok \(AgentGrantPayload.maxMinutes) dakika, \(AgentGrantPayload.maxFolders) klasör."))
            }
        case .runFilePlan:
            guard case .filePlan(let plan) = request.payload, filePlanError(plan) == nil else {
                return RovaError(code: "INVALID_PAYLOAD", message: filePlanErrorMessage(request.payload))
            }
        case .convertFile:
            // The destination is optional (the PDF lands next to the source); when given it must be a .pdf path.
            guard case .fileOperation(let operation) = request.payload,
                  isValidLocalPath(operation.path),
                  RovaFileConversion.canConvert(path: operation.path),
                  operation.destination.map({ isValidLocalPath($0) && $0.lowercased().hasSuffix(".pdf") && $0 != operation.path }) ?? true else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Bu dosya PDF'e çevrilemez veya yol geçersiz."))
            }
        case .moveFile, .copyFile:
            guard case .fileOperation(let operation) = request.payload,
                  isValidLocalPath(operation.path),
                  let destination = operation.destination,
                  isValidLocalPath(destination),
                  operation.path != destination else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Kaynak veya hedef dosya yolu geçersiz."))
            }
        case .deleteFile:
            guard case .fileOperation(let operation) = request.payload,
                  isValidLocalPath(operation.path) else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Silinecek dosya yolu geçersiz."))
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
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Kod çalıştırma isteği geçersiz."))
            }
        case .captureScreen:
            guard case .screenCapture(let capture) = request.payload,
                  (400...2_400).contains(capture.maxWidth),
                  capture.targetApplication.map({ isSafeText($0, maxLength: 200) }) ?? true else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Ekran görüntüsü ayarları geçersiz."))
            }
        case .runShortcut:
            guard case .shortcut(let shortcut) = request.payload,
                  (1...30).contains(shortcut.timeoutSeconds) else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Shortcut isteği veya zaman aşımı geçersiz."))
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
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Accessibility hedefi veya değeri geçersiz."))
            }
        case .clickScreen:
            guard case .screenClick(let click) = request.payload,
                  (0.0...1.0).contains(click.normalizedX),
                  (0.0...1.0).contains(click.normalizedY),
                  (400...2_400).contains(click.screenshotWidth),
                  (400...2_400).contains(click.screenshotHeight),
                  click.expectedTarget.map({ isSafeText($0, maxLength: 240) }) ?? false else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Ekran tıklaması koordinat veya hedef doğrulamasından geçmedi."))
            }
        case .computerDesktop:
            guard case .computerDesktop(let desktop) = request.payload,
                  UUID(uuidString: desktop.taskId) != nil,
                  desktop.snapshotId.map({ UUID(uuidString: $0) != nil }) ?? true,
                  desktop.targetRef.map(isValidDesktopTargetRef) ?? true,
                  desktop.sourceRef.map(isValidDesktopTargetRef) ?? true,
                  desktop.destinationRef.map(isValidDesktopTargetRef) ?? true,
                  desktop.normalizedX.map({ (0...1).contains($0) }) ?? true,
                  desktop.normalizedY.map({ (0...1).contains($0) }) ?? true,
                  desktop.text.map({ !$0.contains("\0") && $0.count <= 4_000 }) ?? true,
                  desktop.keys.map({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(isAllowedDesktopKey) }) ?? true else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Masaüstü görevi veya hedefi geçersiz."), category: "validation")
            }
            if desktop.action == .runSteps {
                guard desktop.snapshotId == nil, desktop.targetRef == nil, desktop.sourceRef == nil,
                      desktop.destinationRef == nil, desktop.normalizedX == nil, desktop.normalizedY == nil,
                      desktop.direction == nil, desktop.amount == nil, desktop.text == nil, desktop.keys == nil,
                      let steps = desktop.steps, (1...8).contains(steps.count), steps.allSatisfy(isValidDesktopStep) else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Toplu masaüstü adımları geçersiz."), category: "validation")
                }
                break
            }
            guard desktop.steps == nil else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Masaüstü adımları yalnızca runSteps ile kullanılabilir."), category: "validation")
            }
            let hasPoint = desktop.normalizedX != nil && desktop.normalizedY != nil
            let hasTarget = desktop.targetRef != nil
            switch desktop.action {
            case .observe, .cancel:
                guard desktop.targetRef == nil, desktop.sourceRef == nil, desktop.destinationRef == nil,
                      desktop.normalizedX == nil, desktop.normalizedY == nil, desktop.direction == nil,
                      desktop.amount == nil, desktop.text == nil, desktop.keys == nil else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Bu masaüstü eylemi ek parametre kabul etmiyor."), category: "validation")
                }
            case .move, .click, .doubleClick, .rightClick:
                guard hasTarget != hasPoint, desktop.sourceRef == nil, desktop.destinationRef == nil,
                      desktop.direction == nil, desktop.amount == nil, desktop.text == nil, desktop.keys == nil else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Masaüstü hedefi tek bir referans veya koordinat olmalıdır."), category: "validation")
                }
            case .scroll:
                guard desktop.direction == "up" || desktop.direction == "down",
                      desktop.amount.map({ (1...5).contains($0) }) ?? true,
                      desktop.sourceRef == nil, desktop.destinationRef == nil,
                      desktop.normalizedX == nil, desktop.normalizedY == nil,
                      desktop.text == nil, desktop.keys == nil else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Kaydırma yönü veya miktarı geçersiz."), category: "validation")
                }
            case .dragDrop:
                guard desktop.sourceRef != nil, desktop.destinationRef != nil,
                      desktop.targetRef == nil, desktop.normalizedX == nil, desktop.normalizedY == nil,
                      desktop.direction == nil, desktop.amount == nil, desktop.text == nil, desktop.keys == nil else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Sürükleme için kaynak ve hedef referansı gerekli."), category: "validation")
                }
            case .type:
                guard hasTarget, desktop.text != nil, desktop.sourceRef == nil, desktop.destinationRef == nil,
                      desktop.normalizedX == nil, desktop.normalizedY == nil, desktop.direction == nil,
                      desktop.amount == nil, desktop.keys == nil else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Yazma eylemi için güvenli hedef ve metin gerekli."), category: "validation")
                }
            case .hotkey:
                guard desktop.keys != nil, desktop.targetRef == nil, desktop.sourceRef == nil, desktop.destinationRef == nil,
                      desktop.normalizedX == nil, desktop.normalizedY == nil, desktop.direction == nil,
                      desktop.amount == nil, desktop.text == nil else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Klavye kısayolu geçersiz."), category: "validation")
                }
            case .wait:
                guard desktop.amount.map({ (50...5_000).contains($0) }) == true,
                      desktop.targetRef == nil, desktop.sourceRef == nil, desktop.destinationRef == nil,
                      desktop.normalizedX == nil, desktop.normalizedY == nil, desktop.direction == nil,
                      desktop.text == nil, desktop.keys == nil else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Bekleme süresi geçersiz."), category: "validation")
                }
            case .runSteps:
                break
            }
        case .computerBrowser:
            guard case .computerBrowser(let browser) = request.payload,
                  UUID(uuidString: browser.taskId) != nil,
                  ["navigate", "observe", "observe_diff", "read", "click", "fill", "select", "press", "scroll", "back", "submit", "run_steps", "handoff"].contains(browser.action),
                  browser.submit == nil || browser.action == "fill",
                  browser.key == nil || browser.action == "press",
                  browser.offset == nil || (browser.action == "read" && (0...2_000_000).contains(browser.offset!)) else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Tarayıcı görevi veya eylemi geçersiz."), category: "validation")
            }
            if browser.action == "run_steps" {
                guard browser.url == nil, browser.targetRef == nil, browser.targetBy == nil, browser.target == nil,
                      browser.role == nil, browser.value == nil, browser.direction == nil, browser.scrollAmount == nil,
                      browser.submit == nil, browser.key == nil, browser.offset == nil,
                      let steps = browser.steps, (1...8).contains(steps.count), steps.allSatisfy(isValidBrowserStep) else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Toplu tarayıcı adımları geçersiz."), category: "validation")
                }
                break
            }
            if browser.action == "handoff" {
                guard browser.url.map(isAllowedBrowserURL) == true, browser.targetRef == nil, browser.targetBy == nil,
                      browser.target == nil, browser.role == nil, browser.value == nil, browser.direction == nil,
                      browser.scrollAmount == nil, browser.submit == nil, browser.key == nil, browser.offset == nil else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Canlı tarayıcı devri geçersiz."), category: "validation")
                }
            }
            guard browser.steps == nil else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Tarayıcı adımları yalnızca run_steps ile kullanılabilir."), category: "validation")
            }
            let validRef = browser.targetRef.map {
                isValidBrowserTargetRef($0)
            } ?? false
            let legacyTarget = ["role", "label", "placeholder"].contains(browser.targetBy ?? "")
                && browser.target.map({ isSafeText($0, maxLength: 240) }) == true
                && (browser.targetBy != "role" || ["button", "link", "textbox", "searchbox", "checkbox", "radio", "combobox", "option", "tab", "menuitem", "heading"].contains(browser.role ?? ""))
                && (browser.targetBy == "role" || browser.role == nil)
            // targetRef is the current protocol. Ignore redundant legacy locator metadata when a
            // valid ref is present so mixed-version clients cannot reject an otherwise safe target.
            let hasTarget = validRef || (!validRef && legacyTarget)
            let noTarget = browser.targetRef == nil && browser.targetBy == nil && browser.target == nil && browser.role == nil
            let noValue = browser.value == nil
            let noDirection = browser.direction == nil
            let noScrollAmount = browser.scrollAmount == nil
            switch browser.action {
            case "navigate":
                guard let url = browser.url, isAllowedBrowserURL(url), noTarget, noValue, noDirection, noScrollAmount else {
                    return RovaError(code: "BROWSER_URL_BLOCKED", message: String(localized: "Yalnızca herkese açık http/https adresleri açılabilir."), category: "permission")
                }
            case "read":
                guard browser.url == nil, noTarget, noValue, noDirection, noScrollAmount else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Sayfa okuma ek parametre kabul etmiyor."), category: "validation")
                }
            case "press":
                guard browser.url == nil, noTarget, noValue, noDirection, noScrollAmount,
                      ["Enter", "Escape", "Tab", "ArrowDown", "ArrowUp"].contains(browser.key ?? "") else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Tuş desteklenmiyor."), category: "validation")
                }
            case "observe", "observe_diff", "back":
                guard browser.url == nil, noTarget, noValue, noDirection, noScrollAmount else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Sayfa gözlemi ek parametre kabul etmiyor."), category: "validation")
                }
            case "scroll":
                guard browser.url == nil, noTarget, noValue,
                      browser.direction == "up" || browser.direction == "down",
                      browser.scrollAmount.map({ (1...3).contains($0) }) ?? true else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Kaydırma yönü geçersiz."), category: "validation")
                }
            case "click", "fill", "select", "submit":
                guard browser.url == nil,
                      hasTarget,
                      browser.value.map({ $0.count <= 2_000 && !$0.contains("\0") }) ?? true,
                      !["fill", "select"].contains(browser.action) || browser.value != nil,
                      ["fill", "select"].contains(browser.action) || noValue,
                      browser.action != "submit" || validRef || (browser.targetBy == "role" && browser.role == "button"),
                      noDirection, noScrollAmount else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Erişilebilir tarayıcı hedefi veya değeri geçersiz."), category: "validation")
                }
            default:
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Tarayıcı eylemi desteklenmiyor."), category: "validation")
            }
        case .endBrowserTask:
            guard case .browserTask(let task) = request.payload, UUID(uuidString: task.taskId) != nil else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Tarayıcı görevi geçersiz."), category: "validation")
            }
        case .localAnalyze:
            guard case .localAnalysis(let analysis) = request.payload,
                  (1...500).contains(analysis.limit),
                  analysis.variables.map({ !$0.isEmpty && $0.count <= 12 && $0.allSatisfy { $0.range(of: "^[A-Za-z][A-Za-z0-9]{0,31}$", options: .regularExpression) != nil } }) ?? true else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Yerel analiz isteği geçersiz."), category: "validation")
            }
            switch analysis.action {
            case .dependencyStatus:
                guard analysis.path == nil, analysis.query == nil, analysis.expression == nil, analysis.variables == nil else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Bağımlılık denetimi ek parametre kabul etmiyor."), category: "validation")
                }
            case .extractDocument:
                guard analysis.path.map(isValidLocalPath) == true, analysis.query == nil, analysis.expression == nil, analysis.variables == nil else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Belge çıkarımı için geçerli bir yerel dosya yolu gerekli."), category: "validation")
                }
            case .queryData:
                guard analysis.path.map(isValidLocalPath) == true,
                      analysis.query.map(isSafeReadOnlyQuery) == true,
                      analysis.expression == nil, analysis.variables == nil else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Veri sorgusu yalnızca güvenli bir SELECT/WITH sorgusu kabul eder."), category: "validation")
                }
            case .solveSymbolic:
                guard analysis.path == nil, analysis.query == nil,
                      analysis.expression.map(isSafeSymbolicExpression) == true else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Sembolik ifade geçersiz."), category: "validation")
                }
            case .workspaceDiff:
                guard analysis.path.map(isValidLocalPath) == true, analysis.query == nil, analysis.expression == nil, analysis.variables == nil else {
                    return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Çalışma alanı yolu geçersiz."), category: "validation")
                }
            }
        case .fileUtility:
            guard case .fileUtility(let utility) = request.payload, let message = fileUtilityError(utility) else { break }
            return RovaError(code: "INVALID_PAYLOAD", message: message, category: "validation")
        case .systemUtility:
            guard case .systemUtility(let utility) = request.payload else {
                return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Sistem işlemi geçersiz."), category: "validation")
            }
            let valid: Bool
            switch utility.action {
            case .darkMode: valid = ["on", "off", "toggle"].contains(utility.mode ?? "toggle")
            case .arrangeWindows: valid = ["split", "maximize"].contains(utility.mode ?? "")
            case .speak: valid = utility.text.map { isSafeText($0, maxLength: 4_000) && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
            case .topProcesses, .battery: valid = (1...50).contains(utility.limit)
            }
            if !valid { return RovaError(code: "INVALID_PAYLOAD", message: String(localized: "Sistem işlemi için gereken bilgi eksik ya da geçersiz."), category: "validation") }
        }
        return nil
    }

    /// The reason a file chore cannot run as asked, or nil. Each action names the fields it needs; every path is a safe local path.
    public static func fileUtilityError(_ utility: FileUtilityPayload) -> String? {
        guard (1...500).contains(utility.limit) else { return "Sınır 1-500 arasında olmalı." }
        if let path = utility.path, !isValidLocalPath(path) { return String(localized: "Yol güvenli bir yerel yol değil.") }
        if let destination = utility.destination, !isValidLocalPath(destination) { return String(localized: "Hedef yol güvenli bir yerel yol değil.") }
        if let paths = utility.paths, paths.count > 50 || !paths.allSatisfy(isValidLocalPath) { return String(localized: "Dosya listesi geçersiz.") }
        if let name = utility.name, !isSafeText(name, maxLength: 120) { return String(localized: "Ad geçersiz.") }
        if let tags = utility.tags, tags.count > 10 || !tags.allSatisfy({ isSafeText($0, maxLength: 40) && !$0.isEmpty }) { return String(localized: "Etiketler geçersiz.") }
        let hasPath = utility.path != nil
        switch utility.action {
        case .createFolder, .extract, .splitPDF, .compressImage, .findDuplicates, .diskUsage, .reveal, .print, .ocr:
            return hasPath ? nil : String(localized: "Bu işlem için path gerekli.")
        case .archive:
            return hasPath || !(utility.paths ?? []).isEmpty ? nil : String(localized: "Arşivlenecek path ya da paths gerekli.")
        case .mergePDF:
            return (utility.paths?.count ?? 0) >= 2 && utility.destination != nil ? nil : "Birleştirme için en az iki PDF (paths) ve destination gerekli."
        case .recentFiles:
            return nil
        case .restoreFromTrash:
            return utility.name?.isEmpty == false ? nil : "Çöpten geri getirilecek dosyanın adı (name) gerekli."
        case .openWith:
            return hasPath && utility.name?.isEmpty == false ? nil : "Dosya (path) ve uygulama adı (name) gerekli."
        case .setTags:
            return hasPath && utility.tags != nil ? nil : "Dosya (path) ve etiketler (tags) gerekli."
        case .organize:
            return hasPath && ["type", "month"].contains(utility.mode ?? "type") ? nil : "Düzenlenecek klasör (path) gerekli; mode type ya da month olmalı."
        case .moveDocuments:
            return hasPath && utility.destination != nil ? nil : "Kaynak klasör (path) ve hedef klasör (destination) gerekli."
        case .inspect:
            return hasPath ? nil : "Kontrol edilecek dosya yolu (path) gerekli."
        case .batchRename:
            return hasPath && (utility.name?.contains("{n}") ?? false) ? nil : "Klasör (path) ve {n} içeren ad kalıbı (name) gerekli."
        }
    }

    /// File chores that only look (nothing on disk changes).
    public static func fileUtilityIsReadOnly(_ action: FileUtilityAction) -> Bool {
        [.findDuplicates, .diskUsage, .recentFiles, .reveal, .ocr, .inspect].contains(action)
    }

    /// A single path component with no separators or traversal - this is appended directly to
    /// the Desktop folder URL, so it must never be able to escape that directory.
    public static func isValidArtifactDirectory(_ directory: String?) -> Bool {
        guard let directory, !directory.isEmpty else { return true }
        return directory.count <= 500 && !directory.hasPrefix("~")
            && directory.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                isValidDesktopFilename(String($0)) && $0 != "." && $0 != ".."
            }
    }

    public static func isValidDesktopFilename(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 255, trimmed != ".", trimmed != ".." else { return false }
        return !trimmed.contains("/") && !trimmed.contains("\\") && !trimmed.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }

    /// Why a file plan is refused, or nil when it is well formed. Bindings ("$s1") are legal only in a
    /// step's `path`, and only for an earlier step whose result holds files.
    public static func filePlanError(_ plan: FilePlanPayload) -> String? {
        guard (1...FilePlanPayload.maxSteps).contains(plan.steps.count) else { return "Plan 1–\(FilePlanPayload.maxSteps) adım içermeli." }
        var earlier: [String: String] = [:]
        for step in plan.steps {
            guard step.id.range(of: #"^[a-z][a-z0-9]{0,7}$"#, options: .regularExpression) != nil, earlier[step.id] == nil else { return "Adım kimliği geçersiz veya tekrarlanıyor." }
            guard FilePlanPayload.operations.contains(step.op) else { return "Bilinmeyen plan işlemi: \(step.op)." }
            /// "$s1" is the first file of an earlier step; "$s1*" is all of them (up to 20), for move, copy and convert.
            func pathOK(_ value: String?, allowAll: Bool = false) -> Bool {
                guard let value else { return false }
                if value.hasPrefix("$") {
                    let all = value.hasSuffix("*")
                    guard !all || allowAll else { return false }
                    let name = String(value.dropFirst().dropLast(all ? 1 : 0))
                    return earlier[name].map(FilePlanPayload.producesFiles.contains) ?? false
                }
                return isValidLocalPath(value)
            }
            switch step.op {
            case "search":
                guard (step.query ?? "").isEmpty || isSafeText(step.query ?? "", maxLength: 120),
                      !(step.query ?? "").trimmingCharacters(in: .whitespaces).isEmpty || step.kind != nil || step.folder != nil || step.modifiedWithinDays != nil,
                      (step.alternatives ?? []).count <= FileSearchPayload.maxAlternatives,
                      (step.alternatives ?? []).allSatisfy({ isSafeText($0, maxLength: 60) }),
                      step.folder.map({ isValidLocalPath($0) }) ?? true,
                      step.kind.map({ FileSearchPayload.kinds.contains($0) }) ?? true,
                      step.modifiedWithinDays.map({ (1...3_650).contains($0) }) ?? true,
                      step.sort.map({ FileSearchPayload.sorts.contains($0) }) ?? true else { return "Arama adımı geçersiz (\(step.id))." }
            case "list":
                guard let path = step.path, isValidLocalPath(path) else { return String(localized: "Listeleme adımı bir klasör yolu ister (\(step.id)).") }
            case "read":
                guard pathOK(step.path) else { return String(localized: "read adımı geçerli bir dosya yolu ya da önceki adıma bağ ister (\(step.id)).") }
            case "send":
                guard pathOK(step.path), let transfer = step.transferId, UUID(uuidString: transfer) != nil else { return "send adımı bir dosya yolu (ya da bağ) ve aktarım kimliği ister (\(step.id))." }
            case "convert":
                let all = step.path?.hasSuffix("*") ?? false
                guard pathOK(step.path, allowAll: true), step.path.map({ $0.hasPrefix("$") || RovaFileConversion.canConvert(path: $0) }) ?? false,
                      all ? step.destination == nil : (step.destination.map({ isValidLocalPath($0) && $0.lowercased().hasSuffix(".pdf") }) ?? true) else { return "Çevirme adımı geçersiz (\(step.id))." }
            default: // move, copy
                let all = step.path?.hasSuffix("*") ?? false
                guard pathOK(step.path, allowAll: true), let destination = step.destination, isValidLocalPath(destination), step.path != destination,
                      !all || destination.hasSuffix("/") else { return "\(step.op) adımı kaynak ve hedef yol ister; birden çok dosya için hedef bir klasör olmalı, / ile bitmeli (\(step.id))." }
            }
            earlier[step.id] = step.op
        }
        return nil
    }

    private static func filePlanErrorMessage(_ payload: CommandPayload) -> String {
        if case .filePlan(let plan) = payload { return filePlanError(plan) ?? String(localized: "Plan geçersiz.") }
        return String(localized: "Plan isteği geçersiz.")
    }

    private static func isSafeText(_ value: String, maxLength: Int) -> Bool {
        !value.isEmpty && value.count <= maxLength && !value.contains(where: { $0.isNewline || $0 == "\0" })
    }

    private static func isSafeReadOnlyQuery(_ value: String) -> Bool {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 8_000, !query.contains(";"), !query.contains("\0"),
              query.range(of: "^(SELECT|WITH)\\b", options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        return query.range(of: "\\b(ATTACH|COPY|CREATE|DELETE|DROP|EXPORT|IMPORT|INSERT|INSTALL|LOAD|PRAGMA|UPDATE|CALL|READ_[A-Z0-9_]*|[A-Z0-9_]*SCAN|HTTPFS|SQLITE|POSTGRES|GLOB|SECRET)\\b", options: [.regularExpression, .caseInsensitive]) == nil
    }

    private static func isSafeSymbolicExpression(_ value: String) -> Bool {
        let expression = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty, expression.count <= 2_000, !expression.contains("__") else { return false }
        return expression.range(of: "^[A-Za-z0-9+*/^=(), \\t.-]+$", options: .regularExpression) != nil
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
        "sil", String(localized: "kaldır"), "format", String(localized: "sıfırla"), "delete", "remove", "erase", "reset"
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

    public static func signedRequest(id: UUID, type: CommandType, payload: CommandPayload, createdAt: Date = Date(), nonce: String, token: String) -> CommandRequest {
        let unsigned = CommandRequest(id: id, type: type, payload: payload, createdAt: createdAt, signatureVersion: 2, nonce: nonce)
        let signature = signRequest(request: unsigned, token: token)
        return CommandRequest(id: id, type: type, payload: payload, createdAt: createdAt, signatureVersion: 2, createdAtEpochMs: unsigned.createdAtEpochMs, signature: signature, nonce: nonce)
    }

    public static func signRequest(request: CommandRequest, token: String, canonicalPayload: Data? = nil) -> String {
        guard request.signatureVersion == 2,
              let nonce = request.nonce, !nonce.isEmpty, nonce.count <= 200,
              let timestamp = request.createdAtEpochMs,
              let payload = canonicalPayload ?? (try? RovaCanonicalJSON.data(request.payload)) else { return "" }
        let digest = RovaCrypto.sha256Hex(payload)
        let message = "wiqo-command:v2:\(request.id.uuidString.lowercased()):\(request.type.rawValue):\(timestamp):\(nonce):\(digest)"
        return RovaCrypto.hmacSHA256Hex(key: token, message: message)
    }

    /// `canonicalPayload`: the payload as received (RovaCanonicalJSON.data(jsonObject:)); without it the decoded payload is re-encoded, which
    /// fails whenever the sender's build carries a field this build does not know.
    public static func verifyRequestSignature(request: CommandRequest, token: String, canonicalPayload: Data? = nil) -> Bool {
        guard let signature = request.signature, !signature.isEmpty,
              request.signatureVersion == 2,
              let timestamp = request.createdAtEpochMs,
              abs(Date().timeIntervalSince1970 * 1_000 - Double(timestamp)) <= 600_000,
              abs(request.createdAt.timeIntervalSince1970 * 1_000 - Double(timestamp)) < 1_000,
              let nonce = request.nonce, !nonce.isEmpty, nonce.count <= 200 else {
            return false
        }
        let expected = signRequest(request: request, token: token, canonicalPayload: canonicalPayload)
        guard !expected.isEmpty else { return false }
        guard RovaCrypto.constantTimeEquals(signature, expected), requestNonceCache.claim(token: token, nonce: nonce, now: Date()) else { return false }
        return true
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

    private static func isAllowedBrowserURL(_ rawValue: String) -> Bool {
        guard isAllowedURL(rawValue), let components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(),
              components.port == nil || components.port == (scheme == "https" ? 443 : 80),
              host.contains("."), !host.contains(":"),
              host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"), !host.hasSuffix(".internal"),
              host.range(of: "^[0-9.]+$", options: .regularExpression) == nil else { return false }
        return true
    }

    private static func isValidDesktopTargetRef(_ value: String) -> Bool {
        value.range(of: #"^(?:d\d+-t\d+|d-[0-9a-f]{8})$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isValidBrowserTargetRef(_ value: String) -> Bool {
        value.range(of: #"^(?:p\d+-t\d+|b-[0-9a-f]{8})$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isValidDesktopStep(_ step: ComputerDesktopStep) -> Bool {
        guard step.action != .runSteps, step.action != .cancel,
              step.targetRef.map(isValidDesktopTargetRef) ?? true,
              step.sourceRef.map(isValidDesktopTargetRef) ?? true,
              step.destinationRef.map(isValidDesktopTargetRef) ?? true,
              step.normalizedX.map({ (0...1).contains($0) }) ?? true,
              step.normalizedY.map({ (0...1).contains($0) }) ?? true,
              step.text.map({ !$0.contains("\0") && $0.count <= 4_000 }) ?? true,
              step.keys.map({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(isAllowedDesktopKey) }) ?? true else { return false }
        let hasPoint = step.normalizedX != nil && step.normalizedY != nil
        guard (step.normalizedX == nil) == (step.normalizedY == nil) else { return false }
        let hasTarget = step.targetRef != nil
        switch step.action {
        case .observe:
            return step.targetRef == nil && step.sourceRef == nil && step.destinationRef == nil && !hasPoint && step.direction == nil && step.amount == nil && step.text == nil && step.keys == nil
        case .move, .click, .doubleClick, .rightClick:
            return hasTarget != hasPoint && step.sourceRef == nil && step.destinationRef == nil && step.direction == nil && step.amount == nil && step.text == nil && step.keys == nil
        case .scroll:
            return (step.direction == "up" || step.direction == "down") && (step.amount.map({ (1...5).contains($0) }) ?? true) && step.sourceRef == nil && step.destinationRef == nil && !hasPoint && step.text == nil && step.keys == nil
        case .dragDrop:
            return step.sourceRef != nil && step.destinationRef != nil && !hasTarget && !hasPoint && step.direction == nil && step.amount == nil && step.text == nil && step.keys == nil
        case .type:
            return hasTarget && step.text != nil && !hasPoint && step.sourceRef == nil && step.destinationRef == nil && step.direction == nil && step.amount == nil && step.keys == nil
        case .hotkey:
            return step.keys != nil && !hasTarget && !hasPoint && step.sourceRef == nil && step.destinationRef == nil && step.direction == nil && step.amount == nil && step.text == nil
        case .wait:
            return step.amount.map({ (50...5_000).contains($0) }) == true && !hasTarget && !hasPoint && step.sourceRef == nil && step.destinationRef == nil && step.direction == nil && step.text == nil && step.keys == nil
        case .runSteps, .cancel:
            return false
        }
    }

    private static func isValidBrowserStep(_ step: ComputerBrowserStep) -> Bool {
        guard ["navigate", "observe", "observe_diff", "read", "click", "fill", "select", "press", "scroll", "back", "submit"].contains(step.action),
              step.targetRef.map(isValidBrowserTargetRef) ?? true,
              step.submit == nil || step.action == "fill",
              step.key == nil || step.action == "press",
              step.offset == nil || (step.action == "read" && (0...2_000_000).contains(step.offset!)) else { return false }
        let hasRef = step.targetRef.map(isValidBrowserTargetRef) ?? false
        let hasLegacy = ["role", "label", "placeholder"].contains(step.targetBy ?? "")
            && step.target.map({ isSafeText($0, maxLength: 240) }) == true
            && (step.targetBy != "role" || ["button", "link", "textbox", "searchbox", "checkbox", "radio", "combobox", "option", "tab", "menuitem", "heading"].contains(step.role ?? ""))
            && (step.targetBy == "role" || step.role == nil)
        let hasTarget = hasRef || (!hasRef && hasLegacy)
        let noTarget = step.targetRef == nil && step.targetBy == nil && step.target == nil && step.role == nil
        switch step.action {
        case "navigate":
            return step.url.map(isAllowedBrowserURL) == true && noTarget && step.value == nil && step.direction == nil && step.scrollAmount == nil
        case "observe", "observe_diff", "back", "read":
            return step.url == nil && noTarget && step.value == nil && step.direction == nil && step.scrollAmount == nil
        case "press":
            return step.url == nil && noTarget && step.value == nil && step.direction == nil && step.scrollAmount == nil && ["Enter", "Escape", "Tab", "ArrowDown", "ArrowUp"].contains(step.key ?? "")
        case "scroll":
            return step.url == nil && noTarget && step.value == nil && (step.direction == "up" || step.direction == "down") && (step.scrollAmount.map({ (1...3).contains($0) }) ?? true)
        case "click", "submit":
            return step.url == nil && hasTarget && step.value == nil && step.direction == nil && step.scrollAmount == nil && (step.action != "submit" || hasRef || (step.targetBy == "role" && step.role == "button"))
        case "fill", "select":
            return step.url == nil && hasTarget && step.value.map({ $0.count <= 2_000 && !$0.contains("\0") }) == true && step.direction == nil && step.scrollAmount == nil
        default:
            return false
        }
    }

    private static func isAllowedDesktopKey(_ value: String) -> Bool {
        ["command", "control", "option", "alt", "shift", "a", "c", "v", "x", "z", "f", "enter", "escape", "tab", "arrowup", "arrowdown", "arrowleft", "arrowright"].contains(value.lowercased())
    }

    public static func isAllowedArtifactURL(_ rawValue: String) -> Bool {
        guard isAllowedURL(rawValue), let url = URLComponents(string: rawValue),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              ["api.wiqoai.com", "84-247-172-213.sslip.io"].contains(host),
              url.port == nil || url.port == 443,
              url.query == nil, url.fragment == nil else { return false }
        return url.path.range(
            of: #"^/copilot/artifacts/[0-9a-f-]{20,128}$"#,
            options: .caseInsensitive.union(.regularExpression)
        ) != nil
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
        case .copyFile, .convertFile: return "device.files.copy"
        case .runFilePlan, .grantAgentAccess: return "device.files.list"
        case .deleteFile: return "device.files.delete"
        case .saveArtifact: return "artifact.save"
        case .readDocument: return "document.read"
        case .editDocument: return "document.edit"
        case .executeCode: return "device.code.execute"
        case .captureScreen: return "device.screen.capture"
        case .runShortcut: return "device.shortcut.run"
        case .controlUIElement: return "device.ui.control"
        case .clickScreen: return "device.screen.click"
        case .computerDesktop: return "device.desktop.control"
        case .listRunningApplications: return "device.app.list"
        case .computerBrowser, .endBrowserTask: return "device.browser.control"
        case .localAnalyze: return "local.analysis"
        case .fileUtility: return "device.files.utility"
        case .systemUtility: return "device.system.utility"
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
             .editDocument, .writeFile, .moveFile, .copyFile, .convertFile, .runFilePlan, .grantAgentAccess, .deleteFile, .executeCode,
             .clickScreen, .runShortcut:
            return true
        case .controlApplication:
            guard case .applicationControl(let application) = payload else { return true }
            return application.force
        case .controlUIElement:
            guard case .uiElement(let element) = payload else { return true }
            return RovaValidation.uiElementRequiresUserPresence(element)
        case .computerBrowser:
            guard case .computerBrowser(let browser) = payload else { return true }
            if browser.action == "handoff" { return false }
            if browser.action == "run_steps" {
                return browser.steps?.contains(where: { $0.action == "submit" }) == true
                    && browser.interactionAccessGranted != true
            }
            return browser.action == "submit" && browser.interactionAccessGranted != true
        case .computerDesktop:
            return false
        case .localAnalyze:
            return false
        case .fileUtility:
            // Moving many files at once or putting paper through a printer is a decision the person makes.
            guard case .fileUtility(let utility) = payload else { return true }
            return [.organize, .batchRename, .moveDocuments, .print].contains(utility.action)
        default:
            return false
        }
    }

    /// `autoReadOwnFolders` is the person's own switch (the phone's settings): finding, listing and
    /// reading files inside Desktop, Documents and Downloads then needs no approval. Anything that
    /// writes, moves, deletes or sends a file, and every path outside those folders, still asks.
    public static func requiresUserPresence(type: CommandType, payload: CommandPayload, autoReadOwnFolders: Bool = false) -> Bool {
        if isDestructive(type: type, payload: payload) { return true }
        if autoReadOwnFolders, RovaOwnFolders.isAutoReadable(type: type, payload: payload) { return false }
        switch type {
        case .saveTextFile, .readDocument, .editDocument, .saveArtifact,
             .listFiles, .searchFiles, .readFile, .sendFileToPhone, .writeFile, .moveFile, .copyFile, .convertFile, .deleteFile,
             .executeCode, .captureScreen, .controlUIElement, .clickScreen,
             .controlApplication, .getClipboardText, .getClipboardHistory:
            return true
        case .computerDesktop:
            guard case .computerDesktop(let desktop) = payload else { return true }
            return desktop.action == .cancel ? false : desktop.accessGranted != true
        case .computerBrowser:
            guard case .computerBrowser(let browser) = payload else { return true }
            if browser.action == "run_steps" {
                let actions = Set((browser.steps ?? []).map(\.action))
                let readsContent = !actions.isDisjoint(with: ["navigate", "observe", "observe_diff", "read", "back", "scroll"])
                let interacts = !actions.isDisjoint(with: ["navigate", "click", "fill", "select", "press", "scroll", "back", "submit"])
                return (readsContent && browser.contentAccessGranted != true)
                    || (interacts && browser.interactionAccessGranted != true)
            }
            if ["navigate", "observe", "observe_diff", "read", "back", "scroll"].contains(browser.action),
               browser.contentAccessGranted != true { return true }
            if ["navigate", "click", "fill", "select", "press", "scroll", "back", "submit"].contains(browser.action) {
                return browser.interactionAccessGranted != true
            }
            return false
        case .localAnalyze:
            guard case .localAnalysis(let analysis) = payload else { return true }
            return analysis.action != .dependencyStatus && analysis.action != .solveSymbolic
        case .fileUtility:
            guard case .fileUtility(let utility) = payload else { return true }
            if utility.action == .reveal || utility.action == .recentFiles { return false }
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
        case .readDocument, .listFiles, .searchFiles, .readFile, .sendFileToPhone, .captureScreen, .controlUIElement, .clickScreen, .computerDesktop, .computerBrowser, .endBrowserTask, .localAnalyze, .fileUtility:
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
    /// Plans, session folder, file read/write/search, multi-file edits, longer grants.
    public static let featureV2 = "terminal-session-v2"
    /// Reads in the person's own folders without a card, and folder grants of up to 30 days.
    public static let featureV3 = "terminal-session-v3"
    /// Companion-owned undo records for terminal file changes.
    public static let featureV4 = "terminal-session-v4"
    /// Longest grant the phone may sign; the backend offers more than 30 minutes only to v2 Macs, more than 8 hours only to v3.
    public static let maxGrantSeconds = 30 * 24 * 60 * 60
    /// The id of the grant a card-less read runs under (never signed; read mode, one folder, checked by readFolderWithoutGrant).
    public static let readWithoutGrantId = "read-without-grant"
    /// The folder name the backend sends for a read that names no folder ("pmset -g batt", "df -h"): an empty scratch folder of this
    /// companion, so a relative path in the command can reach nothing of the person's.
    public static let scratchFolder = "@scratch"

    /// The scratch folder itself, created on first use.
    public static func scratchDirectory() -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("wiqo-terminal-scratch")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func grantMessage(grantId: String, rootDirectory: String, mode: String, expiresAt: Int) -> String {
        "wiqo-terminal-grant:v1:\(grantId.lowercased()):\(rootDirectory):\(mode):\(expiresAt)"
    }

    public static func signGrant(grantId: String, rootDirectory: String, mode: String, expiresAt: Int, token: String) -> String {
        RovaCrypto.hmacSHA256Hex(key: token, message: grantMessage(grantId: grantId, rootDirectory: rootDirectory, mode: mode, expiresAt: expiresAt))
    }

    public static func verifyGrant(grantId: String, rootDirectory: String, mode: String, expiresAt: Int, signature: String, token: String, now: Date = Date()) -> Bool {
        guard mode == "read" || mode == "full", expiresAt > Int(now.timeIntervalSince1970), expiresAt <= Int(now.timeIntervalSince1970) + maxGrantSeconds else { return false }
        let expected = signGrant(grantId: grantId, rootDirectory: rootDirectory, mode: mode, expiresAt: expiresAt, token: token)
        return RovaCrypto.constantTimeEquals(signature.lowercased(), expected)
    }

    private static let readOnlyPrograms: Set<String> = [
        "ls", "pwd", "cat", "head", "tail", "wc", "grep", "egrep", "rg", "find", "file", "stat", "du", "df", "tree", "which", "whereis",
        "type", "echo", "date", "uname", "sw_vers", "whoami", "ps", "sort", "uniq", "cut", "jq", "diff", "cmp", "basename", "dirname",
        "realpath", "md5", "shasum", "lsof", "uptime", "hostname", "xcodebuild", "system_profiler", "cd", "mdls",
        "ifconfig", "vm_stat", "ioreg", "ping", "nslookup", "dig", "host", "pbpaste"
    ]
    private static let versionOnlyPrograms: Set<String> = ["node", "npm", "npx", "python", "python3", "pip", "pip3", "brew", "java", "swift", "go", "cargo", "ruby", "git", "docker", "pnpm", "yarn"]
    private static let gitReadSubcommands: Set<String> = ["status", "log", "diff", "show", "branch", "remote", "rev-parse", "ls-files", "blame", "describe", "tag", "shortlog", "config"]
    private static let packageReadSubcommands: [String: Set<String>] = [
        "npm": ["ls", "list", "outdated", "view"], "pnpm": ["ls", "list", "outdated"], "yarn": ["list", "outdated", "info"],
        "pip": ["list", "show", "freeze"], "pip3": ["list", "show", "freeze"], "brew": ["list", "info", "outdated", "search"],
        "docker": ["ps", "images", "version", "info"],
        // System readings: read-only only with these first arguments (`defaults read` is, `defaults write` is not).
        "pmset": ["-g"], "defaults": ["read", "domains", "read-type", "find"], "scutil": ["--get", "--dns", "--proxy", "--nwi"],
        "ipconfig": ["getifaddr", "getpacket", "ifcount", "getoption", "getsummary"], "sips": ["-g"], "plutil": ["-p", "-lint"],
        "top": ["-l"], "sysctl": ["-n", "-a"],
        "networksetup": ["-listallnetworkservices", "-listallhardwareports", "-getinfo", "-getairportnetwork", "-getairportpower", "-getdnsservers", "-getwebproxy", "-getcomputername"]
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
        // AppleScript runs under a full grant like any command; sending mail or messages as the person and asking for admin rights do not.
        #"\bosascript\b[\s\S]*(application\s+\"(Mail|Messages)\"|administrator\s+privileges)"#,
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
        // Read grants accept relative paths only. Full shell access cannot be a filesystem
        // sandbox; this at least prevents inspection commands from naming an outside path.
        if withoutStderrMerge.contains("..") || withoutStderrMerge.contains("~") || withoutStderrMerge.contains("$") || matches(#"(^|[\s"'=])/"#, withoutStderrMerge) { return false }
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
            // Spotlight content search: read-only only when kept to the session folder.
            if program == "mdfind" { return rest.contains("-onlyin") }
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

    /// The folder a read may run in without a card: inside the home folder, under a folder of the person's own (not the home itself, not
    /// Library, not a hidden folder such as .ssh or .aws). The read stays inside this folder, never above it.
    public static func readFolderWithoutGrant(_ path: String, home: String = NSHomeDirectory()) -> String? {
        if path == scratchFolder { return scratchDirectory() }
        let resolvedHome = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
        guard let directory = resolveDirectory(path, home: home), directory != resolvedHome, isWithin(directory, root: resolvedHome) else { return nil }
        let first = directory.dropFirst(resolvedHome.count + 1).split(separator: "/").first.map(String.init) ?? ""
        guard !first.isEmpty, !first.hasPrefix("."), first != "Library" else { return nil }
        return directory
    }

    public static func isWithin(_ directory: String, root: String) -> Bool {
        directory == root || directory.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// `~/x` is the user's home, `/x` is absolute, anything else is relative to the working folder.
    static func absoluteFilePath(_ path: String, workingDirectory: String, home: String = NSHomeDirectory()) -> String {
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path.hasPrefix("/") ? path : URL(fileURLWithPath: workingDirectory).appendingPathComponent(path).path
    }

    /// A full-access session's approved folder that does not exist yet ("~/Desktop/deneme'de
    /// dosya oluştur"): it may be created when it is strictly inside the home folder.
    public static func creatableDirectory(_ directory: String, root: String, mode: String, home: String = NSHomeDirectory()) -> Bool {
        let resolvedHome = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
        return mode == "full" && isWithin(directory, root: root) && directory != resolvedHome
            && isWithin(directory, root: resolvedHome) && !FileManager.default.fileExists(atPath: directory)
    }

    /// Resolve an existing file and reject symlinks at each path component. Callers must already
    /// have verified the time-limited grant and directory boundary before applying a patch.
    public static func resolveExistingFile(_ path: String, workingDirectory: String, root: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0"), !trimmed.split(separator: "/").contains("..") else { return nil }
        let candidate = absoluteFilePath(trimmed, workingDirectory: workingDirectory)
        let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
        guard isWithin(standardized, root: root) else { return nil }
        let components = standardized.split(separator: "/").map(String.init)
        var current = ""
        for component in components {
            current += "/" + component
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: current, isDirectory: &isDirectory) else { return nil }
            guard (try? URL(fileURLWithPath: current).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        return isWithin(resolved, root: root) ? resolved : nil
    }

    /// A file to create or overwrite inside the grant: its parent folder must exist inside `root`
    /// with no symlink on the way, and an existing target must be a regular file, not a symlink.
    public static func resolveWritableFile(_ path: String, workingDirectory: String, root: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0"), !trimmed.hasSuffix("/"), !trimmed.split(separator: "/").contains("..") else { return nil }
        let candidate = absoluteFilePath(trimmed, workingDirectory: workingDirectory)
        let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
        guard isWithin(standardized, root: root), standardized != root else { return nil }
        let parent = (standardized as NSString).deletingLastPathComponent
        var current = ""
        for component in parent.split(separator: "/").map(String.init) {
            current += "/" + component
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: current, isDirectory: &isDirectory), isDirectory.boolValue,
                  (try? URL(fileURLWithPath: current).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        }
        if FileManager.default.fileExists(atPath: standardized) {
            let values = try? URL(fileURLWithPath: standardized).resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values?.isSymbolicLink != true, values?.isRegularFile == true else { return nil }
        }
        let resolvedParent = URL(fileURLWithPath: parent).resolvingSymlinksInPath().path
        return isWithin(resolvedParent, root: root) ? standardized : nil
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

/// The folders a person's own files live in, and the names that are never read without asking.
/// Paths are compared as text: `~/Downloads/x.pdf`, `/Users/ada/Downloads/x.pdf` and
/// `C:\Users\ada\Downloads\x.pdf` are all "Downloads". (The companions resolve symlinks and
/// re-check what they open; this only decides whether the phone asks first.)
public enum RovaOwnFolders {
    public static let names: Set<String> = ["desktop", "documents", "downloads"]

    /// Key material and credential stores. Never auto-read, and left out of automatic searches.
    private static let sensitiveNames: [String] = [
        ".ssh", ".gnupg", ".aws", ".kube", ".docker", ".netrc", ".npmrc", ".pypirc", ".git-credentials",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "keychain", "keychains", "wallet", "1password", "bitwarden", "lastpass"
    ]
    private static let sensitiveExtensions: Set<String> = ["pem", "key", "p12", "p8", "pfx", "kdbx", "keystore", "jks", "ovpn", "gpg", "asc", "ppk"]
    private static let sensitiveWords: [String] = ["password", "parola", "sifre", String(localized: "şifre"), "passwd", "credential", "secret", "recovery code", "backup code", "seed phrase", "private key"]

    private static func components(_ raw: String) -> [String]? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("~/") {
            path.removeFirst(2)
        } else if path.hasPrefix("/Users/") {
            let parts = path.dropFirst("/Users/".count).split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 1 else { return nil }
            path = parts.dropFirst().joined(separator: "/")
        } else if let range = path.range(of: #"^[A-Za-z]:/Users/[^/]+/"#, options: .regularExpression) {
            path.removeSubrange(range)
        } else {
            return nil
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return parts.contains("..") || parts.contains(".") ? nil : parts
    }

    /// The path is (a place inside) Desktop, Documents or Downloads.
    public static func isOwnFolder(_ raw: String) -> Bool {
        guard let parts = components(raw), let first = parts.first?.lowercased() else { return false }
        return names.contains(first)
    }

    public static func isSensitive(_ raw: String) -> Bool {
        let lowered = raw.lowercased().replacingOccurrences(of: "\\", with: "/")
        let parts = lowered.split(separator: "/").map(String.init)
        if parts.contains(where: { part in sensitiveNames.contains(where: { part == $0 || part.hasPrefix($0 + ".") }) }) { return true }
        if let last = parts.last, let dot = last.lastIndex(of: "."), sensitiveExtensions.contains(String(last[last.index(after: dot)...])) { return true }
        if let last = parts.last, last == ".env" || last.hasPrefix(".env.") { return true }
        return sensitiveWords.contains(where: { lowered.contains($0) })
    }

    /// Reversible file work inside the own folders that ONE "bu görev boyunca" approval may cover: a new folder, a copy, a move, a rename, a PDF,
    /// a zip, a tidy-up. Never a delete, never an overwrite, nothing that leaves the Mac (send, print), nothing outside Desktop, Documents and
    /// Downloads, no sensitive name - and it holds even when the task has read outside text, because none of these can hurt more than a move can undo.
    public static func isTaskWritable(type: CommandType, payload: CommandPayload) -> Bool {
        func safe(_ path: String?) -> Bool { path.map { isOwnFolder($0) && !isSensitive($0) } ?? true }
        switch (type, payload) {
        case (.moveFile, .fileOperation(let operation)), (.copyFile, .fileOperation(let operation)):
            return !operation.overwrite && operation.destination != nil && safe(operation.path) && safe(operation.destination)
        case (.convertFile, .fileOperation(let operation)):
            return !operation.overwrite && safe(operation.path) && safe(operation.destination)
        case (.moveDesktopFile, .fileMove(let move)), (.renameDesktopFile, .fileMove(let move)):
            return !isSensitive(move.source) && !isSensitive(move.destination)
        case (.saveArtifact, .artifactFile(let artifact)):
            return !artifact.overwrite && !isSensitive(artifact.filename) && (artifact.destinationDirectory.map { !isSensitive($0) } ?? true)
        case (.fileUtility, .fileUtility(let utility)):
            guard [.createFolder, .archive, .extract, .mergePDF, .splitPDF, .compressImage, .organize, .batchRename, .moveDocuments, .setTags, .restoreFromTrash, .openWith, .reveal].contains(utility.action) else { return false }
            let paths = [utility.path, utility.destination].compactMap { $0 } + (utility.paths ?? [])
            if utility.action == .moveDocuments && (utility.path == nil || utility.destination == nil) { return false }
            guard paths.allSatisfy({ isOwnFolder($0) && !isSensitive($0) }) else { return false }
            // Restoring from the Trash names a file, not a path; everything else works on paths.
            return utility.action == .restoreFromTrash || !paths.isEmpty
        default:
            return false
        }
    }

    /// Finding, listing and reading inside the own folders, when the name is not sensitive.
    public static func isAutoReadable(type: CommandType, payload: CommandPayload) -> Bool {
        switch (type, payload) {
        case (.listFiles, .fileOperation(let operation)), (.readFile, .fileOperation(let operation)):
            return isOwnFolder(operation.path) && !isSensitive(operation.path)
        case (.readDocument, .fileName(let name)):
            return !isSensitive(name)
        case (.fileUtility, .fileUtility(let utility)):
            guard RovaValidation.fileUtilityIsReadOnly(utility.action), let path = utility.path else { return false }
            return isOwnFolder(path) && !isSensitive(path)
        case (.searchFiles, .fileSearch(let search)):
            if search.everywhere == true { return false }
            guard let folder = search.folder else { return true }
            return isOwnFolder(folder) && !isSensitive(folder)
        default:
            return false
        }
    }
}

/// Which files can be turned into a PDF, and by what. Shared so the phone can refuse a request the
/// Mac could never fulfil, and the Mac picks the engine by the same table.
public enum RovaFileConversion {
    public enum Engine: Equatable, Sendable {
        /// `sips`: images.
        case image
        /// `cupsfilter`: plain text and PDFs.
        case text
        /// LibreOffice when installed, else Pages, Numbers or Keynote driven by AppleScript.
        case office(preferredApp: String)
    }

    private static let images: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp"]
    private static let text: Set<String> = ["txt", "md", "log"]
    private static let writer: Set<String> = ["docx", "doc", "rtf", "odt", "pages", "html", "htm"]
    private static let sheet: Set<String> = ["xlsx", "xls", "csv", "ods", "numbers"]
    private static let slides: Set<String> = ["pptx", "ppt", "odp", "key"]

    public static func engine(for path: String) -> Engine? {
        let ext = (path as NSString).pathExtension.lowercased()
        if images.contains(ext) { return .image }
        if text.contains(ext) { return .text }
        if writer.contains(ext) { return .office(preferredApp: "Pages") }
        if sheet.contains(ext) { return .office(preferredApp: "Numbers") }
        if slides.contains(ext) { return .office(preferredApp: "Keynote") }
        return nil
    }

    public static func canConvert(path: String) -> Bool {
        engine(for: path) != nil
    }
}
