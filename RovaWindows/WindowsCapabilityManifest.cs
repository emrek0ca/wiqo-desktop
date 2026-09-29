namespace RovaWindows;

/// The operations this Windows companion implements. It must equal the Windows entries of the
/// shared catalogue (RovaShared/OperationManifest.swift -> windowsSupported); ParityTests and
/// contracts/companion/check.sh fail when the two drift. Apple-only operations (Calendar,
/// Reminders, Notes, Mail, Messages, Shortcuts) have no Windows counterpart here: calendar and
/// mail reach the user through the cloud connectors instead.
public static class WindowsCapabilityManifest
{
    public const int Version = 3;

    public static readonly IReadOnlySet<string> Operations = new HashSet<string>(StringComparer.Ordinal)
    {
        "ping", "getSystemStatus", "openURL", "listRunningApplications",
        "openApplication", "openApplicationByName", "controlApplication", "quitApplication",
        "lockMac", "sleepMac", "displaySleep", "setVolume", "toggleMute", "mediaControl",
        "setClipboardText", "getClipboardText",
        "saveTextFile", "listDesktopFiles", "readDesktopFile", "moveDesktopFile", "renameDesktopFile",
        "listFiles", "searchFiles", "readFile", "sendFileToPhone", "writeFile", "moveFile", "copyFile", "deleteFile",
        "saveArtifact", "captureScreen", "computerDesktop", "computerBrowser", "endBrowserTask", "localAnalyze"
    };

    public static string CapabilityFor(string operation) =>
        Operations.Contains(operation) && OperationCatalog.Entries.TryGetValue(operation, out var entry) ? entry.Capability : "";

    public static readonly IReadOnlySet<string> Capabilities = Operations.Select(CapabilityFor).Where(value => value.Length > 0).ToHashSet(StringComparer.Ordinal);

    /// The label and approval level the phone shows per capability (MacSystem.capabilityAuthorities).
    public static readonly IReadOnlyDictionary<string, (string Name, string Access)> Authorities = new Dictionary<string, (string, string)>(StringComparer.Ordinal)
    {
        ["runtime.status"] = ("Sistem durumu", "automatic"),
        ["device.url.open"] = ("Bağlantı açma", "automatic"),
        ["device.app.list"] = ("Açık uygulamalar", "automatic"),
        ["device.app.open"] = ("Uygulama açma", "automatic"),
        ["device.app.open_by_name"] = ("Uygulama açma", "automatic"),
        ["device.app.control"] = ("Uygulama açma ve odaklama", "confirmation"),
        ["device.app.quit"] = ("Uygulama kapatma", "confirmation"),
        ["device.audio"] = ("Ses kontrolü", "automatic"),
        ["device.media"] = ("Medya kontrolü", "automatic"),
        ["device.clipboard"] = ("Pano", "automatic"),
        ["device.system.power"] = ("Kilit ve uyku", "confirmation"),
        ["device.files.list"] = ("Dosya listeleme", "automatic"),
        ["device.files.read"] = ("Dosya okuma", "confirmation"),
        ["device.files.write"] = ("Dosya yazma", "confirmation"),
        ["device.files.move"] = ("Dosya taşıma", "confirmation"),
        ["device.files.copy"] = ("Dosya kopyalama", "confirmation"),
        ["device.files.delete"] = ("Dosya silme (Geri Dönüşüm Kutusu)", "confirmation"),
        ["artifact.save"] = ("Dosya kaydetme", "confirmation"),
        ["device.screen.capture"] = ("Ekran gözlemi", "confirmation"),
        ["device.desktop.control"] = ("Göreve özel masaüstü kontrolü", "confirmation"),
        ["device.browser.control"] = ("Geçici tarayıcı", "confirmation"),
        ["local.analysis"] = ("Yerel analiz", "confirmation")
    };
}
