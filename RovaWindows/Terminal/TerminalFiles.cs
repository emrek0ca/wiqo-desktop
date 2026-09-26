using System.Diagnostics;
using System.IO.Enumeration;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace RovaWindows.Terminal;

internal sealed record Replacement(string Path, string Display, string Find, string Replace, bool ReplaceAll);

/// File work inside an approved terminal folder (MacSystem+Code counterparts): line-numbered reads,
/// atomic writes that keep the file's line endings and BOM, exact find/replace edits applied all or
/// nothing, content search, and a guard that never saves a JSON file broken by an edit.
internal static class TerminalFiles
{
    private const int MaxReadBytes = 2_000_000;
    private const int MaxReadText = 60_000;

    internal static (string? Text, int TotalLines, WireError? Error) Read(string path, int? startLine, int? endLine)
    {
        try
        {
            if (new FileInfo(path).Length > MaxReadBytes) return (null, 0, new WireError("TERMINAL_FILE_TOO_LARGE", "Dosya okunamadı ya da 2 MB'tan büyük.", "validation"));
            var content = Decode(File.ReadAllBytes(path), out _);
            if (content is null) return (null, 0, new WireError("TERMINAL_FILE_NOT_TEXT", "Dosya UTF-8 metin değil.", "validation"));
            var lines = content.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
            var first = Math.Max(1, startLine ?? 1);
            var last = Math.Min(lines.Length, Math.Max(first, endLine ?? first + 399));
            if (first > lines.Length) return ("", lines.Length, null);
            var text = new StringBuilder();
            for (var index = first - 1; index < last; index++)
            {
                text.Append(index + 1).Append('\t').Append(lines[index]).Append('\n');
                if (text.Length > MaxReadText) { text.Append("[... 60 KB sınırı; daha dar satır aralığı iste ...]\n"); break; }
            }
            return (RovaTerminalPolicy.RedactSecrets(text.ToString()), lines.Length, null);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return (null, 0, new WireError("TERMINAL_FILE_READ_FAILED", $"Dosya okunamadı: {error.Message}", "tool_failure"));
        }
    }

    /// Creates or replaces a file; an existing file keeps its CRLF/LF style and its BOM.
    internal static (bool Created, WireError? Error) Write(string path, string content, string display)
    {
        if (content.Length > 400_000 || content.Contains('\0')) return (false, new WireError("TERMINAL_FILE_TOO_LARGE", "Yazılacak içerik 400 KB'tan büyük ya da ikili.", "validation"));
        try
        {
            var existed = File.Exists(path);
            var bom = false;
            var crlf = false;
            string? before = null;
            if (existed)
            {
                before = Decode(File.ReadAllBytes(path), out bom);
                crlf = before?.Contains("\r\n", StringComparison.Ordinal) == true;
            }
            var normalized = content.Replace("\r\n", "\n", StringComparison.Ordinal);
            var final = crlf ? normalized.Replace("\n", "\r\n", StringComparison.Ordinal) : normalized;
            if (existed && BrokenJson(path, before, final, display) is { } error) return (false, error);
            Save(path, final, bom);
            return (!existed, null);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return (false, new WireError("TERMINAL_FILE_WRITE_FAILED", $"Dosya yazılamadı: {error.Message}", "tool_failure"));
        }
    }

