using System.Diagnostics;
using System.Text.Json;
using System.Text;
using System.Collections.Concurrent;
using System.Text.RegularExpressions;

namespace RovaWindows;

public sealed record WindowsCommandResult(
    string CommandId,
    string Status,
    string Message,
    DateTimeOffset StartedAt,
    DateTimeOffset FinishedAt,
    object? Data = null,
    object? Error = null);

/// Platform adapter for the small, verified Windows operation set. It has no UI dependencies and
/// can therefore be hosted by WinUI, a tray process, or a service without changing the protocol.
public sealed class WindowsRuntime : IAsyncDisposable
{
    private readonly SemaphoreSlim sideEffectGate = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly int queueCapacity;
    private int queued;
    private Func<string, string, CancellationToken, Task<string?>>? fileUploader;
    private Func<string, string, CancellationToken, Task<bool>>? fileAccessApproval;
    private Func<string, string, string?, Task>? terminalJobReporter;
    private readonly ConcurrentDictionary<string, WindowsTerminalJob> terminalJobs = new(StringComparer.OrdinalIgnoreCase);
    private string? pairingToken;

    private sealed class WindowsTerminalJob(string id, string grantId, string directory)
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

    public void ConfigureFileUploader(Func<string, string, CancellationToken, Task<string?>> uploader) => fileUploader = uploader;
    public void ConfigureTerminalJobReporter(Func<string, string, string?, Task> reporter) => terminalJobReporter = reporter;
    /// The future Windows host must present the exact search/send target to its user.
    /// Without a host approval provider, private-file capabilities are not advertised or run.
    public void ConfigureFileAccessApproval(Func<string, string, CancellationToken, Task<bool>> approval) => fileAccessApproval = approval;

    public WindowsRuntime(int queueCapacity = 64)
    {
        if (queueCapacity < 1) throw new ArgumentOutOfRangeException(nameof(queueCapacity));
        this.queueCapacity = queueCapacity;
    }

    public string DeviceId { get; } = LoadDeviceId();
    public string DisplayName => Environment.MachineName;
    public string? PairingToken => pairingToken;
    public IReadOnlyList<string> Features => PairingToken is null ? Array.Empty<string>() : new[] { "terminal-session-v1" };
    public void SetPairingToken(string? token) => pairingToken = string.IsNullOrWhiteSpace(token) ? null : token;

    public IReadOnlyList<string> Capabilities => WindowsCapabilityManifest.Capabilities
        .Where(value => fileAccessApproval is not null || !value.StartsWith("device.files.", StringComparison.Ordinal))
        .OrderBy(value => value, StringComparer.Ordinal).ToArray();

    public object[] Authorities => Capabilities.Select(capability => new
    {
        capability,
        displayName = capability,
        access = capability.StartsWith("device.files.", StringComparison.Ordinal) ? "confirmation" : "automatic",
        requiredPermissions = capability.StartsWith("device.files.", StringComparison.Ordinal) ? new[] { "user_presence" } : Array.Empty<string>(),
        message = ""
    }).Cast<object>().ToArray();

