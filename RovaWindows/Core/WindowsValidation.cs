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
                return search is not null && IsValidSearch(search) ? null : Invalid("Dosya arama isteği geçersiz.");
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
                return capture is not null && capture.MaxWidth is >= 400 and <= 2_400
                    && (capture.TargetApplication is null || IsSafeText(capture.TargetApplication, 200))
                    ? null : Invalid("Ekran görüntüsü ayarları geçersiz.");
            case "computerDesktop":
                var desktop = PayloadReader.Object<ComputerDesktopPayload>(payload, "computerDesktop");
                return desktop is not null && IsValidDesktopPayload(desktop) ? null : Invalid("Masaüstü işlemi geçersiz.", "validation");
            case "computerBrowser":
                var browser = PayloadReader.Object<ComputerBrowserPayload>(payload, "computerBrowser");
                return browser is not null && IsValidBrowserPayload(browser) ? null : Invalid("Tarayıcı işlemi geçersiz.", "validation");
            case "endBrowserTask":
                var browserTask = PayloadReader.Object<BrowserTaskPayload>(payload, "browserTask");
                return browserTask is not null && Guid.TryParse(browserTask.TaskId, out _) ? null : Invalid("Tarayıcı görevi geçersiz.", "validation");
            case "localAnalyze":
                var analysis = PayloadReader.Object<LocalAnalysisPayload>(payload, "localAnalysis");
                return analysis is not null && IsValidLocalAnalysis(analysis) ? null : Invalid("Yerel analiz isteği geçersiz.", "validation");
            default:
                return Invalid("Bu işlem Windows'ta desteklenmiyor.");
        }
    }

    private static bool IsValidLocalAnalysis(LocalAnalysisPayload value)
    {
        if (value.Limit is < 1 or > 500 || value.Variables is { Length: > 12 }
            || (value.Variables?.Any(item => !Regex.IsMatch(item, "^[A-Za-z][A-Za-z0-9]{0,31}$")) ?? false)) return false;
        return value.Action switch
        {
            "dependencyStatus" => value.Path is null && value.Query is null && value.Expression is null && value.Variables is null,
            "extractDocument" => IsValidLocalPath(value.Path) && value.Query is null && value.Expression is null && value.Variables is null,
            "queryData" => IsValidLocalPath(value.Path) && IsSafeReadOnlyQuery(value.Query) && value.Expression is null && value.Variables is null,
            "solveSymbolic" => value.Path is null && value.Query is null && IsSafeSymbolicExpression(value.Expression),
            "workspaceDiff" => IsValidLocalPath(value.Path) && value.Query is null && value.Expression is null && value.Variables is null,
            _ => false
        };
    }

    private static bool IsSafeReadOnlyQuery(string? value)
    {
        var query = value?.Trim() ?? "";
        return query.Length is > 0 and <= 8_000 && !query.Contains(';') && !query.Contains('\0')
            && Regex.IsMatch(query, "^(SELECT|WITH)\\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)
            && !Regex.IsMatch(query, "\\b(ATTACH|COPY|CREATE|DELETE|DROP|EXPORT|IMPORT|INSERT|INSTALL|LOAD|PRAGMA|UPDATE|CALL|READ_[A-Z0-9_]*|[A-Z0-9_]*SCAN|HTTPFS|SQLITE|POSTGRES|GLOB|SECRET)\\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    }

    private static bool IsSafeSymbolicExpression(string? value)
    {
        var expression = value?.Trim() ?? "";
        return expression.Length is > 0 and <= 2_000 && !expression.Contains("__", StringComparison.Ordinal)
            && Regex.IsMatch(expression, "^[A-Za-z0-9+*/^=(), \\t.-]+$", RegexOptions.CultureInvariant);
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

    private static readonly HashSet<string> SearchKinds = ["pdf", "document", "spreadsheet", "presentation", "image", "text", "archive", "audio", "video", "folder"];

    /// Mirrors RovaValidation's searchFiles rule: a query may be empty when a filter says enough.
    private static bool IsValidSearch(FileSearchPayload search)
    {
        var hasFilter = search.Kind is not null || search.ModifiedWithinDays is not null || search.Folder is not null;
        return (search.Query.Length == 0 || IsSafeText(search.Query, 120))
            && (search.Query.Trim().Length > 0 || hasFilter)
            && (search.Cursor is null || Guid.TryParse(search.Cursor, out _) || Regex.IsMatch(search.Cursor, @"^o:\d{1,5}$"))
            && (search.Folder is null || IsValidLocalPath(search.Folder))
            && (search.Kind is null || SearchKinds.Contains(search.Kind))
            && (search.ModifiedWithinDays is null or >= 1 and <= 3650)
            && (search.Sort is null or "recent" or "relevance");
    }

    private static bool IsValidBrowserPayload(ComputerBrowserPayload value)
    {
        if (!Guid.TryParse(value.TaskId, out _)) return false;
        if (value.Action == "run_steps")
            return value.Url is null && value.TargetRef is null && value.TargetBy is null && value.Target is null && value.Role is null
                && value.Value is null && value.Direction is null && value.ScrollAmount is null && value.Submit is null
                && value.Key is null && value.Offset is null && value.Steps is { Length: >= 1 and <= 8 }
                && value.Steps.All(IsValidBrowserStep);
        if (value.Steps is not null) return false;
        return IsValidBrowserAction(value.Action, value.Url, value.TargetRef, value.TargetBy, value.Target, value.Role,
            value.Value, value.Direction, value.ScrollAmount, value.Submit, value.Key, value.Offset);
    }

    private static bool IsValidBrowserStep(ComputerBrowserStep value) =>
        value.Action != "download" && IsValidBrowserAction(value.Action, value.Url, value.TargetRef, value.TargetBy, value.Target, value.Role,
            value.Value, value.Direction, value.ScrollAmount, value.Submit, value.Key, value.Offset);

    private static bool IsValidBrowserAction(string action, string? url, string? targetRef, string? targetBy,
        string? target, string? role, string? value, string? direction, int? scrollAmount, bool? submit,
        string? key, int? offset)
    {
        var hasRef = targetRef is { Length: <= 48 } candidate && IsBrowserTargetRef(candidate);
        var hasLegacyTarget = (targetBy is "role" or "label" or "placeholder")
            && IsSafeText(target, 240)
            && (targetBy != "role" || role is "button" or "link" or "textbox" or "searchbox" or "checkbox" or "radio" or "combobox" or "option" or "tab" or "menuitem" or "heading")
            && (targetBy == "role" || role is null);
        // A current target ref wins over redundant legacy locator metadata from mixed versions.
        var hasTarget = hasRef || (!hasRef && hasLegacyTarget);
        var noTarget = targetRef is null && targetBy is null && target is null && role is null;
        var noValue = value is null;
        var noDirection = direction is null;
        var noUrl = url is null;

        if (submit is not null && action != "fill") return false;
        if (key is not null && action != "press") return false;
        if (offset is not null && (action != "read" || offset is < 0 or > 2_000_000)) return false;
        return action switch
        {
            "handoff" => IsPublicBrowserUrl(url) && noTarget && noValue && noDirection && scrollAmount is null && submit is null && key is null && offset is null,
            "read" => noUrl && noTarget && noValue && noDirection && scrollAmount is null,
            "press" => noUrl && noTarget && noValue && noDirection && scrollAmount is null && key is "Enter" or "Escape" or "Tab" or "ArrowDown" or "ArrowUp",
            "navigate" => IsPublicBrowserUrl(url) && noTarget && noValue && noDirection && scrollAmount is null,
            "observe" or "observe_diff" or "back" => noUrl && noTarget && noValue && noDirection && scrollAmount is null,
            "scroll" => noUrl && noTarget && noValue && (direction is "up" or "down") && (scrollAmount is null or >= 1 and <= 3),
            "click" or "download" => noUrl && hasTarget && noValue && noDirection && scrollAmount is null,
            "submit" => noUrl && hasTarget && noValue && noDirection && scrollAmount is null && (hasRef || (targetBy == "role" && role == "button")),
            "fill" or "select" => noUrl && hasTarget && value is { Length: <= 2_000 } fillValue && !fillValue.Contains('\0') && noDirection && scrollAmount is null,
            _ => false
        };
    }

    private static bool IsValidDesktopPayload(ComputerDesktopPayload value)
    {
        if (!Guid.TryParse(value.TaskId, out _) || (value.SnapshotId is not null && !Guid.TryParse(value.SnapshotId, out _))) return false;
        if (value.Action == "runSteps")
            return value.SnapshotId is null && value.TargetRef is null && value.SourceRef is null && value.DestinationRef is null
                && value.NormalizedX is null && value.NormalizedY is null && value.Direction is null && value.Amount is null
                && value.Text is null && value.Keys is null && value.Steps is { Length: >= 1 and <= 8 }
                && value.Steps.All(IsValidDesktopStep);
        if (value.Steps is not null) return false;
        return IsValidDesktopAction(value.Action, value.TargetRef, value.SourceRef, value.DestinationRef,
            value.NormalizedX, value.NormalizedY, value.Direction, value.Amount, value.Text, value.Keys, allowCancel: true);
    }

    private static bool IsValidDesktopStep(ComputerDesktopStep value) =>
        IsValidDesktopAction(value.Action, value.TargetRef, value.SourceRef, value.DestinationRef,
            value.NormalizedX, value.NormalizedY, value.Direction, value.Amount, value.Text, value.Keys, allowCancel: false);

    private static bool IsValidDesktopAction(string action, string? targetRef, string? sourceRef, string? destinationRef,
        double? normalizedX, double? normalizedY, string? direction, int? amount, string? text, string[]? keys, bool allowCancel)
    {
        bool ValidRef(string? target) => target is null || IsDesktopTargetRef(target);
        if (!ValidRef(targetRef) || !ValidRef(sourceRef) || !ValidRef(destinationRef)) return false;
        if (normalizedX is < 0 or > 1 || normalizedY is < 0 or > 1) return false;
        if ((normalizedX is null) != (normalizedY is null)) return false;
        if (text is { Length: > 4_000 } || text?.Contains('\0') == true) return false;
        var allowedKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "command", "control", "option", "alt", "shift", "a", "c", "v", "x", "z", "f", "enter", "escape", "tab", "arrowup", "arrowdown", "arrowleft", "arrowright" };
        if (keys is { Length: 0 or > 4 } || keys?.Any(key => !allowedKeys.Contains(key)) == true) return false;
        var hasTarget = targetRef is not null;
        var hasPoint = normalizedX is not null && normalizedY is not null;
        return action switch
        {
            "observe" => !hasTarget && !hasPoint && sourceRef is null && destinationRef is null && direction is null && amount is null && text is null && keys is null,
            "cancel" => allowCancel && !hasTarget && !hasPoint && sourceRef is null && destinationRef is null && direction is null && amount is null && text is null && keys is null,
            "move" or "click" or "doubleClick" or "rightClick" => hasTarget != hasPoint && sourceRef is null && destinationRef is null && direction is null && amount is null && text is null && keys is null,
            "scroll" => (direction is "up" or "down") && (amount is null or >= 1 and <= 5) && sourceRef is null && destinationRef is null && !hasPoint && text is null && keys is null,
            "dragDrop" => sourceRef is not null && destinationRef is not null && !hasTarget && !hasPoint && direction is null && amount is null && text is null && keys is null,
            "type" => hasTarget && text is not null && !hasPoint && sourceRef is null && destinationRef is null && direction is null && amount is null && keys is null,
            "hotkey" => keys is not null && !hasTarget && !hasPoint && sourceRef is null && destinationRef is null && direction is null && amount is null && text is null,
            "wait" => amount is >= 50 and <= 5_000 && !hasTarget && !hasPoint && sourceRef is null && destinationRef is null && direction is null && text is null && keys is null,
            _ => false
        };
    }

    private static bool IsBrowserTargetRef(string value) => Regex.IsMatch(value, @"^(?:p\d+-t\d+|b-[0-9a-f]{8})$", RegexOptions.IgnoreCase);
    private static bool IsDesktopTargetRef(string value) => Regex.IsMatch(value, @"^(?:d\d+-t\d+|d-[0-9a-f]{8})$", RegexOptions.IgnoreCase);

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
