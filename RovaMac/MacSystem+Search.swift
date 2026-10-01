import Foundation

/// Finding files on this Mac. Spotlight answers in well under a second - by name, by kind, by
/// modification date and (when asked) by what is inside - where the old walk over the whole disk
/// visited 25,000 entries per call and only compared names. Without an index (Spotlight off, or a
/// folder it does not cover) a bounded walk over the searched folders takes over.
enum MacFileSearch {
    struct Spec: Equatable {
        var tokens: [String]
        /// The query's words first, then each alternative's: a name matching any group counts.
        var groups: [[String]]
        /// Most files one search may return (a survey lists far more than a page).
        var limit: Int
        var roots: [URL]
        var kind: String?
        var since: Date?
        var content: Bool
        var recent: Bool
        /// Own folders only: key material and credential names are left out.
        var hidesSensitive: Bool
    }

    static let pageSize = 12
    private static let candidateLimit = 400

    /// Places that hold other programs' files, not the person's: they would drown a search for
    /// "rapor" in build output and package checkouts.
    private static let noisyComponents: Set<String> = [
        "node_modules", "deriveddata", ".git", "pods", "sourcepackages", "checkouts", ".build", "venv", ".venv",
        "__pycache__", "site-packages", "library", ".trash", "caches", ".cache", "target"
    ]
    private static let noisySuffixes = [".app", ".xcodeproj", ".xcworkspace", ".framework", ".photoslibrary", ".lproj"]

