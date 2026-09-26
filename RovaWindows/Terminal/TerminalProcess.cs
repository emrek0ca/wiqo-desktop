using System.Collections;
using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace RovaWindows.Terminal;

internal sealed record ProcessOutcome(string Stdout, string Stderr, int ExitCode, bool TimedOut, bool Truncated, int DurationMs, string? EndDirectory);

/// Runs one shell command the way a developer's own terminal would: PowerShell 7 when installed
/// (else Windows PowerShell 5.1), UTF-8 output, the user's current PATH (read fresh from the
/// registry, so a tool installed after login is found), and the folder the command ended in so a
/// `cd` carries over to the next command of the session.
internal static class TerminalProcess
{
    private const int OutputCap = 200_000;
    private const string DirectoryMarker = "__WIQO_PWD__";
    private static readonly Regex SecretName = new("(TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|API_?KEY|PRIVATE_?KEY|ACCESS_?KEY)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    // WIQO_PWSH points at a specific PowerShell 7 (tests run the wrapper on macOS with it).
    private static readonly Lazy<string?> PwshPath = new(() => System.Environment.GetEnvironmentVariable("WIQO_PWSH") is { Length: > 0 } custom ? custom : FindOnPath("pwsh.exe"));

    internal static string ShellDescription => PwshPath.Value is not null ? "PowerShell 7" : "Windows PowerShell 5.1";

    internal static async Task<ProcessOutcome> RunAsync(string command, string shell, string directory, int timeoutSeconds, CancellationToken cancellationToken, bool trackDirectory = true, Action<Process>? started = null)
    {
        var (fileName, arguments) = Build(command, shell, trackDirectory);
        var stopwatch = Stopwatch.StartNew();
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = fileName,
                WorkingDirectory = directory,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            }
        };
        foreach (var argument in arguments) process.StartInfo.ArgumentList.Add(argument);
        process.StartInfo.Environment.Clear();
        foreach (var pair in Environment(directory)) process.StartInfo.Environment[pair.Key] = pair.Value;
        try { process.Start(); }
        catch (Exception error) { return new ProcessOutcome("", $"Kabuk başlatılamadı: {error.Message}", -1, false, false, 0, null); }
        // No interactive prompt can ever wait for input that will not come.
        try { process.StandardInput.Close(); } catch { }
        started?.Invoke(process);

        var stdoutTask = ReadBoundedAsync(process.StandardOutput);
        var stderrTask = ReadBoundedAsync(process.StandardError);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(timeoutSeconds, 1, 1800)));
        var timedOut = false;
        try { await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false); }
        catch (OperationCanceledException)
        {
            timedOut = !cancellationToken.IsCancellationRequested;
            try { process.Kill(entireProcessTree: true); } catch { }
            await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
            if (!timedOut) throw;
        }
        var stdout = await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);
        var text = stdout.Text;
        string? endDirectory = null;
        var marker = text.LastIndexOf(DirectoryMarker, StringComparison.Ordinal);
        if (marker >= 0)
        {
            endDirectory = text[(marker + DirectoryMarker.Length)..].Trim();
            text = text[..marker].TrimEnd('\r', '\n');
        }
        return new ProcessOutcome(text, stderr.Text, timedOut ? -1 : process.ExitCode, timedOut, stdout.Truncated || stderr.Truncated, (int)stopwatch.ElapsedMilliseconds, endDirectory);
    }

    /// PowerShell: UTF-8 in and out, the command itself, then an exit code that is non-zero when a
    /// native program or a cmdlet failed, and the final folder after a marker.
    private static (string FileName, string[] Arguments) Build(string command, string shell, bool trackDirectory)
    {
        if (shell == "cmd")
        {
            // Delayed expansion keeps the command's own exit code past the folder marker.
            var cmdCommand = trackDirectory
                ? $"chcp 65001 >nul & {command} & set WIQO_RC=!errorlevel! & echo {DirectoryMarker}!cd! & exit /b !WIQO_RC!"
                : $"chcp 65001 >nul & {command}";
            return ("cmd.exe", ["/d", "/s", "/v:on", "/c", cmdCommand]);
        }
        var script = new StringBuilder()
            .AppendLine("$ProgressPreference = 'SilentlyContinue'")
            .AppendLine("[Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8")
            .AppendLine("$global:LASTEXITCODE = 0")
            .AppendLine(command)
            .AppendLine("$wiqoOk = $?")
            .AppendLine("$wiqoCode = if ($global:LASTEXITCODE -ne 0) { $global:LASTEXITCODE } elseif (-not $wiqoOk) { 1 } else { 0 }");
        if (trackDirectory) script.AppendLine($"[Console]::Out.Write(\"`n{DirectoryMarker}\" + (Get-Location).ProviderPath)");
        script.AppendLine("exit $wiqoCode");
        // -EncodedCommand: no quoting layer between us and PowerShell can change the command.
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script.ToString()));
        return (PwshPath.Value ?? "powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded]);
    }

    /// The user's environment as a new terminal would see it, minus variables that look like
    /// secrets (a command's output is sent to the model).
    internal static Dictionary<string, string> Environment(string workingDirectory)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry entry in System.Environment.GetEnvironmentVariables())
        {
            if (entry.Key is not string key || entry.Value is not string value || value.Contains('\0') || SecretName.IsMatch(key)) continue;
            result[key] = value;
        }
        if (FreshPath() is { Length: > 0 } path) result["PATH"] = path;
        result["WIQO_WORKING_DIRECTORY"] = workingDirectory;
        result["NO_COLOR"] = "1";
        result["TERM"] = "dumb";
        return result;
    }

    /// Machine PATH + user PATH from the registry, expanded - what a terminal opened now would get.
    internal static string? FreshPath()
    {
        try
        {
            using var machine = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Session Manager\Environment");
            using var user = Registry.CurrentUser.OpenSubKey("Environment");
            var parts = new[] { machine?.GetValue("Path") as string, user?.GetValue("Path") as string }
                .Where(value => !string.IsNullOrWhiteSpace(value))
                .SelectMany(value => System.Environment.ExpandEnvironmentVariables(value!).Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();
            return parts.Length > 0 ? string.Join(';', parts) : null;
        }
        catch { return null; }
    }

    internal static string? FindOnPath(string executable)
    {
        var path = FreshPath() ?? System.Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var directory in path.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            try
            {
                var candidate = Path.Combine(directory, executable);
                if (File.Exists(candidate)) return candidate;
            }
            catch { }
        }
        return null;
    }

    private static async Task<(string Text, bool Truncated)> ReadBoundedAsync(StreamReader reader)
    {
        var buffer = new char[4096];
        var output = new StringBuilder(8192);
        var truncated = false;
        while (true)
        {
            var count = await reader.ReadAsync(buffer.AsMemory()).ConfigureAwait(false);
            if (count == 0) break;
            var remaining = OutputCap - output.Length;
            if (remaining > 0) output.Append(buffer, 0, Math.Min(count, remaining));
            if (count > remaining) truncated = true;
        }
        return (output.ToString(), truncated);
    }
}
