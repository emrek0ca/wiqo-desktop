using System.Diagnostics;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.UI.Xaml;
using RovaWindows.Core;

namespace RovaWindows;

public sealed partial class MainWindow : Window
{
    private readonly WindowsRuntime runtime;

    public MainWindow()
    {
        InitializeComponent();
        runtime = new WindowsRuntime(UpdateStatus, UpdatePairingCode);
        Activated += (_, _) => runtime.Start();
        Closed += (_, _) => runtime.Stop();
    }

    private void UpdateStatus(string text)
    {
        DispatcherQueue.TryEnqueue(() => StatusText.Text = text);
    }

    private void UpdatePairingCode(string? value)
    {
        DispatcherQueue.TryEnqueue(() => _ = ApplyPairingCodeAsync(value));
    }

    private async Task ApplyPairingCodeAsync(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            PairingBorder.Visibility = Visibility.Collapsed;
            PairingImage.Source = null;
            return;
        }

        try
        {
            PairingImage.Source = await QrImageFactory.CreateAsync(value);
            PairingBorder.Visibility = Visibility.Visible;
        }
        catch
        {
            PairingBorder.Visibility = Visibility.Collapsed;
            StatusText.Text = "Eşleştirme kodu hazırlanamadı.";
        }
    }
}

internal sealed class WindowsRuntime
{
    private static readonly HttpClient pairingClient = new() { BaseAddress = new Uri("https://api.wiqoai.com/") };
    private readonly Action<string> publishStatus;
    private readonly Action<string?> publishPairingCode;
    private CancellationTokenSource? lifetime;
    private Task? connectionTask;
    private Task? pairingTask;
    private BackendRelayConnection? relay;
    private bool started;

    public WindowsRuntime(Action<string> publishStatus, Action<string?> publishPairingCode)
    {
        this.publishStatus = publishStatus;
        this.publishPairingCode = publishPairingCode;
    }

    public void Start()
    {
        if (started) return;
        started = true;
        lifetime = new CancellationTokenSource();
        publishStatus("Eşleşmeye hazır");
        _ = StartStoredConnectionAsync(lifetime.Token);
    }

    public async Task AdoptBackendTokenAsync(string token)
    {
        if (string.IsNullOrWhiteSpace(token) || lifetime is null) return;
        await SaveTokenAsync("backend-token", token, lifetime.Token).ConfigureAwait(false);
        await StartRelayAsync(token, await ReadTokenAsync("pairing-token").ConfigureAwait(false), lifetime.Token).ConfigureAwait(false);
    }

    public void Stop()
    {
        started = false;
        lifetime?.Cancel();
        lifetime?.Dispose();
        lifetime = null;
        pairingTask = null;
        relay = null;
        connectionTask = null;
        publishPairingCode(null);
    }

    private async Task StartStoredConnectionAsync(CancellationToken cancellationToken)
    {
        try
        {
            var backendToken = await ReadTokenAsync("backend-token", cancellationToken).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(backendToken))
            {
                // Keep compatibility with the first Windows scaffold, which stored the account JWT
                // under device-token. New installs always use the separate backend-token file.
                backendToken = await ReadTokenAsync("device-token", cancellationToken).ConfigureAwait(false);
            }
            var pairingToken = await ReadTokenAsync("pairing-token", cancellationToken).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(backendToken) || string.IsNullOrWhiteSpace(pairingToken))
            {
                pairingTask = StartPairingAsync(cancellationToken);
                await pairingTask.ConfigureAwait(false);
                return;
            }
            if (backendToken is null) return;
            await StartRelayAsync(backendToken, pairingToken, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch { publishStatus("Eşleşme bilgileri okunamadı. Yeniden eşleştirin."); }
    }