    /// Every find must match exactly once (or replaceAll); all files are checked before any is
    /// written. A find written with "\n" also matches a CRLF file (the model rarely sends "\r\n").
    internal static (string? Summary, WireError? Error) Edit(IReadOnlyList<Replacement> edits)
    {
        var contents = new Dictionary<string, (string Text, bool Bom)>(StringComparer.OrdinalIgnoreCase);
        var originals = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var edit in edits)
        {
            if (edit.Find.Length == 0) return (null, new WireError("TERMINAL_EDIT_INVALID", $"{edit.Display}: aranacak metin boş; hiçbir dosya değiştirilmedi.", "validation"));
            if (!contents.TryGetValue(edit.Path, out var current))
            {
                string? text;
                bool bom;
                try { text = Decode(File.ReadAllBytes(edit.Path), out bom); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { text = null; bom = false; }
                if (text is null) return (null, new WireError("TERMINAL_FILE_NOT_TEXT", $"{edit.Display} okunamadı; hiçbir dosya değiştirilmedi.", "validation"));
                current = (text, bom);
                contents[edit.Path] = current;
                originals[edit.Path] = text;
            }
            var (find, replace) = (edit.Find, edit.Replace);
            var occurrences = Count(current.Text, find);
            if (occurrences == 0 && current.Text.Contains("\r\n", StringComparison.Ordinal) && find.Contains('\n') && !find.Contains("\r\n", StringComparison.Ordinal))
            {
                find = find.Replace("\n", "\r\n", StringComparison.Ordinal);
                replace = replace.Replace("\r\n", "\n", StringComparison.Ordinal).Replace("\n", "\r\n", StringComparison.Ordinal);
                occurrences = Count(current.Text, find);
            }
            if (occurrences == 0)
                return (null, new WireError("TERMINAL_EDIT_NOT_FOUND", $"{edit.Display}: aranan metin dosyada birebir bulunamadı (boşluk ve girinti dahil); dosyayı read_file ile okuyup tekrar dene. Hiçbir dosya değiştirilmedi.", "validation"));
            if (occurrences > 1 && !edit.ReplaceAll)
                return (null, new WireError("TERMINAL_EDIT_AMBIGUOUS", $"{edit.Display}: aranan metin {occurrences} kez geçiyor; daha uzun, tek geçen bir parça ver ya da replaceAll kullan. Hiçbir dosya değiştirilmedi.", "validation"));
            var index = current.Text.IndexOf(find, StringComparison.Ordinal);
            var updated = edit.ReplaceAll ? current.Text.Replace(find, replace, StringComparison.Ordinal) : current.Text[..index] + replace + current.Text[(index + find.Length)..];
            contents[edit.Path] = (updated, current.Bom);
            counts[edit.Display] = counts.GetValueOrDefault(edit.Display) + (edit.ReplaceAll ? occurrences : 1);
        }
        foreach (var (path, value) in contents)
            if (BrokenJson(path, originals[path], value.Text, Path.GetFileName(path)) is { } error) return (null, error);
        try
        {
            foreach (var (path, value) in contents) Save(path, value.Text, value.Bom);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return (null, new WireError("TERMINAL_FILE_WRITE_FAILED", $"Dosya yazılamadı: {error.Message}", "tool_failure"));
        }
        return (string.Join("\n", counts.OrderBy(item => item.Key, StringComparer.Ordinal).Select(item => $"{item.Key}: {item.Value} değişiklik")), null);
    }

    /// ripgrep when installed, otherwise a managed search with the same limits: 20 hits per file,
    /// 200 lines, 20 seconds, .git and node_modules skipped, binary files ignored.
    internal static async Task<(string? Text, WireError? Error)> SearchAsync(string pattern, string directory, string? glob, CancellationToken cancellationToken)
    {
        if (pattern.Length is 0 or > 200 || pattern.Contains('\0')) return (null, new WireError("TERMINAL_SEARCH_INVALID", "Arama kalıbı boş ya da çok uzun.", "validation"));
        if (glob is { Length: > 100 }) glob = null;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        try
        {
            var text = TerminalProcess.FindOnPath("rg.exe") is { } ripgrep
                ? await RipgrepAsync(ripgrep, pattern, directory, glob, timeout.Token).ConfigureAwait(false)
                : ManagedSearch(pattern, directory, glob, timeout.Token);
            return (RovaTerminalPolicy.RedactSecrets(string.IsNullOrWhiteSpace(text) ? "(eşleşme yok)" : text), null);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return (null, new WireError("TERMINAL_SEARCH_TIMEOUT", "Arama 20 saniyede bitmedi; daha dar bir klasör veya kalıp dene.", "timeout"));
        }
    }

