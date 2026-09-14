import AppKit
import EventKit
import Foundation
import IOKit
import IOKit.ps

enum MacSystem {
    static let applications: [(ApplicationID, String)] = [
        (.safari, "com.apple.Safari"),
        (.xcode, "com.apple.dt.Xcode"),
        (.terminal, "com.apple.Terminal"),
        (.finder, "com.apple.finder"),
        (.visualStudioCode, "com.microsoft.VSCode"),
        (.mail, "com.apple.mail"),
        (.music, "com.apple.Music"),
        (.messages, "com.apple.MobileSMS"),
        (.notes, "com.apple.Notes"),
        (.systemSettings, "com.apple.systempreferences")
    ]

    static func availableApplications() -> [ApplicationInfo] {
        applications.compactMap { id, bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) == nil ? nil : ApplicationInfo(id: id)
        }
    }

    static func openApplication(_ id: ApplicationID) -> RovaError? {
        guard let bundleID = applications.first(where: { $0.0 == id })?.1,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return RovaError(code: "APPLICATION_NOT_FOUND", message: "Uygulama bu Mac’te bulunamadı.")
        }
        guard NSWorkspace.shared.open(url) else {
            return RovaError(code: "APPLICATION_OPEN_FAILED", message: "Uygulama açılamadı.")
        }
        return nil
    }

    static func openURL(_ rawValue: String) -> RovaError? {
        guard RovaValidation.isAllowedURL(rawValue), let url = URL(string: rawValue), NSWorkspace.shared.open(url) else {
            return RovaError(code: "URL_OPEN_FAILED", message: "URL açılamadı.")
        }
        return nil
    }

    static func lockMac() -> RovaError? {
        // 1. Direct SACLockScreenImmediate call (native loginwindow lock, no synthetic keystroke TCC required)
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW) {
            defer { dlclose(handle) }
            if let sym = dlsym(handle, "SACLockScreenImmediate") {
                typealias LockFunc = @convention(c) () -> Int32
                let lock = unsafeBitCast(sym, to: LockFunc.self)
                if lock() == 0 {
                    return nil
                }
            }
        }
        // 2. Fallback: System Events keystroke
        guard let script = NSAppleScript(source: "tell application \"System Events\" to keystroke \"q\" using {control down, command down}") else {
            return RovaError(code: "LOCK_UNAVAILABLE", message: "Mac kilitleme hazırlanamadı.")
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        guard error == nil else {
            return RovaError(code: "LOCK_PERMISSION_DENIED", message: "Mac kilitleme izni verilmedi.")
        }
        return nil
    }

    static func sleepMac() -> RovaError? {
        guard let script = NSAppleScript(source: "tell application \"Finder\" to sleep") else {
            return RovaError(code: "SLEEP_UNAVAILABLE", message: "Uyku komutu hazırlanamadı.")
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        guard error == nil else {
            return RovaError(code: "SLEEP_FAILED", message: "Mac uyku moduna alınamadı.")
        }
        return nil
    }

    static func displaySleep() -> RovaError? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler")
        guard entry != 0 else {
            return RovaError(code: "DISPLAY_UNAVAILABLE", message: "Ekran yöneticisi bulunamadı.")
        }
        defer { IOObjectRelease(entry) }
        let kr = IORegistryEntrySetCFProperty(entry, "IORequestIdle" as CFString, kCFBooleanTrue)
        guard kr == KERN_SUCCESS else {
            return RovaError(code: "DISPLAY_FAILED", message: "Ekran uyku moduna alınamadı.")
        }
        return nil
    }

    static func setBrightness(_ level: Int) -> RovaError? {
        let clamped = max(0, min(100, level))
        let normalized = Float(clamped) / 100.0
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) else {
            return RovaError(code: "BRIGHTNESS_UNAVAILABLE", message: "Ekran parlaklığı bu Mac'te desteklenmiyor.")
        }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "DisplayServicesSetBrightness") else {
            return RovaError(code: "BRIGHTNESS_UNAVAILABLE", message: "Ekran parlaklığı bu Mac'te desteklenmiyor.")
        }
        typealias SetBrightnessFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let setB = unsafeBitCast(sym, to: SetBrightnessFunc.self)
        let res = setB(CGMainDisplayID(), normalized)
        guard res == 0 else {
            return RovaError(code: "BRIGHTNESS_FAILED", message: "Parlaklık ayarlanamadı. Harici ekranlarda veya bazı Mac modellerinde desteklenmiyor olabilir.")
        }
        return nil
    }

    @MainActor
    static func setClipboardText(_ text: String) -> RovaError? {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            return RovaError(code: "CLIPBOARD_FAILED", message: "Panoya metin yazılamadı.")
        }
        return nil
    }

    static func saveTextFile(_ payload: TextFilePayload) -> RovaError? {
        guard RovaValidation.isValidDesktopFilename(payload.filename) else {
            return RovaError(code: "INVALID_FILENAME", message: "Dosya adı geçersiz.")
        }
        guard let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            return RovaError(code: "DESKTOP_UNAVAILABLE", message: "Masaüstü klasörüne erişilemedi.")
        }
        let fileURL = desktopURL.appendingPathComponent(payload.filename)
        guard isDirectDesktopEntry(fileURL, desktop: desktopURL),
              !FileManager.default.fileExists(atPath: fileURL.path) else {
            return RovaError(code: "FILE_EXISTS", message: "Aynı adlı dosya zaten var; üzerine yazılmadı.")
        }
        do {
            try payload.content.write(to: fileURL, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return RovaError(code: "FILE_WRITE_FAILED", message: "Dosya yazılamadı.")
        }
    }

    static func readDocument(_ filename: String) -> (data: CommandData?, error: RovaError?) {
        let outcome = DocumentEngine.read(filename: filename)
        return (outcome.data.map(CommandData.documentContent), outcome.error)
    }

    static func editDocument(_ payload: DocumentPayload) -> RovaError? {
        DocumentEngine.write(payload)
    }

    /// Downloads a backend-produced artifact over the authenticated Mac channel and commits it
    /// to Desktop only after the complete response has arrived. The URL is allow-listed by the
    /// shared validator, so a model-produced URL cannot turn this into an arbitrary downloader.
    static func saveArtifact(_ payload: ArtifactFilePayload, token: String) async -> RovaError? {
        guard RovaValidation.isAllowedArtifactURL(payload.downloadURL),
              let url = URL(string: payload.downloadURL) else {
            return RovaError(code: "INVALID_ARTIFACT_URL", message: "Artifact indirme adresi güvenli değil.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 45
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return RovaError(code: "ARTIFACT_DOWNLOAD_FAILED", message: "Artifact backend'den indirilemedi.")
            }
            if let contentType = http.value(forHTTPHeaderField: "Content-Type"), contentType.lowercased().hasPrefix("application/json") {
                return RovaError(code: "ARTIFACT_DOWNLOAD_FAILED", message: "Artifact backend'den geçerli bir dosya döndürmedi.")
            }
            if let contentLength = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), contentLength > DocumentEngine.maxFileBytes {
                return RovaError(code: "ARTIFACT_TOO_LARGE", message: "İndirilen dosya desteklenen boyut sınırını aşıyor.")
            }
            var data = Data()
            data.reserveCapacity(min(Int(payload.byteCount ?? DocumentEngine.maxFileBytes), Int(DocumentEngine.maxFileBytes)))
            for try await byte in bytes {
                if data.count >= Int(DocumentEngine.maxFileBytes) {
                    return RovaError(code: "ARTIFACT_TOO_LARGE", message: "İndirilen dosya desteklenen boyut sınırını aşıyor.")
                }
                data.append(byte)
            }
            if let expectedByteCount = payload.byteCount, Int64(data.count) != expectedByteCount {
                return RovaError(code: "ARTIFACT_INTEGRITY_FAILED", message: "İndirilen artifact boyut doğrulamasından geçmedi.")
            }
            if let expectedSHA256 = payload.sha256, RovaCrypto.sha256Hex(data) != expectedSHA256.lowercased() {
                return RovaError(code: "ARTIFACT_INTEGRITY_FAILED", message: "İndirilen artifact bütünlük doğrulamasından geçmedi.")
            }
            return DocumentEngine.commitArtifact(data, filename: payload.filename, overwrite: payload.overwrite)
        } catch is CancellationError {
            return RovaError(code: "CANCELLED", message: "Artifact indirme iptal edildi.")
        } catch {
            return RovaError(code: "ARTIFACT_DOWNLOAD_FAILED", message: "Artifact indirilemedi.")
        }
    }

    @MainActor
    static func sendMessage(_ payload: MessagePayload) -> RovaError? {
        let recipient = appleScriptLiteral(payload.recipient)
        let body = appleScriptLiteral(payload.body)
        let source = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy \(recipient) of targetService
            send \(body) to targetBuddy
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            return RovaError(code: "MESSAGE_UNAVAILABLE", message: "Mesaj gönderme hazırlanamadı.")
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        guard let error else { return nil }
        let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        if number == -1743 {
            return RovaError(code: "MESSAGE_PERMISSION_DENIED", message: "Mac'te Rova için Messages/Otomasyon izni verilmedi.")
        }
        return RovaError(code: "MESSAGE_SEND_FAILED", message: "Mesaj gönderilemedi.")
    }

    @MainActor
    static func listCalendarEvents() async -> (data: CommandData?, error: RovaError?) {
        guard let store = await calendarStore() else {
            return (nil, RovaError(code: "CALENDAR_PERMISSION_DENIED", message: "Takvim erişimi verilmedi."))
        }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: 14, to: start) ?? start.addingTimeInterval(14 * 24 * 60 * 60)
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
            .prefix(100)
            .map(calendarInfo)
        return (.calendarEvents(Array(events)), nil)
    }

    @MainActor
    static func createCalendarEvent(_ payload: CalendarEventPayload) async -> (data: CommandData?, error: RovaError?) {
        guard let store = await calendarStore() else {
            return (nil, RovaError(code: "CALENDAR_PERMISSION_DENIED", message: "Takvim erişimi verilmedi."))
        }
        let calendar: EKCalendar?
        if let name = payload.calendarName, !name.isEmpty {
            calendar = store.calendars(for: .event).first { $0.title == name }
        } else {
            calendar = store.defaultCalendarForNewEvents
        }
        guard let calendar else {
            return (nil, RovaError(code: "CALENDAR_NOT_FOUND", message: "Etkinliğin ekleneceği takvim bulunamadı."))
        }
        let event = EKEvent(eventStore: store)
        event.title = payload.title
        event.startDate = payload.startAt
        event.endDate = payload.endAt
        event.calendar = calendar
        event.notes = payload.notes
        event.location = payload.location
        do {
            try store.save(event, span: .thisEvent)
            return (.calendarEvents([calendarInfo(event)]), nil)
        } catch {
            return (nil, RovaError(code: "CALENDAR_SAVE_FAILED", message: "Takvim etkinliği kaydedilemedi."))
        }
    }

    static func listDesktopFiles() -> (data: CommandData?, error: RovaError?) {
        guard let desktopURL = desktopURL() else {
            return (nil, RovaError(code: "DESKTOP_UNAVAILABLE", message: "Masaüstü klasörüne erişilemedi."))
        }
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: desktopURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
            let files = urls.compactMap { url -> DesktopFileInfo? in
                guard isDirectDesktopEntry(url, desktop: desktopURL) else { return nil }
                guard RovaValidation.isValidDesktopFilename(url.lastPathComponent),
                      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { return nil }
                return DesktopFileInfo(filename: url.lastPathComponent, byteCount: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate, isDirectory: values.isDirectory ?? false)
            }.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
            return (.desktopFiles(Array(files.prefix(100))), nil)
        } catch {
            return (nil, RovaError(code: "DESKTOP_LIST_FAILED", message: "Masaüstü dosyaları listelenemedi."))
        }
    }

    static func readDesktopFile(_ filename: String) -> (data: CommandData?, error: RovaError?) {
        guard let desktop = desktopURL(), let url = safeDesktopURL(filename),
              isDirectDesktopEntry(url, desktop: desktop), FileManager.default.fileExists(atPath: url.path) else {
            return (nil, RovaError(code: "FILE_NOT_FOUND", message: "Masaüstünde bu dosya bulunamadı."))
        }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            guard values.isDirectory != true, values.isRegularFile == true, let size = values.fileSize, size <= 200_000 else {
                return (nil, RovaError(code: "FILE_TOO_LARGE", message: "Yalnızca 200 KB veya daha küçük metin dosyaları okunabilir."))
            }
            let content = try String(contentsOf: url, encoding: .utf8)
            return (.fileContent(DesktopFileContent(filename: filename, content: content)), nil)
        } catch {
            return (nil, RovaError(code: "FILE_READ_FAILED", message: "Dosya okunamadı."))
        }
    }

    static func moveDesktopFile(_ payload: DesktopFileMovePayload) -> RovaError? {
        guard let desktop = desktopURL(),
              let source = safeDesktopURL(payload.source), let destination = safeDesktopURL(payload.destination),
              isDirectDesktopEntry(source, desktop: desktop), isDirectDesktopEntry(destination, desktop: desktop),
              FileManager.default.fileExists(atPath: source.path) else {
            return RovaError(code: "FILE_NOT_FOUND", message: "Kaynak dosya masaüstünde bulunamadı.")
        }
        guard let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]),
              values.isDirectory != true, values.isRegularFile == true else {
            return RovaError(code: "FILE_NOT_REGULAR", message: "Yalnızca normal dosyalar taşınabilir.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return RovaError(code: "FILE_EXISTS", message: "Hedef dosya zaten var; üzerine yazılmadı.")
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return nil
        } catch {
            return RovaError(code: "FILE_MOVE_FAILED", message: "Dosya taşınamadı veya yeniden adlandırılamadı.")
        }
    }

    private static func desktopURL() -> URL? {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    private static func isDirectDesktopEntry(_ url: URL, desktop: URL) -> Bool {
        let resolvedDesktop = desktop.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        return resolvedURL.deletingLastPathComponent().path == resolvedDesktop
    }

    private static func safeDesktopURL(_ filename: String) -> URL? {
        guard RovaValidation.isValidDesktopFilename(filename), let desktop = desktopURL() else { return nil }
        return desktop.appendingPathComponent(filename, isDirectory: false)
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    @MainActor
    private static func calendarStore() async -> EKEventStore? {
        let store = EKEventStore()
        let granted = await withCheckedContinuation { continuation in
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents { granted, _ in continuation.resume(returning: granted) }
            } else {
                store.requestAccess(to: .event) { granted, _ in continuation.resume(returning: granted) }
            }
        }
        return granted ? store : nil
    }

    private static func calendarInfo(_ event: EKEvent) -> CalendarEventInfo {
        CalendarEventInfo(identifier: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "(Başlıksız)", startAt: event.startDate, endAt: event.endDate, calendarName: event.calendar?.title ?? "Takvim", location: event.location)
    }

    @MainActor
    static func quitApplication(_ id: ApplicationID) -> RovaError? {
        guard let bundleID = applications.first(where: { $0.0 == id })?.1 else {
            return RovaError(code: "APPLICATION_NOT_FOUND", message: "Uygulama tanımlanamadı.")
        }
        if id == .finder {
            if let script = NSAppleScript(source: "tell application \"Finder\" to close every window") {
                var error: NSDictionary?
                _ = script.executeAndReturnError(&error)
            }
            return nil
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else {
            return nil
        }
        var terminated = false
        for app in running {
            if app.terminate() {
                terminated = true
            } else if app.forceTerminate() {
                terminated = true
            }
        }
        if !terminated {
            let scriptSource = "tell application id \"\(bundleID)\" to quit"
            if let script = NSAppleScript(source: scriptSource) {
                var error: NSDictionary?
                _ = script.executeAndReturnError(&error)
                if error == nil {
                    terminated = true
                } else if let errorDict = error {
                    let errorNumber = (errorDict[NSAppleScript.errorNumber] as? Int) ?? 0
                    if errorNumber == -1743 {
                        return RovaError(code: "PERMISSION_DENIED", message: "Mac'te Rova için Otomasyon izni verilmedi. Sistem Ayarları > Gizlilik ve Güvenlik > Otomasyon altından izin verin.")
                    }
                }
            }
        }
        if !terminated {
            return RovaError(code: "QUIT_FAILED", message: "Uygulama kapatılamadı. Yanıt vermiyor veya sistem izni gerekiyor.")
        }
        return nil
    }

    static func setVolume(_ level: Int) -> RovaError? {
        let clamped = max(0, min(100, level))
        guard let script = NSAppleScript(source: "set volume output volume \(clamped)") else {
            return RovaError(code: "VOLUME_UNAVAILABLE", message: "Ses ayarı hazırlanamadı.")
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        guard error == nil else {
            return RovaError(code: "VOLUME_FAILED", message: "Ses ayarlanamadı.")
        }
        return nil
    }

    static func toggleMute() -> RovaError? {
        guard let script = NSAppleScript(source: "set volume output muted not (output muted of (get volume settings))") else {
            return RovaError(code: "MUTE_UNAVAILABLE", message: "Sessiz modu hazırlanamadı.")
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        guard error == nil else {
            return RovaError(code: "MUTE_FAILED", message: "Sessiz modu değiştirilemedi.")
        }
        return nil
    }

    /// System-wide media command IDs used by `MRMediaRemoteSendCommand`. These match the
    /// values Control Center's Now Playing widget sends, so they reach whichever app currently
    /// owns Now Playing (Music, Spotify, Safari, Chrome, ...) without needing to know which one.
    private enum MediaRemoteCommand: UInt32 {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    @MainActor
    static func mediaControl(_ action: MediaAction) -> RovaError? {
        let command: MediaRemoteCommand
        switch action {
        case .playPause: command = .togglePlayPause
        case .nextTrack: command = .nextTrack
        case .previousTrack: command = .previousTrack
        }
        if sendMediaRemoteCommand(command) {
            return nil
        }
        // Fall back to the app-specific AppleScript path if MediaRemote is unavailable
        // (e.g. blocked by the App Sandbox on this macOS version).
        return legacyMediaControl(action)
    }

    /// Sends a command via the private MediaRemote framework, the same mechanism the system
    /// media keys and Control Center's Now Playing widget use. Returns false if the framework,
    /// symbol, or the XPC call to `mediaremoted` is unavailable, so the caller can fall back.
    private static func sendMediaRemoteCommand(_ command: MediaRemoteCommand) -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else {
            return false
        }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "MRMediaRemoteSendCommand") else { return false }
        typealias SendCommandFunc = @convention(c) (UInt32, CFDictionary?) -> Bool
        let sendCommand = unsafeBitCast(sym, to: SendCommandFunc.self)
        return sendCommand(command.rawValue, nil)
    }

    @MainActor
    private static func legacyMediaControl(_ action: MediaAction) -> RovaError? {
        let isSpotifyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
        let isMusicRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty

        let targetApp: String
        let verb: String

        if isSpotifyRunning {
            targetApp = "Spotify"
            switch action {
            case .playPause: verb = "playpause"
            case .nextTrack: verb = "next track"
            case .previousTrack: verb = "previous track"
            }
        } else if isMusicRunning || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") != nil {
            targetApp = "Music"
            switch action {
            case .playPause: verb = "playpause"
            case .nextTrack: verb = "next track"
            case .previousTrack: verb = "previous track"
            }
        } else {
            return RovaError(code: "NO_MEDIA_PLAYER", message: "Medya oynatıcı (Müzik veya Spotify) bulunamadı.")
        }

        let command = "tell application \"\(targetApp)\" to \(verb)"
        guard let script = NSAppleScript(source: command) else {
            return RovaError(code: "MEDIA_UNAVAILABLE", message: "Medya komutu hazırlanamadı.")
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        if let error {
            let errorNumber = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let errorMsg = (error[NSAppleScript.errorMessage] as? String) ?? "Bilinmeyen hata"
            if errorNumber == -1743 {
                return RovaError(code: "MEDIA_PERMISSION_DENIED", message: "Mac'te Rova için Otomasyon (\(targetApp)) izni verilmedi. Sistem Ayarları > Gizlilik ve Güvenlik > Otomasyon altından izin verin.")
            }
            return RovaError(code: "MEDIA_FAILED", message: "Medya komutu çalıştırılamadı: \(errorMsg)")
        }
        return nil
    }

    static func systemStatus(runtimeStatus: String) -> SystemStatus {
        var batteryPercentage: Int?
        var isCharging: Bool?
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue()
        for index in 0..<CFArrayGetCount(sources) {
            let source = unsafeBitCast(CFArrayGetValueAtIndex(sources, index), to: CFTypeRef.self)
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let current = description[kIOPSCurrentCapacityKey] as? Int { batteryPercentage = current }
            if let state = description[kIOPSIsChargingKey] as? Bool { isCharging = state }
            break
        }
        return SystemStatus(
            hostname: Host.current().localizedName ?? Host.current().name ?? "Mac",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            batteryPercentage: batteryPercentage,
            isCharging: isCharging,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            runtimeStatus: runtimeStatus,
            volumePercentage: currentVolume(),
            brightnessPercentage: currentBrightness()
        )
    }

    static func currentVolume() -> Int? {
        guard let script = NSAppleScript(source: "output volume of (get volume settings)") else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return Int(result.int32Value)
    }

    static func currentBrightness() -> Int? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) else {
            return nil
        }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        typealias GetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let getB = unsafeBitCast(sym, to: GetBrightnessFunc.self)
        var value: Float = 0
        guard getB(CGMainDisplayID(), &value) == 0 else { return nil }
        return Int((value * 100).rounded())
    }

    static func localIPv4Address() -> String {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return "Unavailable" }
        defer { freeifaddrs(pointer) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current?.pointee {
            current = interface.ifa_next
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name) != "lo0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var socketAddress = address.pointee
            if getnameinfo(&socketAddress, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let bytes = host.map { UInt8(bitPattern: $0) }.prefix(while: { $0 != 0 })
                return String(decoding: bytes, as: UTF8.self)
            }
        }
        return "Unavailable"
    }
}