    private async Task StartPairingAsync(CancellationToken cancellationToken)
    {
        try
        {
            var deviceId = await GetOrCreateDeviceIdAsync(cancellationToken).ConfigureAwait(false);
            using var response = await pairingClient.PostAsJsonAsync("device-pairing/sessions", new
            {
                deviceId,
                displayName = Environment.MachineName,
                platform = "windows"
            }, cancellationToken).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            var session = await response.Content.ReadFromJsonAsync<PairingSessionResponse>(cancellationToken: cancellationToken).ConfigureAwait(false)
                ?? throw new InvalidOperationException("Eşleşme oturumu yanıtı geçersiz.");
            var value = $"rova-relay:v1:{Base64Url(JsonSerializer.SerializeToUtf8Bytes(new { version = 1, sessionID = session.SessionId, secret = session.Secret, expiresAt = session.ExpiresAt }))}";
            publishPairingCode(value);
            publishStatus("Telefonla eşleştirmeye hazır");

            while (!cancellationToken.IsCancellationRequested && DateTimeOffset.UtcNow < session.ExpiresAt)
            {
                var path = $"device-pairing/sessions/{Uri.EscapeDataString(session.SessionId)}?secret={Uri.EscapeDataString(session.Secret)}";
                using var pollResponse = await pairingClient.GetAsync(path, cancellationToken).ConfigureAwait(false);
                if ((int)pollResponse.StatusCode == 429)
                {
                    await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
                    continue;
                }
                pollResponse.EnsureSuccessStatusCode();
                var poll = await pollResponse.Content.ReadFromJsonAsync<PairingPollResponse>(cancellationToken: cancellationToken).ConfigureAwait(false);
                if (poll?.Status == "claimed" && poll.BackendToken is { Length: > 0 } backendToken && poll.PairingToken is { Length: > 0 } pairingToken)
                {
                    await SaveTokenAsync("backend-token", backendToken, cancellationToken).ConfigureAwait(false);
                    await SaveTokenAsync("pairing-token", pairingToken, cancellationToken).ConfigureAwait(false);
                    publishPairingCode(null);
                    await StartRelayAsync(backendToken, pairingToken, cancellationToken).ConfigureAwait(false);
                    return;
                }
                await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
            }
            if (!cancellationToken.IsCancellationRequested) publishStatus("Eşleştirme kodunun süresi doldu.");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch
        {
            publishPairingCode(null);
            publishStatus("Eşleştirme hazırlanamadı. İnternet bağlantısını kontrol edin.");
        }
    }

    private async Task<string> GetOrCreateDeviceIdAsync(CancellationToken cancellationToken)
    {
        var path = Path.Combine(DataDirectory, "device-id");
        if (File.Exists(path) && Guid.TryParse(await File.ReadAllTextAsync(path, cancellationToken).ConfigureAwait(false), out var existing)) return existing.ToString();
        var created = Guid.NewGuid().ToString();
        Directory.CreateDirectory(DataDirectory);
        await File.WriteAllTextAsync(path, created, cancellationToken).ConfigureAwait(false);
        return created;
    }

    private Task StartRelayAsync(string token, string? pairingToken, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(token)) return Task.CompletedTask;
        if (relay is not null && connectionTask is not null) return connectionTask;
        var deviceIdPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Wiqo", "device-id");
        Directory.CreateDirectory(Path.GetDirectoryName(deviceIdPath)!);
        var id = File.Exists(deviceIdPath) && Guid.TryParse(File.ReadAllText(deviceIdPath), out var stored) ? stored : Guid.NewGuid();
        File.WriteAllText(deviceIdPath, id.ToString());
        var capabilities = WindowsOperationManifest.AdvertisedCapabilities;
        var authorities = capabilities.Select(capability => new DeviceAuthority(
            capability,
            capability,
            capability is "device.files.write" or "device.files.move" or "device.files.copy" ? "confirmation" : "automatic",
            Array.Empty<string>())).Append(new DeviceAuthority(
                "device.app.quit",
                "Uygulama kapatma",
                "automatic",
                Array.Empty<string>())).ToArray();
        var targets = Process.GetProcesses().Where(process => !string.IsNullOrWhiteSpace(process.ProcessName)).Select(process => new ApplicationTarget(process.ProcessName, null, true, ["open", "activate", "quit"])).DistinctBy(target => target.Name, StringComparer.OrdinalIgnoreCase).Take(250).ToArray();
        var info = new DeviceInfo(id.ToString(), Environment.MachineName, Environment.MachineName, "", 0, "running", targets.Select(target => target.Name).ToArray(), targets, capabilities, authorities);
        var ledgerPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Wiqo", "command-ledger.json");
        var engine = new WindowsCommandEngine(new WindowsOperationAdapter(), new CommandLedger(ledgerPath));
        relay = new BackendRelayConnection(new Uri("wss://api.wiqoai.com/device/socket"), engine, info, pairingToken, connected => publishStatus(connected ? "İnternet üzerinden bağlı" : "Yeniden bağlanıyor…"));
        publishStatus("İnternet üzerinden bağlanıyor…");
        connectionTask = relay.RunAsync(token, cancellationToken).ContinueWith(_ => publishStatus("Yeniden bağlanıyor…"), TaskScheduler.Default);
        return connectionTask;
    }

