using System.Reflection;
using System.Text.Json;

namespace RovaWindows;

public sealed record OperationEntry(string Operation, string PayloadKind, string Capability, bool IsDestructive, bool RequiresUserPresence, string TimeoutClass, bool Windows);

/// The shared operation catalogue (RovaShared/OperationManifest.swift, exported to
/// contracts/companion/operations.json and embedded here). Destructiveness, user presence and
/// timeout class come from the same entries the Mac uses, so the two companions cannot drift.
public static class OperationCatalog
{
    public static readonly IReadOnlyDictionary<string, OperationEntry> Entries = Load();

    /// Background automations never run private reads, UI actions or app control, even when a
    /// step claims otherwise (RovaCommandAuthority.permitsUnattended on the Mac).
    private static readonly HashSet<string> NeverUnattended = new(StringComparer.Ordinal)
    {
        "readDocument", "listFiles", "searchFiles", "readFile", "sendFileToPhone", "captureScreen",
        "controlUIElement", "clickScreen", "controlApplication", "quitApplication", "runShortcut",
        "computerDesktop", "computerBrowser", "endBrowserTask", "localAnalyze"
    };

    public static bool PermitsUnattended(string operation) =>
        Entries.TryGetValue(operation, out var entry) && !entry.IsDestructive && !entry.RequiresUserPresence && !NeverUnattended.Contains(operation);

    /// Same deadlines as MacCommandEngine.timeoutNanoseconds.
    public static TimeSpan Timeout(string operation) => operation switch
    {
        "sendFileToPhone" => TimeSpan.FromSeconds(120),
        "readDocument" or "editDocument" or "saveArtifact" or "executeCode" or "runShortcut" or "searchFiles" => TimeSpan.FromSeconds(60),
        // First use may install the pinned Playwright runtime and Chromium into LocalAppData.
        "computerBrowser" => TimeSpan.FromSeconds(120),
        "computerDesktop" => TimeSpan.FromSeconds(20),
        "localAnalyze" => TimeSpan.FromSeconds(60),
        "endBrowserTask" => TimeSpan.FromSeconds(5),
        "listDesktopFiles" or "readDesktopFile" or "listFiles" or "readFile" or "writeFile" or "moveFile" or "copyFile" or "deleteFile" or "saveTextFile" => TimeSpan.FromSeconds(20),
        _ => TimeSpan.FromSeconds(10)
    };

    /// Read-only operations run concurrently; everything else is serialized (MacExecutionLane).
    public static bool IsReadOnlyLane(string operation) => operation is
        "getSystemStatus" or "getClipboardText" or "getClipboardHistory" or "listDesktopFiles" or "readDesktopFile" or
        "listFiles" or "searchFiles" or "readFile" or "readDocument" or "captureScreen" or "listRunningApplications" or "localAnalyze" or "ping";

    private static IReadOnlyDictionary<string, OperationEntry> Load()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("RovaWindows.operations.json")
            ?? throw new InvalidOperationException("operations.json is not embedded.");
        using var document = JsonDocument.Parse(stream);
        var entries = new Dictionary<string, OperationEntry>(StringComparer.Ordinal);
        foreach (var item in document.RootElement.GetProperty("operations").EnumerateArray())
        {
            var operation = item.GetProperty("operation").GetString()!;
            entries[operation] = new OperationEntry(
                operation,
                item.GetProperty("payloadKind").GetString()!,
                item.GetProperty("capability").GetString()!,
                item.GetProperty("isDestructive").GetBoolean(),
                item.GetProperty("requiresUserPresence").GetBoolean(),
                item.GetProperty("timeoutClass").GetString()!,
                item.GetProperty("supportedPlatforms").EnumerateArray().Any(platform => platform.GetString() == "windows"));
        }
        return entries;
    }
}
