using System.Collections.Concurrent;
using System.Net.Http;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using RovaWindows.Terminal;

namespace RovaWindows;

public enum ConnectionState { Disconnected, Connecting, Connected, NeedsPairing }

/// The relay connection to the Wiqo backend, envelope for envelope what MacBackendChannel sends:
/// "register" (capabilities, features, authorities, terminal profile), signed "interactiveCommand"
/// execution, "terminalCommand" sessions, unattended "automationStep"s, "automationReceipts" for
/// results that finished while offline, and "terminalJobUpdate" signals. It reconnects with backoff
/// (1-30 s), rotates the device session before reconnecting, and never replays a finished command.
public sealed class ProtocolV2Client : IAsyncDisposable
{
    private static readonly TimeSpan OpenTimeout = TimeSpan.FromSeconds(15);
    private static readonly int[] BackoffSeconds = [1, 2, 4, 8, 16, 30];
    private const int MaxFrameBytes = 1_500_000;

    private readonly WindowsRuntime runtime;
    private readonly DeviceSessionClient sessions;
    private readonly Uri endpoint;
    private readonly Uri apiBase;
    private readonly HttpClient uploadHttp = new() { Timeout = TimeSpan.FromSeconds(130) };
    private readonly SemaphoreSlim sendGate = new(1, 1);
    private readonly SemaphoreSlim refreshGate = new(1, 1);
    private readonly SemaphoreSlim transferGate = new(1, 1);
    /// Commands run for the client's lifetime, not the socket's: a dropped connection must not cut a
    /// running command short. The result goes out on the socket if it is still open, otherwise
    /// the ledger reports it as a receipt on the next connection.
    private readonly CancellationTokenSource lifetime = new();
    private readonly ConcurrentDictionary<string, string> completedSignatures = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, string> completedTerminalHashes = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, WindowsCommandResult> completedTerminal = new(StringComparer.Ordinal);
    private static readonly ConcurrentDictionary<string, long> UsedNonces = new(StringComparer.Ordinal);
    private ClientWebSocket? socket;
    private CancellationTokenSource? connectionCancel;
    private DeviceSessionCredentials? credentials;
    private DateTimeOffset credentialsIssuedAt;
    private Dictionary<string, object>? terminalProfile;
    private ConnectionState state = ConnectionState.Disconnected;

    public event Action<ConnectionState>? StateChanged;
    public event Action<string>? Activity;
    /// The PC agent step running now (null when it finished), for the tray.
    public event Action<string?>? AgentStep;

    public ConnectionState State => state;

    public ProtocolV2Client(WindowsRuntime runtime, DeviceSessionClient sessions, Uri? endpoint = null)
    {
        this.runtime = runtime;
        this.sessions = sessions;
        apiBase = sessions.BaseUri;
        this.endpoint = endpoint ?? new Uri(new Uri(apiBase.ToString().Replace("https://", "wss://", StringComparison.OrdinalIgnoreCase)), "device/socket");
        runtime.SetPairingToken(WindowsSecretStore.LoadPairingToken());
        runtime.ConfigureFileUploader(UploadFileAsync);
        runtime.ConfigureAccessToken(AccessTokenAsync);
        runtime.Terminal.ConfigureJobReporter((jobId, jobState, errorCode) =>
            socket is { State: WebSocketState.Open } current
                ? SendAsync(current, new { type = "terminalJobUpdate", jobId, state = jobState, errorCode }, CancellationToken.None)
                : Task.CompletedTask);
    }