    private static let uniformTypes: [String: [String]] = [
        "pdf": ["com.adobe.pdf"],
        "document": ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "public.rtf", "com.apple.iwork.pages.sffpages", "org.oasis-open.opendocument.text"],
        "spreadsheet": ["org.openxmlformats.spreadsheetml.sheet", "com.microsoft.excel.xls", "public.comma-separated-values-text", "com.apple.iwork.numbers.sffnumbers", "org.oasis-open.opendocument.spreadsheet"],
        "presentation": ["org.openxmlformats.presentationml.presentation", "com.microsoft.powerpoint.ppt", "com.apple.iwork.keynote.sffkey", "org.oasis-open.opendocument.presentation"],
        "image": ["public.image"],
        "audio": ["public.audio"],
        "video": ["public.movie"],
        "archive": ["public.archive"],
        "folder": ["public.folder"]
    ]

    private static let extensions: [String: Set<String>] = [
        "pdf": ["pdf"],
        "document": ["doc", "docx", "rtf", "odt", "pages"],
        "spreadsheet": ["xls", "xlsx", "csv", "tsv", "numbers", "ods"],
        "presentation": ["ppt", "pptx", "key", "odp"],
        "image": ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg"],
        "text": ["txt", "md", "markdown", "log", "json", "xml", "yml", "yaml", "html"],
        "archive": ["zip", "rar", "7z", "tar", "gz", "tgz", "dmg"],
        "audio": ["mp3", "m4a", "wav", "aac", "flac"],
        "video": ["mp4", "mov", "mkv", "avi", "m4v"]
    ]

    // MARK: Building the search

    /// Words worth matching: letters, digits and a few name characters. Anything that could change
    /// the meaning of a Spotlight expression (quotes, wildcards, parentheses) is dropped.
    static func tokens(from query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace })
            .map { word in String(word.filter { $0.isLetter || $0.isNumber || "._-@#".contains($0) }) }
            .filter { !$0.isEmpty }
            .prefix(8)
            .map { $0 }
    }

    static func ownFolders() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Desktop", "Documents", "Downloads"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func spec(for payload: FileSearchPayload, now: Date = Date()) -> (spec: Spec?, error: RovaError?) {
        var roots: [URL]
        var hidesSensitive = false
        if payload.everywhere == true {
            roots = [FileManager.default.homeDirectoryForCurrentUser]
        } else if let folder = payload.folder {
            guard let url = MacSystem.resolvedLocalFolder(folder) else {
                return (nil, MacSystem.missingPathError(folder, message: "\"\(folder)\" klasörü bulunamadı."))
            }
            roots = [url]
            hidesSensitive = RovaOwnFolders.isOwnFolder(folder)
        } else {
            roots = ownFolders()
            hidesSensitive = true
        }
        if roots.isEmpty { return (nil, RovaError(code: "SEARCH_FAILED", message: "Aranacak klasör bulunamadı.", category: "tool_failure")) }
        let words = tokens(from: payload.query)
        let alternatives = (payload.alternatives ?? []).prefix(FileSearchPayload.maxAlternatives).map(tokens(from:)).filter { !$0.isEmpty }
        let since = payload.modifiedWithinDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
        let spec = Spec(
            tokens: words,
            groups: ([words] + alternatives).filter { !$0.isEmpty },
            limit: candidateLimit,
            roots: roots,
            kind: payload.kind,
            since: since,
            content: payload.content == true,
            recent: payload.sort == "recent" || (words.isEmpty && payload.sort != "relevance"),
            hidesSensitive: hidesSensitive
        )
        return (spec, nil)
    }

    /// The Spotlight expression for a search. Names always match case- and diacritic-insensitively
    /// ("rapor" finds "Rapör"); with `content`, a word may also match inside the file.
    static func spotlightPredicate(_ spec: Spec) -> String {
        var parts: [String] = []
        let alternatives = spec.groups.count > 1
        let groupClauses: [String] = spec.groups.map { group in
            let clauses = group.map { token -> String in
                let name = "kMDItemDisplayName == \"*\(token)*\"cd"
                return spec.content ? "(\(name) || kMDItemTextContent == \"*\(token)*\"cd)" : name
            }
            let joined = clauses.joined(separator: " && ")
            return alternatives && clauses.count > 1 ? "(" + joined + ")" : joined
        }
        if !groupClauses.isEmpty { parts.append(alternatives ? "(" + groupClauses.joined(separator: " || ") + ")" : groupClauses[0]) }
        if let kind = spec.kind {
            if kind == "text" {
                parts.append("(kMDItemContentTypeTree == \"public.plain-text\" && kMDItemContentTypeTree != \"public.source-code\")")
            } else if let types = uniformTypes[kind] {
                parts.append("(" + types.map { "kMDItemContentTypeTree == \"\($0)\"" }.joined(separator: " || ") + ")")
            }
        } else if spec.groups.isEmpty {
            parts.append("kMDItemContentType != \"public.folder\"")
        }
        if let since = spec.since {
            let stamp = ISO8601DateFormatter().string(from: since)
            parts.append("kMDItemFSContentChangeDate >= $time.iso(\(stamp))")
        }
        return parts.joined(separator: " && ")
    }

    // MARK: Ranking and filtering

    private static func isNoise(_ path: String) -> Bool {
        let lowered = path.lowercased()
        let parts = lowered.split(separator: "/").map(String.init)
        if parts.contains(where: { noisyComponents.contains($0) || $0.hasPrefix(".") }) { return true }
        return noisySuffixes.contains(where: { suffix in parts.dropLast().contains(where: { $0.hasSuffix(suffix) }) })
    }

    /// "İşlem", "islem" and "ISLEM" are one word: fold with a neutral locale (a Turkish one turns a
    /// plain "I" into a dotless "ı"), then treat the dotless i as an i.
    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "ı", with: "i")
    }

    /// Higher is a better match: the name is the query, starts with it, holds every word; shorter
    /// paths win ties, since what people mean is rarely buried in a project checkout.
    static func score(name: String, path: String, groups: [[String]]) -> Double {
        groups.map { score(name: name, path: path, tokens: $0) }.max() ?? 0
    }

    static func score(name: String, path: String, tokens: [String]) -> Double {
        guard !tokens.isEmpty else { return 0 }
        let folded = fold((name as NSString).deletingPathExtension)
        let query = fold(tokens.joined(separator: " "))
        var score = 0.0
        if folded == query { score += 6 } else if folded.hasPrefix(query) { score += 3 } else if folded.contains(query) { score += 2 }
        score += Double(tokens.filter { folded.contains(fold($0)) }.count)
        score -= Double(path.split(separator: "/").count) * 0.02
        return score
    }

    private static func entry(for url: URL, isDirectory: Bool? = nil) -> FileSystemEntry? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
              values.isSymbolicLink != true else { return nil }
        let directory = values.isDirectory ?? isDirectory ?? false
        return FileSystemEntry(
            path: url.standardizedFileURL.path,
            name: url.lastPathComponent,
            byteCount: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate,
            isDirectory: directory,
            fileType: directory ? nil : url.pathExtension.lowercased()
        )
    }

    private static func admissible(_ path: String, _ spec: Spec) -> Bool {
        guard path.count <= 500, !isNoise(path) else { return false }
        return !(spec.hidesSensitive && RovaOwnFolders.isSensitive(path))
    }

    static func rank(_ entries: [FileSystemEntry], spec: Spec) -> [FileSystemEntry] {
        entries.sorted { left, right in
            if spec.recent {
                let leftDate = left.modifiedAt ?? .distantPast, rightDate = right.modifiedAt ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
            } else {
                let leftScore = score(name: left.name, path: left.path, groups: spec.groups)
                let rightScore = score(name: right.name, path: right.path, groups: spec.groups)
                if leftScore != rightScore { return leftScore > rightScore }
                let leftDate = left.modifiedAt ?? .distantPast, rightDate = right.modifiedAt ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
            }
            return left.path.localizedStandardCompare(right.path) == .orderedAscending
        }
    }

    // MARK: Running it

    static func search(_ payload: FileSearchPayload) async -> (data: CommandData?, message: String, error: RovaError?) {
        if let cursor = payload.cursor, !cursor.hasPrefix("o:") {
            return (nil, "Arama sürdürülemedi.", RovaError(code: "INVALID_CURSOR", message: "Aramayı yeniden başlat."))
        }
        let offset = payload.cursor.flatMap { Int($0.dropFirst(2)) } ?? 0
        let built = spec(for: payload)
        guard let spec = built.spec else {
            return (nil, built.error?.message ?? "Arama kurulamadı.", built.error)
        }

        var entries = await Task.detached(priority: .userInitiated) { spotlight(spec) }.value
        var usedIndex = entries != nil
        if entries == nil || (entries?.isEmpty == true && !spec.content) {
            // No index, or it knows nothing here (a folder Spotlight does not cover): walk the folders.
            let walked = await Task.detached(priority: .userInitiated) { walk(spec) }.value
            if entries == nil || !walked.isEmpty { entries = walked; usedIndex = false }
        }
        if payload.survey == true {
            return await survey(payload, spec: spec, matched: entries ?? [], usedIndex: usedIndex)
        }
        let ranked = rank(entries ?? [], spec: spec)
        let page = Array(ranked.dropFirst(offset).prefix(payload.survey == true ? FileSearchPayload.surveyLimit : pageSize))
        let scope = spec.roots.map { $0.lastPathComponent == NSUserName() ? "Ev klasörü" : displayName(for: $0) }.joined(separator: ", ")
        let remaining = ranked.count - offset - page.count
        var message = payload.survey == true
            ? "\(page.count) dosya listelendi (\(scope))."
            : ranked.isEmpty
            ? "Eşleşen dosya bulunamadı (aranan: \(scope))."
            : "\(ranked.count) sonuç (aranan: \(scope)); \(offset + 1)–\(offset + page.count) gösteriliyor."
        if remaining > 0 { message += " Devam kodu o:\(offset + page.count)." }
        if spec.content && !usedIndex { message += " İçerik araması için Spotlight dizini gerekli; yalnızca adlara bakıldı." }
        return (.files(page), message, nil)
    }

    /// Every file in scope, newest first (the name matches, whatever their age, go first), so the
    /// backend can rank them by what they mean rather than by the words in their names.
    private static func survey(_ payload: FileSearchPayload, spec: Spec, matched: [FileSystemEntry], usedIndex: Bool) async -> (data: CommandData?, message: String, error: RovaError?) {
        var widened = spec
        widened.tokens = []
        widened.groups = []
        widened.recent = true
        widened.limit = FileSearchPayload.surveyLimit
        let everything = widened
        var broad = await Task.detached(priority: .userInitiated) { spotlight(everything) }.value
        if broad == nil || broad?.isEmpty == true {
            broad = await Task.detached(priority: .userInitiated) { walk(everything) }.value
        }
        var seen = Set<String>()
        var listed: [FileSystemEntry] = []
        for entry in rank(matched, spec: spec) + rank(broad ?? [], spec: everything) where seen.insert(entry.path).inserted {
            listed.append(entry)
            if listed.count >= FileSearchPayload.surveyLimit { break }
        }
        return (.files(listed), "\(listed.count) dosya listelendi.", nil)
    }

    private static func displayName(for url: URL) -> String {
        switch url.lastPathComponent {
        case "Desktop": return "Masaüstü"
        case "Documents": return "Belgeler"
        case "Downloads": return "İndirilenler"
        default: return url.lastPathComponent
        }
    }

    /// nil when Spotlight could not answer (the caller falls back to walking).
    private static func spotlight(_ spec: Spec) -> [FileSystemEntry]? {
        var arguments: [String] = []
        for root in spec.roots { arguments += ["-onlyin", root.path] }
        arguments.append(spotlightPredicate(spec))
        let result = MacSystem.runProcess(executable: "/usr/bin/mdfind", arguments: arguments, timeoutSeconds: 8)
        guard !result.timedOut, result.exitCode == 0, let text = String(data: result.stdout, encoding: .utf8) else { return nil }
        var seen = Set<String>()
        var entries: [FileSystemEntry] = []
        for line in text.split(whereSeparator: \.isNewline).prefix(spec.limit * 3) {
            let path = String(line)
            guard admissible(path, spec), seen.insert(path).inserted, let found = entry(for: URL(fileURLWithPath: path)) else { continue }
            if let since = spec.since, let modified = found.modifiedAt, modified < since { continue }
            entries.append(found)
            if entries.count >= spec.limit { break }
        }
        return entries
    }

    /// A bounded walk: at most 20,000 entries or 8 seconds, names and kinds only.
    static func walk(_ spec: Spec) -> [FileSystemEntry] {
        let deadline = Date().addingTimeInterval(8)
        var visited = 0
        var found: [FileSystemEntry] = []
        let folded = spec.groups.map { $0.map(fold) }
        let wanted = spec.kind.flatMap { extensions[$0] }
        for root in spec.roots {
            guard let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while let url = walker.nextObject() as? URL {
                visited += 1
                if visited > 20_000 || Date() >= deadline || found.count >= spec.limit { return found }
                if noisyComponents.contains(url.lastPathComponent.lowercased()) { walker.skipDescendants(); continue }
                guard let item = entry(for: url) else { continue }
                if item.isDirectory && spec.kind != "folder" { continue }
                if spec.kind == "folder" && !item.isDirectory { continue }
                if let wanted, !wanted.contains(url.pathExtension.lowercased()) { continue }
                if let since = spec.since, (item.modifiedAt ?? .distantPast) < since { continue }
                let foldedName = fold(url.lastPathComponent)
                if !folded.isEmpty, !folded.contains(where: { group in group.allSatisfy { foldedName.contains($0) } }) { continue }
                if admissible(item.path, spec) { found.append(item) }
            }
        }
        return found
    }
}
