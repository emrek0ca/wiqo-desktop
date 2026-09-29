using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace RovaWindows.Operations;

/// File search (the counterpart of RovaMac/MacSystem+Search.swift): by name, kind, change date and,
/// when asked, by what is inside. Where nothing else is said it looks in Desktop, Documents and
/// Downloads; "everywhere" means the whole profile. Names compare case- and diacritic-insensitively,
/// so "rapor" finds "Rapör.docx". A bounded walk (30,000 entries or 12 seconds) collects candidates,
/// which are ranked and paged with a stateless "o:N" cursor.
internal static class FileSearch
{
    internal const int PageSize = 12;
    private const int CandidateLimit = 400;
    private const int EntryLimit = 30_000;
    private const int ContentReadLimit = 1_500;
    private const long ContentBytesLimit = 5L * 1024 * 1024;

    internal sealed record Spec(string[] Tokens, string[] Roots, string? Kind, DateTimeOffset? Since, bool Content, bool Recent, bool HidesSensitive);
    internal sealed record Hit(string Path, string Name, string Extension, long Bytes, DateTime ModifiedUtc, bool IsDirectory);

    private static readonly HashSet<string> NoisyDirectories = new(StringComparer.OrdinalIgnoreCase)
    {
        "node_modules", "DerivedData", ".git", "Pods", "SourcePackages", "checkouts", ".build", "venv", ".venv", "__pycache__",
        "site-packages", "AppData", "$Recycle.Bin", "System Volume Information", "Windows", "Program Files", "Program Files (x86)", ".cache", "target"
    };

    private static readonly Dictionary<string, HashSet<string>> Extensions = new(StringComparer.Ordinal)
    {
        ["pdf"] = ["pdf"],
        ["document"] = ["doc", "docx", "rtf", "odt", "pages"],
        ["spreadsheet"] = ["xls", "xlsx", "csv", "tsv", "numbers", "ods"],
        ["presentation"] = ["ppt", "pptx", "key", "odp"],
        ["image"] = ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg"],
        ["text"] = ["txt", "md", "markdown", "log", "json", "xml", "yml", "yaml", "html"],
        ["archive"] = ["zip", "rar", "7z", "tar", "gz", "tgz"],
        ["audio"] = ["mp3", "m4a", "wav", "aac", "flac"],
        ["video"] = ["mp4", "mov", "mkv", "avi", "m4v"]
    };

    private static readonly HashSet<string> TextLike = ["txt", "md", "markdown", "log", "json", "xml", "yml", "yaml", "html", "csv", "tsv"];

    // The same names the phone never reads without asking (RovaShared/Validation.swift RovaOwnFolders).
    private static readonly string[] SensitiveNames = [".ssh", ".gnupg", ".aws", ".kube", ".docker", ".netrc", ".npmrc", ".pypirc", ".git-credentials", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "keychain", "keychains", "wallet", "1password", "bitwarden", "lastpass"];
    private static readonly HashSet<string> SensitiveExtensions = ["pem", "key", "p12", "p8", "pfx", "kdbx", "keystore", "jks", "ovpn", "gpg", "asc", "ppk"];
    private static readonly string[] SensitiveWords = ["password", "parola", "sifre", "şifre", "passwd", "credential", "secret", "recovery code", "backup code", "seed phrase", "private key"];