    public async Task<WindowsCommandResult> ExecuteAsync(string commandId, string operation, JsonElement payload, TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        var started = DateTimeOffset.UtcNow;
        if (!WindowsCapabilityManifest.Operations.Contains(operation))
            return Failed(commandId, started, "UNSUPPORTED_OPERATION", "Bu işlem Windows'ta desteklenmiyor.");

        if (Interlocked.Increment(ref queued) > queueCapacity)
        {
            Interlocked.Decrement(ref queued);
            return Failed(commandId, started, "QUEUE_FULL", "Windows işlemleri kuyruğu dolu; lütfen tekrar dene.");
        }

        try
        {
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token, cancellationToken);
            linked.CancelAfter(operation == "sendFileToPhone" ? TimeSpan.FromSeconds(120) : timeout);
            if (operation is "searchFiles" or "sendFileToPhone")
            {
                var target = payload.ValueKind == JsonValueKind.Object && payload.TryGetProperty("value", out var value) && value.ValueKind == JsonValueKind.Object
                    ? StringProperty(value, operation == "searchFiles" ? "query" : "path") : "";
                if (fileAccessApproval is null || string.IsNullOrWhiteSpace(target) ||
                    !await fileAccessApproval(operation, target, linked.Token).ConfigureAwait(false))
                    return Failed(commandId, started, "FILE_ACCESS_DENIED", "Dosya erişimine izin verilmedi.");
            }
            // Side effects remain ordered; read-only operations can execute without this gate.
            var sideEffect = operation is "openURL" or "sendFileToPhone";
            if (sideEffect) await sideEffectGate.WaitAsync(linked.Token).ConfigureAwait(false);
            try
            {
                return await RunAsync(commandId, operation, payload, started, linked.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (linked.IsCancellationRequested)
            {
                return Failed(commandId, started, "TIMEOUT", "Windows işlemi zaman aşımına uğradı; sonucu doğrulanamadı.", "unknown");
            }
            catch (Exception)
            {
                return Failed(commandId, started, "EXECUTION_FAILED", "Windows işlemi tamamlanamadı.");
            }
            finally
            {
                if (sideEffect) sideEffectGate.Release();
            }
        }
        finally
        {
            Interlocked.Decrement(ref queued);
        }
    }

    private async Task<WindowsCommandResult> RunAsync(string commandId, string operation, JsonElement payload, DateTimeOffset started, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        object? data = null;
        string message;
        switch (operation)
        {
            case "ping":
                data = new { kind = "ping", value = new { timestamp = DateTimeOffset.UtcNow } };
                message = "Windows PC bağlantısı hazır.";
                break;
            case "getSystemStatus":
                data = new
                {
                    kind = "systemStatus",
                    value = new { operatingSystem = Environment.OSVersion.VersionString, machineName = Environment.MachineName }
                };
                message = "Windows sistem durumu okundu.";
                break;
            case "openURL":
                var url = PayloadString(payload);
                if (string.IsNullOrWhiteSpace(url) || !Uri.TryCreate(url, UriKind.Absolute, out var parsed) || parsed.Scheme is not ("http" or "https"))
                    return Failed(commandId, started, "INVALID_PAYLOAD", "Açılacak bağlantı geçersiz.");
                if (Process.Start(new ProcessStartInfo(parsed.AbsoluteUri) { UseShellExecute = true }) is null)
                    return Failed(commandId, started, "LAUNCH_FAILED", "Bağlantı Windows'ta açılamadı.");
                message = "Bağlantı Windows'ta açıldı.";
                break;
            case "listRunningApplications":
                data = new
                {
                    kind = "runningApplications",
                    value = Process.GetProcesses()
                        .Select(process => process.ProcessName)
                        .Distinct(StringComparer.OrdinalIgnoreCase)
                        .OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
                        .Take(200)
                        .Select(name => new { name, isRunning = true, supportedActions = new[] { "open", "activate", "quit" } })
                        .ToArray()
                };
                message = "Açık uygulamalar listelendi.";
                break;
            case "searchFiles":
                return SearchFiles(commandId, payload, started, cancellationToken);
            case "sendFileToPhone":
                if (!payload.TryGetProperty("value", out var fileValue) || fileValue.ValueKind != JsonValueKind.Object || fileUploader is null)
                    return Failed(commandId, started, "TRANSFER_UNAVAILABLE", "Dosya aktarımı hazır değil.");
                var filePath = StringProperty(fileValue, "path");
                if (!Path.IsPathFullyQualified(filePath) || !File.Exists(filePath) || IsReparsePoint(filePath))
                    return Failed(commandId, started, "INVALID_FILE", "Dosya bulunamadı veya erişilemiyor.");
                var fileInfo = new FileInfo(filePath);
                if (fileInfo.Length is < 1 or > 25 * 1024 * 1024)
                    return Failed(commandId, started, "FILE_TOO_LARGE", "Yalnızca 25 MB veya daha küçük dosyalar gönderilebilir.");
                var artifactId = await fileUploader(filePath, commandId, cancellationToken).ConfigureAwait(false);
                if (artifactId is null) return Failed(commandId, started, "TRANSFER_FAILED", "Dosya telefona iletilemedi.");
                return new WindowsCommandResult(commandId, "completed", "Dosya telefona gönderildi.", started, DateTimeOffset.UtcNow, new { kind = "fileTransfer", value = artifactId });
            default:
                return Failed(commandId, started, "UNSUPPORTED_OPERATION", "Bu işlem Windows'ta desteklenmiyor.");
        }

        return new WindowsCommandResult(commandId, "completed", message, started, DateTimeOffset.UtcNow, data);
    }

    private static bool IsReparsePoint(string path)
    {
        try { return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0; }
        catch { return true; }
    }

    private sealed class SearchSession
    {
        public required string Query { get; init; }
        public required Stack<string> Directories { get; init; }
        public IEnumerator<string>? Entries { get; set; }
        public int Skipped { get; set; }
        public DateTimeOffset ExpiresAt { get; set; } = DateTimeOffset.UtcNow.AddMinutes(10);
        public void Close() { Entries?.Dispose(); Entries = null; }
    }

    private static readonly object SearchGate = new();
    private static readonly Dictionary<string, SearchSession> Searches = new(StringComparer.Ordinal);

    private static WindowsCommandResult SearchFiles(string commandId, JsonElement payload, DateTimeOffset started, CancellationToken cancellationToken)
    {
        if (!payload.TryGetProperty("value", out var value) || value.ValueKind != JsonValueKind.Object)
            return Failed(commandId, started, "INVALID_PAYLOAD", "Dosya arama isteği geçersiz.");
        var query = StringProperty(value, "query").Trim();
        var cursor = StringProperty(value, "cursor");
        if (query.Length is < 1 or > 120 || (!string.IsNullOrEmpty(cursor) && !Guid.TryParse(cursor, out _)))
            return Failed(commandId, started, "INVALID_PAYLOAD", "Dosya arama isteği geçersiz.");
        lock (SearchGate)
        {
            foreach (var expired in Searches.Where(item => item.Value.ExpiresAt < DateTimeOffset.UtcNow).Select(item => item.Key).ToArray())
            {
                Searches[expired].Close();
                Searches.Remove(expired);
            }
            SearchSession session;
            string id;
            if (!string.IsNullOrEmpty(cursor))
            {
                if (!Searches.TryGetValue(cursor, out var existing) || !string.Equals(existing.Query, query, StringComparison.OrdinalIgnoreCase))
                    return Failed(commandId, started, "INVALID_CURSOR", "Aramayı yeniden başlat.");
                id = cursor;
                session = existing;
            }
            else
            {
                if (Searches.Count >= 5) return Failed(commandId, started, "SEARCH_LIMIT", "Çok fazla arama açık.");
                try {
                    session = new SearchSession { Query = query, Directories = new Stack<string>(DriveInfo.GetDrives().Where(drive => drive.IsReady).Select(drive => drive.RootDirectory.FullName)) };
                } catch { return Failed(commandId, started, "SEARCH_FAILED", "Diskler aranamadı."); }
                id = Guid.NewGuid().ToString();
                Searches[id] = session;
            }
            var matches = new List<object>();
            var visited = 0;
            var deadline = DateTimeOffset.UtcNow.AddSeconds(15);
            while (session.Entries is not null || session.Directories.Count > 0)
            {
                if (cancellationToken.IsCancellationRequested) {
                    Searches.Remove(id);
                    session.Close();
                    cancellationToken.ThrowIfCancellationRequested();
                }
                if (session.Entries is null)
                {
                    var directory = session.Directories.Pop();
                    try { session.Entries = Directory.EnumerateFileSystemEntries(directory).GetEnumerator(); }
                    catch (UnauthorizedAccessException) { session.Skipped++; continue; }
                    catch (IOException) { session.Skipped++; continue; }
                }
                bool more;
                try { more = session.Entries.MoveNext(); }
                catch (UnauthorizedAccessException) { session.Skipped++; more = false; }
                catch (IOException) { session.Skipped++; more = false; }
                if (!more) { session.Close(); continue; }
                var path = session.Entries.Current;
                visited++;
                if (!IsReparsePoint(path))
                {
                    bool isDirectory;
                    try { isDirectory = Directory.Exists(path); }
                    catch { session.Skipped++; continue; }
                    if (isDirectory) session.Directories.Push(path);
                    else if (path.Length <= 500 && Path.GetFileName(path).Contains(query, StringComparison.OrdinalIgnoreCase))
                    {
                        try {
                            var info = new FileInfo(path);
                            matches.Add(new { path = info.FullName, name = info.Name, fileType = info.Extension.TrimStart('.').ToLowerInvariant(), byteCount = info.Length, modifiedAt = info.LastWriteTimeUtc, isDirectory = false });
                        } catch { session.Skipped++; }
                    }
                }
                if (matches.Count >= 12 || visited >= 25_000 || DateTimeOffset.UtcNow >= deadline)
                {
                    session.ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(10);
                    return new WindowsCommandResult(commandId, "completed", $"Kısmi sonuç; devam kodu {id}. Erişilemeyen öğe: {session.Skipped}.", started, DateTimeOffset.UtcNow, new { kind = "files", value = matches });
                }
            }
            Searches.Remove(id);
            session.Close();
            return new WindowsCommandResult(commandId, "completed", $"Arama tamamlandı. Erişilemeyen öğe: {session.Skipped}.", started, DateTimeOffset.UtcNow, new { kind = "files", value = matches });
        }
    }

    /// Executes the terminal-session protocol. Authority comes from the phone-signed grant and is
    /// revalidated locally for every command; backend routing alone never grants Windows access.
    public async Task<WindowsCommandResult> ExecuteTerminalCommandAsync(string commandId, JsonElement request, CancellationToken cancellationToken = default)
    {
        var started = DateTimeOffset.UtcNow;
        var action = StringProperty(request, "action");
        if (action.Length == 0) action = "run";
        if (action is "get_job" or "cancel_job") return await HandleTerminalJobActionAsync(commandId, request, action, started, cancellationToken).ConfigureAwait(false);
        if (action is not ("run" or "start_job" or "apply_patch")) return Failed(commandId, started, "TERMINAL_ACTION_INVALID", "Terminal işlemi desteklenmiyor.");
        if (!request.TryGetProperty("grant", out var grant) || grant.ValueKind != JsonValueKind.Object ||
            !RovaTerminalPolicy.VerifyGrant(grant, PairingToken, out var rawRoot, out var mode))
            return Failed(commandId, started, "TERMINAL_GRANT_INVALID", "Terminal izni geçersiz veya süresi dolmuş.", "denied");
        var root = RovaTerminalPolicy.ResolveDirectory(rawRoot);
        var rawDirectory = StringProperty(request, "workingDirectory");
        var directory = RovaTerminalPolicy.ResolveDirectory(rawDirectory);
        if (root is null || directory is null || !RovaTerminalPolicy.IsWithin(directory, root))
            return Failed(commandId, started, "TERMINAL_OUTSIDE_GRANT", "Çalışma klasörü imzalı iznin dışında veya güvenli biçimde çözümlenemedi.", "denied");

        if (action == "apply_patch")
        {
            if (mode != "full") return Failed(commandId, started, "TERMINAL_READ_ONLY", "Dosya yaması için tam terminal izni gerekiyor.", "denied");
            var rawFilePath = StringProperty(request, "filePath");
            var filePath = RovaTerminalPolicy.ResolveExistingFile(rawFilePath, directory, root);
            var patch = StringProperty(request, "patch");
            if (filePath is null || patch.Length is < 1 or > 120_000) return Failed(commandId, started, "TERMINAL_PATCH_SCOPE", "Yama mevcut dosya ve onaylı klasör sınırlarını karşılamıyor.", "denied");
            var diff = ApplyTerminalPatch(filePath, rawFilePath, patch);
            if (diff is null) return Failed(commandId, started, "TERMINAL_PATCH_REJECTED", "Yama mevcut dosyada bağlam eşleşmedi veya güvenli tek dosya biçiminde değil.");
            return new WindowsCommandResult(commandId, "completed", "Yama uygulandı; değişiklik diff'i döndürüldü.", started, DateTimeOffset.UtcNow,
                new { kind = "terminalJob", value = new { jobId = commandId, status = "completed", diff = diff[..Math.Min(diff.Length, 12_000)], applied = true, message = "Yama uygulandı." } });
        }

        var command = StringProperty(request, "command").Trim();
        var shell = StringProperty(request, "shell").ToLowerInvariant();
        if (shell.Length == 0) shell = "powershell";
        if (shell is not ("powershell" or "cmd")) return Failed(commandId, started, "TERMINAL_SHELL_UNSUPPORTED", "Windows'ta yalnızca PowerShell veya cmd destekleniyor.");
        if (command.Length is < 1 or > 4_000 || command.Contains('\0')) return Failed(commandId, started, "TERMINAL_COMMAND_INVALID", "Terminal komutu geçersiz.");
        if (RovaTerminalPolicy.IsForbidden(command)) return Failed(commandId, started, "TERMINAL_COMMAND_FORBIDDEN", "Bu komut Windows terminal oturumlarında yasak.", "denied");
        if (mode != "full" && !RovaTerminalPolicy.IsReadOnly(command, shell)) return Failed(commandId, started, "TERMINAL_READ_ONLY", "Bu oturum yalnızca salt okuma komutlarına izin veriyor.", "denied");
        var requestedSeconds = request.TryGetProperty("timeoutSeconds", out var timeout) && timeout.TryGetInt32(out var suppliedTimeout)
            ? suppliedTimeout : action == "start_job" ? 600 : 60;
        var remainingSeconds = Math.Max(1, (int)(grant.GetProperty("expiresAt").GetInt64() - DateTimeOffset.UtcNow.ToUnixTimeSeconds()));
        var timeoutSeconds = Math.Clamp(requestedSeconds, 1, action == "start_job" ? Math.Min(1800, remainingSeconds) : 110);
        var processCommand = BuildTerminalProcess(command, shell);
        if (processCommand is null) return Failed(commandId, started, "TERMINAL_SHELL_UNSUPPORTED", "Windows shell başlatılamadı.");
        if (action == "start_job")
        {
            var jobId = StringProperty(request, "jobId");
            if (!Guid.TryParse(jobId, out _)) return Failed(commandId, started, "TERMINAL_JOB_ID_INVALID", "Arka plan işi kimliği geçersiz.");
            PruneTerminalJobs();
            var job = new WindowsTerminalJob(jobId, RovaTerminalPolicy.String(grant, "id"), directory);
            if (!terminalJobs.TryAdd(jobId, job))
                return terminalJobs.TryGetValue(jobId, out var existing) && string.Equals(existing.GrantId, job.GrantId, StringComparison.OrdinalIgnoreCase)
                    ? TerminalJobResult(commandId, existing, started)
                    : Failed(commandId, started, "TERMINAL_GRANT_INVALID", "Bu iş farklı bir terminal iznine bağlı.", "denied");
            job.Worker = Task.Run(() => RunTerminalJobAsync(job, processCommand.Value.FileName, processCommand.Value.Arguments, timeoutSeconds));
            return TerminalJobResult(commandId, job, started);
        }

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token, cancellationToken);
        try
        {
            var outcome = await RunProcessAsync(processCommand.Value.FileName, processCommand.Value.Arguments, directory, linked.Token, timeoutSeconds).ConfigureAwait(false);
            var stdout = RovaTerminalPolicy.RedactSecrets(outcome.Stdout);
            var stderr = RovaTerminalPolicy.RedactSecrets(outcome.Stderr);
            var output = new { kind = "processOutput", value = new { language = "shell", exitCode = outcome.TimedOut ? -1 : outcome.ExitCode, stdout, stderr, truncated = outcome.Truncated, durationMs = outcome.DurationMs } };
            if (outcome.TimedOut) return new WindowsCommandResult(commandId, "unknown", "Terminal komutu zaman aşımına uğradı; sonucu doğrulanamadı.", started, DateTimeOffset.UtcNow, output, new { code = "TERMINAL_TIMEOUT", message = "Terminal komutu zaman aşımına uğradı." });
            if (outcome.ExitCode != 0) return new WindowsCommandResult(commandId, "failed", "Terminal komutu hata verdi.", started, DateTimeOffset.UtcNow, output, new { code = "TERMINAL_COMMAND_FAILED", message = "Çıkış kodu sıfır değil." });
            return new WindowsCommandResult(commandId, "completed", "Terminal komutu çalıştırıldı.", started, DateTimeOffset.UtcNow, output);
        }
        catch (OperationCanceledException)
        {
            return Failed(commandId, started, "TERMINAL_CANCELLED", "Terminal komutu durduruldu; yan etkiler kısmen uygulanmış olabilir.", "unknown");
        }
    }

