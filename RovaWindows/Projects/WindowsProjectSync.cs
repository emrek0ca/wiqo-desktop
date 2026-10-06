using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace RovaWindows.Projects;

internal sealed record ProjectMeta(string Name, string Kind);
internal sealed record SealedFile(string P, string? B, string? H, bool D = false);
internal sealed record FileEnvelope(string Path, string? Content);
internal sealed record ProjectLink(int HubId, int Version, ProjectMeta Meta, Dictionary<string, string> Base, string KeyId);
internal sealed record ProjectItem(string Name, string Kind, string Folder);

/// Bounded, cancellable Act adapter. Uses the existing encrypted hub, never a second sync service.
internal sealed class WindowsProjectSync : IDisposable
{
    private const string LinkName = ".wiqo-sync.json";
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(40) };
    private readonly Uri api;
    private readonly Func<CancellationToken, Task<string?>> token;
    private readonly SemaphoreSlim gate = new(1, 1);
    private static readonly UTF8Encoding Utf8 = new(false, true);
    private static readonly HashSet<string> Extensions = new(StringComparer.OrdinalIgnoreCase) { ".html", ".htm", ".css", ".js", ".json", ".txt", ".md", ".py", ".svg", ".csv" };
    internal string Root { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Wiqo Projeleri");
    internal string Status { get; private set; } = "Senkron için iPhone'daki Act kurtarma kodunu gir.";
    internal IReadOnlyList<ProjectItem> Items { get; private set; } = Array.Empty<ProjectItem>();
    internal event Action? Changed;
    internal WindowsProjectSync(Uri api, Func<CancellationToken, Task<string?>> token) { this.api = api; this.token = token; }

    internal async Task EnableAsync(string recoveryCode, CancellationToken ct)
    {
        var key = ActVault.RecoveryKey(recoveryCode);
        try
        {
            await gate.WaitAsync(ct).ConfigureAwait(false);
            try { WindowsSecretStore.SaveActKey(key); }
            finally { gate.Release(); }
        }
        finally { CryptographicOperations.ZeroMemory(key); }
        await SyncAsync(ct).ConfigureAwait(false);
    }
    internal async Task RunAsync(CancellationToken ct)
    {
        // One bounded pass per interval; no overlapping scans or retry storm when offline.
        while (!ct.IsCancellationRequested)
        {
            await SyncAsync(ct).ConfigureAwait(false);
            await Task.Delay(TimeSpan.FromSeconds(30), ct).ConfigureAwait(false);
        }
    }
    internal async Task SyncAsync(CancellationToken ct)
    {
        if (!await gate.WaitAsync(0, ct).ConfigureAwait(false)) return;
        try
        {
            var key = WindowsSecretStore.LoadActKey();
            if (key is null) { Status = "Senkron kapalı: Act kurtarma kodunu gir."; return; }
            using var vault = new ActVault(key); CryptographicOperations.ZeroMemory(key);
            Directory.CreateDirectory(Root); EnsureNoLinks(Root);
            using var projects = await RequestAsync(HttpMethod.Get, "code-sync/projects", null, ct).ConfigureAwait(false);
            var folders = new Dictionary<int, string>();
            foreach (var dir in Directory.EnumerateDirectories(Root).Take(100))
            {
                EnsureNoLinks(dir);
                var link = ReadLink(dir);
                if (link is not null && link.KeyId == vault.KeyId && !folders.TryAdd(link.HubId, dir))
                    throw new InvalidDataException("Aynı projenin iki bağlı klasörü var; bir kopyayı proje klasörünün dışına taşı.");
            }
            var active = new List<ProjectItem>(); var foreign = 0;
            foreach (var project in projects.RootElement.GetProperty("projects").EnumerateArray())
            {
                ct.ThrowIfCancellationRequested();
                var id = project.GetProperty("id").GetInt32();
                ProjectMeta meta;
                try { meta = vault.Open<ProjectMeta>(project.GetProperty("meta").GetString()!); }
                catch (CryptographicException) { foreign++; continue; }
                var folder = folders.GetValueOrDefault(id);
                if (folder is null)
                {
                    if (project.GetProperty("version").GetInt32() == 0) continue;
                    folder = NewFolder(meta.Name);
                    Directory.CreateDirectory(folder);
                    WriteLink(folder, new(id, 0, meta, new(), vault.KeyId));
                }
                await SyncFolder(folder, vault, ct).ConfigureAwait(false);
                active.Add(new(meta.Name, meta.Kind, folder));
            }
            foreach (var folder in Directory.EnumerateDirectories(Root).Take(100))
            {
                ct.ThrowIfCancellationRequested(); EnsureNoLinks(folder);
                if (ReadLink(folder) is not null) continue;
                var files = Scan(folder);
                var kind = files.ContainsKey("index.html") ? "web" : files.Keys.Any(p => p.EndsWith(".py", StringComparison.OrdinalIgnoreCase)) ? "python" : null;
                if (kind is null) continue;
                var meta = new ProjectMeta(Path.GetFileName(folder), kind);
                using var created = await RequestAsync(HttpMethod.Post, "code-sync/projects", new { meta = vault.Seal(meta) }, ct).ConfigureAwait(false);
                WriteLink(folder, new(created.RootElement.GetProperty("id").GetInt32(), 0, meta, new(), vault.KeyId));
                await SyncFolder(folder, vault, ct).ConfigureAwait(false);
                active.Add(new(meta.Name, meta.Kind, folder));
            }
            Items = active;
            Status = $"Eşit · {active.Count} proje" + (foreign > 0 ? $" · {foreign} proje başka anahtarla şifreli" : "");
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception error)
        {
            Status = error switch
            {
                HttpRequestException => "Sunucuya ulaşılamadı; yeniden denenecek.",
                OperationCanceledException => "Senkron süresi doldu; yeniden denenecek.",
                CryptographicException => "Proje anahtarı uyuşmuyor; iPhone'daki kurtarma kodunu kullan.",
                InvalidDataException => "Proje sınırı, dosya yolu veya senkron verisi geçersiz; dosyalar korundu.",
                UnauthorizedAccessException => "Klasöre veya cihaz oturumuna erişilemiyor; izinleri ve eşleşmeyi kontrol et.",
                _ => "Senkron tamamlanamadı; dosyalar korundu, yeniden denenecek."
            };
        }
        finally { gate.Release(); Changed?.Invoke(); }
    }
    private async Task SyncFolder(string folder, ActVault vault, CancellationToken ct)
    {
        var link = ReadLink(folder) ?? throw new InvalidDataException();
        if (link.KeyId != vault.KeyId) throw new CryptographicException();
        var before = Scan(folder);
        // Never treat an excluded/oversize/unreadable file as a user deletion.
        foreach (var name in link.Base.Keys) if (!before.ContainsKey(name) && File.Exists(SafePath(folder, name))) throw new InvalidDataException();
        var baseline = new Dictionary<string, string>(link.Base, StringComparer.Ordinal);
        var changes = before.Where(pair => baseline.GetValueOrDefault(pair.Key) != vault.ContentHash(pair.Key, pair.Value))
            .Select(pair => new SealedFile(vault.PathToken(pair.Key), vault.Seal(new FileEnvelope(pair.Key, pair.Value)), vault.ContentHash(pair.Key, pair.Value))).ToList();
        changes.AddRange(baseline.Keys.Where(p => !before.ContainsKey(p)).Select(p => new SealedFile(vault.PathToken(p), vault.Seal(new FileEnvelope(p, null)), null, true)));
        if (changes.Count > 0)
        {
            using var pushed = await RequestAsync(HttpMethod.Post, $"code-sync/projects/{link.HubId}/push", new { baseVersion = link.Version, changes, summary = vault.Seal(new { text = "Windows düzenlemesi" }), device = "Windows" }, ct, allowConflict: true).ConfigureAwait(false);
            if (pushed.RootElement.TryGetProperty("ok", out var ok) && ok.GetBoolean())
                baseline = before.ToDictionary(p => p.Key, p => vault.ContentHash(p.Key, p.Value), StringComparer.Ordinal);
            else if (!pushed.RootElement.TryGetProperty("conflict", out var conflict) || !conflict.GetBoolean()) throw new InvalidDataException();
        }
        using var snapshot = await RequestAsync(HttpMethod.Get, $"code-sync/projects/{link.HubId}/snapshot", null, ct).ConfigureAwait(false);
        var remote = new Dictionary<string, string>(StringComparer.Ordinal);
        var windowsNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in snapshot.RootElement.GetProperty("files").EnumerateArray())
        {
            var file = entry.Deserialize<SealedFile>(ActVault.Json) ?? throw new InvalidDataException();
            var opened = vault.Open<FileEnvelope>(file.B ?? throw new InvalidDataException());
            if (opened.Content is null || !Syncable(opened.Path, opened.Content) || !windowsNames.Add(opened.Path)
                || file.P != vault.PathToken(opened.Path) || file.H != vault.ContentHash(opened.Path, opened.Content)) throw new InvalidDataException();
            _ = SafePath(folder, opened.Path); remote.Add(opened.Path, opened.Content);
        }
        if (remote.Count > 40) throw new InvalidDataException();
        var merged = new Dictionary<string, string>(before, StringComparer.Ordinal);
        foreach (var name in baseline.Keys.Union(remote.Keys).Union(before.Keys).ToArray())
        {
            before.TryGetValue(name, out var local); remote.TryGetValue(name, out var incoming);
            var localHash = local is null ? null : vault.ContentHash(name, local);
            var remoteHash = incoming is null ? null : vault.ContentHash(name, incoming);
            if (localHash == remoteHash || remoteHash == baseline.GetValueOrDefault(name)) continue;
            if (localHash != baseline.GetValueOrDefault(name) && local is not null)
            {
                var ext = Path.GetExtension(name); var stem = name[..^ext.Length]; var copy = stem + " - Windows kopyası" + ext; var n = 2;
                while (merged.Keys.Concat(remote.Keys).Contains(copy, StringComparer.OrdinalIgnoreCase)) copy = stem + $" - Windows kopyası {n++}" + ext;
                merged[copy] = local;
            }
            if (incoming is null) merged.Remove(name); else merged[name] = incoming;
        }
        // The editor may have changed a file while HTTP was pending. Retry from disk next pass.
        var current = Scan(folder);
        if (current.Count != before.Count || before.Any(p => current.GetValueOrDefault(p.Key) != p.Value)) throw new IOException();
        foreach (var pair in merged.Where(p => before.GetValueOrDefault(p.Key) != p.Value)) AtomicWrite(SafePath(folder, pair.Key), pair.Value);
        foreach (var name in before.Keys.Except(merged.Keys)) File.Delete(SafePath(folder, name));
        var meta = vault.Open<ProjectMeta>(snapshot.RootElement.GetProperty("meta").GetString()!);
        WriteLink(folder, new(link.HubId, snapshot.RootElement.GetProperty("version").GetInt32(), meta,
            remote.ToDictionary(p => p.Key, p => vault.ContentHash(p.Key, p.Value)), vault.KeyId));
    }
    private async Task<JsonDocument> RequestAsync(HttpMethod method, string path, object? body, CancellationToken ct, bool allowConflict = false)
    {
        var access = await token(ct).ConfigureAwait(false);
        if (string.IsNullOrEmpty(access)) throw new UnauthorizedAccessException();
        using var request = new HttpRequestMessage(method, new Uri(api, path));
        request.Headers.Authorization = new("Bearer", access);
        if (body is not null) request.Content = JsonContent.Create(body, options: ActVault.Json);
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden) throw new UnauthorizedAccessException();
        if (!(allowConflict && response.StatusCode == HttpStatusCode.Conflict)) response.EnsureSuccessStatusCode();
        await response.Content.LoadIntoBufferAsync(8 * 1024 * 1024).WaitAsync(ct).ConfigureAwait(false);
        return JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false));
    }
    private static bool Syncable(string name, string content) => Extensions.Contains(Path.GetExtension(name)) && Utf8.GetByteCount(content) <= 100 * 1024;
    private static void EnsureNoLinks(string path)
    {
        for (var current = Path.GetFullPath(path); !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
            if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException();
    }
    private static string SafePath(string folder, string name)
    {
        var parts = name.Split('/');
        if (parts.Length > 4 || parts.Any(p => string.IsNullOrWhiteSpace(p) || p.StartsWith('.') || p.EndsWith('.') || p.EndsWith(' ')
            || p.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || p.Contains('\\')
            || System.Text.RegularExpressions.Regex.IsMatch(p, @"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)", System.Text.RegularExpressions.RegexOptions.IgnoreCase))) throw new InvalidDataException();
        var path = Path.GetFullPath(Path.Combine(folder, Path.Combine(parts))); EnsureNoLinks(path);
        if (!path.StartsWith(Path.GetFullPath(folder) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException();
        return path;
    }
    private static Dictionary<string, string> Scan(string folder)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal); EnsureNoLinks(folder);
        void Walk(string dir, int depth)
        {
            if (depth > 4) return;
            foreach (var entry in Directory.EnumerateFileSystemEntries(dir))
            {
                if (Path.GetFileName(entry).StartsWith('.')) continue;
                EnsureNoLinks(entry);
                if (Directory.Exists(entry)) { Walk(entry, depth + 1); continue; }
                if (!Extensions.Contains(Path.GetExtension(entry))) continue;
                var relative = Path.GetRelativePath(folder, entry).Replace('\\', '/'); _ = SafePath(folder, relative);
                if (new FileInfo(entry).Length > 100 * 1024) throw new InvalidDataException();
                result.Add(relative, File.ReadAllText(entry, Utf8));
                if (result.Count > 40) throw new InvalidDataException();
            }
        }
        Walk(folder, 1); return result;
    }
    private static ProjectLink? ReadLink(string folder)
    {
        var path = Path.Combine(folder, LinkName); EnsureNoLinks(path);
        if (!File.Exists(path)) return null;
        if (new FileInfo(path).Length > 64 * 1024) throw new InvalidDataException();
        return JsonSerializer.Deserialize<ProjectLink>(File.ReadAllText(path), ActVault.Json) ?? throw new InvalidDataException();
    }
    private static void WriteLink(string folder, ProjectLink link) => AtomicWrite(Path.Combine(folder, LinkName), JsonSerializer.Serialize(link, ActVault.Json));
    private static void AtomicWrite(string path, string value)
    {
        EnsureNoLinks(path); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try { File.WriteAllText(temp, value, new UTF8Encoding(false)); EnsureNoLinks(path); File.Move(temp, path, true); }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    private string NewFolder(string name)
    {
        var safe = new string(name.Where(c => !Path.GetInvalidFileNameChars().Contains(c) && c != '.' && c != '\\' && c != '/').Take(70).ToArray()).Trim();
        if (string.IsNullOrWhiteSpace(safe)) safe = "Proje";
        // Hub id is in the link; use a random suffix to avoid reserved names and local collisions.
        return SafePath(Root, "Act " + safe + " " + Guid.NewGuid().ToString("N")[..6]);
    }
    public void Dispose() { http.Dispose(); gate.Dispose(); }
}
