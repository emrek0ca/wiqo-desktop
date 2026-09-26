using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;

namespace RovaWindows.Terminal;

/// The terminal-session protocol (v1 + v2) on Windows, message for message what MacBackendChannel
/// does: the phone-signed grant is verified on every command, the working folder must resolve
/// inside it, read grants run inspection commands only, forbidden commands never run, and a
/// session remembers the folder its last command ended in.
public sealed class WindowsTerminal : IAsyncDisposable
{
    public const string FeatureV1 = "terminal-session-v1";
    public const string FeatureV2 = "terminal-session-v2";

    private readonly Func<string?> pairingToken;
    private readonly Func<bool> enabled;
    private readonly ConcurrentDictionary<string, string> sessionDirectories = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, Job> jobs = new(StringComparer.OrdinalIgnoreCase);
    private readonly CancellationTokenSource lifetime = new();
    private Func<string, string, string?, Task>? jobReporter;

    public WindowsTerminal(Func<string?> pairingToken, Func<bool> enabled)
    {
        this.pairingToken = pairingToken;
        this.enabled = enabled;
    }

    public void ConfigureJobReporter(Func<string, string, string?, Task> reporter) => jobReporter = reporter;

    private sealed class Job(string id, string grantId, string directory)
    {
        public string Id { get; } = id;
        public string GrantId { get; } = grantId;
        public string Directory { get; } = directory;
        public object Gate { get; } = new();
        public string State { get; set; } = "running";
        public string Message { get; set; } = "Terminal işi çalışıyor.";
        public string? ErrorCode { get; set; }
        public bool CancelRequested { get; set; }
        public Process? Process { get; set; }
        public Task? Worker { get; set; }
        public object? Output { get; set; }
        public DateTimeOffset StartedAt { get; } = DateTimeOffset.UtcNow;
    }

    private sealed record Grant(string Id, string RawRoot, string Mode, long ExpiresAt, string Root);

    public async Task<WindowsCommandResult> ExecuteAsync(string commandId, JsonElement request, CancellationToken cancellationToken = default)
    {
        var started = DateTimeOffset.UtcNow;
        var action = Text(request, "action") is { Length: > 0 } value ? value : "run";
        if (action is "get_job" or "cancel_job") return await JobActionAsync(commandId, request, action, started, cancellationToken).ConfigureAwait(false);
        if (!enabled()) return Denied(commandId, started, "TERMINAL_DISABLED", "Terminal oturumları Wiqo Windows ayarlarında kapalı.");
        if (!request.TryGetProperty("grant", out var grantElement) || grantElement.ValueKind != JsonValueKind.Object ||
            !RovaTerminalPolicy.VerifyGrant(grantElement, pairingToken(), out var rawRoot, out var mode))
            return Denied(commandId, started, "TERMINAL_GRANT_INVALID", "Terminal oturum izni geçersiz ya da süresi dolmuş; telefondan yeniden onay gerekiyor.");

        // The folder the user approved on the card may not exist yet: create exactly that one.
        if (RovaTerminalPolicy.CreatableRoot(rawRoot, mode) is { } missingRoot)
        {
            try { Directory.CreateDirectory(missingRoot); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                return Denied(commandId, started, "TERMINAL_DIRECTORY_CREATE_FAILED", $"{rawRoot} klasörü yoktu ve oluşturulamadı.");
            }
        }
        var grantId = RovaTerminalPolicy.String(grantElement, "id");
        var root = RovaTerminalPolicy.ResolveDirectory(rawRoot);
        var requested = Text(request, "workingDirectory") is { Length: > 0 } named ? named : sessionDirectories.TryGetValue(grantId, out var last) ? last : rawRoot;
        var directory = RovaTerminalPolicy.ResolveDirectory(requested);
        if (root is null || directory is null || !RovaTerminalPolicy.IsWithin(directory, root))
            return Denied(commandId, started, "TERMINAL_OUTSIDE_GRANT", $"{requested} onaylanan klasörün ({rawRoot}) dışında ya da bulunamadı; o klasör için directory vererek yeni onay iste.");
        var grant = new Grant(grantId, rawRoot, mode, grantElement.GetProperty("expiresAt").GetInt64(), root);

        try
        {
            return action switch
            {
                "run" or "start_job" => await RunAsync(commandId, request, action, grant, directory, started, cancellationToken).ConfigureAwait(false),
                "run_plan" => await PlanAsync(commandId, request, grant, directory, started, cancellationToken).ConfigureAwait(false),
                "read_file" => ReadFile(commandId, request, grant, directory, started),
                "write_file" => WriteFile(commandId, request, grant, directory, started),
                "search" => await SearchAsync(commandId, request, directory, started, cancellationToken).ConfigureAwait(false),
                "edit_file" => EditFile(commandId, request, grant, directory, started),
                "apply_patch" => ApplyPatch(commandId, request, grant, directory, started),
                _ => Denied(commandId, started, "TERMINAL_ACTION_INVALID", "Terminal işlemi desteklenmiyor.")
            };
        }
        catch (OperationCanceledException)
        {
            return Failed(commandId, started, "TERMINAL_CANCELLED", "Terminal komutu durduruldu; yan etkiler kısmen uygulanmış olabilir.", "unknown", category: "unknown");
        }
    }

