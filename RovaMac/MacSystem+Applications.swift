import AppKit
import Foundation
import os

/// How a person names an application, reduced to something comparable: case, diacritics, the
/// Turkish dotless i, a ".app" suffix, a possessive/case suffix ("Safari'yi", "Chrome’u") and
/// filler words ("Safari uygulamasını") are all dropped.
enum ApplicationNameMatcher {
    private static let fillerWords: Set<String> = [
        "uygulama", "uygulamasi", "uygulamasini", "uygulamayi", "uygulamasina", "uygulamasinda",
        "program", "programi", "programini", "app", "application", "the"
    ]

    static func normalize(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasSuffix(".app") { text = String(text.dropLast(4)) }
        text = text
            .replacingOccurrences(of: "İ", with: "i")
            .lowercased()
            .replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var tokens: [String] = []
        for rawToken in text.split(whereSeparator: { $0.isWhitespace }) {
            // "safari'yi", "chrome’u", "notlar`i": the suffix after an apostrophe is grammar.
            let token = rawToken.split(whereSeparator: { "'’`´".contains($0) }).first.map(String.init) ?? ""
            let cleaned = token
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "+" })
                .joined(separator: " ")
            tokens.append(contentsOf: cleaned.split(separator: " ").map(String.init))
        }
        let meaningful = tokens.filter { !fillerWords.contains($0) }
        return (meaningful.isEmpty ? tokens : meaningful).joined(separator: " ")
    }

    /// 1.0 exact, 0.93 whole-word prefix, otherwise a blend of shared words and edit distance.
    static func score(_ name: String, query: String) -> Double {
        let candidate = normalize(name)
        guard !candidate.isEmpty, !query.isEmpty else { return 0 }
        if candidate == query { return 1.0 }
        if candidate.hasPrefix(query + " ") || query.hasPrefix(candidate + " ") { return 0.93 }
        if candidate.hasPrefix(query) || query.hasPrefix(candidate) { return 0.88 }
        let queryTokens = Set(query.split(separator: " ").map(String.init))
        let candidateTokens = Set(candidate.split(separator: " ").map(String.init))
        let overlap = queryTokens.intersection(candidateTokens).count
        let tokenScore = queryTokens.isEmpty ? 0 : Double(overlap) / Double(queryTokens.count)
        let distance = levenshtein(candidate, query)
        let maxLength = max(candidate.count, query.count)
        let editScore = maxLength == 0 ? 0 : 1.0 - Double(distance) / Double(maxLength)
        return tokenScore * 0.6 + editScore * 0.4
    }

    static func levenshtein(_ left: String, _ right: String) -> Int {
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

    /// The other names people (and the model) use for common apps. A Turkish Mac shows "Notlar"
    /// while the model often says "Notes", and the reverse; both must reach the same bundle.
    static let aliases: [String: [String]] = [
        "com.apple.Safari": ["Safari", "Safari tarayıcı"],
        "com.apple.Notes": ["Notes", "Notlar"],
        "com.apple.iCal": ["Calendar", "Takvim"],
        "com.apple.MobileSMS": ["Messages", "Mesajlar", "iMessage"],
        "com.apple.mail": ["Mail", "Posta", "Apple Mail"],
        "com.apple.Music": ["Music", "Müzik", "Apple Music"],
        "com.apple.systempreferences": ["System Settings", "Sistem Ayarları", "System Preferences", "Ayarlar"],
        "com.apple.reminders": ["Reminders", "Anımsatıcılar", "Hatırlatıcılar"],
        "com.apple.AddressBook": ["Contacts", "Kişiler", "Rehber"],
        "com.apple.Photos": ["Photos", "Fotoğraflar"],
        "com.apple.Maps": ["Maps", "Harita", "Haritalar"],
        "com.apple.finder": ["Finder"],
        "com.apple.Terminal": ["Terminal", "Terminal uygulaması"],
        "com.apple.ActivityMonitor": ["Activity Monitor", "Etkinlik Monitörü", "Görev Yöneticisi"],
        "com.apple.calculator": ["Calculator", "Hesap Makinesi"],
        "com.apple.TextEdit": ["TextEdit", "Metin Düzenleyici"],
        "com.apple.Preview": ["Preview", "Önizleme"],
        "com.apple.FaceTime": ["FaceTime"],
        "com.apple.AppStore": ["App Store"],
        "com.apple.podcasts": ["Podcasts", "Podcast'ler"],
        "com.apple.TV": ["TV", "Apple TV"],
        "com.apple.weather": ["Weather", "Hava Durumu"],
        "com.apple.clock": ["Clock", "Saat"],
        "com.apple.shortcuts": ["Shortcuts", "Kestirmeler"],
        "com.apple.Home": ["Home", "Ev"],
        "com.apple.VoiceMemos": ["Voice Memos", "Sesli Notlar"],
        "com.apple.iBooksX": ["Books", "Kitaplar"],
        "com.apple.Passwords": ["Passwords", "Parolalar", "Şifreler"],
        "com.apple.freeform": ["Freeform"],
        "com.apple.iWork.Pages": ["Pages"],
        "com.apple.iWork.Numbers": ["Numbers"],
        "com.apple.iWork.Keynote": ["Keynote"],
        "com.apple.dt.Xcode": ["Xcode"],
        "com.microsoft.VSCode": ["Visual Studio Code", "VS Code", "VSCode"],
        "com.google.Chrome": ["Google Chrome", "Chrome"],
        "org.mozilla.firefox": ["Firefox", "Mozilla Firefox"],
        "com.microsoft.edgemac": ["Microsoft Edge", "Edge"],
        "company.thebrowser.Browser": ["Arc"],
        "com.spotify.client": ["Spotify"],
        "com.tinyspeck.slackmacgap": ["Slack"],
        "com.hnc.Discord": ["Discord"],
        "net.whatsapp.WhatsApp": ["WhatsApp"],
        "ru.keepcoder.Telegram": ["Telegram"],
        "us.zoom.xos": ["Zoom"],
        "com.microsoft.teams2": ["Microsoft Teams", "Teams"],
        "com.microsoft.Word": ["Microsoft Word", "Word"],
        "com.microsoft.Excel": ["Microsoft Excel", "Excel"],
        "com.microsoft.Powerpoint": ["Microsoft PowerPoint", "PowerPoint"],
        "com.microsoft.Outlook": ["Microsoft Outlook", "Outlook"],
        "notion.id": ["Notion"],
        "com.figma.Desktop": ["Figma"],
        "com.openai.chat": ["ChatGPT"]
    ]
}

