import AppKit
import ApplicationServices
import CoreGraphics
import EventKit
import Foundation
import IOKit
import IOKit.ps
import ScreenCaptureKit
import UniformTypeIdentifiers
import Darwin

struct MacAutomationTarget: Identifiable, Sendable {
    let id: String
    let title: String
    let bundleIdentifier: String
}

enum MacAutomationPermissionStatus: Sendable {
    case granted
    case denied
    case notChecked
    case unavailable
}

struct MacAutomationPermission: Identifiable, Sendable {
    let id: String
    let title: String
    let bundleIdentifier: String
    let status: MacAutomationPermissionStatus
    let message: String?

    var granted: Bool { status == .granted }
}

struct MacShortcutInstallationResult: Sendable {
    let alreadyInstalled: [WiqoShortcut]
    let openedForApproval: [WiqoShortcut]
    let missingResources: [WiqoShortcut]
}

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

    /// A path-free snapshot used by the semantic planner. The snapshot is deliberately advisory:
    /// every action resolves the target again immediately before touching the application.
    static func applicationTargets() -> [DeviceApplicationTarget] {
        struct Snapshot {
            var name: String
            var bundleIdentifier: String?
            var isRunning: Bool
        }

        var snapshots: [String: Snapshot] = [:]
        func add(name: String, bundleIdentifier: String?, isRunning: Bool) {
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanName.isEmpty else { return }
            if bundleIdentifier == Bundle.main.bundleIdentifier { return }
            let key = bundleIdentifier?.lowercased() ?? normalizeApplicationName(cleanName)
            if var existing = snapshots[key] {
                existing.isRunning = existing.isRunning || isRunning
                if existing.bundleIdentifier == nil { existing.bundleIdentifier = bundleIdentifier }
                snapshots[key] = existing
            } else {
                snapshots[key] = Snapshot(name: cleanName, bundleIdentifier: bundleIdentifier, isRunning: isRunning)
            }
        }

        for application in NSWorkspace.shared.runningApplications where !application.isTerminated {
            guard application.activationPolicy == .regular || application.bundleIdentifier == "com.apple.finder" else { continue }
            add(
                name: application.localizedName ?? application.bundleIdentifier ?? "Uygulama",
                bundleIdentifier: application.bundleIdentifier,
                isRunning: true
            )
        }

        for (_, bundleIdentifier) in applications {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { continue }
            add(
                name: url.deletingPathExtension().lastPathComponent,
                bundleIdentifier: bundleIdentifier,
                isRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
            )
        }

        let fileManager = FileManager.default
        let folders = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        for folder in folders {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls where url.pathExtension.lowercased() == "app" {
                let bundle = Bundle(url: url)
                let bundleIdentifier = bundle?.bundleIdentifier
                // .app filenames are almost always the English name regardless of system
                // language (e.g. "Notes.app" on a Turkish Mac, which still shows "Notlar" in
                // Finder and to the user) - a not-currently-running app was falling back to that
                // raw filename here while a running one (above) already used localizedName, so
                // the model would say the name it's actually seeing ("Notlar") and this catalog
                // would only ever have "Notes", failing the open with a false "not found."
                // Reading the InfoPlist.strings display name for the current locale is what
                // Finder itself shows, so it lines up with what the user (and therefore the
                // model) actually calls the app.
                let localizedName = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle?.localizedInfoDictionary?["CFBundleName"] as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                add(
                    name: localizedName ?? url.deletingPathExtension().lastPathComponent,
                    bundleIdentifier: bundleIdentifier,
                    isRunning: bundleIdentifier.map { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? false
                )
            }
        }

        return snapshots.values
            .sorted { left, right in
                if left.isRunning != right.isRunning { return left.isRunning && !right.isRunning }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            .prefix(200)
            .map {
                DeviceApplicationTarget(
                    name: $0.name,
                    bundleIdentifier: $0.bundleIdentifier,
                    isRunning: $0.isRunning,
                    supportedActions: $0.bundleIdentifier == "com.apple.finder"
                        ? [.open, .activate]
                        : [.open, .activate, .quit]
                )
            }
    }

    /// A direct, read-only answer to "what's actually open right now" - the missing tool that
    /// pushed the model toward using computer_application's open/activate as an improvised "check
    /// if it's running" step (a real side effect, not a check) before this existed.
    static func listRunningApplications() -> (data: CommandData?, error: RovaError?) {
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular || $0.bundleIdentifier == "com.apple.finder" }
            .map {
                RunningApplicationInfo(
                    name: $0.localizedName ?? $0.bundleIdentifier ?? "Uygulama",
                    bundleIdentifier: $0.bundleIdentifier,
                    isActive: $0.bundleIdentifier != nil && $0.bundleIdentifier == frontmostBundleID
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (.runningApplications(apps), nil)
    }

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
            authority("device.shortcut.run", "Shortcut çalıştırma", .confirmation, permissions: ["Automation"]),
            authority("device.ui.control", "Arayüz kontrolü", accessibility ? .confirmation : .unavailable, permissions: ["Accessibility"], message: accessibility ? nil : "Erişilebilirlik izni gerekli."),
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

    /// Resolves an application by the name a person actually says (including apps that are not
    /// part of the historical fixed enum). Spotlight is queried first, then the standard app
    /// folders are used as a deterministic fallback. A fuzzy match is opened only when it is
    /// unambiguous; otherwise the candidates are returned as data so the phone can ask the user
    /// instead of silently launching the wrong app.
    static func openApplicationByName(_ query: String) -> (data: CommandData?, error: RovaError?) {
        let normalizedQuery = normalizeApplicationName(query)
        guard !normalizedQuery.isEmpty else {
            return (nil, RovaError(code: "INVALID_APPLICATION_NAME", message: "Uygulama adı boş olamaz.", category: "tool_failure"))
        }
        let candidates = applicationCandidates(for: normalizedQuery)
        guard !candidates.isEmpty else {
            return (nil, RovaError(code: "APPLICATION_NOT_FOUND", message: "Bu adla eşleşen uygulama bulunamadı.", category: "tool_failure"))
        }
        let ranked = candidates
            .map { candidate in (candidate, scoreApplication(candidate.name, query: normalizedQuery)) }
            .sorted { left, right in
                if left.1 != right.1 { return left.1 > right.1 }
                return left.0.path.localizedStandardCompare(right.0.path) == .orderedAscending
            }
        guard let best = ranked.first else {
            return (nil, RovaError(code: "APPLICATION_NOT_FOUND", message: "Uygulama bulunamadı.", category: "tool_failure"))
        }
        let secondScore = ranked.dropFirst().first?.1 ?? 0
        let exact = ranked.filter { normalizeApplicationName($0.0.name) == normalizedQuery }
        let ambiguous = exact.count > 1 || (best.1 < 0.86 && best.1 - secondScore < 0.10)
        if ambiguous {
            let choices = ranked.prefix(5).map(\.0)
            return (.installedApplications(Array(choices)), RovaError(code: "APPLICATION_AMBIGUOUS", message: "Birden fazla benzer uygulama bulundu; hangisinin açılacağını seç.", category: "tool_failure"))
        }
        guard NSWorkspace.shared.open(URL(fileURLWithPath: best.0.path)) else {
            return (nil, RovaError(code: "APPLICATION_OPEN_FAILED", message: "Uygulama açılamadı.", category: "tool_failure"))
        }
        return (.installedApplications([best.0]), nil)
    }

    private struct ResolvedApplication: Sendable {
        let name: String
        let bundleIdentifier: String?
        let path: String?
    }

    private struct ManifestApplicationResolution: Sendable {
        let application: DeviceApplicationTarget?
        let candidates: [String]
        let ambiguous: Bool
    }

    /// The backend/client manifest is only planning context. Before any semantic application
    /// action, rebuild the catalog locally and require one exact/contained name match (or an exact
    /// bundle identifier). This prevents a model-supplied arbitrary bundle from becoming a
    /// LaunchServices request and keeps unsupported targets fail-closed.
    private static func resolveManifestApplication(
        target: String,
        bundleIdentifier: String?,
        action: ApplicationControlAction
    ) -> ManifestApplicationResolution {
        let query = normalizeApplicationName(target)
        let catalog = applicationTargets()
        let matches = catalog.filter { candidate in
            if let bundleIdentifier, !bundleIdentifier.isEmpty {
                return candidate.bundleIdentifier?.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
            }
            let candidateName = normalizeApplicationName(candidate.name)
            return !query.isEmpty && (candidateName == query || candidateName.contains(query))
        }
        let candidates = Array(matches.prefix(5).map(\.name))
        guard matches.count == 1, let application = matches.first else {
            return ManifestApplicationResolution(application: nil, candidates: candidates, ambiguous: matches.count > 1)
        }
        guard application.supportedActions.contains(action) else {
            return ManifestApplicationResolution(application: nil, candidates: [application.name], ambiguous: false)
        }
        return ManifestApplicationResolution(application: application, candidates: [application.name], ambiguous: false)
    }

    /// Resolves and executes a human application intent without relying on the historical fixed
    /// `ApplicationID` list. Native LaunchServices/NSRunningApplication APIs are the primary path;
    /// Apple Events are only a graceful-quit fallback. Every state-changing branch observes the
    /// process again before claiming success.
    static func controlApplication(_ payload: ApplicationControlPayload) async -> (data: CommandData?, error: RovaError?) {
        let target = payload.target.trimmingCharacters(in: .whitespacesAndNewlines)
        let manifestResolution = resolveManifestApplication(
            target: target,
            bundleIdentifier: payload.bundleIdentifier,
            action: payload.action
        )
        if manifestResolution.ambiguous {
            let content = ApplicationControlContent(
                action: payload.action,
                resolvedName: target,
                bundleIdentifier: payload.bundleIdentifier,
                stateBefore: "ambiguous",
                stateAfter: "unchanged",
                changed: false,
                verified: false,
                candidates: manifestResolution.candidates
            )
            return (.applicationControl(content), RovaError(code: "APPLICATION_AMBIGUOUS", message: "Birden fazla uygulama eşleşti; hedefi daha net belirtin.", category: "tool_failure"))
        }
        guard manifestResolution.application != nil else {
            let code = manifestResolution.candidates.isEmpty ? "APPLICATION_NOT_AUTHORIZED" : "APPLICATION_ACTION_NOT_SUPPORTED"
            let message = manifestResolution.candidates.isEmpty
                ? "Bu uygulama bağlı Mac'in doğrulanmış uygulama kataloğunda bulunamadı."
                : "Bu uygulama için istenen eylem bağlı Mac'te desteklenmiyor."
            return (nil, RovaError(code: code, message: message, category: "permission"))
        }
        let runningResolution = resolveRunningApplication(target: target, bundleIdentifier: payload.bundleIdentifier)
        if runningResolution.ambiguous {
            let content = ApplicationControlContent(
                action: payload.action,
                resolvedName: target,
                bundleIdentifier: payload.bundleIdentifier,
                stateBefore: "ambiguous",
                stateAfter: "unchanged",
                changed: false,
                verified: false,
                candidates: runningResolution.candidates
            )
            return (.applicationControl(content), RovaError(code: "APPLICATION_AMBIGUOUS", message: "Birden fazla çalışan uygulama eşleşti: \(runningResolution.candidates.joined(separator: ", ")). Hedefi daha net belirtin.", category: "tool_failure"))
        }

        switch payload.action {
        case .quit:
            if let selected = runningResolution.application {
                return await quitResolvedApplication(selected, force: payload.force)
            }
            let installed = await resolveInstalledApplication(target: target, bundleIdentifier: payload.bundleIdentifier)
            if installed.ambiguous {
                let content = ApplicationControlContent(action: .quit, resolvedName: target, bundleIdentifier: payload.bundleIdentifier, stateBefore: "ambiguous", stateAfter: "unchanged", changed: false, verified: false, candidates: installed.candidates)
                return (.applicationControl(content), RovaError(code: "APPLICATION_AMBIGUOUS", message: "Birden fazla uygulama eşleşti: \(installed.candidates.joined(separator: ", ")). Hedefi daha net belirtin.", category: "tool_failure"))
            }
            guard let resolved = installed.application else {
                return (nil, RovaError(code: "APPLICATION_NOT_FOUND", message: "\(target) bu Mac'te bulunamadı.", category: "tool_failure"))
            }
            let content = ApplicationControlContent(action: .quit, resolvedName: resolved.name, bundleIdentifier: resolved.bundleIdentifier, stateBefore: "not_running", stateAfter: "not_running", changed: false, verified: true)
            return (.applicationControl(content), nil)

        case .open, .activate:
            if let selected = runningResolution.application {
                let activated = selected.instances.contains { application in
                    application.activate(options: [.activateAllWindows])
                }
                let verified = await waitForApplication(target: selected, expectedRunning: true, expectedActive: true, timeoutSeconds: 2)
                let content = ApplicationControlContent(
                    action: payload.action,
                    resolvedName: selected.name,
                    bundleIdentifier: selected.bundleIdentifier,
                    stateBefore: "running",
                    stateAfter: verified ? "active" : "running",
                    changed: activated,
                    verified: verified
                )
                return verified
                    ? (.applicationControl(content), nil)
                    : (.applicationControl(content), RovaError(code: "APPLICATION_ACTIVATE_FAILED", message: "\(selected.name) çalışıyor ancak öne getirildiği doğrulanamadı.", category: "tool_failure"))
            }

            let installed = await resolveInstalledApplication(target: target, bundleIdentifier: payload.bundleIdentifier)
            if installed.ambiguous {
                let content = ApplicationControlContent(action: payload.action, resolvedName: target, bundleIdentifier: payload.bundleIdentifier, stateBefore: "ambiguous", stateAfter: "unchanged", changed: false, verified: false, candidates: installed.candidates)
                return (.applicationControl(content), RovaError(code: "APPLICATION_AMBIGUOUS", message: "Birden fazla uygulama eşleşti: \(installed.candidates.joined(separator: ", ")). Hedefi daha net belirtin.", category: "tool_failure"))
            }
            guard let resolved = installed.application, let path = resolved.path else {
                return (nil, RovaError(code: "APPLICATION_NOT_FOUND", message: "\(target) bu Mac'te bulunamadı.", category: "tool_failure"))
            }
            guard NSWorkspace.shared.open(URL(fileURLWithPath: path)) else {
                return (nil, RovaError(code: "APPLICATION_OPEN_FAILED", message: "\(resolved.name) açılamadı.", category: "tool_failure"))
            }
            let observed = RunningApplicationGroup(name: resolved.name, bundleIdentifier: resolved.bundleIdentifier, instances: [])
            let running = await waitForApplication(target: observed, expectedRunning: true, expectedActive: false, timeoutSeconds: 4)
            if payload.action == .activate,
               let application = matchingRunningApplications(name: resolved.name, bundleIdentifier: resolved.bundleIdentifier).first {
                _ = application.activate(options: [.activateAllWindows])
            }
            let active: Bool
            if payload.action == .open {
                active = true
            } else {
                active = await waitForApplication(target: observed, expectedRunning: true, expectedActive: true, timeoutSeconds: 2)
            }
            let verified = running && active
            let content = ApplicationControlContent(
                action: payload.action,
                resolvedName: resolved.name,
                bundleIdentifier: resolved.bundleIdentifier,
                stateBefore: "not_running",
                stateAfter: verified ? (payload.action == .activate ? "active" : "running") : "unknown",
                changed: true,
                verified: verified
            )
            return verified
                ? (.applicationControl(content), nil)
                : (.applicationControl(content), RovaError(code: "APPLICATION_VERIFICATION_FAILED", message: "\(resolved.name) için istenen durum doğrulanamadı.", category: "tool_failure"))
        }
    }

    private struct RunningApplicationGroup {
        let name: String
        let bundleIdentifier: String?
        let instances: [NSRunningApplication]
    }

    private struct RunningApplicationResolution {
        let application: RunningApplicationGroup?
        let candidates: [String]
        let ambiguous: Bool
    }

    private static func resolveRunningApplication(target: String, bundleIdentifier: String?) -> RunningApplicationResolution {
        let applications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && ($0.activationPolicy == .regular || $0.bundleIdentifier == "com.apple.finder")
        }
        var groups: [String: [NSRunningApplication]] = [:]
        for application in applications {
            let name = application.localizedName ?? application.bundleIdentifier ?? "Uygulama"
            let key = application.bundleIdentifier?.lowercased() ?? normalizeApplicationName(name)
            groups[key, default: []].append(application)
        }
        let values = groups.values.map { instances in
            RunningApplicationGroup(
                name: instances.first?.localizedName ?? instances.first?.bundleIdentifier ?? "Uygulama",
                bundleIdentifier: instances.first?.bundleIdentifier,
                instances: instances
            )
        }
        if let bundleIdentifier {
            let matches = values.filter { $0.bundleIdentifier?.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
            return RunningApplicationResolution(application: matches.count == 1 ? matches[0] : nil, candidates: matches.map(\.name), ambiguous: matches.count > 1)
        }
        return chooseRunningApplication(values, target: target)
    }

    private static func chooseRunningApplication(_ applications: [RunningApplicationGroup], target: String) -> RunningApplicationResolution {
        let query = normalizeApplicationName(target)
        let ranked = applications
            .map { ($0, scoreApplication($0.name, query: query)) }
            .filter { $0.1 >= 0.45 }
            .sorted { left, right in
                if left.1 != right.1 { return left.1 > right.1 }
                return left.0.name.localizedStandardCompare(right.0.name) == .orderedAscending
            }
        guard let best = ranked.first else { return RunningApplicationResolution(application: nil, candidates: [], ambiguous: false) }
        let exact = ranked.filter { normalizeApplicationName($0.0.name) == query }
        let secondScore = ranked.dropFirst().first?.1 ?? 0
        let ambiguous = exact.count > 1 || (ranked.count > 1 && best.1 < 0.97 && best.1 - secondScore < 0.12)
        return RunningApplicationResolution(
            application: ambiguous ? nil : best.0,
            candidates: ranked.prefix(5).map { $0.0.name },
            ambiguous: ambiguous
        )
    }

    private struct InstalledApplicationResolution: Sendable {
        let application: ResolvedApplication?
        let candidates: [String]
        let ambiguous: Bool
    }

    private static func resolveInstalledApplication(target: String, bundleIdentifier: String?) async -> InstalledApplicationResolution {
        if let bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let name = url.deletingPathExtension().lastPathComponent
            return InstalledApplicationResolution(application: ResolvedApplication(name: name, bundleIdentifier: bundleIdentifier, path: url.path), candidates: [name], ambiguous: false)
        }
        return await Task.detached(priority: .userInitiated) {
            resolveInstalledApplicationByName(target: target)
        }.value
    }

    private static func resolveInstalledApplicationByName(target: String) -> InstalledApplicationResolution {
        let query = normalizeApplicationName(target)
        let ranked = applicationCandidates(for: query)
            .map { ($0, scoreApplication($0.name, query: query)) }
            .filter { $0.1 >= 0.45 }
            .sorted { left, right in
                if left.1 != right.1 { return left.1 > right.1 }
                return left.0.path.localizedStandardCompare(right.0.path) == .orderedAscending
            }
        guard let best = ranked.first else { return InstalledApplicationResolution(application: nil, candidates: [], ambiguous: false) }
        let exact = ranked.filter { normalizeApplicationName($0.0.name) == query }
        let secondScore = ranked.dropFirst().first?.1 ?? 0
        let ambiguous = exact.count > 1 || (ranked.count > 1 && best.1 < 0.97 && best.1 - secondScore < 0.12)
        let resolved = ResolvedApplication(name: best.0.name, bundleIdentifier: best.0.bundleIdentifier, path: best.0.path)
        return InstalledApplicationResolution(application: ambiguous ? nil : resolved, candidates: ranked.prefix(5).map { $0.0.name }, ambiguous: ambiguous)
    }

    private static func quitResolvedApplication(_ application: RunningApplicationGroup, force: Bool) async -> (data: CommandData?, error: RovaError?) {
        if application.bundleIdentifier == Bundle.main.bundleIdentifier {
            return (nil, RovaError(code: "APPLICATION_SELF_PROTECTED", message: "Wiqo kendi yürütme bağlantısını kapatamaz.", category: "permission"))
        }
        if application.bundleIdentifier == "com.apple.finder" {
            return (nil, RovaError(code: "APPLICATION_SYSTEM_PROTECTED", message: "Finder sistem tarafından yeniden başlatıldığı için uygulama gibi kapatılamaz; pencere kapatma eylemi kullanın.", category: "permission"))
        }

        for instance in application.instances where !instance.isTerminated { _ = instance.terminate() }
        var closed = await waitForApplication(target: application, expectedRunning: false, expectedActive: false, timeoutSeconds: 3)
        if !closed, let bundleIdentifier = application.bundleIdentifier,
           let script = NSAppleScript(source: "tell application id \"\(bundleIdentifier)\" to quit") {
            var scriptError: NSDictionary?
            _ = script.executeAndReturnError(&scriptError)
            if let scriptError,
               ((scriptError[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -1743) {
                let content = ApplicationControlContent(action: .quit, resolvedName: application.name, bundleIdentifier: application.bundleIdentifier, stateBefore: "running", stateAfter: "running", changed: false, verified: false)
                return (.applicationControl(content), RovaError(code: "AUTOMATION_PERMISSION_REQUIRED", message: "\(application.name) kapatma yedeği için Wiqo Otomasyon izni gerekli.", category: "permission"))
            }
            closed = await waitForApplication(target: application, expectedRunning: false, expectedActive: false, timeoutSeconds: 2)
        }
        if !closed && force {
            for instance in matchingRunningApplications(name: application.name, bundleIdentifier: application.bundleIdentifier) where !instance.isTerminated {
                _ = instance.forceTerminate()
            }
            closed = await waitForApplication(target: application, expectedRunning: false, expectedActive: false, timeoutSeconds: 2)
        }

        let content = ApplicationControlContent(
            action: .quit,
            resolvedName: application.name,
            bundleIdentifier: application.bundleIdentifier,
            stateBefore: "running",
            stateAfter: closed ? "not_running" : "running",
            changed: closed,
            verified: closed
        )
        guard closed else {
            let message = force
                ? "\(application.name) kapatılamadı; uygulama yanıt vermiyor veya sistem tarafından korunuyor."
                : "\(application.name) normal biçimde kapanmadı. Zorla kapatmak için bunu açıkça isteyin."
            return (.applicationControl(content), RovaError(code: force ? "APPLICATION_FORCE_QUIT_FAILED" : "APPLICATION_QUIT_REQUIRES_FORCE", message: message, category: "tool_failure"))
        }
        return (.applicationControl(content), nil)
    }

    private static func matchingRunningApplications(name: String, bundleIdentifier: String?) -> [NSRunningApplication] {
        if let bundleIdentifier {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter { !$0.isTerminated }
        }
        let normalizedName = normalizeApplicationName(name)
        return NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && normalizeApplicationName($0.localizedName ?? "") == normalizedName
        }
    }

    private static func waitForApplication(target: RunningApplicationGroup, expectedRunning: Bool, expectedActive: Bool, timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            let matches = matchingRunningApplications(name: target.name, bundleIdentifier: target.bundleIdentifier)
            let runningMatches = matches.filter { !$0.isTerminated }
            let stateMatches = expectedRunning ? !runningMatches.isEmpty : runningMatches.isEmpty
            let activeMatches = !expectedActive || runningMatches.contains(where: \.isActive)
            if stateMatches && activeMatches { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 120_000_000)
        } while true
    }

    private static func normalizeApplicationName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".app", with: "", options: [.caseInsensitive, .anchored])
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .joined(separator: " ")
    }

    private static func applicationCandidates(for query: String) -> [InstalledApplicationInfo] {
        var paths = Set<String>()
        let escaped = query.replacingOccurrences(of: "'", with: "\\'")
        let spotlightQuery = "kMDItemContentType == 'com.apple.application-bundle' && kMDItemFSName ==[c] '*\(escaped)*.app'"
        let data = runProcess(executable: "/usr/bin/mdfind", arguments: [spotlightQuery], timeoutSeconds: 3)
        if data.exitCode == 0,
           let output = String(data: data.stdout, encoding: .utf8) {
            output.split(whereSeparator: \.isNewline).prefix(80).forEach { path in paths.insert(String(path)) }
        }
        let fileManager = FileManager.default
        let folders = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        for folder in folders {
            guard let urls = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for url in urls where url.pathExtension.lowercased() == "app" {
                paths.insert(url.path)
            }
        }
        return paths.compactMap { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.pathExtension.lowercased() == "app" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard !name.isEmpty else { return nil }
            let bundleID = Bundle(url: url)?.bundleIdentifier
            return InstalledApplicationInfo(name: name, bundleIdentifier: bundleID, path: url.path)
        }
    }

    private static func scoreApplication(_ name: String, query: String) -> Double {
        let candidate = normalizeApplicationName(name)
        if candidate == query { return 1.0 }
        if candidate.hasPrefix(query) || query.hasPrefix(candidate) { return 0.93 }
        let queryTokens = Set(query.split(separator: " ").map(String.init))
        let candidateTokens = Set(candidate.split(separator: " ").map(String.init))
        let overlap = queryTokens.intersection(candidateTokens).count
        let tokenScore = queryTokens.isEmpty ? 0 : Double(overlap) / Double(queryTokens.count)
        let distance = levenshtein(candidate, query)
        let maxLength = max(candidate.count, query.count)
        let editScore = maxLength == 0 ? 0 : 1.0 - Double(distance) / Double(maxLength)
        return tokenScore * 0.6 + editScore * 0.4
    }

    private static func levenshtein(_ left: String, _ right: String) -> Int {
        let rightArray = Array(right)
        var previous = Array(0...rightArray.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for rightIndex in rightArray.indices {
                let substitution = previous[rightIndex] + (leftCharacter == rightArray[rightIndex] ? 0 : 1)
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                current.append(min(substitution, insertion, deletion))
            }
            previous = current
        }
        return previous.last ?? 0
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
            return RovaError(code: "MESSAGE_PERMISSION_DENIED", message: "Mac'te Wiqo için Messages/Otomasyon izni verilmedi.")
        }
        return RovaError(code: "MESSAGE_SEND_FAILED", message: "Mesaj gönderilemedi.")
    }

    static func createNote(_ payload: NotePayload) -> (data: CommandData?, error: RovaError?) {
        let title = appleScriptLiteral(payload.title)
        // Notes.app bodies are HTML; a plain-text body is wrapped in <div> per line so line breaks
        // survive, and the title is repeated as an <h1> the same way the Notes UI itself does.
        let htmlBody = ([payload.title] + payload.body.components(separatedBy: "\n"))
            .map { "<div>\(htmlEscape($0))</div>" }
            .joined()
        let body = appleScriptLiteral(htmlBody)
        let folderClause: String
        if let folderName = payload.folderName, !folderName.isEmpty {
            folderClause = "make new note at folder \(appleScriptLiteral(folderName)) with properties {name:\(title), body:\(body)}"
        } else {
            folderClause = "make new note with properties {name:\(title), body:\(body)}"
        }
        let source = "tell application \"Notes\" to \(folderClause)"
        guard let script = NSAppleScript(source: source) else {
            return (nil, RovaError(code: "NOTE_UNAVAILABLE", message: "Not oluşturma hazırlanamadı."))
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return (nil, nil) }
        let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        if number == -1743 {
            return (nil, RovaError(code: "NOTE_PERMISSION_DENIED", message: "Mac'te Wiqo için Notes/Otomasyon izni verilmedi."))
        }
        return (nil, RovaError(code: "NOTE_SAVE_FAILED", message: payload.folderName != nil ? "Not kaydedilemedi; klasör adını kontrol edin." : "Not kaydedilemedi."))
    }

    static func sendEmail(_ payload: EmailPayload) -> RovaError? {
        let recipient = appleScriptLiteral(payload.to)
        let subject = appleScriptLiteral(payload.subject)
        let body = appleScriptLiteral(payload.body)
        let source = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:\(subject), content:\(body), visible:false}
            tell newMessage
                make new to recipient at end of to recipients with properties {address:\(recipient)}
                send
            end tell
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            return RovaError(code: "EMAIL_UNAVAILABLE", message: "E-posta gönderme hazırlanamadı.")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return nil }
        let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        if number == -1743 {
            return RovaError(code: "EMAIL_PERMISSION_DENIED", message: "Mac'te Wiqo için Mail/Otomasyon izni verilmedi.")
        }
        return RovaError(code: "EMAIL_SEND_FAILED", message: "E-posta gönderilemedi.")
    }

    private static func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

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

    // MARK: - Explicit local filesystem capabilities

    private static let maxLocalReadBytes = 512 * 1024
    private static let maxProcessOutputBytes = 50 * 1024
    private static let maxScreenshotBytes = 700 * 1024

    static func listFiles(_ payload: LocalFileOperationPayload) -> (data: CommandData?, error: RovaError?) {
        guard let directory = resolvedLocalURL(payload.path), FileManager.default.fileExists(atPath: directory.path) else {
            return (nil, RovaError(code: "FILE_NOT_FOUND", message: "İstenen klasör bulunamadı.", category: "tool_failure"))
        }
        guard isDirectory(directory) else {
            return (nil, RovaError(code: "NOT_A_DIRECTORY", message: "İstenen yol bir klasör değil.", category: "tool_failure"))
        }
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
                .filter { !$0.lastPathComponent.isEmpty }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let start = min(max(payload.page, 0) * max(payload.pageSize, 1), urls.count)
            let page = urls.dropFirst(start).prefix(max(payload.pageSize, 1)).compactMap(fileSystemEntry)
            return (.files(Array(page)), nil)
        } catch {
            return (nil, localFileError(code: "FILE_LIST_FAILED", fallback: "Klasör içeriği listelenemedi.", error: error))
        }
    }

    static func readFile(_ payload: LocalFileOperationPayload) -> (data: CommandData?, error: RovaError?) {
        guard let file = resolvedLocalURL(payload.path), FileManager.default.fileExists(atPath: file.path) else {
            return (nil, RovaError(code: "FILE_NOT_FOUND", message: "İstenen dosya bulunamadı.", category: "tool_failure"))
        }
        guard !isDirectory(file), isRegularFile(file) else {
            return (nil, RovaError(code: "FILE_NOT_REGULAR", message: "Yalnızca normal dosyalar okunabilir.", category: "tool_failure"))
        }
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size <= maxLocalReadBytes else {
                return (nil, RovaError(code: "FILE_TOO_LARGE", message: "Bu dosya tek yanıt için çok büyük; daha küçük bir dosya veya sayfalı belge okuma kullan.", category: "tool_failure"))
            }
            let bytes = try Data(contentsOf: file, options: [.mappedIfSafe])
            let mimeType = mimeType(for: file)
            if let text = String(data: bytes, encoding: .utf8) {
                return (.fileData(FileDataContent(path: file.path, mimeType: mimeType, text: text, truncated: false)), nil)
            }
            return (.fileData(FileDataContent(path: file.path, mimeType: mimeType, base64: bytes.base64EncodedString(), truncated: false)), nil)
        } catch {
            return (nil, localFileError(code: "FILE_READ_FAILED", fallback: "Dosya okunamadı.", error: error))
        }
    }

    static func writeFile(_ payload: LocalFileOperationPayload) -> RovaError? {
        guard let content = payload.content,
              let destination = resolvedLocalURL(payload.path, allowingMissingLastComponent: true),
              let parent = resolvedLocalURL(destination.deletingLastPathComponent().path),
              isDirectory(parent) else {
            return RovaError(code: "INVALID_FILE_PATH", message: "Dosya yolu veya hedef klasör geçersiz.", category: "tool_failure")
        }
        guard !isSymbolicLink(destination) else {
            return RovaError(code: "SYMLINK_REJECTED", message: "Sembolik bağlantının üzerine yazılmadı.", category: "permission")
        }
        if FileManager.default.fileExists(atPath: destination.path) && !payload.overwrite {
            return RovaError(code: "FILE_EXISTS", message: "Aynı dosya zaten var; üzerine yazma onayı verilmedi.", category: "permission")
        }
        do {
            try Data(content.utf8).write(to: destination, options: [.atomic])
            return nil
        } catch {
            return localFileError(code: "FILE_WRITE_FAILED", fallback: "Dosya yazılamadı.", error: error)
        }
    }

    static func moveFile(_ payload: LocalFileOperationPayload) -> RovaError? {
        transferFile(payload, copy: false)
    }

    static func copyFile(_ payload: LocalFileOperationPayload) -> RovaError? {
        transferFile(payload, copy: true)
    }

    private static func transferFile(_ payload: LocalFileOperationPayload, copy: Bool) -> RovaError? {
        guard let source = resolvedLocalURL(payload.path),
              let destination = payload.destination.flatMap({ resolvedLocalURL($0, allowingMissingLastComponent: true) }),
              FileManager.default.fileExists(atPath: source.path),
              let parent = resolvedLocalURL(destination.deletingLastPathComponent().path),
              isDirectory(parent) else {
            return RovaError(code: "INVALID_FILE_PATH", message: "Kaynak, hedef veya hedef klasör geçersiz.", category: "tool_failure")
        }
        guard !isSymbolicLink(source), !isSymbolicLink(destination) else {
            return RovaError(code: "SYMLINK_REJECTED", message: "Sembolik bağlantılar üzerinden dosya işlemi yapılmadı.", category: "permission")
        }
        if isDirectory(source) && !payload.recursive {
            return RovaError(code: "RECURSIVE_REQUIRED", message: "Klasör işlemi için recursive=true açıkça belirtilmeli.", category: "permission")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            guard payload.overwrite else {
                return RovaError(code: "FILE_EXISTS", message: "Hedef zaten var; üzerine yazma onayı verilmedi.", category: "permission")
            }
            do {
                try FileManager.default.removeItem(at: destination)
            } catch {
                return localFileError(code: "FILE_REPLACE_FAILED", fallback: "Mevcut hedef değiştirilemedi.", error: error)
            }
        }
        do {
            if copy {
                try FileManager.default.copyItem(at: source, to: destination)
            } else {
                try FileManager.default.moveItem(at: source, to: destination)
            }
            return nil
        } catch {
            return localFileError(code: copy ? "FILE_COPY_FAILED" : "FILE_MOVE_FAILED", fallback: copy ? "Dosya kopyalanamadı." : "Dosya taşınamadı.", error: error)
        }
    }

    static func deleteFile(_ payload: LocalFileOperationPayload) -> RovaError? {
        guard let target = resolvedLocalURL(payload.path), FileManager.default.fileExists(atPath: target.path) else {
            return RovaError(code: "FILE_NOT_FOUND", message: "Silinecek dosya bulunamadı.", category: "tool_failure")
        }
        let normalized = target.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard normalized != "/", normalized != home, normalized != "/Users" else {
            return RovaError(code: "PROTECTED_PATH", message: "Sistem veya kullanıcı kök klasörü silinemez.", category: "permission")
        }
        guard !isSymbolicLink(target) else {
            return RovaError(code: "SYMLINK_REJECTED", message: "Sembolik bağlantı silinmedi.", category: "permission")
        }
        guard !isDirectory(target) || payload.recursive else {
            return RovaError(code: "RECURSIVE_REQUIRED", message: "Klasör silmek için recursive=true açıkça belirtilmeli.", category: "permission")
        }
        do {
            try FileManager.default.removeItem(at: target)
            return nil
        } catch {
            return localFileError(code: "FILE_DELETE_FAILED", fallback: "Dosya silinemedi.", error: error)
        }
    }

    // MARK: - Shortcuts and Accessibility controls

    static func runShortcut(_ payload: ShortcutPayload) -> (data: CommandData?, error: RovaError?) {
        let snapshot = runProcess(
            executable: "/usr/bin/shortcuts",
            arguments: ["run", payload.shortcut.rawValue, "--output-type", "public.plain-text"],
            timeoutSeconds: payload.timeoutSeconds
        )
        let output = String(decoding: snapshot.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(decoding: snapshot.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if snapshot.timedOut {
            return (nil, RovaError(code: "SHORTCUT_TIMEOUT", message: "Shortcut çalıştırma süresi doldu.", category: "timeout"))
        }
        guard snapshot.exitCode == 0 else {
            if stderr.localizedCaseInsensitiveContains("not authorized") || stderr.localizedCaseInsensitiveContains("not permitted") || stderr.localizedCaseInsensitiveContains("permission") || stderr.localizedCaseInsensitiveContains("izin") {
                return (nil, RovaError(code: "SHORTCUT_PERMISSION_REQUIRED", message: "\(payload.shortcut.displayName) için Wiqo'nun Shortcuts/Otomasyon iznini açın. Ayarlar: x-apple.systempreferences:com.apple.preference.security?Privacy_Automation", category: "permission"))
            }
            let code = stderr.localizedCaseInsensitiveContains("not found") || stderr.localizedCaseInsensitiveContains("bulunamadı")
                ? "SHORTCUT_NOT_INSTALLED"
                : "SHORTCUT_FAILED"
            return (nil, RovaError(code: code, message: "\(payload.shortcut.displayName) çalıştırılamadı. Shortcut'ın Wiqo tarafından kurulduğunu kontrol edin.", category: "tool_failure"))
        }

        let observedState = observedShortcutState(payload.shortcut, output: output)
        let verified = observedState == payload.shortcut.expectedState
        let data = CommandData.shortcutResult(ShortcutExecutionContent(
            shortcut: payload.shortcut,
            output: String(output.prefix(4_000)),
            expectedState: payload.shortcut.expectedState,
            observedState: observedState,
            verified: verified
        ))
        guard verified else {
            return (data, RovaError(code: "SHORTCUT_VERIFICATION_FAILED", message: "\(payload.shortcut.displayName) çalıştı ancak istenen durum doğrulanamadı.", category: "tool_failure"))
        }
        return (data, nil)
    }

    private static func observedShortcutState(_ shortcut: WiqoShortcut, output: String) -> String? {
        let normalizedOutput = output.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        switch shortcut {
        case .wifiOn, .wifiOff:
            return currentWiFiState() ?? markerState(in: normalizedOutput)
        case .bluetoothOn, .bluetoothOff:
            return currentBluetoothState() ?? markerState(in: normalizedOutput)
        case .focusDoNotDisturbOn, .focusDoNotDisturbOff,
             .focusPersonalOn, .focusPersonalOff,
             .focusWorkOn, .focusWorkOff:
            return observedFocusState(shortcut, output: normalizedOutput)
        }
    }

    private static func markerState(in output: String) -> String? {
        if output.contains("wiqostate:on") || output.contains("state:on") { return "on" }
        if output.contains("wiqostate:off") || output.contains("state:off") { return "off" }
        return nil
    }

    private static func observedFocusState(_ shortcut: WiqoShortcut, output: String) -> String? {
        let inactiveMarkers = ["off", "kapali", "none", "no focus", "no active focus", "inactive", "devre disi"]
        let turningOff: Bool
        switch shortcut {
        case .focusDoNotDisturbOff, .focusPersonalOff, .focusWorkOff:
            turningOff = true
        default:
            turningOff = false
        }
        if inactiveMarkers.contains(where: output.contains) { return "off" }

        let targetMarkers: [String]
        switch shortcut {
        case .focusDoNotDisturbOn, .focusDoNotDisturbOff:
            targetMarkers = ["rahatsiz etme", "do not disturb", "default"]
        case .focusPersonalOn, .focusPersonalOff:
            targetMarkers = ["kisisel", "personal", "personal-time"]
        case .focusWorkOn, .focusWorkOff:
            targetMarkers = ["is", "work"]
        default:
            targetMarkers = []
        }
        if turningOff && targetMarkers.contains(where: output.contains) { return "on" }
        let allFocusMarkers = [
            "rahatsiz etme", "do not disturb", "default", "kisisel", "personal", "personal-time", "is", "work"
        ]
        if turningOff && allFocusMarkers.contains(where: output.contains) { return "off" }
        if targetMarkers.contains(where: output.contains) || output.contains("on") || output.contains("acik") || output.contains("enabled") {
            return "on"
        }
        return nil
    }

    private static func currentWiFiState() -> String? {
        let interfaceSnapshot = runProcess(executable: "/usr/sbin/networksetup", arguments: ["-listallhardwareports"], timeoutSeconds: 3)
        guard let interfaces = String(data: interfaceSnapshot.stdout, encoding: .utf8) else { return nil }
        let lines = interfaces.split(whereSeparator: \.isNewline).map(String.init)
        guard let wifiIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "Hardware Port: Wi-Fi" }),
              wifiIndex + 1 < lines.count else { return nil }
        let deviceLine = lines[(wifiIndex + 1)...].first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Device:") })
        guard let deviceLine else { return nil }
        let device = deviceLine.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
        let snapshot = runProcess(executable: "/usr/sbin/networksetup", arguments: ["-getairportpower", device], timeoutSeconds: 3)
        let text = String(decoding: snapshot.stdout, as: UTF8.self).lowercased()
        if text.contains("on") { return "on" }
        if text.contains("off") { return "off" }
        return nil
    }

    private static func currentBluetoothState() -> String? {
        let snapshot = runProcess(executable: "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"], timeoutSeconds: 5)
        guard snapshot.exitCode == 0 else { return nil }
        let output = String(decoding: snapshot.stdout, as: UTF8.self).lowercased()
        if output.contains("\"controller_power_state\" : 1") || output.contains("\"controller_power_state\": 1") { return "on" }
        if output.contains("\"controller_power_state\" : 0") || output.contains("\"controller_power_state\": 0") { return "off" }
        if output.contains("bluetooth power: on") { return "on" }
        if output.contains("bluetooth power: off") { return "off" }
        return nil
    }

    static func controlUIElement(_ payload: UIElementPayload) -> (data: CommandData?, error: RovaError?) {
        guard hasAccessibilityAccess() else {
            return (nil, RovaError(code: "ACCESSIBILITY_PERMISSION_REQUIRED", message: "Wiqo'nun arayüz kontrolü için Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik bölümünden izin verin. Ayarlar: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility", category: "permission"))
        }
        guard let runningApplication = NSRunningApplication.runningApplications(withBundleIdentifier: payload.bundleIdentifier).first,
              runningApplication.processIdentifier > 0 else {
            return (nil, RovaError(code: "UI_TARGET_NOT_RUNNING", message: "Hedef uygulama çalışmıyor; arayüz kontrolü için önce uygulamayı açın.", category: "tool_failure"))
        }

        let application = AXUIElementCreateApplication(runningApplication.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(application, 0.75)
        let roots: [AXUIElement]
        if let windowTitle = payload.windowTitle {
            roots = axWindows(of: application).filter { axMatches($0, text: windowTitle) }
            guard !roots.isEmpty else {
                return (nil, RovaError(code: "UI_WINDOW_NOT_FOUND", message: "Hedef pencere bulunamadı.", category: "tool_failure"))
            }
        } else {
            roots = [application]
        }

        let search = axMatches(roots: roots, label: payload.label, role: payload.role)
        guard !search.timedOut else {
            return (nil, RovaError(code: "UI_SEARCH_TIMEOUT", message: "Accessibility ağacı zamanında yanıt vermedi; hedef uygulama meşgul olabilir.", category: "timeout"))
        }
        let matches = search.matches
        guard matches.count == 1, let element = matches.first else {
            if matches.count > 1 {
                return (nil, RovaError(code: "UI_ELEMENT_AMBIGUOUS", message: "Birden fazla Accessibility öğesi eşleşti; daha net bir etiket veya rol belirtin.", category: "tool_failure"))
            }
            return (nil, RovaError(code: "UI_ELEMENT_NOT_FOUND", message: "Accessibility ağacında hedef öğe bulunamadı.", category: "tool_failure"))
        }

        let actionError: AXError
        switch payload.action {
        case .press:
            _ = AXUIElementSetMessagingTimeout(element, 0.75)
            actionError = AXUIElementPerformAction(element, kAXPressAction as CFString)
        case .setValue:
            guard let value = payload.value else {
                return (nil, RovaError(code: "INVALID_PAYLOAD", message: "Değer atama eylemi için value gerekli.", category: "validation"))
            }
            _ = AXUIElementSetMessagingTimeout(element, 0.75)
            actionError = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        }
        guard actionError == .success else {
            return (nil, RovaError(code: "UI_ACTION_FAILED", message: "Accessibility eylemi hedef öğeye uygulanamadı.", category: "tool_failure"))
        }

        Thread.sleep(forTimeInterval: 0.12)
        let content = uiElementContent(element, bundleIdentifier: payload.bundleIdentifier, matchedCount: 1, expectedValue: payload.expectedValue)
        guard payload.expectedValue == nil || content.verified else {
            return (.uiElement(content), RovaError(code: "UI_VERIFICATION_FAILED", message: "Accessibility eylemi uygulandı ancak beklenen değer doğrulanamadı.", category: "tool_failure"))
        }
        return (.uiElement(content), nil)
    }

    private struct AXSearchResult {
        let matches: [AXUIElement]
        let timedOut: Bool
    }

    private static func axMatches(roots: [AXUIElement], label: String, role: String?) -> AXSearchResult {
        let normalizedLabel = normalizeAXText(label)
        var queue = roots.map { ($0, 0) }
        var matches: [AXUIElement] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(5)
        while !queue.isEmpty && visited < 4_000 && Date() < deadline {
            let (element, depth) = queue.removeFirst()
            visited += 1
            guard depth <= 32 else { continue }
            let title = axString(element, attribute: kAXTitleAttribute)
            let description = axString(element, attribute: kAXDescriptionAttribute)
            let elementRole = axString(element, attribute: kAXRoleAttribute)
            let texts = [title, description].compactMap { $0 }.map(normalizeAXText)
            if texts.contains(normalizedLabel), (role == nil || normalizeAXText(elementRole ?? "") == normalizeAXText(role!)) {
                matches.append(element)
                if matches.count > 1 { return AXSearchResult(matches: matches, timedOut: false) }
            }
            for child in axChildren(element) {
                queue.append((child, depth + 1))
            }
        }
        return AXSearchResult(matches: matches, timedOut: !queue.isEmpty && Date() >= deadline)
    }

    private static func axWindows(of application: AXUIElement) -> [AXUIElement] {
        _ = AXUIElementSetMessagingTimeout(application, 0.75)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        _ = AXUIElementSetMessagingTimeout(element, 0.75)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children
    }

    private static func axString(_ element: AXUIElement, attribute: String) -> String? {
        _ = AXUIElementSetMessagingTimeout(element, 0.75)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func axBool(_ element: AXUIElement, attribute: String) -> Bool? {
        _ = AXUIElementSetMessagingTimeout(element, 0.75)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func axMatches(_ element: AXUIElement, text: String) -> Bool {
        let normalized = normalizeAXText(text)
        return [axString(element, attribute: kAXTitleAttribute), axString(element, attribute: kAXDescriptionAttribute)]
            .compactMap { $0 }
            .map(normalizeAXText)
            .contains(normalized)
    }

    private static func normalizeAXText(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uiElementContent(_ element: AXUIElement, bundleIdentifier: String, matchedCount: Int, expectedValue: String?) -> UIElementContent {
        let value = axString(element, attribute: kAXValueAttribute) ?? axString(element, attribute: kAXValueDescriptionAttribute)
        let verified = expectedValue.map { normalizeAXText(value ?? "") == normalizeAXText($0) } ?? true
        return UIElementContent(
            bundleIdentifier: bundleIdentifier,
            title: axString(element, attribute: kAXTitleAttribute),
            role: axString(element, attribute: kAXRoleAttribute),
            value: value,
            description: axString(element, attribute: kAXDescriptionAttribute),
            enabled: axBool(element, attribute: kAXEnabledAttribute),
            matchedCount: matchedCount,
            verified: verified
        )
    }

    static func clickScreen(_ payload: ScreenClickPayload) -> (data: CommandData?, error: RovaError?) {
        guard hasAccessibilityAccess() else {
            return (nil, RovaError(code: "ACCESSIBILITY_PERMISSION_REQUIRED", message: "Ekran tıklaması için Wiqo'ya Erişilebilirlik izni verin. Ayarlar: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility", category: "permission"))
        }
        guard CGPreflightScreenCaptureAccess() else {
            return (nil, RovaError(code: "SCREEN_RECORDING_PERMISSION_REQUIRED", message: "Ekran tıklamasının görüntüyle eşleşmesi için Wiqo'ya Ekran Kaydı izni verin. Ayarlar: x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture", category: "permission"))
        }
        let displayID = payload.displayID ?? CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else {
            return (nil, RovaError(code: "DISPLAY_NOT_FOUND", message: "Hedef ekran bulunamadı.", category: "tool_failure"))
        }
        let screenshotAspect = Double(payload.screenshotWidth) / Double(payload.screenshotHeight)
        let displayAspect = Double(bounds.width) / Double(bounds.height)
        guard abs(screenshotAspect - displayAspect) / displayAspect <= 0.25 else {
            return (nil, RovaError(code: "STALE_SCREEN_OBSERVATION", message: "Ekran gözlemi mevcut ekran düzeniyle eşleşmiyor; yeniden ekran görüntüsü alın.", category: "tool_failure"))
        }
        let point = CGPoint(
            x: bounds.minX + CGFloat(payload.normalizedX) * bounds.width,
            y: bounds.minY + CGFloat(payload.normalizedY) * bounds.height
        )
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            return (nil, RovaError(code: "SCREEN_CLICK_UNAVAILABLE", message: "Ekran tıklaması başlatılamadı.", category: "tool_failure"))
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return (.screenClick(ScreenClickContent(displayID: displayID, x: point.x, y: point.y, expectedTarget: payload.expectedTarget)), nil)
    }

    // MARK: - Sandboxed code execution

    static func executeCode(_ payload: CodeExecutionPayload) -> (data: CommandData?, error: RovaError?) {
        // `/private/tmp/...` and `/tmp/...` refer to the same inode, but the sandbox's `subpath`
        // rules match against the resolved path - a profile built from the raw `/var/folders/...`
        // URL (which is really a symlink through `/private/var`) silently denies the very
        // directory the script lives in. Resolving up front is what makes every subpath rule
        // below actually apply to the directory the script runs from.
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rova-code-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
            let fileExtension: String
            switch payload.language.lowercased() {
            case "python": fileExtension = "py"
            case "javascript": fileExtension = "js"
            case "shell": fileExtension = "sh"
            default:
                return (nil, RovaError(code: "UNSUPPORTED_LANGUAGE", message: "Yalnızca Python, JavaScript veya shell çalıştırılabilir.", category: "tool_failure"))
            }
            let scriptURL = temporaryDirectory.appendingPathComponent("main.\(fileExtension)")
            try Data(payload.code.utf8).write(to: scriptURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

            let command: [String]
            switch payload.language.lowercased() {
            case "python": command = ["/usr/bin/env", "python3", scriptURL.path] + payload.arguments
            case "javascript": command = ["/usr/bin/env", "node", scriptURL.path] + payload.arguments
            case "shell": command = ["/bin/sh", scriptURL.path] + payload.arguments
            default: command = []
            }
            let profile = sandboxProfile(for: temporaryDirectory, allowNetwork: payload.allowNetwork)
            // Process has no public pre-exec hook on macOS, so a fixed shell wrapper applies the
            // CPU-time limit and then execs the already-separated argv vector - user code never
            // becomes part of this shell string. (There is no virtual-memory limit: Darwin's
            // `ulimit -v` is a no-op for RLIMIT_AS - it always fails with EINVAL and every
            // interpreter still runs unbounded - so it only added silent stderr noise here.)
            let limiter = "ulimit -t \(payload.timeoutSeconds); exec \"$@\""
            let arguments = ["-p", profile, "/bin/sh", "-c", limiter, "rova-code"] + command
            // A GUI app launched by launchd gets a minimal PATH/cwd that usually omits Homebrew
            // and always predates the script's own directory - both `env python3`/`env node`
            // lookups and the sandbox's own directory-traversal checks need better defaults than
            // that inherited environment provides.
            let environment: [String: String] = [
                "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": NSHomeDirectory(),
                "TMPDIR": temporaryDirectory.path + "/",
                "LANG": "en_US.UTF-8",
                // bash/sh call getcwd() at shell-init to populate $PWD unless it's already set to
                // a value that stats to the same directory - the sandbox profile above only grants
                // file-read-DATA (not just metadata) on this run's own directory, not on its
                // ancestors, so getcwd()'s directory-walk fallback fails there with "cannot access
                // parent directories" even though the actual chdir (`workingDirectory` below)
                // already succeeded. Pre-seeding $PWD sidesteps that call entirely instead of
                // loosening the sandbox to grant directory-listing on every ancestor up to /.
                "PWD": temporaryDirectory.path
            ]
            let snapshot = runProcess(
                executable: "/usr/bin/sandbox-exec",
                arguments: arguments,
                timeoutSeconds: payload.timeoutSeconds,
                workingDirectory: temporaryDirectory,
                environment: environment
            )
            let stdout = String(decoding: snapshot.stdout, as: UTF8.self)
            let stderr = String(decoding: snapshot.stderr, as: UTF8.self)
            let output = ProcessOutputContent(language: payload.language, exitCode: snapshot.timedOut ? -1 : snapshot.exitCode, stdout: stdout, stderr: stderr, truncated: snapshot.truncated, durationMs: snapshot.durationMs)
            if snapshot.timedOut {
                return (.processOutput(output), RovaError(code: "CODE_TIMEOUT", message: "Kod çalıştırma süresi doldu.", category: "timeout"))
            }
            if snapshot.exitCode != 0 {
                // A shell-init cwd warning (harmless, unrelated to the script's own failure - see
                // the PWD comment above) was eating the whole 300-char budget and hiding the actual
                // reason underneath it. Drop that specific noise before truncating so the model
                // sees the real error instead of two repeated "shell-init:" lines.
                let meaningfulLines = stderr
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .filter { !$0.hasPrefix("shell-init: error retrieving current directory") }
                let detail = meaningfulLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                let message = detail.isEmpty ? "Kod hata ile sonlandı (çıkış kodu \(snapshot.exitCode))." : "Kod hata ile sonlandı: \(detail.prefix(300))"
                return (.processOutput(output), RovaError(code: "CODE_FAILED", message: message, category: "tool_failure"))
            }
            return (.processOutput(output), nil)
        } catch {
            return (nil, localFileError(code: "CODE_SANDBOX_FAILED", fallback: "Kod izole ortamda başlatılamadı.", error: error))
        }
    }

    private static func sandboxProfile(for directory: URL, allowNetwork: Bool) -> String {
        let escapedDirectory = directory.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let networkRule = allowNetwork ? "(allow network*)" : "(deny network*)"
        // `file-read-metadata` (stat/access/readlink - never file content) is left unscoped: the
        // sandbox needs it on arbitrary ancestor directories just to resolve the script's own
        // path and the interpreter's, and macOS has no separate "traverse this directory" rule.
        // Content reads (`file-read-data`) stay confined to the interpreter/toolchain locations
        // below plus this run's own directory. `mach-lookup`/`iokit-open`/`signal` are required
        // for essentially any dynamically-linked macOS binary to even launch under `deny default`
        // (dyld and libSystem talk to several system services before `main()` runs) - none of
        // that grants filesystem or network access on its own. `lsopen`/`appleevent-send` are
        // what let a script use `open -a "App"` or `osascript`/AppleScript to control another
        // app (the model's terminal-based fallback for anything computer_application can't
        // resolve) - without them Launch Services and Apple Events both fail closed inside the
        // sandbox even though the app is actually installed and running. Neither one bypasses
        // macOS's own per-app Automation permission prompt; the user still approves that once,
        // the same as any AppleScript control elsewhere in this app.
        return """
        (version 1) (deny default) \
        (allow process*) (allow sysctl-read) (allow mach-lookup) (allow iokit-open) (allow signal) \
        (allow lsopen) (allow appleevent-send) \
        (allow file-read-metadata) \
        (allow file-read-data \
          (literal "/") \
          (subpath "/System") (subpath "/Library") (subpath "/Applications") \
          (subpath "/usr") (subpath "/bin") \
          (subpath "/opt/homebrew") (subpath "/usr/local") \
          (subpath "/private/etc") (subpath "/private/var/db") \
          (subpath "\(escapedDirectory)")) \
        (allow file-write* (subpath "\(escapedDirectory)")) \
        \(networkRule)
        """
    }

    // MARK: - Screen capture for Gemini vision

    static func captureScreen(_ payload: ScreenCapturePayload) async -> (data: CommandData?, error: RovaError?) {
        guard CGPreflightScreenCaptureAccess() else {
            return (nil, RovaError(code: "SCREEN_RECORDING_PERMISSION_REQUIRED", message: "Ekran görüntüsü için Sistem Ayarları > Gizlilik ve Güvenlik > Ekran ve Sistem Sesi Kaydı bölümünden Wiqo'ya izin verin. Ayarlar: x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture", category: "permission"))
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = payload.displayID.flatMap({ id in content.displays.first(where: { $0.displayID == id }) }) ?? content.displays.first else {
                return (nil, RovaError(code: "DISPLAY_NOT_FOUND", message: "Ekran bulunamadı.", category: "tool_failure"))
            }
            let scale = min(1.0, CGFloat(payload.maxWidth) / CGFloat(max(display.width, 1)))
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(CGFloat(display.width) * scale))
            configuration.height = max(1, Int(CGFloat(display.height) * scale))
            configuration.showsCursor = true
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let resized = resizedImage(image, maxWidth: payload.maxWidth) else {
                return (nil, RovaError(code: "SCREEN_CAPTURE_FAILED", message: "Ekran görüntüsü hazırlanamadı.", category: "tool_failure"))
            }
            var jpeg: Data?
            for quality in [0.72, 0.58, 0.42] {
                let rep = NSBitmapImageRep(cgImage: resized)
                if let candidate = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]), candidate.count <= maxScreenshotBytes {
                    jpeg = candidate
                    break
                }
            }
            guard let jpeg else {
                return (nil, RovaError(code: "SCREEN_TOO_LARGE", message: "Ekran görüntüsü güvenli aktarım sınırına sığmadı.", category: "tool_failure"))
            }
            let screenshot = ScreenshotContent(filename: "rova-screen-\(UUID().uuidString).jpg", mimeType: "image/jpeg", dataBase64: jpeg.base64EncodedString(), width: resized.width, height: resized.height)
            return (.screenshot(screenshot), nil)
        } catch {
            return (nil, RovaError(code: "SCREEN_CAPTURE_FAILED", message: "Ekran görüntüsü alınamadı. Screen Recording iznini kontrol edin.", category: "permission"))
        }
    }

    private static func resizedImage(_ image: CGImage, maxWidth: Int) -> CGImage? {
        let scale = min(1.0, CGFloat(maxWidth) / CGFloat(max(image.width, 1)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static func fileSystemEntry(_ url: URL) -> FileSystemEntry? {
        guard !isSymbolicLink(url) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { return nil }
        return FileSystemEntry(path: url.standardizedFileURL.path, name: url.lastPathComponent, byteCount: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate, isDirectory: values.isDirectory == true)
    }

    private static func resolvedLocalURL(_ rawPath: String, allowingMissingLastComponent: Bool = false) -> URL? {
        guard RovaValidation.isValidLocalPath(rawPath) else { return nil }
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let rawURL = URL(fileURLWithPath: expanded).standardizedFileURL
        if FileManager.default.fileExists(atPath: rawURL.path) {
            guard !isSymbolicLink(rawURL) else { return nil }
            // Resolve existing parent aliases (for example macOS's /var alias), but never
            // follow a symlink at the requested final entry. This prevents a model-produced
            // path from silently operating on a symlink target while keeping legitimate system
            // path aliases usable.
            return rawURL.resolvingSymlinksInPath().standardizedFileURL
        }
        guard allowingMissingLastComponent else { return nil }
        let parent = rawURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path), !isSymbolicLink(parent), isDirectory(parent) else { return nil }
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
        guard !isSymbolicLink(resolvedParent), isDirectory(resolvedParent) else { return nil }
        return resolvedParent.appendingPathComponent(rawURL.lastPathComponent, isDirectory: false)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func localFileError(code: String, fallback: String, error: Error) -> RovaError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && [257, 513, NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code) {
            return RovaError(code: "FULL_DISK_ACCESS_REQUIRED", message: "Wiqo'nun bu klasöre erişmesi için Sistem Ayarları > Gizlilik ve Güvenlik > Tam Disk Erişimi bölümünden izin verin. Ayarlar: x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles", category: "permission")
        }
        return RovaError(code: code, message: fallback, category: "tool_failure")
    }

    private struct ProcessSnapshot {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
        let timedOut: Bool
        let truncated: Bool
        let durationMs: Int
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        timeoutSeconds: Int,
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) -> ProcessSnapshot {
        let started = Date()
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        if let environment { process.environment = environment }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        var stdout = Data()
        var stderr = Data()
        var truncated = false
        var timedOut = false

        do {
            try process.run()
            _ = fcntl(stdoutPipe.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
            _ = fcntl(stderrPipe.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
            let deadline = Date().addingTimeInterval(TimeInterval(max(1, timeoutSeconds)))
            while process.isRunning {
                drainProcessPipe(stdoutPipe.fileHandleForReading, into: &stdout, truncated: &truncated)
                drainProcessPipe(stderrPipe.fileHandleForReading, into: &stderr, truncated: &truncated)
                if process.isRunning && Date() >= deadline {
                    timedOut = true
                    process.terminate()
                    Thread.sleep(forTimeInterval: 0.15)
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                if process.isRunning { Thread.sleep(forTimeInterval: 0.01) }
            }
            process.waitUntilExit()
            drainProcessPipe(stdoutPipe.fileHandleForReading, into: &stdout, truncated: &truncated)
            drainProcessPipe(stderrPipe.fileHandleForReading, into: &stderr, truncated: &truncated)
        } catch {
            stderr.append(Data("İşlem başlatılamadı.".utf8))
            return ProcessSnapshot(stdout: stdout, stderr: stderr, exitCode: -1, timedOut: false, truncated: truncated, durationMs: Int(Date().timeIntervalSince(started) * 1_000))
        }
        return ProcessSnapshot(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus, timedOut: timedOut, truncated: truncated, durationMs: Int(Date().timeIntervalSince(started) * 1_000))
    }

    private static func drainProcessPipe(_ handle: FileHandle, into data: inout Data, truncated: inout Bool) {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(handle.fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count > 0 else { return }
            let bytesRead = Int(count)
            let bytesBefore = data.count
            if data.count < maxProcessOutputBytes {
                let remaining = maxProcessOutputBytes - data.count
                data.append(contentsOf: buffer.prefix(min(bytesRead, remaining)))
            }
            if bytesBefore >= maxProcessOutputBytes || bytesRead > maxProcessOutputBytes - bytesBefore { truncated = true }
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

    private static func remindersStore() async -> EKEventStore? {
        let store = EKEventStore()
        let granted = await withCheckedContinuation { continuation in
            if #available(macOS 14.0, *) {
                store.requestFullAccessToReminders { granted, _ in continuation.resume(returning: granted) }
            } else {
                store.requestAccess(to: .reminder) { granted, _ in continuation.resume(returning: granted) }
            }
        }
        return granted ? store : nil
    }

    private static func reminderInfo(_ reminder: EKReminder) -> ReminderInfo {
        var dueAt: Date?
        if let components = reminder.dueDateComponents {
            dueAt = Calendar.current.date(from: components)
        }
        return ReminderInfo(
            identifier: reminder.calendarItemIdentifier,
            title: reminder.title ?? "(Başlıksız)",
            dueAt: dueAt,
            notes: reminder.notes,
            listName: reminder.calendar?.title ?? "Hatırlatıcılar",
            isCompleted: reminder.isCompleted
        )
    }

    /// Lists incomplete reminders due within the next 30 days plus any without a due date,
    /// mirroring how the Reminders app's "Today"/"Scheduled" smart lists read - a plain "all
    /// reminders ever created" dump would be far less useful to the model.
    static func listReminders() async -> (data: CommandData?, error: RovaError?) {
        guard let store = await remindersStore() else {
            return (nil, RovaError(code: "REMINDERS_PERMISSION_DENIED", message: "Hatırlatıcılar erişimi verilmedi."))
        }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let cutoff = Calendar.current.date(byAdding: .day, value: 30, to: Date())
        // EKReminder isn't Sendable, so it's mapped to the Sendable ReminderInfo before crossing
        // back out of the completion handler rather than after.
        let infos: [ReminderInfo] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let filtered = (reminders ?? [])
                    .filter { reminder in
                        guard let components = reminder.dueDateComponents, let due = Calendar.current.date(from: components) else { return true }
                        return cutoff == nil || due <= cutoff!
                    }
                    .sorted { lhs, rhs in
                        let lhsDue = lhs.dueDateComponents.flatMap(Calendar.current.date(from:)) ?? .distantFuture
                        let rhsDue = rhs.dueDateComponents.flatMap(Calendar.current.date(from:)) ?? .distantFuture
                        return lhsDue < rhsDue
                    }
                    .prefix(100)
                    .map(reminderInfo)
                continuation.resume(returning: Array(filtered))
            }
        }
        return (.reminders(infos), nil)
    }

    static func createReminder(_ payload: ReminderPayload) async -> (data: CommandData?, error: RovaError?) {
        guard let store = await remindersStore() else {
            return (nil, RovaError(code: "REMINDERS_PERMISSION_DENIED", message: "Hatırlatıcılar erişimi verilmedi."))
        }
        let list: EKCalendar?
        if let name = payload.listName, !name.isEmpty {
            list = store.calendars(for: .reminder).first { $0.title == name }
        } else {
            list = store.defaultCalendarForNewReminders()
        }
        guard let list else {
            return (nil, RovaError(code: "REMINDERS_LIST_NOT_FOUND", message: "Hatırlatıcının ekleneceği liste bulunamadı."))
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = payload.title
        reminder.notes = payload.notes
        reminder.calendar = list
        if let dueAt = payload.dueAt {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueAt)
        }
        do {
            try store.save(reminder, commit: true)
            return (.reminders([reminderInfo(reminder)]), nil)
        } catch {
            return (nil, RovaError(code: "REMINDER_SAVE_FAILED", message: "Hatırlatıcı kaydedilemedi."))
        }
    }

    static func completeReminder(_ payload: CompleteReminderPayload) async -> (data: CommandData?, error: RovaError?) {
        guard let store = await remindersStore() else {
            return (nil, RovaError(code: "REMINDERS_PERMISSION_DENIED", message: "Hatırlatıcılar erişimi verilmedi."))
        }
        guard let item = store.calendarItem(withIdentifier: payload.identifier) as? EKReminder else {
            return (nil, RovaError(code: "REMINDER_NOT_FOUND", message: "Hatırlatıcı bulunamadı; listeyi yeniden alıp tekrar dene."))
        }
        item.isCompleted = true
        do {
            try store.save(item, commit: true)
            return (.reminders([reminderInfo(item)]), nil)
        } catch {
            return (nil, RovaError(code: "REMINDER_SAVE_FAILED", message: "Hatırlatıcı güncellenemedi."))
        }
    }

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
                        return RovaError(code: "PERMISSION_DENIED", message: "Mac'te Wiqo için Otomasyon izni verilmedi. Sistem Ayarları > Gizlilik ve Güvenlik > Otomasyon altından izin verin.")
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
        guard getifaddrs(&pointer) == 0, let first = pointer else { return "Kullanılamıyor" }
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
        return "Kullanılamıyor"
    }
}
