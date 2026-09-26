using System.Text.Json;

namespace RovaWindows;

public sealed record CapabilityGroup(string Id, string Title, IReadOnlyList<string> Capabilities);

/// Which capability groups the user turned off (RovaMac/CapabilitySettings.swift). Everything
/// Windows implements is on by default; a group turned off is neither advertised nor executed.
/// The terminal session has its own switch, like "Kod Çalıştırma" on the Mac.
public sealed class CapabilitySettings
{
    public const string TerminalKey = "terminal";

    public static readonly IReadOnlyList<CapabilityGroup> Groups = new CapabilityGroup[]
    {
        new("apps", "Uygulamalar", ["device.app.open", "device.app.open_by_name", "device.app.quit", "device.app.control", "device.app.list"]),
        new("system", "Sistem kontrolü", ["device.system.power", "device.display", "device.audio", "device.media"]),
        new("files", "Dosyalar", ["device.files.list", "device.files.read", "device.files.write", "device.files.move", "device.files.copy", "device.files.delete"]),
        new("documents", "Belgeler", ["document.read", "document.edit", "artifact.save"]),
        new("screen", "Ekran", ["device.screen.capture", "device.screen.click", "device.ui.control"]),
        new("clipboard", "Pano", ["device.clipboard"]),
        new("web", "Bağlantılar", ["device.url.open"])
    }.Select(group => group with { Capabilities = group.Capabilities.Where(WindowsCapabilityManifest.Capabilities.Contains).ToArray() })
     .Where(group => group.Capabilities.Count > 0).ToArray();

    private readonly string path;
    private readonly object gate = new();
    private HashSet<string> disabled;

    public event Action? Changed;

    public CapabilitySettings(string? path = null)
    {
        this.path = path ?? Path.Combine(WindowsPaths.RoamingDirectory, "capabilities.json");
        disabled = Load(this.path);
    }

    public bool IsEnabled(string capability)
    {
        if (capability == "runtime.status") return true;
        lock (gate) return !disabled.Contains(capability);
    }

    public bool TerminalEnabled
    {
        get { lock (gate) return !disabled.Contains(TerminalKey); }
        set => Set(TerminalKey, value);
    }

    public bool IsGroupEnabled(CapabilityGroup group) => group.Capabilities.All(IsEnabled);

    public void SetGroup(CapabilityGroup group, bool enabled)
    {
        lock (gate)
        {
            foreach (var capability in group.Capabilities)
            {
                if (enabled) disabled.Remove(capability); else disabled.Add(capability);
            }
            Save();
        }
        Changed?.Invoke();
    }

    private void Set(string key, bool enabled)
    {
        lock (gate)
        {
            if (enabled) disabled.Remove(key); else disabled.Add(key);
            Save();
        }
        Changed?.Invoke();
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temporary = path + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(new { disabled = disabled.Order(StringComparer.Ordinal).ToArray() }));
            File.Move(temporary, path, true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static HashSet<string> Load(string path)
    {
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            return document.RootElement.GetProperty("disabled").EnumerateArray().Select(item => item.GetString() ?? "").Where(item => item.Length > 0).ToHashSet(StringComparer.Ordinal);
        }
        catch { return new HashSet<string>(StringComparer.Ordinal); }
    }
}
