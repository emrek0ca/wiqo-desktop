using System.Text.Json;
using RovaWindows.Operations;
using RovaWindows.Terminal;

namespace RovaWindows;

/// CommandResult on the wire (RovaShared/Protocol.swift): data is { kind, value }, error is a
/// WireError { code, message, category }.
public sealed record WindowsCommandResult(
    string CommandId,
    string Status,
    string Message,
    DateTimeOffset StartedAt,
    DateTimeOffset FinishedAt,
    object? Data = null,
    object? Error = null);

/// Runs signed commands on Windows the way MacCommandEngine does on the Mac: a command id runs
/// at most once (the ledger survives restarts), only operations this build implements and the user
/// left enabled run, every payload is validated first, read-only work runs concurrently while side
/// effects are serialized, and each operation has the Mac's deadline. No UI dependency: a tray app,
/// a service or a test can host it.
public sealed class WindowsRuntime : IAsyncDisposable
{
    private readonly CapabilitySettings settings;
    private readonly ResultLedger ledger;
    private readonly SemaphoreSlim sideEffectLane = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(60) };
    private readonly int queueCapacity;
    private int queued;
    private string? pairingToken;
    private Func<string, string, CancellationToken, Task<string?>>? fileUploader;
    private Func<CancellationToken, Task<string?>>? accessToken;

    public WindowsRuntime(CapabilitySettings? settings = null, ResultLedger? ledger = null, int queueCapacity = 64)
    {
        if (queueCapacity < 1) throw new ArgumentOutOfRangeException(nameof(queueCapacity));
        this.settings = settings ?? new CapabilitySettings();
        this.ledger = ledger ?? new ResultLedger();
        this.queueCapacity = queueCapacity;
        Terminal = new WindowsTerminal(() => pairingToken, () => this.settings.TerminalEnabled);
    }

    public string DeviceId { get; } = LoadDeviceId();
    public string DisplayName => Environment.MachineName;
    public string? PairingToken => pairingToken;
    public CapabilitySettings Settings => settings;
    public ResultLedger Ledger => ledger;
    public WindowsTerminal Terminal { get; }

    /// "ready" while connected; the tray host reports it in getSystemStatus like the Mac does.
    public string RuntimeStatus { get; set; } = "ready";

    public void SetPairingToken(string? token) => pairingToken = string.IsNullOrWhiteSpace(token) ? null : token;
    public void ConfigureFileUploader(Func<string, string, CancellationToken, Task<string?>> uploader) => fileUploader = uploader;
    public void ConfigureAccessToken(Func<CancellationToken, Task<string?>> provider) => accessToken = provider;

    /// Terminal sessions need the pairing token (the phone signs grants with it) and the switch on.
    public IReadOnlyList<string> Features => pairingToken is not null && settings.TerminalEnabled
        ? [WindowsTerminal.FeatureV1, WindowsTerminal.FeatureV2]
        : [];

    public IReadOnlyList<string> Capabilities => WindowsCapabilityManifest.Capabilities
        .Where(settings.IsEnabled)
        .Order(StringComparer.Ordinal).ToArray();

    public object[] Authorities => Capabilities.Select(capability =>
    {
        var (name, access) = WindowsCapabilityManifest.Authorities.TryGetValue(capability, out var known) ? known : (capability, "confirmation");
        return (object)new { capability, displayName = name, access, requiredPermissions = Array.Empty<string>(), message = "" };
    }).ToArray();

    public async Task<WindowsCommandResult> ExecuteAsync(string commandId, string operation, JsonElement payload, CancellationToken cancellationToken = default, bool unattended = false)
    {
        var started = DateTimeOffset.UtcNow;
        if (ledger.Find(commandId) is { } previous)
            return new WindowsCommandResult(commandId, previous.Status, previous.Message, previous.FinishedAt, previous.FinishedAt, null, previous.Error);
        if (!WindowsCapabilityManifest.Operations.Contains(operation))
            return Finish(Denied(commandId, started, "UNSUPPORTED_OPERATION", "Bu işlem Windows'ta desteklenmiyor."));
        var capability = WindowsCapabilityManifest.CapabilityFor(operation);
        if (!settings.IsEnabled(capability))
            return Finish(Denied(commandId, started, "CAPABILITY_DISABLED", "Bu yetenek Wiqo Windows ayarlarında kapalı."));
        if (unattended && !OperationCatalog.PermitsUnattended(operation))
            return Finish(Denied(commandId, started, "AUTOMATION_STEP_BLOCKED", "Bu otomasyon adımı kullanıcı onayı gerektiriyor."));
        if (WindowsValidation.Validate(operation, payload) is { } invalid)
            return Finish(new WindowsCommandResult(commandId, "denied", invalid.Message, started, DateTimeOffset.UtcNow, null, invalid));

        if (Interlocked.Increment(ref queued) > queueCapacity)
        {
            Interlocked.Decrement(ref queued);
            return new WindowsCommandResult(commandId, "failed", "Windows işlem kuyruğu dolu; bu komut henüz çalıştırılmadı.", started, DateTimeOffset.UtcNow, null,
                new WireError("DEVICE_BUSY", "Windows işlem kuyruğu dolu; lütfen biraz sonra tekrar deneyin.", "retryable"));
        }
        var readOnly = OperationCatalog.IsReadOnlyLane(operation);
        try
        {
            if (!readOnly) await sideEffectLane.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                if (!readOnly) ledger.RecordRunning(commandId);
                using var linked = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token, cancellationToken);
                linked.CancelAfter(OperationCatalog.Timeout(operation));
                // Blocking Win32/COM calls run off the caller's thread; the deadline still applies.
                var work = Task.Run(() => PerformAsync(commandId, operation, payload, linked.Token), CancellationToken.None);
                var finished = await Task.WhenAny(work, Task.Delay(OperationCatalog.Timeout(operation) + TimeSpan.FromSeconds(1), CancellationToken.None)).ConfigureAwait(false);
                Outcome outcome;
                if (finished != work)
                {
                    outcome = Outcome.Fail("COMMAND_TIMEOUT", "Komut zaman aşımına uğradı; sonucu doğrulanamadığı için tekrar çalıştırılmadı.", "timeout");
                }
                else
                {
                    try { outcome = await work.ConfigureAwait(false); }
                    catch (OperationCanceledException) { outcome = Outcome.Fail("COMMAND_TIMEOUT", "Komut zaman aşımına uğradı; sonucu doğrulanamadığı için tekrar çalıştırılmadı.", "timeout"); }
                    catch (Exception) { outcome = Outcome.Fail("EXECUTION_FAILED", "Windows işlemi beklenmeyen bir hatayla tamamlanamadı."); }
                }
                var status = outcome.Error is null ? "completed" : outcome.Error.Category == "timeout" ? "unknown" : "failed";
                return Finish(new WindowsCommandResult(commandId, status, outcome.Message, started, DateTimeOffset.UtcNow, outcome.Data, outcome.Error));
            }
            finally
            {
                if (!readOnly) sideEffectLane.Release();
            }
        }
        finally
        {
            Interlocked.Decrement(ref queued);
        }
    }

    private async Task<Outcome> PerformAsync(string commandId, string operation, JsonElement payload, CancellationToken cancellationToken)
    {
        switch (operation)
        {
            case "ping": return SystemOperations.Ping();
            case "getSystemStatus": return SystemOperations.Status(RuntimeStatus);
            case "openURL":
                var url = PayloadReader.String(payload, "url")!;
                using (var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(new Uri(url).AbsoluteUri) { UseShellExecute = true })) { }
                return Outcome.Ok("URL açıldı.");
            case "listRunningApplications": return ApplicationOperations.ListRunning();
            case "openApplication": return await ApplicationOperations.OpenById(PayloadReader.String(payload, "application")!, cancellationToken).ConfigureAwait(false);
            case "openApplicationByName": return await ApplicationOperations.OpenByName(PayloadReader.String(payload, "applicationQuery")!, cancellationToken).ConfigureAwait(false);
            case "controlApplication": return await ApplicationOperations.Control(PayloadReader.Object<ApplicationControlPayload>(payload, "applicationControl")!, cancellationToken).ConfigureAwait(false);
            case "quitApplication": return await ApplicationOperations.QuitById(PayloadReader.String(payload, "application")!, cancellationToken).ConfigureAwait(false);
            case "lockMac": return SystemOperations.Lock();
            case "sleepMac": return SystemOperations.Sleep();
            case "displaySleep": return SystemOperations.DisplaySleep();
            case "setVolume": return SystemOperations.SetVolume(PayloadReader.Integer(payload, "volume")!.Value);
            case "toggleMute": return SystemOperations.ToggleMute();
            case "mediaControl": return SystemOperations.Media(PayloadReader.String(payload, "media")!);
            case "setClipboardText": return SystemOperations.SetClipboard(PayloadReader.String(payload, "clipboardText")!);
            case "getClipboardText": return SystemOperations.GetClipboard();
            case "captureScreen": return SystemOperations.Screenshot(PayloadReader.Object<ScreenCapturePayload>(payload, "screenCapture")!.MaxWidth);
            case "saveTextFile": return FileOperations.SaveTextFile(PayloadReader.Object<TextFilePayload>(payload, "textFile")!);
            case "listDesktopFiles": return FileOperations.ListDesktop();
            case "readDesktopFile": return FileOperations.ReadDesktop(PayloadReader.String(payload, "fileName")!);
            case "moveDesktopFile":
            case "renameDesktopFile":
                return FileOperations.MoveDesktop(PayloadReader.Object<FileMovePayload>(payload, "fileMove")!, operation == "renameDesktopFile");
            case "listFiles": return FileOperations.List(FileOperation(payload));
            case "readFile": return FileOperations.Read(FileOperation(payload));
            case "writeFile": return FileOperations.Write(FileOperation(payload));
            case "moveFile": return FileOperations.Transfer(FileOperation(payload), copy: false);
            case "copyFile": return FileOperations.Transfer(FileOperation(payload), copy: true);
            case "deleteFile": return FileOperations.Delete(FileOperation(payload));
            case "searchFiles": return FileSearch.Search(PayloadReader.Object<FileSearchPayload>(payload, "fileSearch")!, cancellationToken);
            case "sendFileToPhone":
                if (FileOperations.ValidateTransferSource(FileOperation(payload), out var path) is { } invalid) return invalid;
                if (fileUploader is null) return Outcome.Fail("TRANSFER_UNAVAILABLE", "PC aktarım bağlantısı hazır değil.");
                var artifactId = await fileUploader(path, commandId, cancellationToken).ConfigureAwait(false);
                return artifactId is null
                    ? Outcome.Fail("TRANSFER_FAILED", "Dosya telefona iletilemedi.", "network")
                    : Outcome.WithData("fileTransfer", artifactId, "Dosya telefona gönderildi.");
            case "saveArtifact":
                if (accessToken is null) return Outcome.Fail("BACKEND_AUTH_REQUIRED", "Artifact indirmek için Wiqo oturumu gerekli.");
                return await FileOperations.SaveArtifact(PayloadReader.Object<ArtifactFilePayload>(payload, "artifactFile")!, accessToken, http, cancellationToken).ConfigureAwait(false);
            default:
                return Outcome.Fail("UNSUPPORTED_OPERATION", "Bu işlem Windows'ta desteklenmiyor.");
        }
    }

    private static LocalFileOperationPayload FileOperation(JsonElement payload) => PayloadReader.Object<LocalFileOperationPayload>(payload, "fileOperation")!;

    private WindowsCommandResult Finish(WindowsCommandResult result)
    {
        ledger.Record(result);
        return result;
    }

    private static WindowsCommandResult Denied(string commandId, DateTimeOffset started, string code, string message) =>
        new(commandId, "denied", message, started, DateTimeOffset.UtcNow, null, new WireError(code, message, "permission"));

    private static string LoadDeviceId()
    {
        try
        {
            Directory.CreateDirectory(WindowsPaths.RoamingDirectory);
            var path = Path.Combine(WindowsPaths.RoamingDirectory, "device-id");
            if (File.Exists(path) && File.ReadAllText(path).Trim() is { Length: > 0 } stored && Guid.TryParse(stored, out _)) return stored;
            var id = Guid.NewGuid().ToString();
            File.WriteAllText(path, id);
            return id;
        }
        catch
        {
            // A locked-down profile must not crash the companion; the next launch retries.
            return Guid.NewGuid().ToString();
        }
    }

    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        await Terminal.DisposeAsync().ConfigureAwait(false);
        http.Dispose();
        sideEffectLane.Dispose();
        lifetime.Dispose();
    }
}
