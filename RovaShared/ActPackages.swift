import Foundation

/// A JavaScript package a web project may use (`<script src="act-vendor/...">`), as the backend lists it.
public struct ActWebPackage: Codable, Sendable, Equatable {
    public let id: String
    public let version: String
    /// What the page writes in `src`.
    public let path: String
    public let global: String
    /// The one file taken out of the archive.
    public let archiveEntry: String
    public let archiveUrl: String
    /// SRI (`sha512-...`) of the downloaded archive.
    public let integrity: String
}

public struct ActPackageCatalog: Codable, Sendable, Equatable {
    public struct PythonPin: Codable, Sendable, Equatable { public let id: String; public let version: String }
    public let version: Int
    public let web: [ActWebPackage]
    public let python: [PythonPin]
}

/// The page cannot get a package it needs (not downloaded, not verified). The page is then not shown as working,
/// not counted as verified, and never exported.
public struct ActPackageError: LocalizedError, Sendable {
    public static let code = "DEVICE_PACKAGE_MISSING"
    public let detail: String
    public var errorDescription: String? { String(localized: "Paket eksik (\(Self.code)): \(detail)") }
    public init(_ detail: String) { self.detail = detail }
}

/// The device's own, verified copy of the JavaScript packages. A package is downloaded as its archive, checked against the
/// catalog's SHA-512 value, only then is the one wanted file taken out, and it is kept under id + version + integrity.
/// The preview and the single-file export put that code into the page; the project's files never contain it, the hub
/// never sees it, and the page makes no network request.
public final class ActPackages: @unchecked Sendable {
    public typealias CatalogLoader = @Sendable () async throws -> ActPackageCatalog
    public typealias Downloader = @Sendable (URL) async throws -> Data

    public static let shared = ActPackages()

    private struct Sidecar: Codable { let integrity: String; let entrySHA256: String }

    private let directory: URL
    private let download: Downloader
    private let lock = NSLock()
    private var memory: [String: String] = [:]
    private var catalogMemory: ActPackageCatalog?
    private static let maxArchiveBytes = 12 * 1024 * 1024
    private static let allowedHosts: Set<String> = ["registry.npmjs.org"]

    public init(directory: URL? = nil, downloader: Downloader? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ActPackages", isDirectory: true)
        self.directory = base
        self.download = downloader ?? { url in
            var request = URLRequest(url: url, timeoutInterval: 40)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ActPackageError("indirme başarısız (\(url.host ?? "sunucu"))") }
            return data
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    // MARK: Reading a page

    /// The package paths a page asks for, in order, once each.
    public static func referencedPaths(in html: String) -> [String] {
        var seen: [String] = []
        for match in tagRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let path = String(html[range])
            if !seen.contains(path) { seen.append(path) }
        }
        return seen
    }

    private static let tagRegex = try! NSRegularExpression(
        pattern: #"<script\b[^>]*\bsrc\s*=\s*["'](?:\./)?(act-vendor/[^"']+)["'][^>]*>\s*</script\s*>"#,
        options: [.caseInsensitive]
    )

    // MARK: Using what is on the device