    private async Task<WindowsCommandResult> RunAsync(string commandId, JsonElement request, string action, Grant grant, string directory, DateTimeOffset started, CancellationToken cancellationToken)
    {
        var command = Text(request, "command").Trim();
        var shell = Text(request, "shell").ToLowerInvariant() is "cmd" ? "cmd" : "powershell";
        if (CheckCommand(command, shell, grant) is { } rejected) return Denied(commandId, started, rejected.Code, rejected.Message);
        if (action == "start_job")
        {
            var jobId = Text(request, "jobId");
            if (!Guid.TryParse(jobId, out _)) return Denied(commandId, started, "TERMINAL_JOB_ID_INVALID", "Arka plan işi kimliği geçersiz.");
            PruneJobs();
            var job = new Job(jobId, grant.Id, directory);
            if (!jobs.TryAdd(jobId, job))
                return jobs.TryGetValue(jobId, out var existing) && string.Equals(existing.GrantId, grant.Id, StringComparison.OrdinalIgnoreCase)
                    ? JobResult(commandId, existing, started)
                    : Denied(commandId, started, "TERMINAL_GRANT_INVALID", "Bu iş farklı bir terminal iznine bağlı.");
            var remaining = (int)Math.Max(1, grant.ExpiresAt - DateTimeOffset.UtcNow.ToUnixTimeSeconds());
            var jobTimeout = Math.Clamp(Integer(request, "timeoutSeconds") ?? 600, 1, Math.Min(1800, remaining));
            job.Worker = Task.Run(() => RunJobAsync(job, command, shell, jobTimeout));
            return JobResult(commandId, job, started);
        }
        var timeout = Math.Clamp(Integer(request, "timeoutSeconds") ?? 60, 1, 110);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token, cancellationToken);
        var outcome = await TerminalProcess.RunAsync(command, shell, directory, timeout, linked.Token).ConfigureAwait(false);
        Remember(grant, outcome.EndDirectory);
        var output = ProcessOutput(outcome);
        if (outcome.TimedOut) return new WindowsCommandResult(commandId, "unknown", "Terminal komutu zaman aşımına uğradı; sonucu doğrulanamadı.", started, DateTimeOffset.UtcNow, output, new WireError("CODE_TIMEOUT", "Terminal komutu zaman aşımına uğradı; sonucu doğrulanamadı.", "timeout"));
        if (outcome.ExitCode != 0)
        {
            var detail = outcome.Stderr.Trim();
            var message = detail.Length == 0 ? $"Terminal komutu çıkış kodu {outcome.ExitCode} ile sonlandı." : $"Terminal komutu hata verdi: {(detail.Length > 300 ? detail[..300] : detail)}";
            return new WindowsCommandResult(commandId, "failed", message, started, DateTimeOffset.UtcNow, output, new WireError("CODE_FAILED", message));
        }
        return new WindowsCommandResult(commandId, "completed", "Komut tamamlandı.", started, DateTimeOffset.UtcNow, output);
    }

    /// Up to 8 commands in order, stopping at the first failure unless the step allows it; each
    /// step starts where the previous one ended, all within one 110-second budget.
    private async Task<WindowsCommandResult> PlanAsync(string commandId, JsonElement request, Grant grant, string directory, DateTimeOffset started, CancellationToken cancellationToken)
    {
        var steps = request.TryGetProperty("steps", out var raw) && raw.ValueKind == JsonValueKind.Array ? raw.EnumerateArray().ToArray() : [];
        if (steps.Length is < 1 or > 8) return Denied(commandId, started, "TERMINAL_PLAN_INVALID", "Plan 1-8 komut içermeli.");
        var shell = Text(request, "shell").ToLowerInvariant() is "cmd" ? "cmd" : "powershell";
        foreach (var step in steps)
        {
            var command = Text(step, "command");
            if (command.Length is 0 or > 4_000 || command.Contains('\0')) return Denied(commandId, started, "TERMINAL_COMMAND_INVALID", "Plandaki bir komut geçersiz.");
            if (RovaTerminalPolicy.IsForbidden(command)) return Denied(commandId, started, "TERMINAL_COMMAND_FORBIDDEN", $"Plandaki bir komut Wiqo terminal oturumlarında çalıştırılmaz: {(command.Length > 80 ? command[..80] : command)}");
            if (grant.Mode != "full" && !RovaTerminalPolicy.IsReadOnly(command, shell)) return Denied(commandId, started, "TERMINAL_READ_ONLY", "Bu oturum yalnızca okuma izni veriyor; plandaki değiştiren komut için yeni onay gerekiyor.");
        }
        var budget = Math.Clamp(Integer(request, "timeoutSeconds") ?? 110, 5, 110);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token, cancellationToken);
        var current = directory;
        var results = new List<object>();
        var failed = false;
        var allOk = true;
        foreach (var step in steps)
        {
            var command = Text(step, "command");
            var remaining = budget - (int)(DateTimeOffset.UtcNow - started).TotalSeconds;
            if (failed || remaining < 1)
            {
                results.Add(new { command, exitCode = -1, stdout = "", stderr = "", durationMs = 0, truncated = false, skipped = true });
                allOk = false;
                continue;
            }
            var outcome = await TerminalProcess.RunAsync(command, shell, current, remaining, linked.Token).ConfigureAwait(false);
            if (outcome.EndDirectory is { } end && RovaTerminalPolicy.ResolveDirectory(end) is { } resolved && RovaTerminalPolicy.IsWithin(resolved, grant.Root)) current = resolved;
            results.Add(new
            {
                command,
                exitCode = outcome.ExitCode,
                stdout = RovaTerminalPolicy.RedactSecrets(outcome.Stdout),
                stderr = RovaTerminalPolicy.RedactSecrets(outcome.Stderr),
                durationMs = outcome.DurationMs,
                truncated = outcome.Truncated,
                skipped = false
            });
            if (outcome.ExitCode != 0)
            {
                allOk = false;
                if (!(step.TryGetProperty("continueOnError", out var keepGoing) && keepGoing.ValueKind == JsonValueKind.True)) failed = true;
            }
        }
        sessionDirectories[grant.Id] = current;
        return Result(commandId, started, allOk ? "completed" : "failed", allOk ? "Plan tamamlandı." : "Plandaki bir komut hata verdi.",
            new { kind = "plan", workingDirectory = current, steps = results });
    }

    private WindowsCommandResult ReadFile(string commandId, JsonElement request, Grant grant, string directory, DateTimeOffset started)
    {
        var raw = Text(request, "filePath");
        var path = RovaTerminalPolicy.ResolveExistingFile(raw, directory, grant.Root);
        if (path is null) return Denied(commandId, started, "TERMINAL_FILE_SCOPE", $"{(raw.Length > 0 ? raw : "Dosya")} bulunamadı ya da onaylı klasörün ({grant.RawRoot}) dışında. search ile doğru yolu bul.");
        var read = TerminalFiles.Read(path, Integer(request, "startLine"), Integer(request, "endLine"));
        if (read.Error is { } error) return Failed(commandId, started, error.Code, error.Message, category: error.Category);
        return Result(commandId, started, "completed", "Dosya okundu.", new { kind = "read", workingDirectory = directory, text = read.Text, files = new[] { raw }, totalLines = read.TotalLines });
    }

    private WindowsCommandResult WriteFile(string commandId, JsonElement request, Grant grant, string directory, DateTimeOffset started)
    {
        if (grant.Mode != "full") return Denied(commandId, started, "TERMINAL_READ_ONLY", "Dosya yazmak için tam izin gerekiyor.");
        var raw = Text(request, "filePath");
        var path = RovaTerminalPolicy.ResolveWritableFile(raw, directory, grant.Root);
        if (path is null || !request.TryGetProperty("content", out var contentElement) || contentElement.ValueKind != JsonValueKind.String)
            return Denied(commandId, started, "TERMINAL_FILE_SCOPE", $"{(raw.Length > 0 ? raw : "Dosya")} yazılamadı: onaylı klasörün ({grant.RawRoot}) içinde, var olan bir klasörde olmalı. Alt klasör gerekiyorsa önce run ile New-Item -ItemType Directory -Force çalıştır.");
        var written = TerminalFiles.Write(path, contentElement.GetString() ?? "", Path.GetFileName(path));
        if (written.Error is { } error) return Failed(commandId, started, error.Code, error.Message, category: error.Category);
        return Result(commandId, started, "completed", written.Created ? "Dosya oluşturuldu." : "Dosya güncellendi.", new { kind = "write", workingDirectory = directory, text = written.Created ? "created" : "updated", files = new[] { raw } });
    }

    private async Task<WindowsCommandResult> SearchAsync(string commandId, JsonElement request, string directory, DateTimeOffset started, CancellationToken cancellationToken)
    {
        var found = await TerminalFiles.SearchAsync(Text(request, "pattern"), directory, Text(request, "glob") is { Length: > 0 } glob ? glob : null, cancellationToken).ConfigureAwait(false);
        if (found.Error is { } error) return Failed(commandId, started, error.Code, error.Message, category: error.Category);
        return Result(commandId, started, "completed", "Arama tamamlandı.", new { kind = "search", workingDirectory = directory, text = found.Text });
    }

    private WindowsCommandResult EditFile(string commandId, JsonElement request, Grant grant, string directory, DateTimeOffset started)
    {
        if (grant.Mode != "full") return Denied(commandId, started, "TERMINAL_READ_ONLY", "Dosya düzenlemek için tam izin gerekiyor.");
        var items = request.TryGetProperty("replacements", out var raw) && raw.ValueKind == JsonValueKind.Array ? raw.EnumerateArray().ToArray() : [];
        if (items.Length is < 1 or > 20 || items.Sum(item => Text(item, "find").Length + Text(item, "replace").Length) > 300_000)
            return Denied(commandId, started, "TERMINAL_EDIT_INVALID", "1-20 değişiklik, toplam 300 KB altında gerekiyor.");
        var edits = new List<Replacement>();
        foreach (var item in items)
        {
            var display = Text(item, "filePath");
            var path = RovaTerminalPolicy.ResolveExistingFile(display, directory, grant.Root);
            if (path is null) return Denied(commandId, started, "TERMINAL_FILE_SCOPE", $"{display} onaylı klasörde bulunamadı; hiçbir dosya değiştirilmedi.");
            if (!item.TryGetProperty("find", out var find) || find.ValueKind != JsonValueKind.String || !item.TryGetProperty("replace", out var replace) || replace.ValueKind != JsonValueKind.String)
                return Denied(commandId, started, "TERMINAL_EDIT_INVALID", "Her değişiklikte find ve replace metni olmalı.");
            edits.Add(new Replacement(path, display, find.GetString()!, replace.GetString()!, item.TryGetProperty("replaceAll", out var all) && all.ValueKind == JsonValueKind.True));
        }
        var edited = TerminalFiles.Edit(edits);
        if (edited.Error is { } error) return Failed(commandId, started, error.Code, error.Message, category: error.Category);
        return Result(commandId, started, "completed", "Dosyalar düzenlendi.",
            new { kind = "edits", workingDirectory = directory, text = edited.Summary, files = edits.Select(edit => edit.Display).Distinct().Order(StringComparer.Ordinal).ToArray() });
    }

    /// v1: one file + one unified diff; v2: edits[] (1-10 files), applied all or nothing.
    private WindowsCommandResult ApplyPatch(string commandId, JsonElement request, Grant grant, string directory, DateTimeOffset started)
    {
        if (grant.Mode != "full") return Denied(commandId, started, "TERMINAL_READ_ONLY", "Yama için tam izin gerekiyor.");
        var items = request.TryGetProperty("edits", out var raw) && raw.ValueKind == JsonValueKind.Array && raw.GetArrayLength() > 0
            ? raw.EnumerateArray().Select(item => (FilePath: Text(item, "filePath"), Patch: Text(item, "patch"))).ToArray()
            : [(FilePath: Text(request, "filePath"), Patch: Text(request, "patch"))];
        if (items.Length is < 1 or > 10 || items.Sum(item => item.Patch.Length) > 300_000 || items.Any(item => item.Patch.Length == 0))
            return Denied(commandId, started, "TERMINAL_PATCH_SCOPE", "1-10 dosyalık, toplam 300 KB altında yama gerekiyor.");
        var planned = new List<(string Path, string Result)>();
        foreach (var (filePath, patch) in items)
        {
            var path = RovaTerminalPolicy.ResolveExistingFile(filePath, directory, grant.Root);
            if (path is null) return Denied(commandId, started, "TERMINAL_PATCH_SCOPE", $"{filePath} onaylı klasörde bulunamadı; hiçbir dosya değiştirilmedi.");
            var original = TerminalFiles.Decode(File.ReadAllBytes(path), out _);
            var patched = original is null ? null : UnifiedPatch.Apply(original, filePath, patch);
            if (original is null || patched is null)
                return Failed(commandId, started, "TERMINAL_PATCH_REJECTED", $"{filePath}: yama dosyanın güncel içeriğiyle eşleşmedi; hiçbir dosya değiştirilmedi.", category: "validation");
            if (TerminalFiles.BrokenJson(path, original, patched, filePath) is { } json) return Failed(commandId, started, json.Code, json.Message, category: json.Category);
            planned.Add((path, patched));
        }
        foreach (var item in planned)
        {
            var written = TerminalFiles.Write(item.Path, item.Result, Path.GetFileName(item.Path));
            if (written.Error is { } error) return Failed(commandId, started, error.Code, error.Message, category: error.Category);
        }
        var diff = string.Join("\n", items.Select(item => item.Patch));
        if (items.Length == 1 && !request.TryGetProperty("edits", out _))
            return Result(commandId, started, "completed", "Yama uygulandı; değişiklik diff'i döndürüldü.", null,
                new { kind = "terminalJob", value = new { jobId = commandId, status = "completed", diff = diff.Length > 12_000 ? diff[..12_000] : diff, applied = true, message = "Yama uygulandı." } });
        return Result(commandId, started, "completed", "Yama uygulandı.", new { kind = "edits", workingDirectory = directory, text = diff, files = items.Select(item => item.FilePath).ToArray() });
    }

    private async Task<WindowsCommandResult> JobActionAsync(string commandId, JsonElement request, string action, DateTimeOffset started, CancellationToken cancellationToken)
    {
        var id = Text(request, "jobId");
        if (!Guid.TryParse(id, out _) || !jobs.TryGetValue(id, out var job))
        {
            var message = "Bu Windows sürecinde iş bulunamadı; yeniden başlatıldıysa sonucu bilinmiyor.";
            return new WindowsCommandResult(commandId, "unknown", message, started, DateTimeOffset.UtcNow,
                new { kind = "terminalJob", value = new { jobId = id, status = "unknown", message, errorCode = "TERMINAL_JOB_UNKNOWN" } },
                new WireError("TERMINAL_JOB_UNKNOWN", message, "unknown"));
        }
        if (!request.TryGetProperty("grant", out var grant) || grant.ValueKind != JsonValueKind.Object ||
            !RovaTerminalPolicy.VerifyGrant(grant, pairingToken(), out var rawRoot, out _) ||
            !string.Equals(RovaTerminalPolicy.String(grant, "id"), job.GrantId, StringComparison.OrdinalIgnoreCase) ||
            RovaTerminalPolicy.ResolveDirectory(rawRoot) is not { } root || !RovaTerminalPolicy.IsWithin(job.Directory, root))
            return Denied(commandId, started, "TERMINAL_GRANT_INVALID", "İşin imzalı terminal izni doğrulanamadı.");
        if (action == "cancel_job")
        {
            lock (job.Gate)
            {
                if (job.State == "running")
                {
                    job.CancelRequested = true;
                    job.Message = "İptal istendi; PC işlemi durduruluyor.";
                    try { if (job.Process is { HasExited: false } process) process.Kill(entireProcessTree: true); } catch { }
                }
            }
            if (job.Worker is { } worker) await Task.WhenAny(worker, Task.Delay(500, cancellationToken)).ConfigureAwait(false);
        }
        return JobResult(commandId, job, started);
    }

    private async Task RunJobAsync(Job job, string command, string shell, int timeoutSeconds)
    {
        try
        {
            var outcome = await TerminalProcess.RunAsync(command, shell, job.Directory, timeoutSeconds, lifetime.Token, trackDirectory: false, started: process =>
            {
                bool cancelNow;
                lock (job.Gate) { job.Process = process; cancelNow = job.CancelRequested; }
                if (cancelNow) try { process.Kill(entireProcessTree: true); } catch { }
            }).ConfigureAwait(false);
            lock (job.Gate)
            {
                job.Output = ProcessOutputValue(outcome);
                if (job.CancelRequested) { job.State = "cancelled"; job.Message = "Terminal işi kullanıcı tarafından durduruldu."; job.ErrorCode = null; }
                else if (outcome.TimedOut) { job.State = "unknown"; job.Message = "Terminal işi zaman aşımına uğradı; sonucu doğrulanamadı."; job.ErrorCode = "CODE_TIMEOUT"; }
                else if (outcome.ExitCode != 0) { job.State = "failed"; job.Message = $"Terminal işi çıkış kodu {outcome.ExitCode} ile bitti."; job.ErrorCode = "CODE_FAILED"; }
                else { job.State = "completed"; job.Message = "Terminal işi tamamlandı."; }
                job.Process = null;
            }
        }
        catch (Exception)
        {
            lock (job.Gate)
            {
                job.State = job.CancelRequested ? "cancelled" : "unknown";
                job.Message = job.CancelRequested ? "Terminal işi kullanıcı tarafından durduruldu." : "Terminal işi tamamlanamadı; sonucu doğrulanamadı.";
                job.ErrorCode = job.CancelRequested ? null : "TERMINAL_JOB_UNKNOWN";
                job.Process = null;
            }
        }
        if (jobReporter is { } report)
        {
            try { await report(job.Id, job.State, job.ErrorCode).ConfigureAwait(false); } catch { }
        }
    }

    private static WindowsCommandResult JobResult(string commandId, Job job, DateTimeOffset started)
    {
        lock (job.Gate)
        {
            var value = new { jobId = job.Id, status = job.State, output = job.Output, message = job.Message, errorCode = job.ErrorCode };
            var status = job.State == "unknown" ? "unknown" : job.State == "failed" ? "failed" : "completed";
            return new WindowsCommandResult(commandId, status, job.Message, job.StartedAt, DateTimeOffset.UtcNow, new { kind = "terminalJob", value },
                job.ErrorCode is null ? null : new WireError(job.ErrorCode, job.Message, job.State == "unknown" ? "unknown" : "tool_failure"));
        }
    }

    private void PruneJobs()
    {
        foreach (var job in jobs.Values.Where(item => item.State != "running" && DateTimeOffset.UtcNow - item.StartedAt > TimeSpan.FromHours(24))) jobs.TryRemove(job.Id, out _);
        var finished = jobs.Values.Where(item => item.State != "running").OrderBy(item => item.StartedAt).ToArray();
        foreach (var job in finished.Take(Math.Max(0, finished.Length - 50))) jobs.TryRemove(job.Id, out _);
    }

    private void Remember(Grant grant, string? endDirectory)
    {
        if (endDirectory is not null && RovaTerminalPolicy.ResolveDirectory(endDirectory) is { } resolved && RovaTerminalPolicy.IsWithin(resolved, grant.Root))
            sessionDirectories[grant.Id] = resolved;
    }

    private static (string Code, string Message)? CheckCommand(string command, string shell, Grant grant)
    {
        if (command.Length is < 1 or > 4_000 || command.Contains('\0')) return ("TERMINAL_COMMAND_INVALID", "Komut geçersiz.");
        if (RovaTerminalPolicy.IsForbidden(command)) return ("TERMINAL_COMMAND_FORBIDDEN", "Bu komut Wiqo terminal oturumlarında çalıştırılmaz.");
        if (grant.Mode != "full" && !RovaTerminalPolicy.IsReadOnly(command, shell)) return ("TERMINAL_READ_ONLY", "Bu oturum yalnızca okuma izni veriyor; değiştiren komut için yeni onay gerekiyor.");
        return null;
    }

    private static object ProcessOutput(ProcessOutcome outcome) => new { kind = "processOutput", value = ProcessOutputValue(outcome) };

    private static object ProcessOutputValue(ProcessOutcome outcome) => new
    {
        language = "shell",
        exitCode = outcome.ExitCode,
        stdout = RovaTerminalPolicy.RedactSecrets(outcome.Stdout),
        stderr = RovaTerminalPolicy.RedactSecrets(outcome.Stderr),
        truncated = outcome.Truncated,
        durationMs = outcome.DurationMs
    };

    private static WindowsCommandResult Result(string commandId, DateTimeOffset started, string status, string message, object? terminalResult, object? data = null) =>
        new(commandId, status, message, started, DateTimeOffset.UtcNow, data ?? new { kind = "terminalResult", value = terminalResult });

    private static WindowsCommandResult Denied(string commandId, DateTimeOffset started, string code, string message) =>
        new(commandId, "denied", message, started, DateTimeOffset.UtcNow, null, new WireError(code, message, "permission"));

    private static WindowsCommandResult Failed(string commandId, DateTimeOffset started, string code, string message, string status = "failed", string category = "tool_failure") =>
        new(commandId, status, message, started, DateTimeOffset.UtcNow, null, new WireError(code, message, category));

    private static string Text(JsonElement value, string name) => value.TryGetProperty(name, out var property) && property.ValueKind == JsonValueKind.String ? property.GetString() ?? "" : "";

    private static int? Integer(JsonElement value, string name) => value.TryGetProperty(name, out var property) && property.ValueKind == JsonValueKind.Number && property.TryGetInt32(out var number) ? number : null;

    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        foreach (var job in jobs.Values)
        {
            lock (job.Gate)
            {
                job.CancelRequested = true;
                try { if (job.Process is { HasExited: false } process) process.Kill(entireProcessTree: true); } catch { }
            }
        }
        var workers = jobs.Values.Select(job => job.Worker).OfType<Task>().ToArray();
        try { await Task.WhenAll(workers).WaitAsync(TimeSpan.FromSeconds(3)).ConfigureAwait(false); } catch { }
        lifetime.Dispose();
    }
}
