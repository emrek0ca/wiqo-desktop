using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;
using RovaWindows.Native;

namespace RovaWindows.Operations;

internal sealed record InstalledApplication(string Name, string Id, string Path);

/// Finding, opening, listing and closing apps (MacSystem+Applications). The catalogue is what the
/// Start menu shows - desktop and Store apps with their localized names (Get-StartApps) - plus
/// registered App Paths; names are matched with the Mac's scoring, results use the Mac's shapes.
internal static class ApplicationOperations
{
    private static readonly SemaphoreSlim CatalogGate = new(1, 1);
    private static IReadOnlyList<InstalledApplication> catalog = [];
    private static DateTimeOffset catalogLoadedAt = DateTimeOffset.MinValue;

    /// ApplicationID (a Mac app) mapped to what the user means on Windows.
    private static readonly Dictionary<string, string[]> ApplicationIdQueries = new(StringComparer.Ordinal)
    {
        ["safari"] = ["Microsoft Edge", "Google Chrome"],
        ["terminal"] = ["Terminal", "Windows PowerShell"],
        ["finder"] = ["Dosya Gezgini", "File Explorer"],
        ["visualStudioCode"] = ["Visual Studio Code"],
        ["mail"] = ["Outlook", "Posta", "Mail"],
        ["music"] = ["Spotify", "Media Player", "Medya Oynatıcı"],
        ["notes"] = ["Not Defteri", "Notepad", "Sticky Notes", "Yapışkan Notlar"],
        ["systemSettings"] = ["Ayarlar", "Settings"]
    };

    /// Common English/Turkish names for apps whose Start-menu name is localized.
    private static readonly Dictionary<string, string[]> Aliases = new(StringComparer.Ordinal)
    {
        ["chrome"] = ["google chrome"], ["edge"] = ["microsoft edge"], ["vscode"] = ["visual studio code"], ["vs code"] = ["visual studio code"],
        ["code"] = ["visual studio code"], ["word"] = ["word", "microsoft word"], ["excel"] = ["excel", "microsoft excel"],
        ["powerpoint"] = ["powerpoint"], ["explorer"] = ["dosya gezgini", "file explorer"], ["finder"] = ["dosya gezgini", "file explorer"],
        ["settings"] = ["ayarlar", "settings"], ["ayarlar"] = ["ayarlar", "settings"], ["calculator"] = ["hesap makinesi", "calculator"],
        ["hesap makinesi"] = ["hesap makinesi", "calculator"], ["notepad"] = ["not defteri", "notepad"], ["not defteri"] = ["not defteri", "notepad"],
        ["terminal"] = ["terminal", "windows powershell"], ["cmd"] = ["komut istemi", "command prompt"], ["whatsapp"] = ["whatsapp"],
        ["teams"] = ["microsoft teams", "teams"], ["outlook"] = ["outlook"], ["spotify"] = ["spotify"]
    };

    internal static async Task<Outcome> OpenById(string applicationId, CancellationToken cancellationToken)
    {
        if (!ApplicationIdQueries.TryGetValue(applicationId, out var queries))
            return Outcome.Fail("APPLICATION_NOT_FOUND", "Bu uygulamanın Windows karşılığı yok.");
        foreach (var query in queries)
        {
            var outcome = await OpenByName(query, cancellationToken).ConfigureAwait(false);
            if (outcome.Error is null) return outcome with { Data = null };
        }
        return Outcome.Fail("APPLICATION_NOT_FOUND", "Uygulama bu bilgisayarda bulunamadı.");
    }

    internal static async Task<Outcome> OpenByName(string query, CancellationToken cancellationToken)
    {
        var normalized = Normalize(query);
        if (normalized.Length == 0) return Outcome.Fail("INVALID_APPLICATION_NAME", "Uygulama adı boş olamaz.");
        var apps = await Catalog(cancellationToken).ConfigureAwait(false);
        var ranked = Rank(apps, normalized);
        if (ranked.Count == 0 || ranked[0].Score < 0.5) return Outcome.Fail("APPLICATION_NOT_FOUND", "Bu adla eşleşen uygulama bulunamadı.");
        var best = ranked[0];
        var second = ranked.Count > 1 ? ranked[1].Score : 0;
        var exact = ranked.Count(item => Normalize(item.App.Name) == normalized);
        if (exact > 1 || (best.Score < 0.86 && best.Score - second < 0.10))
            return new Outcome("Birden fazla benzer uygulama bulundu; hangisinin açılacağını seç.",
                new { kind = "installedApplications", value = ranked.Take(5).Select(item => Info(item.App)).ToArray() },
                new WireError("APPLICATION_AMBIGUOUS", "Birden fazla benzer uygulama bulundu; hangisinin açılacağını seç."));
        if (!Launch(best.App)) return Outcome.Fail("APPLICATION_OPEN_FAILED", "Uygulama açılamadı.");
        return Outcome.WithData("installedApplications", new[] { Info(best.App) }, $"{best.App.Name} açıldı.");
    }