    private async Task<WindowsCommandResult> HandleTerminalJobActionAsync(string commandId, JsonElement request, string action, DateTimeOffset started, CancellationToken cancellationToken)
    {
        var id = StringProperty(request, "jobId");
        if (!Guid.TryParse(id, out _) || !terminalJobs.TryGetValue(id, out var job))
        {
            var value = new { jobId = id, status = "unknown", message = "Bu Windows sürecinde iş bulunamadı; yeniden başlatıldıysa sonucu bilinmiyor.", errorCode = "TERMINAL_JOB_UNKNOWN" };
            return new WindowsCommandResult(commandId, "unknown", "İşin sonucu bilinmiyor; yeniden başlatmadan önce yerel PC'de kontrol et.", started, DateTimeOffset.UtcNow, new { kind = "terminalJob", value }, new { code = "TERMINAL_JOB_UNKNOWN", message = "İş bu companion sürecinde bulunamadı." });
        }
        if (!request.TryGetProperty("grant", out var grant) || grant.ValueKind != JsonValueKind.Object ||
            !RovaTerminalPolicy.VerifyGrant(grant, PairingToken, out var rawRoot, out _) ||
            !string.Equals(RovaTerminalPolicy.String(grant, "id"), job.GrantId, StringComparison.OrdinalIgnoreCase) ||
            RovaTerminalPolicy.ResolveDirectory(rawRoot) is not { } root ||
            !RovaTerminalPolicy.IsWithin(job.Directory, root))
            return Failed(commandId, started, "TERMINAL_GRANT_INVALID", "İşin imzalı terminal izni doğrulanamadı.", "denied");
        if (action == "cancel_job")
        {
            lock (job.Gate)
            {
                if (job.State == "running")
                {
                    job.CancelRequested = true;
                    try { if (job.Process is { HasExited: false } process) process.Kill(entireProcessTree: true); } catch { }
                }
            }
            if (job.Worker is { } worker) await Task.WhenAny(worker, Task.Delay(500, cancellationToken)).ConfigureAwait(false);
        }
        return TerminalJobResult(commandId, job, started);
    }