    /// Runs until cancelled or until the device session is no longer valid (NeedsPairing).
    public async Task RunAsync(DeviceSessionCredentials initial, CancellationToken cancellationToken)
    {
        credentials = initial;
        credentialsIssuedAt = DateTimeOffset.MinValue; // unknown age: refresh before the first upload
        runtime.SetPairingToken(WindowsSecretStore.LoadPairingToken());
        var attempt = 0;
        while (!cancellationToken.IsCancellationRequested)
        {
            // Rotate first: a stored access token is usually expired after a restart or sleep.
            var refreshed = await RefreshAsync(cancellationToken).ConfigureAwait(false);
            if (refreshed == false)
            {
                SetState(ConnectionState.NeedsPairing);
                return;
            }
            if (refreshed == true)
            {
                SetState(ConnectionState.Connecting);
                var connected = await ConnectOnceAsync(cancellationToken).ConfigureAwait(false);
                if (connected) attempt = 0;
            }
            if (cancellationToken.IsCancellationRequested) break;
            SetState(ConnectionState.Disconnected);
            var delay = TimeSpan.FromSeconds(BackoffSeconds[Math.Min(attempt++, BackoffSeconds.Length - 1)]) + TimeSpan.FromMilliseconds(Random.Shared.Next(0, 250));
            try { await Task.Delay(delay, cancellationToken).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
        }
        SetState(ConnectionState.Disconnected);
    }

    /// Drops the current socket so RunAsync reconnects now (after sleep, a network change or a
    /// settings change that alters what the registration advertises).
    public void Reconnect() => connectionCancel?.Cancel();

    private async Task<bool> ConnectOnceAsync(CancellationToken cancellationToken)
    {
        using var current = new ClientWebSocket();
        using var connection = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        connectionCancel = connection;
        current.Options.SetRequestHeader("Authorization", $"Bearer {credentials!.AccessToken}");
        current.Options.KeepAliveInterval = TimeSpan.FromSeconds(20);
        var registered = false;
        try
        {
            using (var open = CancellationTokenSource.CreateLinkedTokenSource(connection.Token))
            {
                open.CancelAfter(OpenTimeout);
                await current.ConnectAsync(endpoint, open.Token).ConfigureAwait(false);
            }
            socket = current;
            await SendRegistrationAsync(current, connection.Token).ConfigureAwait(false);
            registered = true;
            SetState(ConnectionState.Connected);
            Activity?.Invoke("Wiqo'ya bağlandı.");
            _ = Task.Run(() => SendReceiptsAsync(current, connection.Token));
            _ = Task.Run(() => SendTerminalProfileAsync(current, connection.Token));
            await ReceiveLoopAsync(current, connection.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { }
        catch (WebSocketException) { }
        catch (IOException) { }
        catch (HttpRequestException) { }
        finally
        {
            if (ReferenceEquals(socket, current)) socket = null;
            connectionCancel = null;
            if (current.State == WebSocketState.Open)
            {
                try { await current.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "reconnect", CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false); } catch { }
            }
        }
        return registered;
    }

    /// true: valid credentials; false: the backend rejected them (pair again); null: offline, retry.
    private async Task<bool?> RefreshAsync(CancellationToken cancellationToken)
    {
        await refreshGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (credentials is null) return false;
            if (DateTimeOffset.UtcNow - credentialsIssuedAt < TimeSpan.FromMinutes(10)) return true;
            var refreshed = await sessions.RefreshAsync(runtime.DeviceId, credentials.RefreshToken, cancellationToken).ConfigureAwait(false);
            if (refreshed is null) return false;
            credentials = refreshed;
            credentialsIssuedAt = DateTimeOffset.UtcNow;
            return true;
        }
        catch (HttpRequestException) { return null; }
        catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested) { return null; }
        finally { refreshGate.Release(); }
    }

    /// A fresh access token for HTTP calls (file transfer, artifact download): they outlive the
    /// 15-minute token when the socket has been up for a while.
    public async Task<string?> AccessTokenAsync(CancellationToken cancellationToken) =>
        await RefreshAsync(cancellationToken).ConfigureAwait(false) == true ? credentials?.AccessToken : null;

    private Task SendRegistrationAsync(ClientWebSocket current, CancellationToken cancellationToken) => SendAsync(current, new
    {
        type = "register",
        protocolVersion = 2,
        deviceId = runtime.DeviceId,
        displayName = runtime.DisplayName,
        platform = "windows",
        capabilities = runtime.Capabilities,
        features = runtime.Features,
        terminalProfile = runtime.Features.Count > 0 ? terminalProfile : null,
        applicationTargets = Array.Empty<object>(),
        authorities = runtime.Authorities
    }, cancellationToken);

    private async Task SendReceiptsAsync(ClientWebSocket current, CancellationToken cancellationToken)
    {
        var receipts = runtime.Ledger.Recent().Select(entry => new { commandId = entry.CommandId, status = entry.Status, message = entry.Message, error = entry.Error }).ToArray();
        if (receipts.Length == 0) return;
        try { await SendAsync(current, new { type = "automationReceipts", receipts }, cancellationToken).ConfigureAwait(false); } catch { }
    }

