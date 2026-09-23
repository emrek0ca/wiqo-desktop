using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Security.Cryptography;

namespace RovaWindows;

/// Minimal Protocol v2 relay client. It intentionally keeps JSON envelopes close to MacBackendChannel
/// so backend/mobile do not need a Windows-specific wire branch.
public sealed class ProtocolV2Client : IAsyncDisposable
{
    private readonly WindowsRuntime runtime;
    private readonly Uri endpoint;
    private readonly DeviceSessionClient? sessions;
    private ClientWebSocket? socket;
    private readonly HttpClient uploadHttp = new();
    private string? currentAccessToken;
    private DeviceSessionCredentials? currentCredentials;
    private readonly SemaphoreSlim transferGate = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly Dictionary<string, WindowsCommandResult> completed = new(StringComparer.Ordinal);
    private readonly object completedGate = new();
    private const int CompletedLimit = 128;
    private const int MaxFrameBytes = 1_500_000;

    public ProtocolV2Client(WindowsRuntime runtime, Uri? endpoint = null, DeviceSessionClient? sessions = null)
    {
        this.runtime = runtime;
        this.endpoint = endpoint ?? new Uri("wss://api.wiqoai.com/device/socket");
        this.sessions = sessions;
        runtime.ConfigureFileUploader(UploadFileAsync);
    }

    public async Task RunAsync(string accessToken, CancellationToken cancellationToken = default)
    {
        currentAccessToken = accessToken;
        var currentSocket = new ClientWebSocket();
        currentSocket.Options.SetRequestHeader("Authorization", $"Bearer {accessToken}");
        socket = currentSocket;
        try
        {
            await currentSocket.ConnectAsync(endpoint, cancellationToken).ConfigureAwait(false);
            await SendRegistrationAsync(currentSocket, cancellationToken).ConfigureAwait(false);
            await ReceiveLoopAsync(currentSocket, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            if (ReferenceEquals(socket, currentSocket)) socket = null;
            currentSocket.Dispose();
        }
    }

    private async Task<string?> UploadFileAsync(string path, string commandId, CancellationToken cancellationToken)
    {
        await transferGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
        var token = currentAccessToken;
        if (sessions is not null && currentCredentials is { } credentials)
        {
            var refreshed = await sessions.RefreshAsync(runtime.DeviceId, credentials.RefreshToken, cancellationToken).ConfigureAwait(false);
            if (refreshed is null) return null;
            currentCredentials = refreshed;
            token = currentAccessToken = refreshed.AccessToken;
        }
        if (string.IsNullOrEmpty(token)) return null;
        await using var hashStream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 256 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        var digest = Convert.ToHexString(await SHA256.HashDataAsync(hashStream, cancellationToken).ConfigureAwait(false)).ToLowerInvariant();
        await using var uploadStream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 256 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        using var request = new HttpRequestMessage(HttpMethod.Put, new Uri("https://api.wiqoai.com/file-transfers/" + commandId));
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
        finally { transferGate.Release(); }
    }

    /// Keeps a scoped socket alive across access-token expiry. A reconnect never replays a
    /// completed command: the in-memory ledger filters duplicate command IDs for this process,
    /// while the backend durable ledger remains the final authority after a restart.
    public async Task RunWithRefreshAsync(DeviceSessionCredentials credentials, CancellationToken cancellationToken = default)
    {
        if (sessions is null) throw new InvalidOperationException("DeviceSessionClient is required for refresh.");
        var current = credentials;
        currentCredentials = credentials;
        var retryDelay = TimeSpan.FromSeconds(1);
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await RunAsync(current.AccessToken, cancellationToken).ConfigureAwait(false);
                retryDelay = TimeSpan.FromSeconds(1);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (WebSocketException)
            {
                // A closed socket may have lost the last result; the backend's unknown-result
                // ledger prevents unsafe replay. Reconnect only for the next server command.
            }

            current = currentCredentials ?? current;
            var refreshed = await sessions.RefreshAsync(runtime.DeviceId, current.RefreshToken, cancellationToken).ConfigureAwait(false);
            if (refreshed is null) return;
            current = refreshed;
            currentCredentials = refreshed;
            await Task.Delay(retryDelay, cancellationToken).ConfigureAwait(false);
            retryDelay = TimeSpan.FromSeconds(Math.Min(retryDelay.TotalSeconds * 2, 30));
        }
    }

    private async Task SendRegistrationAsync(ClientWebSocket currentSocket, CancellationToken cancellationToken)
    {
        var registration = new
        {
            type = "register",
            protocolVersion = 2,
            deviceId = runtime.DeviceId,
            displayName = runtime.DisplayName,
            platform = "windows",
            capabilities = runtime.Capabilities,
            applicationTargets = Array.Empty<object>(),
            authorities = runtime.Authorities
        };
        await SendAsync(currentSocket, registration, cancellationToken).ConfigureAwait(false);
    }

