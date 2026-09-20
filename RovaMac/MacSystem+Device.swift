import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Power, sound, display, media, clipboard and system status.
extension MacSystem {
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

    static func setClipboardText(_ text: String) -> RovaError? {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            return RovaError(code: "CLIPBOARD_FAILED", message: "Panoya metin yazılamadı.")
        }
        return nil
    }

    static func getClipboardText() -> (data: CommandData?, error: RovaError?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return (nil, RovaError(code: "CLIPBOARD_EMPTY", message: "Panoda metin yok."))
        }
        return (.clipboardText(String(text.prefix(20_000))), nil)
    }

    @MainActor
    static func getClipboardHistory() -> (data: CommandData?, error: RovaError?) {
        (.clipboardHistory(ClipboardWatcher.shared.entries), nil)
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
            return RovaError(code: "MEDIA_PERMISSION_DENIED", message: "Mac'te Wiqo için Otomasyon (\(targetApp)) izni verilmedi. Sistem Ayarları > Gizlilik ve Güvenlik > Otomasyon altından izin verin.")
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
            hostname: MacNetwork.computerName,
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
}