    internal static async Task<Outcome> Control(ApplicationControlPayload payload, CancellationToken cancellationToken)
    {
        if (payload.Action == "quit") return await Quit(payload.Target, payload.Force, cancellationToken).ConfigureAwait(false);
        var running = RunningWindows().Where(item => Score(item.Name, Normalize(payload.Target)) >= 0.86).ToList();
        if (payload.Action == "activate" && running.Count > 0)
        {
            var window = running[0];
            if (NativeMethods.IsIconic(window.Window)) NativeMethods.ShowWindow(window.Window, NativeMethods.SwRestore);
            var activated = NativeMethods.SetForegroundWindow(window.Window);
            return Outcome.WithData("applicationControl", Content("activate", window.Name, window.ProcessName, "running", "running", false, activated), $"{window.Name} öne getirildi.");
        }
        var opened = await OpenByName(payload.Target, cancellationToken).ConfigureAwait(false);
        if (opened.Error is not null) return opened with { Data = null };
        var name = FirstName(opened) ?? payload.Target;
        var verified = await WaitFor(() => RunningWindows().Any(item => Score(item.Name, Normalize(name)) >= 0.86), TimeSpan.FromSeconds(6), cancellationToken).ConfigureAwait(false);
        return Outcome.WithData("applicationControl", Content(payload.Action, name, null, running.Count > 0 ? "running" : "not_running", verified ? "running" : "unknown", running.Count == 0, verified),
            verified ? $"{name} açıldı ve doğrulandı." : $"{name} başlatıldı; penceresi henüz doğrulanamadı.");
    }

    internal static Task<Outcome> QuitById(string applicationId, CancellationToken cancellationToken) =>
        ApplicationIdQueries.TryGetValue(applicationId, out var queries)
            ? Quit(queries[0], false, cancellationToken)
            : Task.FromResult(Outcome.Fail("APPLICATION_NOT_FOUND", "Bu uygulamanın Windows karşılığı yok."));

