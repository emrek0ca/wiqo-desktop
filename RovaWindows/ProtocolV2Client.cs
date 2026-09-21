using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace RovaWindows;

/// Minimal Protocol v2 relay client. It intentionally keeps JSON envelopes close to MacBackendChannel
/// so backend/mobile do not need a Windows-specific wire branch.
public sealed class ProtocolV2Client : IAsyncDisposable
{
    private readonly WindowsRuntime runtime;
    private readonly Uri endpoint;
    private readonly DeviceSessionClient? sessions;
    private ClientWebSocket? socket;
    private readonly CancellationTokenSource lifetime = new();
    private readonly Dictionary<string, WindowsCommandResult> completed = new(StringComparer.Ordinal);
    private readonly object completedGate = new();
    private const int CompletedLimit = 128;

    public ProtocolV2Client(WindowsRuntime runtime, Uri? endpoint = null, DeviceSessionClient? sessions = null)
    {
        this.runtime = runtime;
        this.endpoint = endpoint ?? new Uri("wss://api.wiqoai.com/device/socket");
        this.sessions = sessions;
    }

    public async Task RunAsync(string accessToken, CancellationToken cancellationToken = default)
    {
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

    /// Keeps a scoped socket alive across access-token expiry. A reconnect never replays a
    /// completed command: the in-memory ledger filters duplicate command IDs for this process,
    /// while the backend durable ledger remains the final authority after a restart.
    public async Task RunWithRefreshAsync(DeviceSessionCredentials credentials, CancellationToken cancellationToken = default)
    {
        if (sessions is null) throw new InvalidOperationException("DeviceSessionClient is required for refresh.");
        var current = credentials;
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

            var refreshed = await sessions.RefreshAsync(runtime.DeviceId, current.RefreshToken, cancellationToken).ConfigureAwait(false);
            if (refreshed is null) return;
            current = refreshed;
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
                await message.WriteAsync(buffer.AsMemory(0, result.Count), cancellationToken).ConfigureAwait(false);
            } while (!result.EndOfMessage);

            using var document = JsonDocument.Parse(message.ToArray());
            if (document.RootElement.TryGetProperty("type", out var type) && type.GetString() == "interactiveCommand")
                await HandleInteractiveCommandAsync(currentSocket, document.RootElement, cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task HandleInteractiveCommandAsync(ClientWebSocket currentSocket, JsonElement envelope, CancellationToken cancellationToken)
    {
        var commandId = envelope.GetProperty("commandId").GetString() ?? "";
        var request = envelope.GetProperty("request");
        var requestId = request.GetProperty("id").GetString() ?? commandId;
        var operation = request.GetProperty("type").GetString() ?? "";
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
        lifetime.Dispose();
    }
}
