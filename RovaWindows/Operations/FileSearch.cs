using System.Globalization;
using System.Text;

namespace RovaWindows.Operations;

/// Whole-machine file-name search with a resumable cursor (MacSearchRegistry): at most 12 matches,
/// 25,000 entries or 15 seconds per call, sessions expire after 10 minutes, at most 5 open.
/// Names are compared case- and diacritic-insensitively, so "rapor" finds "Rapör.docx".
internal static class FileSearch
{
    private sealed class Session
    {
        public required string Query { get; init; }
        public required Stack<string> Directories { get; init; }
        public IEnumerator<string>? Entries { get; set; }
        public int Skipped { get; set; }
        public DateTimeOffset ExpiresAt { get; set; } = DateTimeOffset.UtcNow.AddMinutes(10);
        public void Close() { Entries?.Dispose(); Entries = null; }
    }

    private static readonly object Gate = new();
    private static readonly Dictionary<string, Session> Sessions = new(StringComparer.Ordinal);
    private static readonly string[] SkippedRoots = ["\\Windows\\WinSxS", "\\$Recycle.Bin", "\\System Volume Information", "\\Windows\\Installer"];

    internal static Outcome Search(FileSearchPayload payload, CancellationToken cancellationToken)
    {
        var query = Fold(payload.Query.Trim());
        lock (Gate)
        {
            foreach (var expired in Sessions.Where(item => item.Value.ExpiresAt < DateTimeOffset.UtcNow).Select(item => item.Key).ToArray())
            {
                Sessions[expired].Close();
                Sessions.Remove(expired);
            }
            Session session;
            string id;
            if (payload.Cursor is { Length: > 0 } cursor)
            {
                if (!Sessions.TryGetValue(cursor, out var existing) || existing.Query != query)
                    return Outcome.Fail("INVALID_CURSOR", "Aramayı yeniden başlat.");
                id = cursor;
                session = existing;
            }
            else
            {
                if (Sessions.Count >= 5) return Outcome.Fail("SEARCH_LIMIT", "Biraz sonra tekrar dene.");
                try
                {
                    var roots = DriveInfo.GetDrives().Where(drive => drive.IsReady && drive.DriveType is DriveType.Fixed or DriveType.Removable).Select(drive => drive.RootDirectory.FullName);
                    // The profile first: that is where the user's files almost always are.
                    session = new Session { Query = query, Directories = new Stack<string>(roots.Reverse().Append(WindowsPaths.UserProfile)) };
                }
                catch { return Outcome.Fail("SEARCH_FAILED", "Dosyalar aranamadı."); }
                id = Guid.NewGuid().ToString();
                Sessions[id] = session;
            }

            var matches = new List<object>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var visited = 0;
            var deadline = DateTimeOffset.UtcNow.AddSeconds(15);
            while (session.Entries is not null || session.Directories.Count > 0)
            {
                if (cancellationToken.IsCancellationRequested)
                {
                    Sessions.Remove(id);
                    session.Close();
                    return Outcome.Fail("CANCELLED", "Arama iptal edildi.");
                }
                if (session.Entries is null)
                {
                    var directory = session.Directories.Pop();
                    if (SkippedRoots.Any(skip => directory.EndsWith(skip, StringComparison.OrdinalIgnoreCase))) continue;
                    try { session.Entries = Directory.EnumerateFileSystemEntries(directory).GetEnumerator(); }
                    catch (Exception error) when (error is UnauthorizedAccessException or IOException) { session.Skipped++; continue; }
                }
                bool more;
                try { more = session.Entries.MoveNext(); }
                catch (Exception error) when (error is UnauthorizedAccessException or IOException) { session.Skipped++; more = false; }
                if (!more) { session.Close(); continue; }
                var path = session.Entries.Current;
                visited++;
                FileAttributes attributes;
                try { attributes = File.GetAttributes(path); }
                catch { session.Skipped++; continue; }
                if ((attributes & FileAttributes.ReparsePoint) != 0 && PathSafety.IsLink(path)) continue;
                if ((attributes & FileAttributes.Directory) != 0)
                {
                    // The profile was searched first; the drive walk does not repeat it.
                    if (!string.Equals(path, WindowsPaths.UserProfile, StringComparison.OrdinalIgnoreCase)) session.Directories.Push(path);
                }
                else if (path.Length <= 500 && Fold(Path.GetFileName(path)).Contains(query, StringComparison.Ordinal) && seen.Add(path))
                {
                    try
                    {
                        var info = new FileInfo(path);
                        matches.Add(new { path = info.FullName, name = info.Name, fileType = info.Extension.TrimStart('.').ToLowerInvariant(), byteCount = info.Length, modifiedAt = info.LastWriteTimeUtc, isDirectory = false });
                    }
                    catch { session.Skipped++; }
                }
                if (matches.Count >= 12 || visited >= 25_000 || DateTimeOffset.UtcNow >= deadline)
                {
                    session.ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(10);
                    return Outcome.WithData("files", matches, $"Kısmi sonuç; devam kodu {id}. Erişilemeyen öğe: {session.Skipped}.");
                }
            }
            Sessions.Remove(id);
            session.Close();
            return Outcome.WithData("files", matches, $"Arama tamamlandı. Erişilemeyen öğe: {session.Skipped}.");
        }
    }

    internal static string Fold(string value)
    {
        var builder = new StringBuilder(value.Length);
        foreach (var character in value.Replace("ı", "i", StringComparison.Ordinal).Replace("İ", "i", StringComparison.Ordinal).Normalize(NormalizationForm.FormD))
            if (CharUnicodeInfo.GetUnicodeCategory(character) != UnicodeCategory.NonSpacingMark) builder.Append(char.ToLowerInvariant(character));
        return builder.ToString();
    }
}