    internal static bool IsSensitive(string path)
    {
        var lowered = path.ToLowerInvariant().Replace('\\', '/');
        var parts = lowered.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Any(part => SensitiveNames.Any(name => part == name || part.StartsWith(name + ".", StringComparison.Ordinal)))) return true;
        var last = parts.LastOrDefault() ?? "";
        var dot = last.LastIndexOf('.');
        if (dot >= 0 && SensitiveExtensions.Contains(last[(dot + 1)..])) return true;
        if (last == ".env" || last.StartsWith(".env.", StringComparison.Ordinal)) return true;
        return SensitiveWords.Any(word => lowered.Contains(word, StringComparison.Ordinal));
    }

    internal static string[] OwnFolders() =>
        new[] { WindowsPaths.Desktop, WindowsPaths.Documents, WindowsPaths.Downloads }
            .Where(Directory.Exists).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();

    private static bool IsOwnFolder(string path)
    {
        var full = Path.GetFullPath(path).TrimEnd('\\');
        return OwnFolders().Any(own => string.Equals(full, own.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)
            || full.StartsWith(own.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase));
    }

    /// Words worth matching; anything else is dropped.
    internal static string[] Tokens(string query) =>
        query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .Select(word => new string(word.Where(character => char.IsLetterOrDigit(character) || "._-@#".Contains(character)).ToArray()))
            .Where(word => word.Length > 0).Take(8).ToArray();

    internal static Spec? BuildSpec(FileSearchPayload payload, DateTimeOffset now, out Outcome? error)
    {
        error = null;
        string[] roots;
        var hides = false;
        if (payload.Everywhere == true)
        {
            roots = [WindowsPaths.UserProfile];
        }
        else if (payload.Folder is { Length: > 0 } folder)
        {
            var resolved = FileOperations.Resolve(folder);
            if (resolved is null || !Directory.Exists(resolved))
            {
                error = Outcome.Fail("FILE_NOT_FOUND", $"\"{folder}\" klasörü bulunamadı.");
                return null;
            }
            roots = [resolved];
            hides = IsOwnFolder(resolved);
        }
        else
        {
            roots = OwnFolders();
            hides = true;
        }
        if (roots.Length == 0)
        {
            error = Outcome.Fail("SEARCH_FAILED", "Aranacak klasör bulunamadı.");
            return null;
        }
        var tokens = Tokens(payload.Query);
        return new Spec(
            tokens, roots, payload.Kind,
            payload.ModifiedWithinDays is { } days ? now.AddDays(-days) : null,
            payload.Content == true,
            payload.Sort == "recent" || (tokens.Length == 0 && payload.Sort != "relevance"),
            hides);
    }

    internal static Outcome Search(FileSearchPayload payload, CancellationToken cancellationToken)
    {
        if (payload.Cursor is { Length: > 0 } cursor && !Regex.IsMatch(cursor, @"^o:\d{1,5}$"))
            return Outcome.Fail("INVALID_CURSOR", "Aramayı yeniden başlat.");
        var offset = payload.Cursor is { Length: > 2 } current ? int.Parse(current[2..], CultureInfo.InvariantCulture) : 0;
        var spec = BuildSpec(payload, DateTimeOffset.UtcNow, out var error);
        if (spec is null) return error!;
        var hits = Scan(spec, cancellationToken, out var partial);
        if (cancellationToken.IsCancellationRequested) return Outcome.Fail("CANCELLED", "Arama iptal edildi.");
        var ranked = Rank(hits, spec);
        var page = ranked.Skip(offset).Take(PageSize).ToList();
        var scope = string.Join(", ", spec.Roots.Select(Describe));
        var remaining = ranked.Count - offset - page.Count;
        var message = ranked.Count == 0
            ? $"Eşleşen dosya bulunamadı (aranan: {scope})."
            : $"{ranked.Count} sonuç (aranan: {scope}); {offset + 1}–{offset + page.Count} gösteriliyor.";
        if (remaining > 0) message += $" Devam kodu o:{offset + page.Count}.";
        if (partial) message += " Arama kısmi kaldı; daha dar bir klasör veya filtre ver.";
        return Outcome.WithData("files", page.Select(hit => new
        {
            path = hit.Path, name = hit.Name, fileType = hit.IsDirectory ? null : hit.Extension,
            byteCount = hit.Bytes, modifiedAt = DateTime.SpecifyKind(hit.ModifiedUtc, DateTimeKind.Utc), isDirectory = hit.IsDirectory
        }).ToArray(), message);
    }

    private static string Describe(string root)
    {
        var name = Path.GetFileName(root.TrimEnd('\\'));
        return name switch { "Desktop" => "Masaüstü", "Documents" => "Belgeler", "Downloads" => "İndirilenler", _ => string.Equals(root, WindowsPaths.UserProfile, StringComparison.OrdinalIgnoreCase) ? "Kullanıcı klasörü" : name };
    }

    internal static List<Hit> Scan(Spec spec, CancellationToken cancellationToken, out bool partial)
    {
        partial = false;
        var deadline = DateTimeOffset.UtcNow.AddSeconds(12);
        var visited = 0;
        var contentReads = 0;
        var hits = new List<Hit>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var folded = spec.Tokens.Select(Fold).ToArray();
        var wanted = spec.Kind is { } kind && Extensions.TryGetValue(kind, out var set) ? set : null;

        foreach (var root in spec.Roots)
        {
            var pending = new Stack<string>();
            pending.Push(root);
            while (pending.Count > 0)
            {
                var directory = pending.Pop();
                IEnumerable<FileSystemInfo> entries;
                try { entries = new DirectoryInfo(directory).EnumerateFileSystemInfos().ToList(); }
                catch (Exception error) when (error is UnauthorizedAccessException or IOException) { continue; }
                foreach (var info in entries)
                {
                    if (cancellationToken.IsCancellationRequested) return hits;
                    if (++visited > EntryLimit || DateTimeOffset.UtcNow >= deadline || hits.Count >= CandidateLimit) { partial = true; return hits; }
                    if ((info.Attributes & (FileAttributes.Hidden | FileAttributes.System)) != 0) continue;
                    if (info is DirectoryInfo folder)
                    {
                        if (NoisyDirectories.Contains(folder.Name) || PathSafety.IsLink(folder.FullName)) continue;
                        pending.Push(folder.FullName);
                        if (spec.Kind == "folder" && MatchesName(folder.Name, folded) && Admissible(folder.FullName, spec) && seen.Add(folder.FullName))
                            hits.Add(new Hit(folder.FullName, folder.Name, "", 0, folder.LastWriteTimeUtc, true));
                        continue;
                    }
                    if (info is not FileInfo file || spec.Kind == "folder") continue;
                    var extension = file.Extension.TrimStart('.').ToLowerInvariant();
                    if (wanted is not null && !wanted.Contains(extension)) continue;
                    if (spec.Since is { } since && new DateTimeOffset(file.LastWriteTimeUtc, TimeSpan.Zero) < since) continue;
                    if (!Admissible(file.FullName, spec) || PathSafety.IsLink(file.FullName)) continue;
                    var nameMatches = MatchesName(file.Name, folded);
                    var matches = nameMatches;
                    if (!matches && spec.Content && folded.Length > 0 && contentReads < ContentReadLimit && file.Length <= ContentBytesLimit)
                    {
                        contentReads++;
                        matches = ContentMatches(file.FullName, extension, folded);
                    }
                    if (matches && seen.Add(file.FullName)) hits.Add(new Hit(file.FullName, file.Name, extension, file.Length, file.LastWriteTimeUtc, false));
                }
            }
        }
        return hits;
    }

    private static bool Admissible(string path, Spec spec) => path.Length <= 500 && !(spec.HidesSensitive && IsSensitive(path));

    private static bool MatchesName(string name, string[] folded)
    {
        if (folded.Length == 0) return true;
        var value = Fold(name);
        return folded.All(token => value.Contains(token, StringComparison.Ordinal));
    }

    /// Text files, and the text inside Word and Excel files (a zip of XML).
    private static bool ContentMatches(string path, string extension, string[] folded)
    {
        try
        {
            string text;
            if (TextLike.Contains(extension))
            {
                using var reader = new StreamReader(path, Encoding.UTF8, true);
                text = reader.ReadToEnd();
            }
            else if (extension is "docx" or "xlsx")
            {
                using var archive = ZipFile.OpenRead(path);
                var entry = archive.GetEntry(extension == "docx" ? "word/document.xml" : "xl/sharedStrings.xml");
                if (entry is null) return false;
                using var reader = new StreamReader(entry.Open(), Encoding.UTF8);
                text = Regex.Replace(reader.ReadToEnd(), "<[^>]+>", " ");
            }
            else return false;
            var value = Fold(text);
            return folded.All(token => value.Contains(token, StringComparison.Ordinal));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException) { return false; }
    }

    internal static double Score(Hit hit, string[] tokens)
    {
        if (tokens.Length == 0) return 0;
        var name = Fold(Path.GetFileNameWithoutExtension(hit.Name));
        var query = Fold(string.Join(' ', tokens));
        var score = 0.0;
        if (name == query) score += 6; else if (name.StartsWith(query, StringComparison.Ordinal)) score += 3; else if (name.Contains(query, StringComparison.Ordinal)) score += 2;
        score += tokens.Count(token => name.Contains(Fold(token), StringComparison.Ordinal));
        score -= hit.Path.Split(['\\', '/'], StringSplitOptions.RemoveEmptyEntries).Length * 0.02;
        return score;
    }

    internal static List<Hit> Rank(IEnumerable<Hit> hits, Spec spec) =>
        (spec.Recent
            ? hits.OrderByDescending(hit => hit.ModifiedUtc).ThenBy(hit => hit.Path, StringComparer.CurrentCultureIgnoreCase)
            : hits.OrderByDescending(hit => Score(hit, spec.Tokens)).ThenByDescending(hit => hit.ModifiedUtc).ThenBy(hit => hit.Path, StringComparer.CurrentCultureIgnoreCase)).ToList();

    internal static string Fold(string value)
    {
        var builder = new StringBuilder(value.Length);
        foreach (var character in value.Replace("ı", "i", StringComparison.Ordinal).Replace("İ", "i", StringComparison.Ordinal).Normalize(NormalizationForm.FormD))
            if (CharUnicodeInfo.GetUnicodeCategory(character) != UnicodeCategory.NonSpacingMark) builder.Append(char.ToLowerInvariant(character));
        return builder.ToString();
    }
}