/// One application the Mac can actually launch: its Finder name, the .app file name (often the
/// English name on a Turkish Mac), bundle identifier and resolved path.
struct InstalledApplicationRecord: Equatable, Sendable {
    let name: String
    let fileName: String
    let bundleIdentifier: String?
    let path: String

    var names: [String] {
        var result = [name]
        if ApplicationNameMatcher.normalize(fileName) != ApplicationNameMatcher.normalize(name) { result.append(fileName) }
        if let bundleIdentifier, let aliases = ApplicationNameMatcher.aliases[bundleIdentifier] { result.append(contentsOf: aliases) }
        return result
    }
}

/// The outcome of turning a spoken name into exactly one application.
struct ApplicationResolution: Sendable {
    enum Outcome: Sendable {
        case resolved(ResolvedApplicationTarget)
        case ambiguous([String])
        case notFound(suggestions: [String])
    }

    let outcome: Outcome
}

struct ResolvedApplicationTarget: Equatable, Sendable {
    let name: String
    let bundleIdentifier: String?
    /// Nil only for a running process that is not in any application folder.
    let path: String?
}

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

    // MARK: - Installed application scan

    /// Where macOS keeps applications. On current macOS `/Applications/Safari.app` is a *hidden*
    /// symlink into the Safari cryptex and Spotlight does not index the cryptex, so skipping hidden
    /// files (as the old scan did) made Safari "not found". Utilities hold Terminal and friends.
    static var applicationFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Cryptexes/App/System/Applications",
            "/System/Library/CoreServices/Applications"
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
            + [home.appendingPathComponent("Applications", isDirectory: true)]
    }

    private static let installedCache = OSAllocatedUnfairLock<(records: [InstalledApplicationRecord], scannedAt: Date)?>(initialState: nil)

    /// Every launchable application, deduplicated by bundle identifier (the copy LaunchServices
    /// would open wins). Cached briefly: a burst of commands must not rescan the disk each time.
    static func installedApplicationRecords(maxAge: TimeInterval = 20) -> [InstalledApplicationRecord] {
        if let cached = installedCache.withLock({ $0 }), Date().timeIntervalSince(cached.scannedAt) < maxAge {
            return cached.records
        }
        let records = scanInstalledApplications()
        installedCache.withLock { $0 = (records, Date()) }
        return records
    }

    static func invalidateInstalledApplications() {
        installedCache.withLock { $0 = nil }
    }

    private static func scanInstalledApplications() -> [InstalledApplicationRecord] {
        let fileManager = FileManager.default
        let vendorFolderRoots: Set<String> = ["/Applications", fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var appURLs: [URL] = []
        var seenPaths = Set<String>()
        func consider(_ url: URL) {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.pathExtension.lowercased() == "app", seenPaths.insert(resolved.path).inserted else { return }
            appURLs.append(url)
        }
        for folder in applicationFolders {
            guard let entries = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
                if entry.pathExtension.lowercased() == "app" {
                    consider(entry)
                } else if vendorFolderRoots.contains(folder.path) {
                    // Vendor folders: "/Applications/Adobe Photoshop 2025/Adobe Photoshop 2025.app".
                    guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let nested = try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                    nested.filter { $0.pathExtension.lowercased() == "app" }.prefix(8).forEach(consider)
                }
            }
        }

        var byKey: [String: InstalledApplicationRecord] = [:]
        for url in appURLs {
            let resolved = url.resolvingSymlinksInPath()
            let bundle = Bundle(url: resolved)
            let bundleIdentifier = bundle?.bundleIdentifier
            if bundleIdentifier == Bundle.main.bundleIdentifier { continue }
            let fileName = url.deletingPathExtension().lastPathComponent
            var displayName = fileManager.displayName(atPath: resolved.path)
            if displayName.lowercased().hasSuffix(".app") { displayName = String(displayName.dropLast(4)) }
            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fileName : displayName
            let record = InstalledApplicationRecord(name: name, fileName: fileName, bundleIdentifier: bundleIdentifier, path: url.path)
            let key = bundleIdentifier?.lowercased() ?? resolved.path
            if let existing = byKey[key], let bundleIdentifier {
                // Two copies of one app: keep the one LaunchServices itself would open.
                let preferred = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)?.resolvingSymlinksInPath().path
                if preferred == URL(fileURLWithPath: existing.path).resolvingSymlinksInPath().path { continue }
                if preferred != resolved.path && existing.path.count <= url.path.count { continue }
            }
            byKey[key] = record
        }
        return byKey.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Planning catalog

    /// A path-free snapshot for the backend planner, capped at the 200 entries it accepts:
    /// running apps first, then everything installed, then the other names of installed apps
    /// ("Notes" next to "Notlar"). Every action still resolves the target again locally.
    static func applicationTargets() -> [DeviceApplicationTarget] {
        let running = runningApplicationGroups()
        let installed = installedApplicationRecords()
        var targets: [DeviceApplicationTarget] = []
        var usedKeys = Set<String>()
        var usedNames = Set<String>()

        func actions(for bundleIdentifier: String?) -> [ApplicationControlAction] {
            bundleIdentifier == "com.apple.finder" ? [.open, .activate] : [.open, .activate, .quit]
        }
        func add(name: String, bundleIdentifier: String?, isRunning: Bool) {
            let normalized = ApplicationNameMatcher.normalize(name)
            let key = bundleIdentifier?.lowercased() ?? "name:\(normalized)"
            guard !normalized.isEmpty, !usedKeys.contains(key), !usedNames.contains(normalized) else { return }
            usedKeys.insert(key)
            usedNames.insert(normalized)
            targets.append(DeviceApplicationTarget(name: name, bundleIdentifier: bundleIdentifier, isRunning: isRunning, supportedActions: actions(for: bundleIdentifier)))
        }

        let runningBundles = Set(running.compactMap { $0.bundleIdentifier?.lowercased() })
        for group in running.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            add(name: group.name, bundleIdentifier: group.bundleIdentifier, isRunning: true)
        }
        for record in installed {
            add(name: record.name, bundleIdentifier: record.bundleIdentifier, isRunning: record.bundleIdentifier.map { runningBundles.contains($0.lowercased()) } ?? false)
        }
        // Alias rows carry no bundle identifier so they survive the backend's per-bundle dedupe;
        // the Mac maps them back to the real bundle when a command arrives.
        let installedBundles = Set(installed.compactMap { $0.bundleIdentifier?.lowercased() }).union(runningBundles)
        for (bundleIdentifier, aliases) in ApplicationNameMatcher.aliases.sorted(by: { $0.key < $1.key })
        where installedBundles.contains(bundleIdentifier.lowercased()) {
            for alias in aliases {
                add(name: alias, bundleIdentifier: nil, isRunning: runningBundles.contains(bundleIdentifier.lowercased()))
            }
        }
        return Array(targets.prefix(200))
    }

    // MARK: - Resolution

    struct RunningApplicationGroup {
        let name: String
        let bundleIdentifier: String?
        let instances: [NSRunningApplication]
    }

    static func runningApplicationGroups() -> [RunningApplicationGroup] {
        let applications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && ($0.activationPolicy == .regular || $0.bundleIdentifier == "com.apple.finder")
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        var groups: [String: [NSRunningApplication]] = [:]
        for application in applications {
            let name = application.localizedName ?? application.bundleIdentifier ?? "Uygulama"
            let key = application.bundleIdentifier?.lowercased() ?? "name:\(ApplicationNameMatcher.normalize(name))"
            groups[key, default: []].append(application)
        }
        return groups.values.map { instances in
            RunningApplicationGroup(
                name: instances.first?.localizedName ?? instances.first?.bundleIdentifier ?? "Uygulama",
                bundleIdentifier: instances.first?.bundleIdentifier,
                instances: instances
            )
        }
    }

    /// Turns what the person said into exactly one application from the live, local state:
    /// installed bundles, running processes and the alias table. Nothing outside those can be
    /// targeted, so a model-invented bundle never reaches LaunchServices. An exact name wins; a
    /// fuzzy one only when it clearly beats the runner-up; otherwise the closest names come back.
    static func resolveApplication(target: String, bundleIdentifier: String?) -> ApplicationResolution {
        let installed = installedApplicationRecords()
        let running = runningApplicationGroups()

        struct Candidate {
            let target: ResolvedApplicationTarget
            let names: [String]
        }
        var candidates: [String: Candidate] = [:]
        for record in installed {
            let key = record.bundleIdentifier?.lowercased() ?? record.path
            candidates[key] = Candidate(target: ResolvedApplicationTarget(name: record.name, bundleIdentifier: record.bundleIdentifier, path: record.path), names: record.names)
        }
        for group in running {
            let key = group.bundleIdentifier?.lowercased() ?? "running:\(ApplicationNameMatcher.normalize(group.name))"
            if let existing = candidates[key] {
                // Prefer the name the Mac shows right now ("Notlar") and keep every other name.
                candidates[key] = Candidate(
                    target: ResolvedApplicationTarget(name: group.name, bundleIdentifier: existing.target.bundleIdentifier, path: existing.target.path),
                    names: [group.name] + existing.names
                )
            } else {
                var names = [group.name]
                if let bundle = group.bundleIdentifier, let aliases = ApplicationNameMatcher.aliases[bundle] { names += aliases }
                let path = group.instances.first?.bundleURL?.path
                candidates[key] = Candidate(target: ResolvedApplicationTarget(name: group.name, bundleIdentifier: group.bundleIdentifier, path: path), names: names)
            }
        }

        if let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleIdentifier.isEmpty {
            if let match = candidates[bundleIdentifier.lowercased()] { return ApplicationResolution(outcome: .resolved(match.target)) }
            // A wrong or invented bundle identifier: fall back to the spoken name.
        }

        let query = ApplicationNameMatcher.normalize(target)
        guard !query.isEmpty else { return ApplicationResolution(outcome: .notFound(suggestions: [])) }
        let ranked = candidates.values
            .map { candidate in (candidate, candidate.names.map { ApplicationNameMatcher.score($0, query: query) }.max() ?? 0) }
            .sorted { left, right in
                if left.1 != right.1 { return left.1 > right.1 }
                return left.0.target.name.localizedStandardCompare(right.0.target.name) == .orderedAscending
            }
        let exact = ranked.filter { $0.1 >= 1.0 }
        if exact.count == 1 { return ApplicationResolution(outcome: .resolved(exact[0].0.target)) }
        if exact.count > 1 { return ApplicationResolution(outcome: .ambiguous(exact.prefix(5).map(\.0.target.name))) }

        let plausible = ranked.filter { $0.1 >= 0.5 }
        guard let best = plausible.first else {
            let suggestions = ranked.prefix(3).filter { $0.1 >= 0.3 }.map(\.0.target.name)
            return ApplicationResolution(outcome: .notFound(suggestions: suggestions))
        }
        let runnerUp = plausible.dropFirst().first?.1 ?? 0
        if best.1 >= 0.86 && best.1 - runnerUp >= 0.08 || plausible.count == 1 && best.1 >= 0.7 {
            return ApplicationResolution(outcome: .resolved(best.0.target))
        }
        return ApplicationResolution(outcome: .ambiguous(plausible.prefix(5).map(\.0.target.name)))
    }

    static func notFoundMessage(_ target: String, suggestions: [String]) -> String {
        suggestions.isEmpty
            ? "\"\(target)\" adında bir uygulama bu Mac'te yüklü değil."
            : "\"\(target)\" adında bir uygulama bu Mac'te yok. En yakın eşleşmeler: \(suggestions.joined(separator: ", "))."
    }

    static func ambiguousMessage(_ candidates: [String]) -> String {
        "Birden fazla uygulama eşleşti: \(candidates.joined(separator: ", ")). Hangisi olduğunu adıyla belirt."
    }

    // MARK: - Commands

    /// A direct, read-only answer to "what's actually open right now".
    static func listRunningApplications() -> (data: CommandData?, error: RovaError?) {
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let apps = runningApplicationGroups()
            .map {
                RunningApplicationInfo(
                    name: $0.name,
                    bundleIdentifier: $0.bundleIdentifier,
                    isActive: $0.bundleIdentifier != nil && $0.bundleIdentifier == frontmostBundleID
                )
            }
            .sorted { left, right in
                if left.isActive != right.isActive { return left.isActive }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        return (.runningApplications(apps), nil)
    }

    static func openApplication(_ id: ApplicationID) -> RovaError? {
        guard let bundleID = applications.first(where: { $0.0 == id })?.1,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return RovaError(code: "APPLICATION_NOT_FOUND", message: "\(id.displayName) bu Mac'te yüklü değil.")
        }
        guard NSWorkspace.shared.open(url) else {
            return RovaError(code: "APPLICATION_OPEN_FAILED", message: "\(id.displayName) açılamadı.")
        }
        return nil
    }

    /// The legacy "open by name" command, now on the same resolver as controlApplication.
    static func openApplicationByName(_ query: String) async -> (data: CommandData?, error: RovaError?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ApplicationNameMatcher.normalize(trimmed).isEmpty else {
            return (nil, RovaError(code: "INVALID_APPLICATION_NAME", message: "Uygulama adı boş olamaz.", category: "tool_failure"))
        }
        switch resolveApplication(target: trimmed, bundleIdentifier: nil).outcome {
        case .ambiguous(let names):
            return (nil, RovaError(code: "APPLICATION_AMBIGUOUS", message: ambiguousMessage(names), category: "tool_failure"))
        case .notFound(let suggestions):
            return (nil, RovaError(code: "APPLICATION_NOT_FOUND", message: notFoundMessage(trimmed, suggestions: suggestions), category: "tool_failure"))
        case .resolved(let application):
            guard let path = application.path else {
                return (nil, RovaError(code: "APPLICATION_OPEN_FAILED", message: "\(application.name) açılamadı.", category: "tool_failure"))
            }
            if let error = await launch(application) { return (nil, error) }
            return (.installedApplications([InstalledApplicationInfo(name: application.name, bundleIdentifier: application.bundleIdentifier, path: path)]), nil)
        }
    }

    /// Resolves and executes a human application intent. Native LaunchServices/NSRunningApplication
    /// APIs are the primary path; Apple Events are only a graceful-quit fallback. Every
    /// state-changing branch observes the process again before claiming success.
    static func controlApplication(_ payload: ApplicationControlPayload) async -> (data: CommandData?, error: RovaError?) {
        let target = payload.target.trimmingCharacters(in: .whitespacesAndNewlines)
        let application: ResolvedApplicationTarget
        switch resolveApplication(target: target, bundleIdentifier: payload.bundleIdentifier).outcome {
        case .ambiguous(let names):
            let content = ApplicationControlContent(action: payload.action, resolvedName: target, bundleIdentifier: payload.bundleIdentifier, stateBefore: "ambiguous", stateAfter: "unchanged", changed: false, verified: false, candidates: names)
            return (.applicationControl(content), RovaError(code: "APPLICATION_AMBIGUOUS", message: ambiguousMessage(names), category: "tool_failure"))
        case .notFound(let suggestions):
            let content = ApplicationControlContent(action: payload.action, resolvedName: target, bundleIdentifier: payload.bundleIdentifier, stateBefore: "not_installed", stateAfter: "unchanged", changed: false, verified: false, candidates: suggestions)
            return (.applicationControl(content), RovaError(code: "APPLICATION_NOT_FOUND", message: notFoundMessage(target, suggestions: suggestions), category: "tool_failure"))
        case .resolved(let resolved):
            application = resolved
        }
        let runningNow = matchingRunningApplications(name: application.name, bundleIdentifier: application.bundleIdentifier)
        let group = RunningApplicationGroup(name: application.name, bundleIdentifier: application.bundleIdentifier, instances: runningNow)

        switch payload.action {
        case .quit:
            if application.bundleIdentifier == "com.apple.finder" {
                return (nil, RovaError(code: "APPLICATION_SYSTEM_PROTECTED", message: "Finder sistem tarafından yeniden başlatıldığı için uygulama gibi kapatılamaz; pencere kapatma eylemi kullanın.", category: "permission"))
            }
            if !runningNow.isEmpty {
                return await quitResolvedApplication(group, force: payload.force)
            }
            let content = ApplicationControlContent(action: .quit, resolvedName: application.name, bundleIdentifier: application.bundleIdentifier, stateBefore: "not_running", stateAfter: "not_running", changed: false, verified: true)
            return (.applicationControl(content), nil)

        case .open, .activate:
            if !runningNow.isEmpty {
                let activated = runningNow.contains { $0.activate(options: [.activateAllWindows]) }
                var verified = await waitForApplication(target: group, expectedRunning: true, expectedActive: true, timeoutSeconds: 2)
                if !verified, let path = application.path {
                    // An app with no open window ignores activate(); reopening it through
                    // LaunchServices brings a window back the way clicking the Dock icon does.
                    _ = await launch(ResolvedApplicationTarget(name: application.name, bundleIdentifier: application.bundleIdentifier, path: path))
                    verified = await waitForApplication(target: group, expectedRunning: true, expectedActive: true, timeoutSeconds: 2)
                }
                // Opening something that is already open succeeded if it is still running.
                let succeeded = verified || payload.action == .open
                let content = ApplicationControlContent(
                    action: payload.action,
                    resolvedName: application.name,
                    bundleIdentifier: application.bundleIdentifier,
                    stateBefore: "running",
                    stateAfter: verified ? "active" : "running",
                    changed: activated,
                    verified: succeeded
                )
                return succeeded
                    ? (.applicationControl(content), nil)
                    : (.applicationControl(content), RovaError(code: "APPLICATION_ACTIVATE_FAILED", message: "\(application.name) çalışıyor ancak öne getirildiği doğrulanamadı.", category: "tool_failure"))
            }

            if let error = await launch(application) {
                return (nil, error)
            }
            let running = await waitForApplication(target: group, expectedRunning: true, expectedActive: false, timeoutSeconds: 6)
            let active = payload.action == .open
                ? true
                : await waitForApplication(target: group, expectedRunning: true, expectedActive: true, timeoutSeconds: 2)
            let verified = running && active
            let content = ApplicationControlContent(
                action: payload.action,
                resolvedName: application.name,
                bundleIdentifier: application.bundleIdentifier,
                stateBefore: "not_running",
                stateAfter: verified ? (payload.action == .activate ? "active" : "running") : "unknown",
                changed: true,
                verified: verified
            )
            return verified
                ? (.applicationControl(content), nil)
                : (.applicationControl(content), RovaError(code: "APPLICATION_VERIFICATION_FAILED", message: "\(application.name) açılma komutu verildi ama çalıştığı doğrulanamadı.", category: "tool_failure"))
        }
    }

    /// Launches (or re-activates) through LaunchServices and reports its real error.
    private static func launch(_ application: ResolvedApplicationTarget) async -> RovaError? {
        let url: URL
        if let path = application.path {
            url = URL(fileURLWithPath: path)
        } else if let bundle = application.bundleIdentifier, let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            url = found
        } else {
            return RovaError(code: "APPLICATION_OPEN_FAILED", message: "\(application.name) açılamadı; uygulama dosyası bulunamadı.", category: "tool_failure")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return nil
        } catch {
            let reason = (error as NSError).localizedDescription
            return RovaError(code: "APPLICATION_OPEN_FAILED", message: "\(application.name) açılamadı: \(reason)", category: "tool_failure")
        }
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
                : "\(application.name) normal biçimde kapanmadı (kaydedilmemiş belge sorusu açık olabilir). Zorla kapatmak için bunu açıkça iste."
            return (.applicationControl(content), RovaError(code: force ? "APPLICATION_FORCE_QUIT_FAILED" : "APPLICATION_QUIT_REQUIRES_FORCE", message: message, category: "tool_failure"))
        }
        return (.applicationControl(content), nil)
    }

    private static func matchingRunningApplications(name: String, bundleIdentifier: String?) -> [NSRunningApplication] {
        if let bundleIdentifier {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter { !$0.isTerminated }
        }
        let normalizedName = ApplicationNameMatcher.normalize(name)
        return NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && ApplicationNameMatcher.normalize($0.localizedName ?? "") == normalizedName
        }
    }

    private static func waitForApplication(target: RunningApplicationGroup, expectedRunning: Bool, expectedActive: Bool, timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            let runningMatches = matchingRunningApplications(name: target.name, bundleIdentifier: target.bundleIdentifier)
            let stateMatches = expectedRunning ? !runningMatches.isEmpty : runningMatches.isEmpty
            let activeMatches = !expectedActive || runningMatches.contains(where: \.isActive)
            if stateMatches && activeMatches { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 120_000_000)
        } while true
    }

    /// Opens a web address in the browser the person is looking at: when the frontmost app can
    /// open http(s) links (Safari just opened by the previous step, say), the page opens there;
    /// otherwise in the default browser. "Safari'yi aç, YouTube'da ara" used to land in Chrome.
    static func openURL(_ rawValue: String) async -> (browser: String?, error: RovaError?) {
        guard RovaValidation.isAllowedURL(rawValue), let url = URL(string: rawValue) else {
            return (nil, RovaError(code: "URL_INVALID", message: "URL geçersiz veya izin verilmeyen bir şema kullanıyor."))
        }
        let front = NSWorkspace.shared.frontmostApplication
        let browsers = NSWorkspace.shared.urlsForApplications(toOpen: url).map { $0.resolvingSymlinksInPath().standardizedFileURL }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier,
           let bundleURL = front.bundleURL?.resolvingSymlinksInPath().standardizedFileURL,
           browsers.contains(bundleURL) {
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: bundleURL, configuration: configuration)
                return (front.localizedName, nil)
            } catch {
                // Fall back to the default browser below.
            }
        }
        guard let defaultBrowser = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            return (nil, RovaError(code: "URL_OPEN_FAILED", message: "Bu adresi açacak tarayıcı bulunamadı."))
        }
        do {
            let application = try await NSWorkspace.shared.open([url], withApplicationAt: defaultBrowser, configuration: configuration)
            return (application.localizedName ?? defaultBrowser.deletingPathExtension().lastPathComponent, nil)
        } catch {
            return (nil, RovaError(code: "URL_OPEN_FAILED", message: "URL açılamadı: \((error as NSError).localizedDescription)"))
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
}
