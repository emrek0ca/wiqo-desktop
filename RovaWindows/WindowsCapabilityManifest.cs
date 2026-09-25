namespace RovaWindows;

/// The Windows companion only advertises operations implemented by this adapter. The backend
/// already filters model-facing tools by this list, so an unsupported Mac operation cannot be
/// routed here accidentally.
public static class WindowsCapabilityManifest
{
    public const int Version = 1;

    public static readonly IReadOnlySet<string> Capabilities = new HashSet<string>(StringComparer.Ordinal)
    {
        "runtime.status",
        "device.url.open",
        "device.app.list",
        "device.files.list",
        "device.files.read"
    };

    public static readonly IReadOnlySet<string> Operations = new HashSet<string>(StringComparer.Ordinal)
    {
        "ping",
        "getSystemStatus",
        "openURL",
        "listRunningApplications",
        "searchFiles",
        "sendFileToPhone"
    };

    public static string CapabilityFor(string operation) => operation switch
    {
        "ping" or "getSystemStatus" => "runtime.status",
        "openURL" => "device.url.open",
        "listRunningApplications" => "device.app.list",
        "searchFiles" => "device.files.list",
        "sendFileToPhone" => "device.files.read",
        _ => ""
    };
}