    private async Task ReceiveLoopAsync(ClientWebSocket currentSocket, CancellationToken cancellationToken)
    {
        var buffer = new byte[1024 * 256];
        while (currentSocket.State == WebSocketState.Open && !cancellationToken.IsCancellationRequested)
        {
            using var message = new MemoryStream();
            WebSocketReceiveResult result;
            do
            {
                result = await currentSocket.ReceiveAsync(buffer, cancellationToken).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close) return;
                if (result.MessageType != WebSocketMessageType.Text || message.Length + result.Count > MaxFrameBytes)
                {
                    await currentSocket.CloseAsync(WebSocketCloseStatus.MessageTooBig, "Invalid command frame", cancellationToken).ConfigureAwait(false);
                    return;
                }
                await message.WriteAsync(buffer.AsMemory(0, result.Count), cancellationToken).ConfigureAwait(false);
            } while (!result.EndOfMessage);

            try
            {
                using var document = JsonDocument.Parse(message.GetBuffer().AsMemory(0, checked((int)message.Length)));
                if (document.RootElement.TryGetProperty("type", out var type) && type.GetString() == "interactiveCommand")
                    await HandleInteractiveCommandAsync(currentSocket, document.RootElement, cancellationToken).ConfigureAwait(false);
            }
            catch (JsonException)
            {
                await currentSocket.CloseAsync(WebSocketCloseStatus.InvalidPayloadData, "Malformed JSON", cancellationToken).ConfigureAwait(false);
                return;
            }
        }
    }

    private async Task HandleInteractiveCommandAsync(ClientWebSocket currentSocket, JsonElement envelope, CancellationToken cancellationToken)
    {
        if (!envelope.TryGetProperty("commandId", out var rawCommandId) ||
            rawCommandId.ValueKind != JsonValueKind.String ||
            !Guid.TryParse(rawCommandId.GetString(), out _) ||
            !envelope.TryGetProperty("request", out var request) ||
            request.ValueKind != JsonValueKind.Object)
        {
            await currentSocket.CloseAsync(WebSocketCloseStatus.InvalidPayloadData, "Invalid command envelope", cancellationToken).ConfigureAwait(false);
            return;
        }
        var commandId = rawCommandId.GetString()!;
        var requestId = request.TryGetProperty("id", out var rawRequestId) && rawRequestId.ValueKind == JsonValueKind.String
            ? rawRequestId.GetString() ?? commandId
            : commandId;
        var operation = request.TryGetProperty("type", out var rawOperation) && rawOperation.ValueKind == JsonValueKind.String
            ? rawOperation.GetString() ?? ""
            : "";
        if (requestId.Length is < 1 or > 160 || operation.Length is < 1 or > 120)
        {
            await currentSocket.CloseAsync(WebSocketCloseStatus.InvalidPayloadData, "Invalid command request", cancellationToken).ConfigureAwait(false);
            return;
        }
        var payload = request.TryGetProperty("payload", out var rawPayload) ? rawPayload : default;
        WindowsCommandResult? cached = null;
        lock (completedGate)
        {
            completed.TryGetValue(commandId, out cached);
        }

        // A reconnect or relay retry must receive the existing result, not execute the
        // side effect again and not silently leave the backend waiting for a receipt.
        if (cached is not null)
        {
            await SendResultAsync(currentSocket, commandId, cached, cancellationToken).ConfigureAwait(false);
            return;
        }

        var result = await runtime.ExecuteAsync(requestId, operation, payload, TimeSpan.FromSeconds(45), cancellationToken).ConfigureAwait(false);
        lock (completedGate)
        {
            completed[commandId] = result;
            while (completed.Count > CompletedLimit)
                completed.Remove(completed.Keys.First());
        }
        await SendResultAsync(currentSocket, commandId, result, cancellationToken).ConfigureAwait(false);
    }

    private static Task SendResultAsync(ClientWebSocket currentSocket, string commandId, WindowsCommandResult result, CancellationToken cancellationToken)
        => SendAsync(currentSocket, new
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

    private static async Task SendAsync(ClientWebSocket currentSocket, object value, CancellationToken cancellationToken)
    {
        var json = JsonSerializer.Serialize(value);
        var bytes = Encoding.UTF8.GetBytes(json);
        await currentSocket.SendAsync(bytes, WebSocketMessageType.Text, true, cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        if (socket is { State: WebSocketState.Open or WebSocketState.CloseReceived } current)
            await current.CloseAsync(WebSocketCloseStatus.NormalClosure, "shutdown", CancellationToken.None).ConfigureAwait(false);
        socket?.Dispose();
        uploadHttp.Dispose();
        transferGate.Dispose();
        lifetime.Dispose();
    }
}