    private static string DataDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Wiqo");

    private static async Task<string?> ReadTokenAsync(string name, CancellationToken cancellationToken = default)
    {
        var path = Path.Combine(DataDirectory, name);
        if (!File.Exists(path)) return null;
        var value = await File.ReadAllTextAsync(path, cancellationToken).ConfigureAwait(false);
        return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    }

    private static async Task SaveTokenAsync(string name, string value, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(DataDirectory);
        await File.WriteAllTextAsync(Path.Combine(DataDirectory, name), value, cancellationToken).ConfigureAwait(false);
    }

    private static string Base64Url(byte[] data) => Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private sealed record PairingSessionResponse(
        [property: JsonPropertyName("sessionId")] string SessionId,
        [property: JsonPropertyName("secret")] string Secret,
        [property: JsonPropertyName("expiresAt")] DateTimeOffset ExpiresAt);

    private sealed record PairingPollResponse(
        [property: JsonPropertyName("status")] string Status,
        [property: JsonPropertyName("pairingToken")] string? PairingToken,
        [property: JsonPropertyName("backendToken")] string? BackendToken);
}

internal sealed class WindowsOperationAdapter : IWindowsOperationAdapter
{
    public async Task<(JsonElement? Data, string Message, RovaError? Error)> ExecuteAsync(CommandRequest request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try
        {
            return request.Type switch
            {
                "ping" => (null, "Pong.", null),
                "getSystemStatus" => (JsonSerializer.SerializeToElement(new { platform = "windows", host = Environment.MachineName, osVersion = Environment.OSVersion.VersionString }), "Windows sistem durumu hazır.", null),
                "openURL" => OpenUrl(request.Payload),
                "openApplicationByName" => OpenApplication(request.Payload),
                "controlApplication" => ControlApplication(request.Payload),
                "listRunningApplications" => ListProcesses(),
                "listFiles" => ListFiles(request.Payload),
                "readFile" => ReadFile(request.Payload),
                "writeFile" => WriteFile(request.Payload),
                "moveFile" => MoveFile(request.Payload),
                "copyFile" => CopyFile(request.Payload),
                _ => (null, "Bu Windows sürümünde bu işlem desteklenmiyor.", new RovaError("UNSUPPORTED_OPERATION", "Bu Windows sürümünde bu işlem desteklenmiyor.", "validation"))
            };
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception)
        {
            return (null, "İşlem Windows üzerinde tamamlanamadı.", new RovaError("WINDOWS_OPERATION_FAILED", "İşlem Windows üzerinde tamamlanamadı."));
        }
    }