    private async Task RunTerminalJobAsync(WindowsTerminalJob job, string fileName, IReadOnlyList<string> arguments, int timeoutSeconds)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        try
        {
            var outcome = await RunProcessAsync(fileName, arguments, job.Directory, linked.Token, timeoutSeconds, process =>
            {
                var cancelNow = false;
                lock (job.Gate) { job.Process = process; cancelNow = job.CancelRequested; }
                if (cancelNow) try { process.Kill(entireProcessTree: true); } catch { }
            }).ConfigureAwait(false);
            var stdout = RovaTerminalPolicy.RedactSecrets(outcome.Stdout);
            var stderr = RovaTerminalPolicy.RedactSecrets(outcome.Stderr);
            var output = new { language = "shell", exitCode = outcome.TimedOut ? -1 : outcome.ExitCode, stdout, stderr, truncated = outcome.Truncated, durationMs = outcome.DurationMs };
            lock (job.Gate)
            {
                job.Output = output;
                if (job.CancelRequested) { job.State = "cancelled"; job.Message = "Terminal işi kullanıcı tarafından durduruldu."; }
                else if (outcome.TimedOut) { job.State = "unknown"; job.Message = "Terminal işi zaman aşımına uğradı; sonucu doğrulanamadı."; job.ErrorCode = "TERMINAL_TIMEOUT"; }
                else if (outcome.ExitCode != 0) { job.State = "failed"; job.Message = "Terminal işi hata verdi."; job.ErrorCode = "TERMINAL_COMMAND_FAILED"; }
                else { job.State = "completed"; job.Message = "Terminal işi tamamlandı."; }
                job.Process = null;
            }
            if (terminalJobReporter is { } report)
            {
                try { await report(job.Id, job.State, job.ErrorCode).ConfigureAwait(false); } catch { }
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
            if (terminalJobReporter is { } report)
            {
                try { await report(job.Id, job.State, job.ErrorCode).ConfigureAwait(false); } catch { }
            }
        }
    }

