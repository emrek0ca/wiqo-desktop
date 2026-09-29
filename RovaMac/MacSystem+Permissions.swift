import AppKit
import ApplicationServices
import CoreGraphics
import EventKit
import Foundation

/// What this Mac has allowed Wiqo to do, and asking for it.
extension MacSystem {
    // These checks are deliberately read-only. Opening a settings tab must never trigger a
    // privacy prompt; the action buttons below take the user to the relevant system pane.
    static func hasScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Called only from the explicit Settings action. The read-only preflight above keeps
    /// opening the permissions panel free of unexpected prompts.
    @MainActor
    static func requestScreenRecordingAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    static func hasAccessibilityAccess() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Called only from the explicit Settings action. Status checks must keep using the
    /// non-prompting variant above.
    @MainActor
    static func requestAccessibilityAccess() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func hasCalendarAccess() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .fullAccess
    }

    static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let protectedFolders = [
            home.appendingPathComponent("Library/Mail", isDirectory: true),
            home.appendingPathComponent("Library/Safari", isDirectory: true)
        ]
        let existingFolders = protectedFolders.filter { FileManager.default.fileExists(atPath: $0.path) }
        return existingFolders.isEmpty || existingFolders.allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    static func capabilityAuthorities() -> [DeviceCapabilityAuthority] {
        let accessibility = hasAccessibilityAccess()
        let screenRecording = hasScreenRecordingAccess()
        let calendar = hasCalendarAccess()
        let fullDisk = hasFullDiskAccess()
        // create_note automates Notes.app via AppleScript (see MacSystem.createNote) and fails
        // with error -1743 without this - semanticDeviceTools.ts maps that tool to the "notes.write"
        // authority key, but nothing here ever reported it, so the model had no way to know in
        // advance whether Notes access was actually granted on this Mac.
        let notesAccess = hasAutomationAccess(for: "com.apple.Notes")

        func authority(
            _ capability: String,
            _ name: String,
            _ access: CapabilityAuthorityAccess,
            permissions: [String] = [],
            message: String? = nil
        ) -> DeviceCapabilityAuthority {
            DeviceCapabilityAuthority(
                capability: capability,
                displayName: name,
                access: access,
                requiredPermissions: permissions,
                message: message
            )
        }

        return [
            authority("runtime.status", "Sistem durumu", .automatic),
            authority("device.app.control", "Uygulama açma ve odaklama", .confirmation),
            authority("device.app.quit", "Uygulama kapatma", .confirmation),
            authority("device.url.open", "Bağlantı açma", .automatic),
            authority("device.browser.control", "Göreve özel tarayıcı", .confirmation),
            authority("device.audio", "Ses kontrolü", .automatic),
            authority("device.display", "Ekran kontrolü", .automatic),
            authority("device.media", "Medya kontrolü", .automatic),
            authority("device.clipboard", "Pano", .automatic),
            authority("device.system.power", "Kilit ve uyku", .confirmation),
            authority("device.messaging.send", "Mesaj gönderme", .confirmation, permissions: ["Automation"]),
            authority("notes.write", "Not oluşturma", notesAccess ? .confirmation : .unavailable, permissions: ["Automation"], message: notesAccess ? nil : "Notes için Otomasyon izni gerekli."),
            authority("calendar.read", "Takvim okuma", calendar ? .automatic : .unavailable, permissions: ["Calendar"], message: calendar ? nil : "Takvim izni gerekli."),
            authority("calendar.write", "Takvime yazma", calendar ? .confirmation : .unavailable, permissions: ["Calendar"], message: calendar ? nil : "Takvim izni gerekli."),
            authority("device.files.list", "Dosya listeleme", .automatic, permissions: fullDisk ? [] : ["Full Disk Access"]),
            authority("device.files.read", "Dosya okuma", .confirmation, permissions: fullDisk ? [] : ["Full Disk Access"]),
            authority("device.files.write", "Dosya yazma", .confirmation, permissions: fullDisk ? [] : ["Full Disk Access"]),
            authority("device.files.move", "Dosya taşıma", .confirmation, permissions: fullDisk ? [] : ["Full Disk Access"]),
            authority("device.files.copy", "Dosya kopyalama", .confirmation, permissions: fullDisk ? [] : ["Full Disk Access"]),
            authority("device.files.delete", "Dosya silme", .confirmation, permissions: fullDisk ? [] : ["Full Disk Access"]),
            authority("document.read", "Belge okuma", .confirmation, permissions: fullDisk ? [] : ["Full Disk Access"]),
            authority("document.edit", "Belge düzenleme", .confirmation, permissions: fullDisk ? [] : ["Full Disk Access"]),
            authority("artifact.save", "Dosya kaydetme", .confirmation),
            authority("device.code.execute", "Kod çalıştırma", .confirmation),
            authority("local.analysis", "Yerel analiz", .confirmation, permissions: fullDisk ? [] : ["Full Disk Access"]),
            authority("device.shortcut.run", "Shortcut çalıştırma", .confirmation, permissions: ["Automation"]),
            authority("device.ui.control", "Arayüz kontrolü", accessibility ? .confirmation : .unavailable, permissions: ["Accessibility"], message: accessibility ? nil : "Erişilebilirlik izni gerekli."),
            authority("device.desktop.control", "Göreve özel masaüstü kontrolü", accessibility ? .confirmation : .unavailable, permissions: ["Accessibility"], message: accessibility ? nil : "Masaüstü kontrolü için Erişilebilirlik izni gerekli."),
            authority("device.screen.capture", "Ekran gözlemi", screenRecording ? .confirmation : .unavailable, permissions: ["Screen Recording"], message: screenRecording ? nil : "Ekran Kaydı izni gerekli."),
            authority("device.screen.click", "Ekrana tıklama", accessibility && screenRecording ? .confirmation : .unavailable, permissions: ["Accessibility", "Screen Recording"], message: accessibility && screenRecording ? nil : "Erişilebilirlik ve Ekran Kaydı izinleri gerekli.")
        ]
    }

    static let automationTargets: [MacAutomationTarget] = [
        MacAutomationTarget(id: "system-events", title: "System Events", bundleIdentifier: "com.apple.systemevents"),
        MacAutomationTarget(id: "music", title: "Music", bundleIdentifier: "com.apple.Music"),
        MacAutomationTarget(id: "messages", title: "Messages", bundleIdentifier: "com.apple.MobileSMS"),
        MacAutomationTarget(id: "calendar", title: "Calendar", bundleIdentifier: "com.apple.iCal"),
        MacAutomationTarget(id: "mail", title: "Mail", bundleIdentifier: "com.apple.mail"),
        MacAutomationTarget(id: "notes", title: "Notes", bundleIdentifier: "com.apple.Notes"),
        MacAutomationTarget(id: "finder", title: "Finder", bundleIdentifier: "com.apple.finder"),
        MacAutomationTarget(id: "shortcuts", title: "Shortcuts", bundleIdentifier: "com.apple.shortcuts")
    ]

    static func hasAutomationAccess(for bundleIdentifier: String) -> Bool {
        var target = AEAddressDesc()
        let createStatus = bundleIdentifier.withCString { value in
            AECreateDesc(typeApplicationBundleID, value, strlen(value), &target)
        }
        guard createStatus == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, kAECoreSuite, kAEGetData, false) == noErr
    }

    static func automationPermissionSnapshot() -> [MacAutomationPermission] {
        automationTargets.map { target in
            guard NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleIdentifier).isEmpty == false else {
                return MacAutomationPermission(
                    id: target.id,
                    title: target.title,
                    bundleIdentifier: target.bundleIdentifier,
                    status: .notChecked,
                    message: "Durumu görmek için bu uygulamayı çalıştırıp yenileyin veya tüm izinleri isteyin."
                )
            }
            let granted = hasAutomationAccess(for: target.bundleIdentifier)
            return MacAutomationPermission(
                id: target.id,
                title: target.title,
                bundleIdentifier: target.bundleIdentifier,
                status: granted ? .granted : .denied,
                message: granted ? nil : "Wiqo için Otomasyon izni verilmedi."
            )
        }
    }

    static func installedWiqoShortcuts() -> Set<WiqoShortcut> {
        let snapshot = runProcess(executable: "/usr/bin/shortcuts", arguments: ["list", "--show-identifiers"], timeoutSeconds: 5)
        guard snapshot.exitCode == 0 else { return [] }
        let output = String(decoding: snapshot.stdout, as: UTF8.self)
        return Set(WiqoShortcut.allCases.filter { output.localizedCaseInsensitiveContains($0.rawValue) })
    }

    /// macOS intentionally has no supported CLI import/create command. Opening an exported
    /// shortcut is the supported user-mediated install path; the Shortcuts app owns the final
    /// confirmation and TCC decision. We only open bundled, allow-listed resources.
    @MainActor
    static func openWiqoShortcutsForInstallation() -> MacShortcutInstallationResult {
        let installed = installedWiqoShortcuts()
        var alreadyInstalled: [WiqoShortcut] = []
        var openedForApproval: [WiqoShortcut] = []
        var missingResources: [WiqoShortcut] = []
        for shortcut in WiqoShortcut.allCases {
            if installed.contains(shortcut) {
                alreadyInstalled.append(shortcut)
                continue
            }
            guard let url = Bundle.main.url(forResource: shortcut.resourceName, withExtension: "shortcut") else {
                missingResources.append(shortcut)
                continue
            }
            if NSWorkspace.shared.open(url) {
                openedForApproval.append(shortcut)
            } else {
                missingResources.append(shortcut)
            }
        }
        return MacShortcutInstallationResult(alreadyInstalled: alreadyInstalled, openedForApproval: openedForApproval, missingResources: missingResources)
    }

    private static func runAutomationProbe(for target: MacAutomationTarget) -> RovaError? {
        let source = "tell application id \"\(target.bundleIdentifier)\" to get version"
        guard let script = NSAppleScript(source: source) else {
            return RovaError(code: "AUTOMATION_PROBE_FAILED", message: "\(target.title) izin kontrolü hazırlanamadı.", category: "tool_failure")
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        guard let error else { return nil }
        let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? (error[NSAppleScript.errorNumber] as? Int) ?? 0
        if number == -1743 || number == -1744 {
            return RovaError(code: "AUTOMATION_PERMISSION_REQUIRED", message: "Wiqo için \(target.title) Otomasyon izni verilmedi.", category: "permission")
        }
        if number == -600 || number == -1728 {
            return RovaError(code: "AUTOMATION_TARGET_UNAVAILABLE", message: "\(target.title) bu Mac'te kullanılamıyor.", category: "tool_failure")
        }
        return RovaError(code: "AUTOMATION_PROBE_FAILED", message: "\(target.title) izin kontrolü tamamlanamadı.", category: "tool_failure")
    }

    /// Explicitly called from the Settings button. Each probe is a harmless getter, but macOS
    /// still decides independently whether to display a TCC prompt for the target application.
    static func warmUpAutomationPermissions() -> [MacAutomationPermission] {
        automationTargets.map { target in
            let error = runAutomationProbe(for: target)
            let status: MacAutomationPermissionStatus
            if error == nil && hasAutomationAccess(for: target.bundleIdentifier) {
                status = .granted
            } else if error?.code == "AUTOMATION_TARGET_UNAVAILABLE" {
                status = .unavailable
            } else {
                status = .denied
            }
            return MacAutomationPermission(
                id: target.id,
                title: target.title,
                bundleIdentifier: target.bundleIdentifier,
                status: status,
                message: error?.message
            )
        }
    }

    /// Calendar access is a separate EventKit permission from Calendar's Apple Events
    /// permission. It is requested only from the explicit all-permissions action in Settings.
    @MainActor
    static func requestCalendarAccessForWarmUp() async -> Bool {
        if hasCalendarAccess() { return true }
        let store = EKEventStore()
        return await withCheckedContinuation { continuation in
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents { granted, _ in continuation.resume(returning: granted) }
            } else {
                store.requestAccess(to: .event) { granted, _ in continuation.resume(returning: granted) }
            }
        }
    }
}