    /// Computed once per process off the connection path (tool versions take a few seconds).
    private async Task SendTerminalProfileAsync(ClientWebSocket current, CancellationToken cancellationToken)
    {
        if (runtime.Features.Count == 0) return;
        try
        {
            terminalProfile ??= await TerminalProfile.BuildAsync(cancellationToken).ConfigureAwait(false);
            await SendAsync(current, new { type = "terminalProfile", profile = terminalProfile }, cancellationToken).ConfigureAwait(false);
        }
        catch { }
    }

    private async Task ReceiveLoopAsync(ClientWebSocket current, CancellationToken cancellationToken)
    {
        var buffer = new byte[256 * 1024];
        while (current.State == WebSocketState.Open && !cancellationToken.IsCancellationRequested)
        {
            using var message = new MemoryStream();
            WebSocketReceiveResult result;
            do
            {
                result = await current.ReceiveAsync(buffer, cancellationToken).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    if ((int?)result.CloseStatus is 4001 or 4003) credentialsIssuedAt = DateTimeOffset.MinValue;
                    return;
                }
                if (result.MessageType != WebSocketMessageType.Text || message.Length + result.Count > MaxFrameBytes)
                {
                    await current.CloseAsync(WebSocketCloseStatus.MessageTooBig, "Invalid frame", cancellationToken).ConfigureAwait(false);
                    return;
                }
                message.Write(buffer, 0, result.Count);
            } while (!result.EndOfMessage);

            JsonDocument document;
            try { document = JsonDocument.Parse(message.ToArray()); }
            catch (JsonException) { continue; }
            // Each command runs on its own task so a long terminal job never blocks the socket.
            _ = Task.Run(async () =>
            {
                using (document)
                {
                    try { await DispatchAsync(current, document.RootElement, lifetime.Token).ConfigureAwait(false); }
                    catch (OperationCanceledException) { }
                    catch (WebSocketException) { }
                    catch (ObjectDisposedException) { }
                }
            }, CancellationToken.None);
        }
    }

    private Task DispatchAsync(ClientWebSocket current, JsonElement envelope, CancellationToken cancellationToken)
    {
        var type = envelope.TryGetProperty("type", out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
        return type switch
        {
            "interactiveCommand" => HandleInteractiveAsync(current, envelope, cancellationToken),
            "terminalCommand" => HandleTerminalAsync(current, envelope, cancellationToken),
            "agentCommand" => HandleAgentAsync(current, envelope, cancellationToken),
            "automationStep" => HandleAutomationStepAsync(current, envelope, cancellationToken),
            _ => Task.CompletedTask
        };
    }

    private async Task HandleInteractiveAsync(ClientWebSocket current, JsonElement envelope, CancellationToken cancellationToken)
    {
        if (!TryCommandId(envelope, out var commandId) || !envelope.TryGetProperty("request", out var request) || request.ValueKind != JsonValueKind.Object) return;
        var operation = request.TryGetProperty("type", out var rawOperation) && rawOperation.ValueKind == JsonValueKind.String ? rawOperation.GetString() ?? "" : "";
        var requestId = request.TryGetProperty("id", out var rawId) && rawId.ValueKind == JsonValueKind.String ? rawId.GetString() ?? commandId : commandId;
        var payload = request.TryGetProperty("payload", out var rawPayload) ? rawPayload : default;
        var incomingSignature = request.TryGetProperty("signature", out var signatureValue) && signatureValue.ValueKind == JsonValueKind.String ? signatureValue.GetString() ?? "" : "";

        var previous = runtime.Ledger.Find(requestId);
        var signatureValid = VerifyCommandSignature(request, out var signatureError, consumeNonce: previous is null);
        // A reconnect may resend the same signed request; a different request never borrows its result.
        if (!signatureValid || (previous is not null && completedSignatures.TryGetValue(requestId, out var known) && !ConstantTimeEquals(known, incomingSignature)))
        {
            var error = signatureError == "SIGNATURE_VERSION_REQUIRED"
                ? new WireError(signatureError, "Güvenli komut imzası için Wiqo telefon uygulamasını güncelleyin.", "permission")
                : new WireError("INVALID_SIGNATURE", "Komutun v2 imzası doğrulanamadı.", "permission");
            var now = DateTimeOffset.UtcNow;
            await SendResultAsync(current, commandId, new WindowsCommandResult(requestId, "denied", error.Message, now, now, null, error), cancellationToken).ConfigureAwait(false);
            return;
        }
        completedSignatures[requestId] = incomingSignature;
        Activity?.Invoke($"Komut: {operation}");
        var result = await runtime.ExecuteAsync(requestId, operation, payload, cancellationToken).ConfigureAwait(false);
        TrimCaches();
        await SendResultAsync(current, commandId, result, cancellationToken).ConfigureAwait(false);
    }

    /// A step from the backend's PC agent (rova-backend src/agent/pcAgent.ts). No phone signature:
    /// it runs only while the owner has "Tam yetki" on here. ExecuteAsync still validates the
    /// payload, dedupes by id and refuses capabilities turned off in Settings.
    private async Task HandleAgentAsync(ClientWebSocket current, JsonElement envelope, CancellationToken cancellationToken)
    {
        if (!TryCommandId(envelope, out var commandId)) return;
        var now = DateTimeOffset.UtcNow;
        if (!envelope.TryGetProperty("request", out var request) || request.ValueKind != JsonValueKind.Object)
        {
            await SendResultAsync(current, commandId, new WindowsCommandResult(commandId, "failed", "Ajan komutu çözülemedi.", now, now, null,
                new WireError("INVALID_PAYLOAD", "Ajan komutu çözülemedi.", "validation")), cancellationToken).ConfigureAwait(false);
            return;
        }
        var operation = request.TryGetProperty("type", out var rawOperation) && rawOperation.ValueKind == JsonValueKind.String ? rawOperation.GetString() ?? "" : "";
        var requestId = request.TryGetProperty("id", out var rawId) && rawId.ValueKind == JsonValueKind.String ? rawId.GetString() ?? commandId : commandId;
        if (!runtime.Settings.AgentFullAccess)
        {
            await SendResultAsync(current, commandId, new WindowsCommandResult(requestId, "denied", "Bu bilgisayarda tam yetki kapalı.", now, now, null,
                new WireError("FULL_ACCESS_DISABLED", "Bu bilgisayarda tam yetki kapalı; Wiqo ayarlarından açılmadan ajan komut çalıştıramaz.", "permission")), cancellationToken).ConfigureAwait(false);
            return;
        }
        Activity?.Invoke($"Ajan: {operation}");
        AgentStep?.Invoke(operation);
        var result = await runtime.ExecuteAsync(requestId, operation, request.TryGetProperty("payload", out var payload) ? payload : default, cancellationToken).ConfigureAwait(false);
        AgentStep?.Invoke(null);
        TrimCaches();
        await SendResultAsync(current, commandId, result, cancellationToken).ConfigureAwait(false);
    }

    private async Task HandleTerminalAsync(ClientWebSocket current, JsonElement envelope, CancellationToken cancellationToken)
    {
        if (!TryCommandId(envelope, out var commandId) || !envelope.TryGetProperty("request", out var request) || request.ValueKind != JsonValueKind.Object) return;
        string requestHash;
        try { requestHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(CanonicalJson.Serialize(request)))); }
        catch (JsonException) { return; }
        if (completedTerminal.TryGetValue(commandId, out var cached))
        {
            // The same terminal request after a reconnect gets its original result, never a rerun.
            var sameRequest = completedTerminalHashes.TryGetValue(commandId, out var hash) && ConstantTimeEquals(hash, requestHash);
            var now = DateTimeOffset.UtcNow;
            await SendResultAsync(current, commandId, sameRequest ? cached : new WindowsCommandResult(commandId, "denied", "Terminal isteği doğrulanamadı.", now, now, null,
                new WireError("TERMINAL_GRANT_INVALID", "Terminal isteği doğrulanamadı.", "permission")), cancellationToken).ConfigureAwait(false);
            return;
        }
        Activity?.Invoke("Terminal komutu");
        var result = await runtime.Terminal.ExecuteAsync(commandId, request, cancellationToken).ConfigureAwait(false);
        completedTerminal[commandId] = result;
        completedTerminalHashes[commandId] = requestHash;
        TrimCaches();
        await SendResultAsync(current, commandId, result, cancellationToken).ConfigureAwait(false);
    }

    /// Unattended automation steps: acknowledged at once, run only when the shared catalogue says
    /// the step may run without the user (never private reads, app control or writes).
    private async Task HandleAutomationStepAsync(ClientWebSocket current, JsonElement envelope, CancellationToken cancellationToken)
    {
        if (!envelope.TryGetProperty("runId", out var runId) || !envelope.TryGetProperty("stepId", out var stepId) ||
            !envelope.TryGetProperty("commandId", out var rawCommandId) || rawCommandId.ValueKind != JsonValueKind.String ||
            !envelope.TryGetProperty("step", out var step) || step.ValueKind != JsonValueKind.Object) return;
        var commandId = rawCommandId.GetString()!;
        await SendAsync(current, new { type = "automationStepAck", protocolVersion = 2, runId, stepId, commandId }, cancellationToken).ConfigureAwait(false);
        WindowsCommandResult result;
        var now = DateTimeOffset.UtcNow;
        var claimsSafe = !(step.TryGetProperty("isDestructive", out var destructive) && destructive.ValueKind == JsonValueKind.True) &&
                         !(step.TryGetProperty("requiresUserPresence", out var presence) && presence.ValueKind == JsonValueKind.True);
        var operation = step.TryGetProperty("type", out var type) && type.ValueKind == JsonValueKind.String ? type.GetString() ?? "" : "";
        if (!Guid.TryParse(commandId, out _))
            result = new WindowsCommandResult(commandId, "denied", "Otomasyon komut kimliği geçersiz.", now, now, null, new WireError("INVALID_COMMAND_ID", "Otomasyon komut kimliği geçersiz.", "validation"));
        else if (!claimsSafe)
            result = new WindowsCommandResult(commandId, "denied", "Bu otomasyon adımı kullanıcı onayı gerektiriyor.", now, now, null, new WireError("AUTOMATION_STEP_BLOCKED", "Bu otomasyon adımı kullanıcı onayı gerektiriyor.", "permission"));
        else
            result = await runtime.ExecuteAsync(commandId, operation, step.TryGetProperty("payload", out var payload) ? payload : default, cancellationToken, unattended: true).ConfigureAwait(false);
        await SendAsync(current, new { type = "automationStepResult", protocolVersion = 2, runId, stepId, commandId, status = result.Status, message = result.Message, error = result.Error }, cancellationToken).ConfigureAwait(false);
    }

    private bool VerifyCommandSignature(JsonElement request, out string errorCode, bool consumeNonce)
    {
        errorCode = "INVALID_SIGNATURE";
        if (!request.TryGetProperty("signatureVersion", out var version) || version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var number) || number != 2)
        {
            errorCode = "SIGNATURE_VERSION_REQUIRED";
            return false;
        }
        if (runtime.PairingToken is not { Length: > 0 } token ||
            !request.TryGetProperty("id", out var idValue) || idValue.ValueKind != JsonValueKind.String || !Guid.TryParse(idValue.GetString(), out var id) ||
            !request.TryGetProperty("type", out var typeValue) || typeValue.ValueKind != JsonValueKind.String ||
            !request.TryGetProperty("payload", out var payload) ||
            !request.TryGetProperty("createdAtEpochMs", out var epochValue) || !epochValue.TryGetInt64(out var epochMs) ||
            !request.TryGetProperty("createdAt", out var dateValue) || dateValue.ValueKind != JsonValueKind.String ||
            !DateTimeOffset.TryParse(dateValue.GetString(), System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal, out var createdAt) ||
            Math.Abs(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - epochMs) > 600_000 || Math.Abs(createdAt.ToUnixTimeMilliseconds() - epochMs) >= 1_000 ||
            !request.TryGetProperty("nonce", out var nonceValue) || nonceValue.ValueKind != JsonValueKind.String || nonceValue.GetString() is not { Length: > 0 and <= 200 } nonce ||
            !request.TryGetProperty("signature", out var signatureValue) || signatureValue.ValueKind != JsonValueKind.String || signatureValue.GetString() is not { Length: > 0 } signature)
            return false;
        byte[] actual;
        try { actual = Convert.FromHexString(signature); }
        catch (FormatException) { return false; }
        byte[] expected;
        try { expected = CommandSignature(token, id, typeValue.GetString() ?? "", epochMs, nonce, payload); }
        catch (JsonException) { return false; }
        if (actual.Length != expected.Length || !CryptographicOperations.FixedTimeEquals(actual, expected)) return false;
        if (!consumeNonce) return true;
        var key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token + "\n" + nonce)));
        var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        foreach (var entry in UsedNonces.Where(entry => nowMs - entry.Value > 600_000).Take(256)) UsedNonces.TryRemove(entry.Key, out _);
        return UsedNonces.TryAdd(key, nowMs);
    }

    /// HMAC of a v2 CommandRequest, identical to RovaValidation.signRequest on the phone and Mac.
    internal static byte[] CommandSignature(string token, Guid id, string type, long epochMs, string nonce, JsonElement payload)
    {
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(CanonicalJson.Serialize(payload)))).ToLowerInvariant();
        var message = $"wiqo-command:v2:{id.ToString().ToLowerInvariant()}:{type}:{epochMs}:{nonce}:{digest}";
        return HMACSHA256.HashData(Encoding.UTF8.GetBytes(token), Encoding.UTF8.GetBytes(message));
    }

    private async Task<string?> UploadFileAsync(string path, string commandId, CancellationToken cancellationToken)
    {
        await transferGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var token = await AccessTokenAsync(cancellationToken).ConfigureAwait(false);
            if (string.IsNullOrEmpty(token)) return null;
            string digest;
            await using (var hashStream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 256 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan))
                digest = Convert.ToHexString(await SHA256.HashDataAsync(hashStream, cancellationToken).ConfigureAwait(false)).ToLowerInvariant();
            await using var uploadStream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 256 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
            using var request = new HttpRequestMessage(HttpMethod.Put, new Uri(apiBase, "file-transfers/" + commandId));
            request.Headers.Authorization = new("Bearer", token);
            request.Headers.TryAddWithoutValidation("X-File-Name", Uri.EscapeDataString(Path.GetFileName(path)));
            request.Headers.TryAddWithoutValidation("X-File-SHA256", digest);
            request.Content = new StreamContent(uploadStream, 256 * 1024);
            request.Content.Headers.ContentType = new("application/octet-stream");
            request.Content.Headers.ContentLength = uploadStream.Length;
            using var response = await uploadHttp.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return null;
            using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false));
            return document.RootElement.TryGetProperty("artifactId", out var id) ? id.GetString() : null;
        }
        catch (Exception error) when (error is HttpRequestException or IOException or JsonException) { return null; }
        finally { transferGate.Release(); }
    }

    private Task SendResultAsync(ClientWebSocket current, string commandId, WindowsCommandResult result, CancellationToken cancellationToken) => SendAsync(current, new
    {
        type = "interactiveCommandResult",
        commandId,
        result = new
        {
            commandID = result.CommandId,
            status = result.Status,
            message = result.Message,
            startedAt = result.StartedAt,
            finishedAt = result.FinishedAt,
            data = result.Data,
            error = result.Error
        }
    }, cancellationToken);

    /// Best effort on a socket that may have closed meanwhile; what matters is in the ledger.
    private async Task SendAsync(ClientWebSocket current, object value, CancellationToken cancellationToken)
    {
        var bytes = Encoding.UTF8.GetBytes(WireJson.Serialize(value));
        await sendGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (current.State == WebSocketState.Open) await current.SendAsync(bytes, WebSocketMessageType.Text, true, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (error is WebSocketException or ObjectDisposedException or IOException) { }
        finally { sendGate.Release(); }
    }

    private void TrimCaches()
    {
        foreach (var cache in new IDictionary<string, string>[] { completedSignatures, completedTerminalHashes })
            if (cache.Count > 256) foreach (var key in cache.Keys.Take(cache.Count - 128).ToArray()) cache.Remove(key);
        if (completedTerminal.Count > 256) foreach (var key in completedTerminal.Keys.Take(completedTerminal.Count - 128).ToArray()) completedTerminal.TryRemove(key, out _);
    }

    private void SetState(ConnectionState next)
    {
        if (state == next) return;
        state = next;
        runtime.RuntimeStatus = next == ConnectionState.Connected ? "ready" : "offline";
        StateChanged?.Invoke(next);
    }

    private static bool TryCommandId(JsonElement envelope, out string commandId)
    {
        commandId = envelope.TryGetProperty("commandId", out var raw) && raw.ValueKind == JsonValueKind.String ? raw.GetString() ?? "" : "";
        return Guid.TryParse(commandId, out _);
    }

    private static bool ConstantTimeEquals(string left, string right)
    {
        var leftBytes = Encoding.UTF8.GetBytes(left);
        var rightBytes = Encoding.UTF8.GetBytes(right);
        return leftBytes.Length == rightBytes.Length && CryptographicOperations.FixedTimeEquals(leftBytes, rightBytes);
    }

    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        connectionCancel?.Cancel();
        if (socket is { State: WebSocketState.Open } current)
        {
            try { await current.CloseAsync(WebSocketCloseStatus.NormalClosure, "shutdown", CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false); } catch { }
        }
        uploadHttp.Dispose();
        sendGate.Dispose();
        refreshGate.Dispose();
        transferGate.Dispose();
        lifetime.Dispose();
    }
}