    private static (JsonElement? Data, string Message, RovaError? Error) OpenUrl(JsonElement payload)
    {
        var url = payload.GetProperty("value").GetString();
        if (string.IsNullOrWhiteSpace(url) || !Uri.TryCreate(url, UriKind.Absolute, out var parsed) || parsed.Scheme is not ("http" or "https"))
            return (null, "URL geçersiz.", new RovaError("INVALID_PAYLOAD", "URL geçersiz.", "validation"));
        var process = Process.Start(new ProcessStartInfo(parsed.ToString()) { UseShellExecute = true });
        if (process is null) return (null, "URL açılamadı.", new RovaError("WINDOWS_OPERATION_FAILED", "URL açılamadı."));
        return (null, "URL açıldı.", null);
    }

    private static (JsonElement? Data, string Message, RovaError? Error) OpenApplication(JsonElement payload)
    {
        var target = payload.GetProperty("value").GetString()?.Trim();
        if (string.IsNullOrWhiteSpace(target)) return (null, "Uygulama adı geçersiz.", new RovaError("INVALID_PAYLOAD", "Uygulama adı geçersiz.", "validation"));
        var process = Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
        if (process is null) return (null, "Uygulama açılamadı.", new RovaError("WINDOWS_OPERATION_FAILED", "Uygulama açılamadı."));
        return (null, $"{target} açıldı.", null);
    }

    private static (JsonElement? Data, string Message, RovaError? Error) ListProcesses()
    {
        var processes = Process.GetProcesses().Where(process => !string.IsNullOrWhiteSpace(process.ProcessName)).Select(process => new { name = process.ProcessName, isRunning = true }).DistinctBy(item => item.name, StringComparer.OrdinalIgnoreCase).OrderBy(item => item.name, StringComparer.OrdinalIgnoreCase).Take(250).ToArray();
        return (JsonSerializer.SerializeToElement(new { applications = processes }), "Açık uygulamalar listelendi.", null);
    }

    private static (JsonElement? Data, string Message, RovaError? Error) ControlApplication(JsonElement payload)
    {
        var value = payload.GetProperty("value");
        var action = value.GetProperty("action").GetString();
        var target = value.GetProperty("target").GetString()?.Trim();
        var force = value.TryGetProperty("force", out var forceValue) && forceValue.GetBoolean();
        if (string.IsNullOrWhiteSpace(target) || action is not ("open" or "activate" or "quit")) return (null, "Uygulama isteği geçersiz.", new RovaError("INVALID_PAYLOAD", "Uygulama isteği geçersiz.", "validation"));
        var normalizedTarget = new string(target.Where(char.IsLetterOrDigit).ToArray());
        var processes = Process.GetProcesses()
            .Where(process => new string(process.ProcessName.Where(char.IsLetterOrDigit).ToArray()).Contains(normalizedTarget, StringComparison.OrdinalIgnoreCase) || normalizedTarget.Contains(new string(process.ProcessName.Where(char.IsLetterOrDigit).ToArray()), StringComparison.OrdinalIgnoreCase))
            .ToArray();
        if (action is "open" or "activate")
        {
            if (processes.Length == 0)
            {
                var process = Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
                if (process is null) return (null, $"{target} açılamadı.", new RovaError("WINDOWS_OPERATION_FAILED", $"{target} açılamadı."));
            }
            return (null, $"{target} açıldı.", null);
        }
        if (processes.Length == 0) return (null, $"{target} zaten kapalı.", null);
        foreach (var process in processes)
        {
            if (!process.HasExited && !force) process.CloseMainWindow();
            if (force && !process.HasExited) process.Kill(entireProcessTree: true);
            if (!process.WaitForExit(2_000) && !process.HasExited)
                return (null, $"{target} kapatılamadı.", new RovaError("WINDOWS_OPERATION_FAILED", $"{target} kapatılamadı."));
        }
        return (null, $"{target} kapatıldı.", null);
    }

    private static string? ReadPath(JsonElement payload) => payload.TryGetProperty("value", out var value) && value.TryGetProperty("path", out var path) ? path.GetString() : null;