    /// Graceful first (WM_CLOSE to every main window of the app), kill only when force was asked
    /// and approved - never a silent force quit that could drop unsaved work.
    internal static async Task<Outcome> Quit(string target, bool force, CancellationToken cancellationToken)
    {
        var query = Normalize(target);
        var matches = RunningWindows().Select(item => (Item: item, Score: Score(item.Name, query))).Where(item => item.Score >= 0.86).ToList();
        var apps = matches.GroupBy(item => item.Item.ProcessName, StringComparer.OrdinalIgnoreCase).ToList();
        if (apps.Count == 0)
            return Outcome.WithData("applicationControl", Content("quit", target, null, "not_running", "not_running", false, true), $"{target} zaten açık değildi.");
        if (apps.Count > 1 && apps.Select(group => group.Max(item => item.Score)).Count(score => score >= 0.99) != 1)
        {
            var candidates = apps.Select(group => group.First().Item.Name).Distinct().ToArray();
            return new Outcome($"Birden fazla çalışan uygulama eşleşti: {string.Join(", ", candidates)}. Hedefi daha net belirtin.",
                new { kind = "applicationControl", value = Content("quit", target, null, "ambiguous", "unchanged", false, false, candidates) },
                new WireError("APPLICATION_AMBIGUOUS", $"Birden fazla çalışan uygulama eşleşti: {string.Join(", ", candidates)}. Hedefi daha net belirtin."));
        }
        var chosen = apps.OrderByDescending(group => group.Max(item => item.Score)).First();
        var processName = chosen.Key;
        var displayName = chosen.First().Item.Name;
        foreach (var process in Process.GetProcessesByName(processName))
        {
            try { if (process.MainWindowHandle != IntPtr.Zero) process.CloseMainWindow(); } catch { }
            finally { process.Dispose(); }
        }
        var closed = await WaitFor(() => Process.GetProcessesByName(processName).All(process => { using (process) return process.MainWindowHandle == IntPtr.Zero; }), TimeSpan.FromSeconds(6), cancellationToken).ConfigureAwait(false);
        if (!closed && force)
        {
            foreach (var process in Process.GetProcessesByName(processName))
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                finally { process.Dispose(); }
            }
            closed = await WaitFor(() => Process.GetProcessesByName(processName).Length == 0, TimeSpan.FromSeconds(4), cancellationToken).ConfigureAwait(false);
        }
        if (!closed)
            return new Outcome($"{displayName} kapanmadı; kaydedilmemiş bir belge onay bekliyor olabilir.",
                new { kind = "applicationControl", value = Content("quit", displayName, processName, "running", "running", false, false) },
                new WireError("APPLICATION_QUIT_TIMEOUT", $"{displayName} kapanmadı; kaydedilmemiş bir belge onay bekliyor olabilir. Zorla kapatmak için açıkça iste."));
        return Outcome.WithData("applicationControl", Content("quit", displayName, processName, "running", "not_running", true, true), $"{displayName} kapatıldı ve doğrulandı.");
    }

    internal static Outcome ListRunning()
    {
        var foreground = NativeMethods.GetForegroundWindow();
        NativeMethods.GetWindowThreadProcessId(foreground, out var activeProcessId);
        var apps = RunningWindows()
            .GroupBy(item => item.ProcessName, StringComparer.OrdinalIgnoreCase)
            .Select(group => new { name = group.First().Name, bundleIdentifier = group.Key, isActive = group.Any(item => item.ProcessId == activeProcessId) })
            .OrderBy(item => item.name, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
        return Outcome.WithData("runningApplications", apps, "Açık uygulamalar listelendi.");
    }

    private sealed record RunningWindow(string Name, string ProcessName, uint ProcessId, IntPtr Window);

    /// Apps with a visible main window - what the user sees in the taskbar, not services.
    private static List<RunningWindow> RunningWindows()
    {
        var result = new List<RunningWindow>();
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    if (process.MainWindowHandle == IntPtr.Zero || process.Id == Environment.ProcessId) continue;
                    string name = process.ProcessName;
                    try { name = process.MainModule?.FileVersionInfo.FileDescription is { Length: > 0 } description ? description : name; } catch { }
                    result.Add(new RunningWindow(name, process.ProcessName, (uint)process.Id, process.MainWindowHandle));
                }
                catch { }
            }
        }
        return result;
    }

    private static object Content(string action, string name, string? id, string before, string after, bool changed, bool verified, string[]? candidates = null) => new
    {
        action, resolvedName = name, bundleIdentifier = id, stateBefore = before, stateAfter = after, changed, verified, candidates = candidates ?? []
    };

    private static object Info(InstalledApplication app) => new { name = app.Name, bundleIdentifier = app.Id, path = app.Path };

    private static string? FirstName(Outcome outcome)
    {
        try
        {
            var element = JsonSerializer.SerializeToElement(outcome.Data, WireJson.Options);
            return element.GetProperty("value")[0].GetProperty("name").GetString();
        }
        catch { return null; }
    }

    private static bool Launch(InstalledApplication app)
    {
        try
        {
            var start = app.Path.StartsWith("shell:AppsFolder\\", StringComparison.OrdinalIgnoreCase)
                ? new ProcessStartInfo("explorer.exe", app.Path) { UseShellExecute = true }
                : new ProcessStartInfo(app.Path) { UseShellExecute = true };
            using var process = Process.Start(start);
            return true;
        }
        catch { return false; }
    }

    internal static List<(InstalledApplication App, double Score)> Rank(IEnumerable<InstalledApplication> apps, string normalizedQuery)
    {
        var queries = Aliases.TryGetValue(normalizedQuery, out var alias) ? alias.Select(Normalize).Prepend(normalizedQuery).Distinct().ToArray() : [normalizedQuery];
        return apps
            .Select(app => (App: app, Score: queries.Max(query => Score(app.Name, query))))
            .Where(item => item.Score > 0.3)
            .OrderByDescending(item => item.Score).ThenBy(item => item.App.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
    }

    /// MacSystem.scoreApplication: exact 1.0, prefix 0.93, otherwise token overlap and edit distance.
    internal static double Score(string name, string query)
    {
        var candidate = Normalize(name);
        if (candidate.Length == 0 || query.Length == 0) return 0;
        if (candidate == query) return 1.0;
        if (candidate.StartsWith(query, StringComparison.Ordinal) || query.StartsWith(candidate, StringComparison.Ordinal)) return 0.93;
        var queryTokens = query.Split(' ').ToHashSet();
        var candidateTokens = candidate.Split(' ').ToHashSet();
        var tokenScore = queryTokens.Count == 0 ? 0 : queryTokens.Intersect(candidateTokens).Count() / (double)queryTokens.Count;
        var maxLength = Math.Max(candidate.Length, query.Length);
        var editScore = 1.0 - Levenshtein(candidate, query) / (double)maxLength;
        return tokenScore * 0.6 + editScore * 0.4;
    }

    internal static string Normalize(string value)
    {
        var folded = new StringBuilder();
        foreach (var character in value.Trim().Replace("ı", "i", StringComparison.Ordinal).Replace("İ", "i", StringComparison.Ordinal).Normalize(NormalizationForm.FormD))
        {
            if (CharUnicodeInfo.GetUnicodeCategory(character) == UnicodeCategory.NonSpacingMark) continue;
            folded.Append(char.IsLetterOrDigit(character) ? char.ToLowerInvariant(character) : ' ');
        }
        var text = folded.ToString();
        if (text.EndsWith(" exe", StringComparison.Ordinal)) text = text[..^4];
        return string.Join(' ', text.Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }

    private static int Levenshtein(string left, string right)
    {
        var previous = Enumerable.Range(0, right.Length + 1).ToArray();
        for (var i = 1; i <= left.Length; i++)
        {
            var current = new int[right.Length + 1];
            current[0] = i;
            for (var j = 1; j <= right.Length; j++)
                current[j] = Math.Min(Math.Min(previous[j] + 1, current[j - 1] + 1), previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1));
            previous = current;
        }
        return previous[right.Length];
    }

    private static async Task<bool> WaitFor(Func<bool> condition, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (condition()) return true;
            await Task.Delay(250, cancellationToken).ConfigureAwait(false);
        }
        return condition();
    }

    /// Start-menu apps (cached for 10 minutes; the query takes about a second) plus App Paths.
    internal static async Task<IReadOnlyList<InstalledApplication>> Catalog(CancellationToken cancellationToken)
    {
        if (DateTimeOffset.UtcNow - catalogLoadedAt < TimeSpan.FromMinutes(10) && catalog.Count > 0) return catalog;
        await CatalogGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (DateTimeOffset.UtcNow - catalogLoadedAt < TimeSpan.FromMinutes(10) && catalog.Count > 0) return catalog;
            var apps = new List<InstalledApplication>();
            apps.AddRange(await StartApps(cancellationToken).ConfigureAwait(false));
            apps.AddRange(AppPaths());
            catalog = apps.GroupBy(app => app.Name, StringComparer.OrdinalIgnoreCase).Select(group => group.First()).ToArray();
            catalogLoadedAt = DateTimeOffset.UtcNow;
            return catalog;
        }
        finally { CatalogGate.Release(); }
    }

    private static async Task<List<InstalledApplication>> StartApps(CancellationToken cancellationToken)
    {
        var result = new List<InstalledApplication>();
        try
        {
            var start = new ProcessStartInfo("powershell.exe")
            {
                RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8
            };
            foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                         "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Get-StartApps | Select-Object Name,AppID | ConvertTo-Json -Compress" })
                start.ArgumentList.Add(argument);
            using var process = Process.Start(start);
            if (process is null) return result;
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(8));
            var output = await process.StandardOutput.ReadToEndAsync(timeout.Token).ConfigureAwait(false);
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            using var document = JsonDocument.Parse(output.Length == 0 ? "[]" : output);
            var items = document.RootElement.ValueKind == JsonValueKind.Array ? document.RootElement.EnumerateArray().ToArray() : [document.RootElement];
            foreach (var item in items)
            {
                var name = item.TryGetProperty("Name", out var n) ? n.GetString() : null;
                var id = item.TryGetProperty("AppID", out var a) ? a.GetString() : null;
                if (string.IsNullOrWhiteSpace(name) || string.IsNullOrWhiteSpace(id) || id.StartsWith("http", StringComparison.OrdinalIgnoreCase)) continue;
                result.Add(new InstalledApplication(name, id, "shell:AppsFolder\\" + id));
            }
        }
        catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested) { }
        return result;
    }

    private static IEnumerable<InstalledApplication> AppPaths()
    {
        var result = new List<InstalledApplication>();
        foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            try
            {
                using var key = hive.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths");
                if (key is null) continue;
                foreach (var name in key.GetSubKeyNames())
                {
                    using var entry = key.OpenSubKey(name);
                    if (entry?.GetValue(null) is not string path) continue;
                    path = path.Trim('"');
                    if (!File.Exists(path)) continue;
                    string display = System.IO.Path.GetFileNameWithoutExtension(name);
                    try { display = FileVersionInfo.GetVersionInfo(path).FileDescription is { Length: > 0 } description ? description : display; } catch { }
                    result.Add(new InstalledApplication(display, System.IO.Path.GetFileNameWithoutExtension(name), path));
                }
            }
            catch { }
        }
        return result;
    }
}
