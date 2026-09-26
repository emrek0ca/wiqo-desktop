using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using RovaWindows.Operations;

namespace RovaWindows.Terminal;

/// This PC's developer environment for the model (MacSystem.terminalProfile): OS, architecture,
/// shell, installed toolchains with versions and the git projects in the usual folders. Paths use
/// forward slashes: the backend's profile filter drops backslashes, and PowerShell accepts both.
internal static class TerminalProfile
{
    private static readonly (string Name, string Arguments)[] Tools =
    [
        ("node", "--version"), ("npm", "--version"), ("pnpm", "--version"), ("yarn", "--version"), ("bun", "--version"),
        ("python", "--version"), ("pip", "--version"), ("git", "--version"), ("dotnet", "--version"), ("docker", "--version"),
        ("go", "version"), ("cargo", "--version"), ("java", "-version"), ("winget", "--version"), ("rg", "--version")
    ];

    internal static async Task<Dictionary<string, object>> BuildAsync(CancellationToken cancellationToken)
    {
        var tools = new List<string>();
        foreach (var (name, arguments) in Tools)
        {
            var version = await VersionAsync(name, arguments, cancellationToken).ConfigureAwait(false);
            if (version is not null) tools.Add($"{name} {version}");
        }
        return new Dictionary<string, object>
        {
            ["os"] = SystemOperations.WindowsVersion(),
            ["arch"] = RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant(),
            ["shell"] = TerminalProcess.ShellDescription.Replace(' ', '-'),
            ["tools"] = tools,
            ["projects"] = GitProjects()
        };
    }

    private static async Task<string?> VersionAsync(string name, string arguments, CancellationToken cancellationToken)
    {
        var executable = TerminalProcess.FindOnPath(name + ".exe") ?? TerminalProcess.FindOnPath(name + ".cmd");
        if (executable is null) return null;
        try
        {
            var start = new ProcessStartInfo(executable)
            {
                RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
            };
            foreach (var argument in arguments.Split(' ')) start.ArgumentList.Add(argument);
            // .cmd shims (npm, pnpm, yarn) need cmd.exe to run.
            if (executable.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase))
            {
                start = new ProcessStartInfo("cmd.exe") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
                foreach (var argument in new[] { "/d", "/c", executable, arguments }) start.ArgumentList.Add(argument);
            }
            using var process = Process.Start(start);
            if (process is null) return null;
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(4));
            var stdout = process.StandardOutput.ReadToEndAsync(timeout.Token);
            var stderr = process.StandardError.ReadToEndAsync(timeout.Token);
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            var line = ((await stdout.ConfigureAwait(false)) + "\n" + (await stderr.ConfigureAwait(false))).Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).FirstOrDefault() ?? "";
            line = line.Replace("version", "", StringComparison.OrdinalIgnoreCase).Replace(name, "", StringComparison.OrdinalIgnoreCase).Trim(' ', ':', '"');
            return line.Length is > 0 and <= 40 ? line : line.Length > 40 ? line[..40] : null;
        }
        catch { return null; }
    }

    private static List<string> GitProjects()
    {
        var projects = new List<string>();
        var profile = WindowsPaths.UserProfile;
        var folders = new[] { WindowsPaths.Desktop, Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments) }
            .Concat(new[] { "source\\repos", "Projects", "Code", "code", "src", "GitHub", "dev", "Developer" }.Select(name => Path.Combine(profile, name)))
            .Distinct(StringComparer.OrdinalIgnoreCase);
        foreach (var folder in folders)
        {
            try
            {
                foreach (var child in Directory.EnumerateDirectories(folder))
                {
                    if (!Directory.Exists(Path.Combine(child, ".git"))) continue;
                    projects.Add(child.Replace('\\', '/'));
                    if (projects.Count >= 12) return projects;
                }
            }
            catch { }
        }
        return projects;
    }
}
