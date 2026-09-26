using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace RovaWindows;

/// Windows counterpart of RovaShared/RovaTerminalPolicy. The backend relays a phone-signed,
/// time-limited grant; this adapter resolves paths and evaluates command policy on every message.
internal static class RovaTerminalPolicy
{
    /// Same limit as RovaTerminalPolicy.maxGrantSeconds on the Mac (8 hours; the phone offers it).
    internal const long MaxGrantSeconds = 8 * 60 * 60;

    private static readonly Regex[] Forbidden =
    [
        Rx(@"(^|[\s;&|()])(?:sudo|runas|Start-Process\s+.*-Verb\s+RunAs)(\s|$)"),
        Rx(@"\b(?:Remove-Item|del|erase|rd|rmdir)\b[^\r\n]*(?:-Recurse|-Force|/s|/q|\*|\$env:USERPROFILE|%USERPROFILE%)[^\r\n]*", RegexOptions.IgnoreCase),
        Rx(@"\b(?:Format-Volume|Clear-Disk|Initialize-Disk|Remove-Partition|diskpart|format\.com|cipher\s+/w|bcdedit|takeown|icacls\s+.*\/reset)\b"),
        Rx(@"\b(?:Stop-Computer|Restart-Computer|shutdown\.exe|shutdown|reboot|Set-ExecutionPolicy|reg\s+delete|schtasks\s+/delete)\b"),
        Rx(@"\b(?:Invoke-WebRequest|iwr|curl|wget)\b[^\r\n]*\|\s*(?:Invoke-Expression|iex|powershell|pwsh|cmd)\b"),
        Rx(@"\b(?:Get-Credential|ConvertFrom-SecureString|Get-Secret|cmdkey|vaultcmd|reg\s+save|dpapi)\b"),
        Rx(@"\b(?:Start-Process|Invoke-Expression|iex|Add-MpPreference|Set-MpPreference)\b")
    ];

    private static readonly HashSet<string> PowerShellReadOnly = new(StringComparer.OrdinalIgnoreCase)
    {
        "Get-ChildItem", "Get-Item", "Get-Content", "Get-Location", "Get-Help", "Get-Date", "Get-ComputerInfo",
        "Get-Process", "Get-Service", "Get-Command", "Get-FileHash", "Get-ItemProperty", "Get-Member", "Test-Path",
        "Select-Object", "Where-Object", "Sort-Object", "Measure-Object", "Format-Table", "Format-List", "Out-String",
        "ConvertTo-Json", "Write-Output", "Write-Host", "git", "dotnet", "node", "npm", "python", "python3"
    };

    private static readonly HashSet<string> CmdReadOnly = new(StringComparer.OrdinalIgnoreCase)
    {
        "dir", "cd", "type", "more", "find", "findstr", "where", "ver", "whoami", "hostname", "tasklist", "git", "dotnet", "node", "npm", "python", "python3"
    };

    private static Regex Rx(string pattern, RegexOptions extra = RegexOptions.None) => new(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | extra, TimeSpan.FromMilliseconds(100));

    internal static bool VerifyGrant(JsonElement grant, string? pairingToken, out string root, out string mode, DateTimeOffset? now = null)
    {
        root = String(grant, "rootDirectory");
        mode = String(grant, "mode");
        var id = String(grant, "id");
        var signature = String(grant, "signature");
        if (string.IsNullOrWhiteSpace(pairingToken) || !Guid.TryParse(id, out _) || mode is not ("read" or "full") ||
            !grant.TryGetProperty("expiresAt", out var expiration) || !expiration.TryGetInt64(out var expiresAt)) return false;
        var nowSeconds = (now ?? DateTimeOffset.UtcNow).ToUnixTimeSeconds();
        if (expiresAt <= nowSeconds || expiresAt > nowSeconds + MaxGrantSeconds || signature.Length != 64) return false;
        var message = $"wiqo-terminal-grant:v1:{id.ToLowerInvariant()}:{root}:{mode}:{expiresAt}";
        var expected = HMACSHA256.HashData(Encoding.UTF8.GetBytes(pairingToken), Encoding.UTF8.GetBytes(message));
        byte[] supplied;
        try { supplied = Convert.FromHexString(signature); }
        catch (FormatException) { return false; }
        return supplied.Length == expected.Length && CryptographicOperations.FixedTimeEquals(supplied, expected);
    }