    private static WindowsCommandResult TerminalJobResult(string commandId, WindowsTerminalJob job, DateTimeOffset started)
    {
        lock (job.Gate)
        {
            var value = new { jobId = job.Id, status = job.State, output = job.Output, message = job.Message, errorCode = job.ErrorCode };
            return new WindowsCommandResult(commandId, job.State == "unknown" ? "unknown" : job.State == "failed" ? "failed" : "completed", job.Message, started, DateTimeOffset.UtcNow, new { kind = "terminalJob", value }, job.ErrorCode is null ? null : new { code = job.ErrorCode, message = job.Message });
        }
    }

    private static (string FileName, string[] Arguments)? BuildTerminalProcess(string command, string shell) => shell switch
    {
        "powershell" => ("powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command]),
        "cmd" => ("cmd.exe", ["/d", "/s", "/c", command]),
        _ => null
    };

    private static string? ApplyTerminalPatch(string filePath, string requestPath, string patch)
    {
        try
        {
            var original = File.ReadAllText(filePath, Encoding.UTF8);
            var hadBom = original.StartsWith('\uFEFF');
            if (hadBom) original = original[1..];
            var newline = original.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";
            var normalized = original.Replace("\r\n", "\n", StringComparison.Ordinal);
            var hadTrailing = normalized.EndsWith('\n');
            var source = normalized.Split('\n').ToList();
            if (hadTrailing) source.RemoveAt(source.Count - 1);
            var lines = patch.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
            if (lines.Length < 4 || !HeaderMatches(lines[0], "--- ", requestPath) || !HeaderMatches(lines[1], "+++ ", requestPath)) return null;
            var output = new List<string>();
            var sourceIndex = 0;
            var index = 2;
            var sawHunk = false;
            var hunkRegex = new Regex("^@@ -(\\d+)(?:,(\\d+))? \\+(\\d+)(?:,(\\d+))? @@", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
            while (index < lines.Length)
            {
                if (index == lines.Length - 1 && lines[index].Length == 0) break;
                var match = hunkRegex.Match(lines[index]);
                if (!match.Success) return null;
                var oldStart = int.Parse(match.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);
                var oldCount = match.Groups[2].Success ? int.Parse(match.Groups[2].Value, System.Globalization.CultureInfo.InvariantCulture) : 1;
                var oldCursor = oldCount == 0 && oldStart == 0 ? 0 : Math.Max(0, oldStart - 1);
                if (oldCursor < sourceIndex || oldCursor > source.Count) return null;
                output.AddRange(source.Skip(sourceIndex).Take(oldCursor - sourceIndex));
                sourceIndex = oldCursor;
                sawHunk = true;
                index++;
                var consumedOld = 0;
                while (index < lines.Length && !lines[index].StartsWith("@@ ", StringComparison.Ordinal))
                {
                    var line = lines[index];
                    if (line.StartsWith("\\ No newline at end of file", StringComparison.Ordinal)) { index++; continue; }
                    if (line.Length == 0) return null;
                    var content = line[1..];
                    switch (line[0])
                    {
                        case ' ':
                            if (sourceIndex >= source.Count || source[sourceIndex] != content) return null;
                            output.Add(content); sourceIndex++; consumedOld++; break;
                        case '-':
                            if (sourceIndex >= source.Count || source[sourceIndex] != content) return null;
                            sourceIndex++; consumedOld++; break;
                        case '+': output.Add(content); break;
                        default: return null;
                    }
                    index++;
                }
                if (consumedOld != oldCount) return null;
            }
            if (!sawHunk) return null;
            output.AddRange(source.Skip(sourceIndex));
            var result = string.Join(newline, output) + (hadTrailing ? newline : "");
            if (result.Length == 0 || result == original) return null;
            var temporary = filePath + ".wiqo-" + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllText(temporary, (hadBom ? "\uFEFF" : "") + result, new UTF8Encoding(false));
                File.Move(temporary, filePath, true);
            }
            finally { try { File.Delete(temporary); } catch { } }
            return patch;
        }
        catch { return null; }
    }

    private static bool HeaderMatches(string line, string prefix, string expected)
    {
        if (!line.StartsWith(prefix, StringComparison.Ordinal)) return false;
        var path = line[prefix.Length..].Split('\t')[0];
        if (path == "/dev/null" || path.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries).Any(part => part == "..")) return false;
        if (path.StartsWith("a/", StringComparison.Ordinal) || path.StartsWith("b/", StringComparison.Ordinal)) path = path[2..];
        var normalizedExpected = expected.StartsWith("a/", StringComparison.Ordinal) || expected.StartsWith("b/", StringComparison.Ordinal) ? expected[2..] : expected;
        return path.Equals(normalizedExpected, StringComparison.OrdinalIgnoreCase);
    }

