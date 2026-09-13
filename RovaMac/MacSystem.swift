import AppKit
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
        if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) {
            defer { dlclose(handle) }
            typealias SetBrightnessFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32
            if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
                let setB = unsafeBitCast(sym, to: SetBrightnessFunc.self)
                let res = setB(CGMainDisplayID(), normalized)
                if res == 0 {
                    return nil
                }
            }
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

    @MainActor
    static func mediaControl(_ action: MediaAction) -> RovaError? {
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
            runtimeStatus: runtimeStatus
        )
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