    private static async Task<string> RipgrepAsync(string executable, string pattern, string directory, string? glob, CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo(executable)
        {
            WorkingDirectory = directory, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8
        };
        foreach (var argument in new[] { "--line-number", "--no-heading", "--color", "never", "--max-count", "20", "--max-columns", "300", "-g", "!.git", "-g", "!node_modules" })
            start.ArgumentList.Add(argument);
        if (!string.IsNullOrEmpty(glob)) { start.ArgumentList.Add("-g"); start.ArgumentList.Add(glob); }
        start.ArgumentList.Add("--");
        start.ArgumentList.Add(pattern);
        start.ArgumentList.Add(".");
        using var process = Process.Start(start) ?? throw new IOException("ripgrep başlatılamadı.");
        try
        {
            var output = await process.StandardOutput.ReadToEndAsync(cancellationToken).ConfigureAwait(false);
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            return string.Join("\n", output.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n').Take(200));
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch { }
            throw;
        }
    }

    private static string ManagedSearch(string pattern, string directory, string? glob, CancellationToken cancellationToken)
    {
        Regex regex;
        try { regex = new Regex(pattern, RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(200)); }
        catch (ArgumentException) { regex = new Regex(Regex.Escape(pattern), RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(200)); }
        var lines = new List<string>();
        var pending = new Stack<string>([directory]);
        while (pending.Count > 0 && lines.Count < 200)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var current = pending.Pop();
            IEnumerable<string> entries;
            try { entries = Directory.EnumerateFileSystemEntries(current).ToArray(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { continue; }
            foreach (var entry in entries)
            {
                var name = Path.GetFileName(entry);
                if (Directory.Exists(entry))
                {
                    if (name is not (".git" or "node_modules" or "bin" or "obj") && !PathSafety.IsLink(entry)) pending.Push(entry);
                    continue;
                }
                if (glob is not null && !FileSystemName.MatchesSimpleExpression(glob, name)) continue;
                try
                {
                    var info = new FileInfo(entry);
                    if (info.Length > 2_000_000) continue;
                    var text = Decode(File.ReadAllBytes(entry), out _);
                    if (text is null) continue;
                    var relative = Path.GetRelativePath(directory, entry).Replace('\\', '/');
                    var hits = 0;
                    var number = 0;
                    foreach (var line in text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
                    {
                        number++;
                        if (!regex.IsMatch(line)) continue;
                        lines.Add($"{relative}:{number}:{(line.Length > 300 ? line[..300] : line)}");
                        if (++hits >= 20 || lines.Count >= 200) break;
                    }
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or RegexMatchTimeoutException) { }
                if (lines.Count >= 200) break;
            }
        }
        return string.Join("\n", lines);
    }

    /// A JSON file that parsed before the change must still parse after it; JSONC files (a
    /// commented tsconfig) never parsed and are left alone (MacSystem.brokenJSON).
    internal static WireError? BrokenJson(string path, string? before, string after, string display)
    {
        if (!path.EndsWith(".json", StringComparison.OrdinalIgnoreCase) || before is null || !Parses(before)) return null;
        try
        {
            using var _ = JsonDocument.Parse(after);
            return null;
        }
        catch (JsonException error)
        {
            return new WireError("TERMINAL_EDIT_INVALID_JSON", $"{display}: değişiklik sonrası JSON geçersiz olurdu ({error.Message}); hiçbir dosya değiştirilmedi. Virgül ve parantezleri kontrol edip tekrar dene.", "validation");
        }
    }

    private static bool Parses(string text)
    {
        try { using var _ = JsonDocument.Parse(text); return true; }
        catch (JsonException) { return false; }
    }

    /// UTF-8 (with or without BOM); null for binary or non-UTF-8 content.
    internal static string? Decode(byte[] bytes, out bool bom)
    {
        bom = bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
        if (Array.IndexOf(bytes, (byte)0) >= 0) return null;
        try { return new UTF8Encoding(false, true).GetString(bytes, bom ? 3 : 0, bytes.Length - (bom ? 3 : 0)); }
        catch (DecoderFallbackException) { return null; }
    }

    private static void Save(string path, string text, bool bom)
    {
        var bytes = new UTF8Encoding(bom).GetPreamble().Concat(new UTF8Encoding(false).GetBytes(text)).ToArray();
        var temporary = path + ".wiqo-" + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(temporary, bytes);
            File.Move(temporary, path, true);
        }
        finally { try { File.Delete(temporary); } catch { } }
    }

    private static int Count(string text, string find)
    {
        var count = 0;
        for (var index = text.IndexOf(find, StringComparison.Ordinal); index >= 0; index = text.IndexOf(find, index + find.Length, StringComparison.Ordinal)) count++;
        return count;
    }
}
