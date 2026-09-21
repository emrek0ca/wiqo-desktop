using System.Diagnostics;
using System.Text.Json;
using System.Text;

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

    public WindowsRuntime(int queueCapacity = 64)
    {
        if (queueCapacity < 1) throw new ArgumentOutOfRangeException(nameof(queueCapacity));
        this.queueCapacity = queueCapacity;
    }

    public string DeviceId { get; } = LoadDeviceId();
    public string DisplayName => Environment.MachineName;

    public IReadOnlyList<string> Capabilities => WindowsCapabilityManifest.Capabilities.OrderBy(value => value, StringComparer.Ordinal).ToArray();

    public object[] Authorities => Capabilities.Select(capability => new
    {
        capability,
        displayName = capability,
        access = capability == "device.code.execute" ? "confirmation" : "automatic",
        requiredPermissions = capability == "device.code.execute" ? new[] { "user_presence" } : Array.Empty<string>(),
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
            linked.CancelAfter(timeout);
            // Side effects remain ordered; read-only operations can execute without this gate.
            var sideEffect = operation is "openURL";
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

    private static async Task<WindowsCommandResult> RunAsync(string commandId, string operation, JsonElement payload, DateTimeOffset started, CancellationToken cancellationToken)
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
                Process.Start(new ProcessStartInfo(parsed.AbsoluteUri) { UseShellExecute = true });
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
            case "executeCode":
                return await ExecuteCodeAsync(commandId, payload, started, cancellationToken).ConfigureAwait(false);
            default:
                return Failed(commandId, started, "UNSUPPORTED_OPERATION", "Bu işlem Windows'ta desteklenmiyor.");
        }

        return new WindowsCommandResult(commandId, "completed", message, started, DateTimeOffset.UtcNow, data);
    }

    private static async Task<WindowsCommandResult> ExecuteCodeAsync(string commandId, JsonElement payload, DateTimeOffset started, CancellationToken cancellationToken)
    {
        if (!payload.TryGetProperty("value", out var value) || value.ValueKind != JsonValueKind.Object)
            return Failed(commandId, started, "INVALID_PAYLOAD", "Terminal isteği geçersiz.");

        var language = StringProperty(value, "language").ToLowerInvariant();
        var code = StringProperty(value, "code");
        var scope = StringProperty(value, "scope").ToLowerInvariant();
        if (scope.Length == 0) scope = "sandbox";
        var shell = StringProperty(value, "shell").ToLowerInvariant();
        if (shell.Length == 0) shell = "default";
        var workingDirectory = StringProperty(value, "workingDirectory");
        if (string.IsNullOrWhiteSpace(code) || code.Length > 100_000 || language is not ("shell" or "python" or "javascript") || scope is not ("sandbox" or "computer"))
            return Failed(commandId, started, "INVALID_PAYLOAD", "Terminal dili, kodu veya kapsamı geçersiz.");

        var arguments = new List<string>();
        if (value.TryGetProperty("arguments", out var rawArguments) && rawArguments.ValueKind == JsonValueKind.Array)
            arguments.AddRange(rawArguments.EnumerateArray().Where(item => item.ValueKind == JsonValueKind.String).Select(item => item.GetString() ?? ""));
        if (arguments.Count > 20 || arguments.Any(argument => argument.Length == 0 || argument.Length > 200 || argument.Contains('\0')))
            return Failed(commandId, started, "INVALID_PAYLOAD", "Terminal argümanları geçersiz.");

        var temporaryDirectory = scope == "sandbox"
            ? Directory.CreateTempSubdirectory("wiqo-terminal-")
            : null;
        try
        {
            var directory = scope == "sandbox"
                ? temporaryDirectory!.FullName
                : (string.IsNullOrWhiteSpace(workingDirectory) ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) : workingDirectory);
            if (!Directory.Exists(directory))
                return Failed(commandId, started, "INVALID_WORKING_DIRECTORY", "Çalışma klasörü bulunamadı.");

            var command = BuildCommand(language, shell, code, arguments, directory);
            if (command is null) return Failed(commandId, started, "UNSUPPORTED_SHELL", "Bu shell Windows'ta desteklenmiyor.");
            var scriptPath = language == "shell" ? null : command.Value.Arguments.FirstOrDefault();
            ProcessOutcome outcome;
            try
            {
                outcome = await RunProcessAsync(command.Value.FileName, command.Value.Arguments, directory, cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                if (scriptPath is not null) try { File.Delete(scriptPath); } catch { }
            }
            var output = new
            {
                kind = "processOutput",
                value = new
                {
                    language,
                    exitCode = outcome.TimedOut ? -1 : outcome.ExitCode,
                    stdout = outcome.Stdout,
                    stderr = outcome.Stderr,
                    truncated = outcome.Truncated,
                    durationMs = outcome.DurationMs
                }
            };
            if (outcome.TimedOut)
                return new WindowsCommandResult(commandId, "unknown", "Terminal komutu zaman aşımına uğradı; sonucu doğrulanamadı.", started, DateTimeOffset.UtcNow, output, new { code = "CODE_TIMEOUT", message = "Terminal komutu zaman aşımına uğradı." });
            if (outcome.ExitCode != 0)
                return new WindowsCommandResult(commandId, "failed", "Terminal komutu hata verdi.", started, DateTimeOffset.UtcNow, output, new { code = "CODE_FAILED", message = outcome.Stderr[..Math.Min(outcome.Stderr.Length, 300)] });
            return new WindowsCommandResult(commandId, "completed", "Terminal komutu çalıştırıldı.", started, DateTimeOffset.UtcNow, output);
        }
        finally
        {
            try { temporaryDirectory?.Delete(true); } catch { }
        }
    }

    private static (string FileName, string[] Arguments)? BuildCommand(string language, string shell, string code, IReadOnlyList<string> arguments, string directory)
    {
        if (language == "shell")
        {
            if (shell is "default" or "powershell") return ("powershell.exe", new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", code });
            if (shell == "cmd") return ("cmd.exe", new[] { "/d", "/s", "/c", code });
            if (shell == "bash") return ("bash.exe", new[] { "-lc", code });
            return null;
        }
        var extension = language == "python" ? ".py" : ".js";
        var script = Path.Combine(directory, $"wiqo-{Guid.NewGuid():N}{extension}");
        File.WriteAllText(script, code, Encoding.UTF8);
        return language == "python"
            ? ("python.exe", new[] { script }.Concat(arguments).ToArray())
            : ("node.exe", new[] { script }.Concat(arguments).ToArray());
    }

    private sealed record ProcessOutcome(string Stdout, string Stderr, int ExitCode, bool TimedOut, bool Truncated, int DurationMs);

    private static async Task<ProcessOutcome> RunProcessAsync(string fileName, IReadOnlyList<string> arguments, string directory, CancellationToken cancellationToken)
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
        var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        var timedOut = false;
        try { await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            timedOut = true;
            try { process.Kill(entireProcessTree: true); } catch { }
            await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
        }
        var stdout = await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);
        const int cap = 200_000;
        var truncated = stdout.Length > cap || stderr.Length > cap;
        return new ProcessOutcome(stdout[..Math.Min(stdout.Length, cap)], stderr[..Math.Min(stderr.Length, cap)], process.ExitCode, timedOut, truncated, ElapsedMs(started));
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

    public ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        sideEffectGate.Dispose();
        lifetime.Dispose();
        return ValueTask.CompletedTask;
    }
}
