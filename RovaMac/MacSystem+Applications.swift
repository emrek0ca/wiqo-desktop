import AppKit
import Foundation

/// Finding, launching, controlling and quitting applications.
extension MacSystem {
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
}
