using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Xunit;

namespace RovaWindows.Tests;

/// A test that needs a real Windows machine (PowerShell, Win32, COM); skipped elsewhere and run by
/// the Windows CI job.
public sealed class WindowsFactAttribute : FactAttribute
{
    public WindowsFactAttribute()
    {
        if (!OperatingSystem.IsWindows()) Skip = "Yalnız Windows'ta çalışır.";
    }
}

internal sealed class TempFolder : IDisposable
{
    public string Path { get; } = Create();

    /// macOS puts temp under /var, a symlink to /private/var; the terminal (rightly) refuses
    /// folders reached through a link, so tests use the real path. Windows temp has no link.
    private static string Create()
    {
        var path = Directory.CreateDirectory(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "wiqo-test-" + Guid.NewGuid().ToString("N"))).FullName;
        return OperatingSystem.IsMacOS() && path.StartsWith("/var/", StringComparison.Ordinal) ? "/private" + path : path;
    }

    public string File(string name, string content)
    {
        var path = System.IO.Path.Combine(Path, name);
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        System.IO.File.WriteAllText(path, content);
        return path;
    }

    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); } catch { }
    }
}

internal static class Grants
{
    public const string Token = "wiqo-test-pairing-token-0123456789abcdef";

    /// A grant signed exactly like the phone signs it (RovaTerminalPolicy.signGrant).
    public static object Signed(string root, string mode = "full", long? expiresAt = null)
    {
        var id = Guid.NewGuid().ToString();
        var expiry = expiresAt ?? DateTimeOffset.UtcNow.AddMinutes(30).ToUnixTimeSeconds();
        var message = $"wiqo-terminal-grant:v1:{id}:{root}:{mode}:{expiry}";
        var signature = Convert.ToHexString(HMACSHA256.HashData(Encoding.UTF8.GetBytes(Token), Encoding.UTF8.GetBytes(message))).ToLowerInvariant();
        return new { id, rootDirectory = root, mode, expiresAt = expiry, signature };
    }

    public static JsonElement Request(object value) => JsonSerializer.SerializeToElement(value);
}