    private void PruneTerminalJobs()
    {
        foreach (var job in terminalJobs.Values.Where(item => item.State != "running" && DateTimeOffset.UtcNow - item.StartedAt > TimeSpan.FromHours(24))) terminalJobs.TryRemove(job.Id, out _);
        var finished = terminalJobs.Values.Where(item => item.State != "running").OrderBy(item => item.StartedAt).ToArray();
        foreach (var job in finished.Take(Math.Max(0, finished.Length - 50))) terminalJobs.TryRemove(job.Id, out _);
    }

    private sealed record ProcessOutcome(string Stdout, string Stderr, int ExitCode, bool TimedOut, bool Truncated, int DurationMs);

    private static async Task<ProcessOutcome> RunProcessAsync(string fileName, IReadOnlyList<string> arguments, string directory, CancellationToken cancellationToken, int timeoutSeconds = 30, Action<Process>? processStarted = null)
    {
        var started = Stopwatch.GetTimestamp();
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = fileName,
                WorkingDirectory = directory,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            }
        };
        process.StartInfo.Environment.Clear();
        foreach (var pair in SafeEnvironment(directory)) process.StartInfo.Environment[pair.Key] = pair.Value;
        foreach (var argument in arguments) process.StartInfo.ArgumentList.Add(argument);
        try { process.Start(); }
        catch { return new ProcessOutcome("", "İşlem başlatılamadı.", -1, false, false, ElapsedMs(started)); }
        processStarted?.Invoke(process);
        var stdoutTask = ReadBoundedAsync(process.StandardOutput, cancellationToken);
        var stderrTask = ReadBoundedAsync(process.StandardError, cancellationToken);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(timeoutSeconds, 1, 1800)));
        var timedOut = false;
        try { await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            timedOut = true;
            try { process.Kill(entireProcessTree: true); } catch { }
            await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch { }
            await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
            throw;
        }
        var stdout = await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);
        return new ProcessOutcome(stdout.Text, stderr.Text, process.ExitCode, timedOut, stdout.Truncated || stderr.Truncated, ElapsedMs(started));
    }

    private static async Task<(string Text, bool Truncated)> ReadBoundedAsync(StreamReader reader, CancellationToken cancellationToken)
    {
        const int cap = 200_000;
        var buffer = new char[4096];
        var output = new StringBuilder(Math.Min(cap, 16_384));
        var truncated = false;
        while (true)
        {
            var count = await reader.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (count == 0) break;
            var remaining = cap - output.Length;
            if (remaining > 0) output.Append(buffer, 0, Math.Min(count, remaining));
            if (count > remaining) truncated = true;
        }
        return (output.ToString(), truncated);
    }

    private static string StringProperty(JsonElement value, string name) => value.TryGetProperty(name, out var property) && property.ValueKind == JsonValueKind.String ? property.GetString() ?? "" : "";
    private static int ElapsedMs(long started) => (int)Math.Min(int.MaxValue, Stopwatch.GetElapsedTime(started).TotalMilliseconds);

    private static IReadOnlyDictionary<string, string> SafeEnvironment(string workingDirectory)
    {
        var inherited = Environment.GetEnvironmentVariables();
        var allowed = new[]
        {
            "PATH", "SystemRoot", "ComSpec", "TEMP", "TMP", "USERPROFILE", "HOMEDRIVE", "HOMEPATH",
            "APPDATA", "LOCALAPPDATA", "ProgramFiles", "ProgramFiles(x86)", "CommonProgramFiles",
            "CommonProgramFiles(x86)", "PATHEXT"
        };
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var key in allowed)
        {
            if (inherited[key] is string value && !value.Contains('\0')) result[key] = value;
        }
        result["WIQO_WORKING_DIRECTORY"] = workingDirectory;
        return result;
    }

    private static string PayloadString(JsonElement payload)
    {
        if (payload.ValueKind == JsonValueKind.Object && payload.TryGetProperty("value", out var value))
            return value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : value.ToString();
        return payload.ValueKind == JsonValueKind.String ? payload.GetString() ?? "" : "";
    }

    private static WindowsCommandResult Failed(string id, DateTimeOffset started, string code, string message, string status = "failed") =>
        new(id, status, message, started, DateTimeOffset.UtcNow, null, new { code, message });

    private static string LoadDeviceId()
    {
        try
        {
            var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Wiqo");
            Directory.CreateDirectory(directory);
            var path = Path.Combine(directory, "device-id");
            if (File.Exists(path))
            {
                var stored = File.ReadAllText(path).Trim();
                if (stored.Length > 0) return stored;
            }
            var id = Guid.NewGuid().ToString();
            File.WriteAllText(path, id);
            return id;
        }
        catch
        {
            // A locked-down profile must not crash the companion; it can still connect for this
            // process and the next launch will retry persistence.
            return Guid.NewGuid().ToString();
        }
    }

    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        foreach (var job in terminalJobs.Values)
        {
            lock (job.Gate)
            {
                job.CancelRequested = true;
                try { if (job.Process is { HasExited: false } process) process.Kill(entireProcessTree: true); } catch { }
            }
        }
        var workers = terminalJobs.Values.Select(job => job.Worker).OfType<Task>().ToArray();
        try { await Task.WhenAll(workers).WaitAsync(TimeSpan.FromSeconds(3)).ConfigureAwait(false); } catch { }
        sideEffectGate.Dispose();
        lifetime.Dispose();
    }
}
