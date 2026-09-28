using System.Text.Json;
using System.Text.RegularExpressions;
using System.Net;

namespace RovaWindows;

/// Payload rules of RovaValidation.validate (Mac), with Windows paths. Fail closed: an operation
/// runs only after its payload passed exactly these checks.
public static class WindowsValidation
{
    private static readonly HashSet<string> NoPayload = new(StringComparer.Ordinal)
    {
        "getSystemStatus", "ping", "lockMac", "sleepMac", "displaySleep", "toggleMute", "listDesktopFiles",
        "getClipboardText", "getClipboardHistory", "listRunningApplications"
    };

    public static WireError? Validate(string operation, JsonElement payload)
    {
        if (NoPayload.Contains(operation))
            return PayloadReader.Kind(payload) is "none" or "" ? null : Invalid("Bu komut payload kabul etmiyor.");
        switch (operation)
        {
            case "openApplication":
            case "quitApplication":
                return PayloadReader.String(payload, "application") is { Length: > 0 and <= 80 } ? null : Invalid("Uygulama seçimi geçersiz.");
            case "openApplicationByName":
                return IsSafeText(PayloadReader.String(payload, "applicationQuery"), 200) ? null : Invalid("Uygulama arama adı geçersiz.");
            case "controlApplication":
                var control = PayloadReader.Object<ApplicationControlPayload>(payload, "applicationControl");
                return control is not null && control.Action is "open" or "activate" or "quit" && IsSafeText(control.Target, 200) && (!control.Force || control.Action == "quit")
                    ? null : Invalid("Uygulama eylemi veya hedefi geçersiz.", "validation");
            case "openURL":
                return IsAllowedUrl(PayloadReader.String(payload, "url")) ? null : new WireError("INVALID_URL", "Yalnızca geçerli http veya https URL'leri açılabilir.", "validation");
            case "setVolume":
                return PayloadReader.Integer(payload, "volume") is >= 0 and <= 100 ? null : Invalid("Ses seviyesi 0 ile 100 arasında olmalıdır.");
            case "setBrightness":
                return PayloadReader.Integer(payload, "brightness") is >= 0 and <= 100 ? null : Invalid("Parlaklık 0 ile 100 arasında olmalıdır.");
            case "setClipboardText":
                return PayloadReader.String(payload, "clipboardText") is { Length: > 0 and <= 10_000 } ? null : Invalid("Pano metni 1 ile 10.000 karakter arasında olmalıdır.");
            case "mediaControl":
                return PayloadReader.String(payload, "media") is "playPause" or "nextTrack" or "previousTrack" ? null : Invalid("Medya komutu geçersiz.");
            case "saveTextFile":
                var file = PayloadReader.Object<TextFilePayload>(payload, "textFile");
                return file is not null && IsValidDesktopFilename(file.Filename) && file.Content.Length is > 0 and <= 200_000 ? null : Invalid("Dosya adı veya içeriği geçersiz.");
            case "readDesktopFile":
                return IsValidDesktopFilename(PayloadReader.String(payload, "fileName")) ? null : Invalid("Okunacak dosya adı geçersiz.");
            case "moveDesktopFile":
            case "renameDesktopFile":
                var move = PayloadReader.Object<FileMovePayload>(payload, "fileMove");
                return move is not null && IsValidDesktopFilename(move.Source) && IsValidDesktopFilename(move.Destination) && move.Source != move.Destination
                    ? null : Invalid("Kaynak veya hedef dosya adı geçersiz.");
            case "saveArtifact":
                var artifact = PayloadReader.Object<ArtifactFilePayload>(payload, "artifactFile");
                return artifact is not null && IsValidDesktopFilename(artifact.Filename) &&
                       Regex.IsMatch(artifact.ArtifactId, "^[0-9a-f-]{20,128}$") &&
                       artifact.MimeType.Length <= 160 && !artifact.MimeType.Any(char.IsWhiteSpace) &&
                       artifact.ByteCount is null or > 0 and <= 25 * 1024 * 1024 &&
                       (artifact.Sha256 is null || Regex.IsMatch(artifact.Sha256, "^[0-9a-fA-F]{64}$")) &&
                       IsAllowedArtifactUrl(artifact.DownloadUrl)
                    ? null : Invalid("Artifact kaydetme isteği geçersiz.");
            case "listFiles":
            case "readFile":
                var read = PayloadReader.Object<LocalFileOperationPayload>(payload, "fileOperation");
                return read is not null && IsValidLocalPath(read.Path) && read.Page is >= 0 and <= 10_000 && read.PageSize is > 0 and <= 500
                    ? null : Invalid("Dosya yolu veya listeleme aralığı geçersiz.");
            case "sendFileToPhone":
            case "deleteFile":
                var target = PayloadReader.Object<LocalFileOperationPayload>(payload, "fileOperation");
                return target is not null && IsValidLocalPath(target.Path) ? null : Invalid("Dosya yolu geçersiz.");
            case "searchFiles":
                var search = PayloadReader.Object<FileSearchPayload>(payload, "fileSearch");
                return search is not null && IsSafeText(search.Query, 120) && (search.Cursor is null || Guid.TryParse(search.Cursor, out _))
                    ? null : Invalid("Dosya arama isteği geçersiz.");
            case "writeFile":
                var write = PayloadReader.Object<LocalFileOperationPayload>(payload, "fileOperation");
                return write is not null && IsValidLocalPath(write.Path) && write.Content is { Length: <= 500_000 } content && !content.Contains('\0')
                    ? null : Invalid("Dosya yazma isteği geçersiz.");
            case "moveFile":
            case "copyFile":
                var transfer = PayloadReader.Object<LocalFileOperationPayload>(payload, "fileOperation");
                return transfer is not null && IsValidLocalPath(transfer.Path) && transfer.Destination is { } destination && IsValidLocalPath(destination) &&
                       !string.Equals(transfer.Path, destination, StringComparison.OrdinalIgnoreCase)
                    ? null : Invalid("Kaynak veya hedef dosya yolu geçersiz.");
            case "captureScreen":
                var capture = PayloadReader.Object<ScreenCapturePayload>(payload, "screenCapture");
                return capture is not null && capture.MaxWidth is >= 400 and <= 2_400 ? null : Invalid("Ekran görüntüsü ayarları geçersiz.");
            case "computerBrowser":
                var browser = PayloadReader.Object<ComputerBrowserPayload>(payload, "computerBrowser");
                return browser is not null && IsValidBrowserPayload(browser) ? null : Invalid("Tarayıcı işlemi geçersiz.", "validation");
            case "endBrowserTask":
                var browserTask = PayloadReader.Object<BrowserTaskPayload>(payload, "browserTask");
                return browserTask is not null && Guid.TryParse(browserTask.TaskId, out _) ? null : Invalid("Tarayıcı görevi geçersiz.", "validation");
            default:
                return Invalid("Bu işlem Windows'ta desteklenmiyor.");
        }
    }