    private static (JsonElement? Data, string Message, RovaError? Error) ListFiles(JsonElement payload)
    {
        var path = ReadPath(payload);
        if (string.IsNullOrWhiteSpace(path)) return (null, "Dosya yolu gerekli.", new RovaError("INVALID_PAYLOAD", "Dosya yolu gerekli.", "validation"));
        var files = Directory.EnumerateFileSystemEntries(path).Take(250).Select(value => new { path = value, name = Path.GetFileName(value) }).ToArray();
        return (JsonSerializer.SerializeToElement(new { files }), "Dosyalar listelendi.", null);
    }

    private static (JsonElement? Data, string Message, RovaError? Error) ReadFile(JsonElement payload)
    {
        var path = ReadPath(payload);
        if (string.IsNullOrWhiteSpace(path)) return (null, "Dosya yolu gerekli.", new RovaError("INVALID_PAYLOAD", "Dosya yolu gerekli.", "validation"));
        var text = File.ReadAllText(path);
        var truncated = text.Length > 100_000;
        return (JsonSerializer.SerializeToElement(new { path, text = truncated ? text[..100_000] : text, truncated }), "Dosya okundu.", null);
    }

    private static (JsonElement? Data, string Message, RovaError? Error) WriteFile(JsonElement payload)
    {
        var value = payload.GetProperty("value");
        var path = value.GetProperty("path").GetString();
        var content = value.GetProperty("content").GetString();
        if (string.IsNullOrWhiteSpace(path) || content is null) return (null, "Dosya yolu veya içerik geçersiz.", new RovaError("INVALID_PAYLOAD", "Dosya yolu veya içerik geçersiz.", "validation"));
        File.WriteAllText(path, content);
        if (!string.Equals(File.ReadAllText(path), content, StringComparison.Ordinal))
            return (null, "Dosya yazıldı ancak doğrulanamadı.", new RovaError("VERIFICATION_FAILED", "Dosya yazıldı ancak doğrulanamadı."));
        return (JsonSerializer.SerializeToElement(new { path }), "Dosya yazıldı.", null);
    }

    private static (JsonElement? Data, string Message, RovaError? Error) MoveFile(JsonElement payload)
    {
        var value = payload.GetProperty("value");
        var source = value.GetProperty("source").GetString();
        var destination = value.GetProperty("destination").GetString();
        if (string.IsNullOrWhiteSpace(source) || string.IsNullOrWhiteSpace(destination)) return (null, "Kaynak veya hedef geçersiz.", new RovaError("INVALID_PAYLOAD", "Kaynak veya hedef geçersiz.", "validation"));
        var overwrite = value.TryGetProperty("overwrite", out var overwriteValue) && overwriteValue.GetBoolean();
        File.Move(source, destination, overwrite);
        if (File.Exists(source) || !File.Exists(destination))
            return (null, "Dosya taşındı ancak doğrulanamadı.", new RovaError("VERIFICATION_FAILED", "Dosya taşındı ancak doğrulanamadı."));
        return (JsonSerializer.SerializeToElement(new { source, destination }), "Dosya taşındı.", null);
    }

    private static (JsonElement? Data, string Message, RovaError? Error) CopyFile(JsonElement payload)
    {
        var value = payload.GetProperty("value");
        var source = value.GetProperty("source").GetString();
        var destination = value.GetProperty("destination").GetString();
        if (string.IsNullOrWhiteSpace(source) || string.IsNullOrWhiteSpace(destination)) return (null, "Kaynak veya hedef geçersiz.", new RovaError("INVALID_PAYLOAD", "Kaynak veya hedef geçersiz.", "validation"));
        var overwrite = value.TryGetProperty("overwrite", out var overwriteValue) && overwriteValue.GetBoolean();
        File.Copy(source, destination, overwrite);
        if (!File.Exists(destination))
            return (null, "Dosya kopyalandı ancak doğrulanamadı.", new RovaError("VERIFICATION_FAILED", "Dosya kopyalandı ancak doğrulanamadı."));
        return (JsonSerializer.SerializeToElement(new { source, destination }), "Dosya kopyalandı.", null);
    }
}