    internal static string? ResolveDirectory(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 500 || value.Contains('\0') || value.StartsWith("\\\\", StringComparison.Ordinal)) return null;
        var raw = ExpandHome(value.Trim());
        if (raw.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries).Any(part => part == "..") || !Path.IsPathFullyQualified(raw)) return null;
        string full;
        try { full = Path.GetFullPath(raw); }
        catch { return null; }
        if (!Directory.Exists(full) || HasReparseComponent(full)) return null;
        var trimmed = full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        return trimmed.Length > 0 ? trimmed : Path.GetPathRoot(full);
    }

    /// The granted folder as a full path, whether or not it exists yet (for creating it).
    internal static string? FullPath(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 500 || value.Contains('\0') || value.StartsWith("\\\\", StringComparison.Ordinal)) return null;
        var raw = ExpandHome(value.Trim());
        if (raw.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries).Any(part => part == "..") || !Path.IsPathFullyQualified(raw)) return null;
        try { return Path.GetFullPath(raw).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar); }
        catch { return null; }
    }

    /// A full-access grant whose folder does not exist yet ("~\\Desktop\\deneme'de dosya oluştur"):
    /// it may be created, but only strictly inside the user profile (RovaTerminalPolicy.creatableDirectory).
    internal static string? CreatableRoot(string rootDirectory, string mode)
    {
        if (mode != "full" || FullPath(rootDirectory) is not { } root || Directory.Exists(root) || File.Exists(root)) return null;
        var profile = Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)).TrimEnd(Path.DirectorySeparatorChar);
        return !root.Equals(profile, StringComparison.OrdinalIgnoreCase) && IsWithin(root, profile) ? root : null;
    }

    /// "~\\x" or "~/x" under the profile, an absolute path as is, anything else under the working folder.
    internal static string AbsoluteFilePath(string path, string workingDirectory)
    {
        var expanded = ExpandHome(path.Trim());
        return Path.IsPathFullyQualified(expanded) ? expanded : Path.Combine(workingDirectory, expanded);
    }

    /// A file to create or overwrite inside the grant: its folder must exist inside the root with
    /// no junction on the way, and an existing target must be a regular file.
    internal static string? ResolveWritableFile(string path, string workingDirectory, string root)
    {
        if (string.IsNullOrWhiteSpace(path) || path.Length > 1000 || path.Contains('\0') || path.EndsWith('/') || path.EndsWith('\\') ||
            path.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries).Any(part => part == "..")) return null;
        try
        {
            var full = Path.GetFullPath(AbsoluteFilePath(path, workingDirectory));
            var parent = Path.GetDirectoryName(full);
            if (parent is null || !IsWithin(full, root) || full.TrimEnd('\\').Equals(root.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) ||
                !Directory.Exists(parent) || HasReparseComponent(parent) || Directory.Exists(full)) return null;
            if (File.Exists(full) && PathSafety.IsLink(full)) return null;
            return full;
        }
        catch { return null; }
    }

    private static string ExpandHome(string raw)
    {
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (raw == "~") return profile;
        return raw.StartsWith("~/", StringComparison.Ordinal) || raw.StartsWith("~\\", StringComparison.Ordinal) ? Path.Combine(profile, raw[2..]) : raw;
    }

    internal static string? ResolveExistingFile(string path, string workingDirectory, string root)
    {
        if (string.IsNullOrWhiteSpace(path) || path.Length > 1000 || path.Contains('\0') || path.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries).Any(part => part == "..")) return null;
        try
        {
            var full = Path.GetFullPath(AbsoluteFilePath(path, workingDirectory));
            if (!IsWithin(full, root) || !File.Exists(full) || (File.GetAttributes(full) & FileAttributes.Directory) != 0 || HasReparseComponent(full)) return null;
            return full;
        }
        catch { return null; }
    }

    /// Links (symlinks, junctions) on the way; OneDrive cloud placeholders are allowed (PathSafety).
    internal static bool HasReparseComponent(string path) => PathSafety.HasLinkComponent(path);

    internal static bool IsWithin(string path, string root)
    {
        var full = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var boundary = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        return full.Equals(boundary, StringComparison.OrdinalIgnoreCase) || full.StartsWith(boundary + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    internal static bool IsForbidden(string command) => Forbidden.Any(pattern => pattern.IsMatch(command));

    internal static bool IsReadOnly(string command, string shell)
    {
        if (string.IsNullOrWhiteSpace(command) || command.Length > 4_000 || IsForbidden(command) ||
            Regex.IsMatch(command, @"[A-Za-z]:|\\\\|(^|[\s""'=])[\\/]", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100)) || command.Contains("..", StringComparison.Ordinal) ||
            command.Contains('%') || command.Contains('~') || command.Contains('$') || command.Contains('`') || command.Contains('>') || command.Contains('<') ||
            command.Contains(';') || command.Contains('&')) return false;
        var segments = command.Split('|', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length == 0) return false;
        foreach (var segment in segments)
        {
            var words = segment.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (words.Length == 0) return false;
            var program = Path.GetFileName(words[0]);
            if (shell.Equals("cmd", StringComparison.OrdinalIgnoreCase))
            {
                if (!CmdReadOnly.Contains(program)) return false;
                if (program.Equals("cd", StringComparison.OrdinalIgnoreCase) && words.Length > 2) return false;
                if (program.Equals("git", StringComparison.OrdinalIgnoreCase) && (words.Length < 2 || !IsGitReadOnly(words[1]))) return false;
                if ((program is "dotnet" or "node" or "npm" or "python" or "python3") && words.Length > 1 && !IsVersionOnly(words[1])) return false;
            }
            else
            {
                if (!PowerShellReadOnly.Contains(program)) return false;
                if (program.Equals("git", StringComparison.OrdinalIgnoreCase) && (words.Length < 2 || !IsGitReadOnly(words[1]))) return false;
                if ((program is "dotnet" or "node" or "npm" or "python" or "python3") && words.Length > 1 && !IsVersionOnly(words[1])) return false;
            }
        }
        return true;
    }

    private static bool IsVersionOnly(string argument) => argument is "--version" or "-v" or "-V" or "--info" or "--list";
    private static bool IsGitReadOnly(string subcommand) => subcommand is "status" or "log" or "diff" or "show" or "branch" or "remote" or "rev-parse" or "ls-files" or "blame" or "describe" or "tag";
    internal static string String(JsonElement value, string name) => value.TryGetProperty(name, out var property) && property.ValueKind == JsonValueKind.String ? property.GetString() ?? "" : "";

    internal static string RedactSecrets(string value)
    {
        var result = Regex.Replace(value, @"(?im)^\s*(?:[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTHORIZATION)[A-Z0-9_]*\s*[=:]\s*)\S.*$", "[gizli bilgi gizlendi]", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
        result = Regex.Replace(result, @"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----|\b(AKIA|ASIA)[0-9A-Z]{16}\b|\bgh[pousr]_[A-Za-z0-9]{30,}\b|\bsk-[A-Za-z0-9_-]{20,}\b|\bxox[abprs]-[A-Za-z0-9-]{10,}\b|\bAIza[0-9A-Za-z_-]{30,}\b|\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b", "[gizli bilgi gizlendi]", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
        return result;
    }
}