    public static bool IsValidDesktopFilename(string? name)
    {
        var trimmed = name?.Trim() ?? "";
        if (trimmed.Length is 0 or > 255 || trimmed is "." or "..") return false;
        return !trimmed.Contains('/') && !trimmed.Contains('\\') && !trimmed.Any(character => character < 32 || character == 127) &&
               trimmed.IndexOfAny(Path.GetInvalidFileNameChars().Concat(['<', '>', ':', '"', '|', '?', '*']).ToArray()) < 0 &&
               !IsReservedDeviceName(trimmed);
    }

    /// "C:\Users\Ada\x.txt" (or "~\x.txt"): drive-rooted, no "..", no UNC shares or device paths.
    public static bool IsValidLocalPath(string? rawPath)
    {
        var path = rawPath?.Trim() ?? "";
        if (path.Length is < 2 or > 2_048 || path.Contains('\0') || path.Any(char.IsControl)) return false;
        if (path.StartsWith("~\\", StringComparison.Ordinal) || path.StartsWith("~/", StringComparison.Ordinal)) path = "C:\\" + path[2..];
        if (!Regex.IsMatch(path, @"^[A-Za-z]:[\\/]")) return false;
        var parts = path[3..].Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries);
        return !parts.Any(part => part is ".." or "." || part.IndexOfAny(['<', '>', ':', '"', '|', '?', '*']) >= 0 || IsReservedDeviceName(part));
    }

    public static bool IsAllowedUrl(string? raw)
    {
        if (raw is null || raw.Length > 2_048 || raw.Any(character => char.IsControl(character) || (char.IsWhiteSpace(character) && character != ' '))) return false;
        return Uri.TryCreate(raw, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https" && uri.Host.Length > 0 && uri.UserInfo.Length == 0;
    }

    private static bool IsValidBrowserPayload(ComputerBrowserPayload value)
    {
        if (!Guid.TryParse(value.TaskId, out _)) return false;
        var hasRef = value.TargetRef is { Length: <= 48 } targetRef && Regex.IsMatch(targetRef, @"^p\d+-t\d+$");
        var hasLegacyTarget = (value.TargetBy is "role" or "label" or "placeholder")
            && IsSafeText(value.Target, 200)
            && (value.TargetBy != "role" || value.Role is "button" or "link" or "textbox" or "searchbox" or "checkbox" or "radio" or "combobox" or "option" or "tab" or "menuitem" or "heading")
            && (value.TargetBy == "role" || value.Role is null);
        var hasTarget = hasRef ^ hasLegacyTarget;
        var noTarget = value.TargetRef is null && value.TargetBy is null && value.Target is null && value.Role is null;
        var noValue = value.Value is null;
        var noDirection = value.Direction is null;
        var noUrl = value.Url is null;

        return value.Action switch
        {
            "navigate" => IsPublicBrowserUrl(value.Url) && noTarget && noValue && noDirection && value.ScrollAmount is null,
            "observe" or "back" => noUrl && noTarget && noValue && noDirection && value.ScrollAmount is null,
            "scroll" => noUrl && noTarget && noValue && (value.Direction is "up" or "down") && (value.ScrollAmount is null or >= 1 and <= 3),
            "click" or "submit" => noUrl && hasTarget && noValue && noDirection && value.ScrollAmount is null,
            "fill" or "select" => noUrl && hasTarget && value.Value is { Length: > 0 and <= 2_000 } fillValue && !fillValue.Contains('\0') && noDirection && value.ScrollAmount is null,
            _ => false
        };
    }

    private static bool IsPublicBrowserUrl(string? raw)
    {
        if (!IsAllowedUrl(raw) || !Uri.TryCreate(raw, UriKind.Absolute, out var uri)) return false;
        if (uri.Port != (uri.Scheme == "https" ? 443 : 80)) return false;
        var host = uri.IdnHost.TrimEnd('.').ToLowerInvariant();
        if (IPAddress.TryParse(host, out _) || !host.Contains('.') || host.Contains('%')) return false;
        return host != "localhost" && !host.EndsWith(".localhost", StringComparison.Ordinal)
            && !host.EndsWith(".local", StringComparison.Ordinal)
            && !host.EndsWith(".internal", StringComparison.Ordinal)
            && !host.EndsWith(".test", StringComparison.Ordinal)
            && !host.EndsWith(".invalid", StringComparison.Ordinal);
    }

    /// Artifacts come only from the Wiqo backend (the canonical host, plus the legacy one).
    public static bool IsAllowedArtifactUrl(string? raw) =>
        IsAllowedUrl(raw) && Uri.TryCreate(raw, UriKind.Absolute, out var uri) && uri.Scheme == "https" &&
        uri.Host.ToLowerInvariant() is "api.wiqoai.com" or "84-247-172-213.sslip.io";

    private static bool IsSafeText(string? value, int maxLength) =>
        value is { Length: > 0 } && value.Length <= maxLength && !value.Any(character => character is '\n' or '\r' or '\0' or '\u2028' or '\u2029');

    private static bool IsReservedDeviceName(string name)
    {
        var stem = name.Split('.')[0].TrimEnd(' ').ToUpperInvariant();
        return stem is "CON" or "PRN" or "AUX" or "NUL" || Regex.IsMatch(stem, "^(COM|LPT)[1-9]$");
    }

    private static WireError Invalid(string message, string category = "validation") => new("INVALID_PAYLOAD", message, category);
}