    /// The page with every package tag replaced by the verified code from the device's cache. Paths that are not in the
    /// cache (or not in the last known catalog, or fail the check) are returned as `missing`; their tags stay as they are.
    public func inlineCached(_ html: String) -> (html: String, missing: [String]) {
        guard Self.referencedPaths(in: html).isEmpty == false else { return (html, []) }
        let catalog = cachedCatalog()
        var codes: [String: (package: ActWebPackage, code: String)] = [:]
        var missing: [String] = []
        for path in Self.referencedPaths(in: html) {
            if let package = catalog?.web.first(where: { $0.path == path }), let code = cachedCode(for: package) { codes[path] = (package, code) } else { missing.append(path) }
        }
        var result = html
        let matches = Self.tagRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result), let pathRange = Range(match.range(at: 1), in: html), let entry = codes[String(html[pathRange])] else { continue }
            let safe = entry.code.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
            result.replaceSubrange(whole, with: "<script data-act-package=\"\(entry.package.id)@\(entry.package.version)\">\n\(safe)\n</script>")
        }
        return (result, missing)
    }

    // MARK: Getting what is missing

    /// Makes sure every package the page needs is on the device, verified. Downloads only what is not cached already.
    /// Throws `ActPackageError` (DEVICE_PACKAGE_MISSING) when something cannot be fetched or does not check out.
    public func prepare(_ html: String, loadCatalog: CatalogLoader) async throws {
        let paths = Self.referencedPaths(in: html)
        guard !paths.isEmpty else { return }
        if inlineCached(html).missing.isEmpty { return }
        let catalog: ActPackageCatalog
        do { catalog = try await loadCatalog() } catch {
            // No catalog now: the cached one may still know the package.
            guard let known = cachedCatalog() else { throw ActPackageError(String(localized: "paket listesi alınamadı")) }
            catalog = known
        }
        saveCatalog(catalog)
        for path in paths {
            guard let package = catalog.web.first(where: { $0.path == path }), Self.isSane(package) else { throw ActPackageError("\(path) izinli paketler arasında yok") }
            if cachedCode(for: package) != nil { continue }
            try await fetch(package)
        }
    }

    private static func isSane(_ package: ActWebPackage) -> Bool {
        guard package.path.range(of: #"^act-vendor/[A-Za-z0-9._-]+\.js$"#, options: .regularExpression) != nil,
              package.integrity.hasPrefix("sha512-"), ActArchive.normalizedPath(package.archiveEntry) == package.archiveEntry,
              let url = URL(string: package.archiveUrl), url.scheme == "https", let host = url.host, allowedHosts.contains(host) else { return false }
        return true
    }

    private func fetch(_ package: ActWebPackage) async throws {
        let label = "\(package.id) \(package.version)"
        guard let url = URL(string: package.archiveUrl) else { throw ActPackageError(String(localized: "\(label) adresi geçersiz")) }
        let archive: Data
        do { archive = try await download(url) } catch { throw ActPackageError("\(label) indirilemedi") }
        guard archive.count <= Self.maxArchiveBytes else { throw ActPackageError(String(localized: "\(label) beklenenden büyük")) }
        // Nothing from the archive is read before it matches the catalog's value.
        guard ActArchive.matches(archive, integrity: package.integrity) else { throw ActPackageError(String(localized: "\(label) doğrulanamadı (özet uyuşmuyor)")) }
        guard let tar = try? ActArchive.gunzip(archive), let entry = ActArchive.tarEntry(tar, named: package.archiveEntry),
              let code = String(data: entry, encoding: .utf8), !code.isEmpty else { throw ActPackageError(String(localized: "\(label) arşivinde \(package.archiveEntry) yok")) }
        store(code: entry, for: package)
    }

    // MARK: Cache on disk

    private func stem(_ package: ActWebPackage) -> String {
        let key = ActArchive.sha256Hex(Data(package.integrity.utf8)).prefix(16)
        return "\(package.id)-\(package.version)-\(key)"
    }

    private func store(code: Data, for package: ActWebPackage) {
        let base = directory.appendingPathComponent(stem(package))
        let sidecar = Sidecar(integrity: package.integrity, entrySHA256: ActArchive.sha256Hex(code))
        try? code.write(to: base.appendingPathExtension("js"), options: .atomic)
        if let data = try? JSONEncoder().encode(sidecar) { try? data.write(to: base.appendingPathExtension("json"), options: .atomic) }
        lock.lock(); memory[stem(package)] = String(decoding: code, as: UTF8.self); lock.unlock()
    }

    /// The package's code when the cached copy exists, belongs to this exact catalog entry and still matches its recorded hash.
    private func cachedCode(for package: ActWebPackage) -> String? {
        let key = stem(package)
        lock.lock(); let known = memory[key]; lock.unlock()
        if let known { return known }
        let base = directory.appendingPathComponent(key)
        guard let code = try? Data(contentsOf: base.appendingPathExtension("js")),
              let data = try? Data(contentsOf: base.appendingPathExtension("json")), let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data),
              sidecar.integrity == package.integrity, sidecar.entrySHA256 == ActArchive.sha256Hex(code) else { return nil }
        let text = String(decoding: code, as: UTF8.self)
        lock.lock(); memory[key] = text; lock.unlock()
        return text
    }

    private var catalogURL: URL { directory.appendingPathComponent("catalog.json") }

    private func cachedCatalog() -> ActPackageCatalog? {
        lock.lock(); let known = catalogMemory; lock.unlock()
        if let known { return known }
        guard let data = try? Data(contentsOf: catalogURL), let catalog = try? JSONDecoder().decode(ActPackageCatalog.self, from: data) else { return nil }
        lock.lock(); catalogMemory = catalog; lock.unlock()
        return catalog
    }

    private func saveCatalog(_ catalog: ActPackageCatalog) {
        lock.lock(); catalogMemory = catalog; lock.unlock()
        if let data = try? JSONEncoder().encode(catalog) { try? data.write(to: catalogURL, options: .atomic) }
    }
}
