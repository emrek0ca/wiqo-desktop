using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RovaWindows.Core;

public enum CommandStatus
{
    Pending,
    Running,
    Completed,
    Failed,
    Denied,
    Unknown
}

public sealed record RovaError(string Code, string Message, string Category = "tool_failure");

public sealed record CommandRequest(
    string Id,
    string Type,
    JsonElement Payload,
    DateTimeOffset CreatedAt,
    string? Signature = null,
    string? Nonce = null);

public sealed record CommandResult(
    string CommandId,
    CommandStatus Status,
    string Message,
    DateTimeOffset StartedAt,
    DateTimeOffset FinishedAt,
    JsonElement? Data = null,
    RovaError? Error = null);

public sealed record ApplicationTarget(
    string Name,
    string? BundleIdentifier,
    bool IsRunning,
    IReadOnlyList<string> SupportedActions);

public sealed record DeviceAuthority(
    string Capability,
    string DisplayName,
    string Access,
    IReadOnlyList<string> RequiredPermissions,
    string? Message = null);

public sealed record DeviceInfo(
    string Id,
    string DisplayName,
    string Hostname,
    string LocalIPAddress,
    int Port,
    string ServiceStatus,
    IReadOnlyList<string> AvailableApplications,
    IReadOnlyList<ApplicationTarget> ApplicationTargets,
    IReadOnlyList<string> Capabilities,
    IReadOnlyList<DeviceAuthority> Authorities,
    string Platform = "windows");

public sealed record OperationManifestEntry(
    string Operation,
    string Capability,
    bool Destructive,
    bool RequiresUserPresence,
    IReadOnlyList<string> SupportedPlatforms);

public static class WindowsOperationManifest
{
    public const int Version = 1;

    // This is intentionally a conservative Windows advertisement. A capability is published only
    // when the adapter below has a real implementation; the backend then prunes everything else.
    public static IReadOnlyList<OperationManifestEntry> Entries { get; } =
    [
        new("getSystemStatus", "runtime.status", false, false, ["macOS", "windows"]),
        new("ping", "runtime.status", false, false, ["macOS", "windows"]),
        new("openApplication", "device.app.open", false, false, ["macOS", "windows"]),
        new("openApplicationByName", "device.app.open_by_name", false, false, ["macOS", "windows"]),
        new("controlApplication", "device.app.control", false, false, ["macOS", "windows"]),
        new("listRunningApplications", "device.app.list", false, false, ["macOS", "windows"]),
        new("openURL", "device.url.open", false, false, ["macOS", "windows"]),
        new("listFiles", "device.files.list", false, false, ["macOS", "windows"]),
        new("readFile", "device.files.read", false, false, ["macOS", "windows"]),
        new("writeFile", "device.files.write", true, true, ["macOS", "windows"]),
        new("moveFile", "device.files.move", true, true, ["macOS", "windows"]),
        new("copyFile", "device.files.copy", true, true, ["macOS", "windows"])
    ];

    public static IReadOnlyList<string> AdvertisedCapabilities =>
        Entries.Where(entry => entry.SupportedPlatforms.Contains("windows", StringComparer.OrdinalIgnoreCase))
            .Select(entry => entry.Capability)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(value => value, StringComparer.Ordinal)
            .ToArray();
}

public interface IWindowsOperationAdapter
{
    Task<(JsonElement? Data, string Message, RovaError? Error)> ExecuteAsync(CommandRequest request, CancellationToken cancellationToken);
}

/// <summary>Bounded, durable command identity ledger. Unknown is terminal for side effects.</summary>
public sealed class CommandLedger
{
    private const int MaximumEntries = 128;
    private readonly object gate = new();
    private readonly string? filePath;
    private readonly Dictionary<string, CommandResult> results = new(StringComparer.Ordinal);

    public CommandLedger(string? filePath = null)
    {
        this.filePath = filePath;
        Load();
    }

    public bool TryGet(string id, out CommandResult result)
    {
        lock (gate) return results.TryGetValue(id, out result!);
    }

    public void Remember(CommandResult result)
    {
        lock (gate)
        {
            results[result.CommandId] = result;
            while (results.Count > MaximumEntries)
            {
                var oldest = results.Values.OrderBy(item => item.FinishedAt).First().CommandId;
                results.Remove(oldest);
            }
            Save();
        }
    }

    private void Load()
    {
        if (string.IsNullOrWhiteSpace(filePath) || !File.Exists(filePath)) return;
        try
        {
            var loaded = JsonSerializer.Deserialize<List<CommandResult>>(File.ReadAllText(filePath), JsonOptions.Default) ?? [];
            foreach (var result in loaded.TakeLast(MaximumEntries)) results[result.CommandId] = result;
        }
        catch
        {
            // A corrupt local ledger must not prevent the PC client from opening. New commands
            // still receive fresh IDs and the next successful result replaces the file.
        }
    }

    private void Save()
    {
        if (string.IsNullOrWhiteSpace(filePath)) return;
        try
        {
            var directory = Path.GetDirectoryName(filePath);
            if (!string.IsNullOrWhiteSpace(directory)) Directory.CreateDirectory(directory);
            var temporary = filePath + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(results.Values.OrderBy(item => item.FinishedAt), JsonOptions.Default));
            File.Move(temporary, filePath, true);
        }
        catch
        {
            // The in-memory ledger remains authoritative for the running process.
        }
    }
}

public sealed class WindowsCommandEngine
{
    private readonly IWindowsOperationAdapter adapter;
    private readonly CommandLedger ledger;
    private readonly SemaphoreSlim executionGate = new(1, 1);
    private readonly ConcurrentDictionary<string, Task<CommandResult>> inFlight = new(StringComparer.Ordinal);

    public WindowsCommandEngine(IWindowsOperationAdapter adapter, CommandLedger ledger)
    {
        this.adapter = adapter;
        this.ledger = ledger;
    }

    public async Task<CommandResult> ExecuteAsync(CommandRequest request, CancellationToken cancellationToken = default)
    {
        if (ledger.TryGet(request.Id, out var previous)) return previous;
        if (inFlight.TryGetValue(request.Id, out var existing)) return await existing.ConfigureAwait(false);

        var task = ExecuteFreshAsync(request, cancellationToken);
        if (!inFlight.TryAdd(request.Id, task)) return await inFlight[request.Id].ConfigureAwait(false);
        try { return await task.ConfigureAwait(false); }
        finally { inFlight.TryRemove(request.Id, out _); }
    }

    private async Task<CommandResult> ExecuteFreshAsync(CommandRequest request, CancellationToken cancellationToken)
    {
        if (ledger.TryGet(request.Id, out var previous)) return previous;
        var started = DateTimeOffset.UtcNow;
        var sideEffect = WindowsOperationManifest.Entries.FirstOrDefault(entry => entry.Operation.Equals(request.Type, StringComparison.OrdinalIgnoreCase))?.Destructive == true;
        var timeout = request.Type switch
        {
            "readDocument" or "editDocument" or "executeCode" => TimeSpan.FromSeconds(60),
            "listFiles" or "readFile" or "writeFile" or "moveFile" or "copyFile" => TimeSpan.FromSeconds(20),
            _ => TimeSpan.FromSeconds(10)
        };

        await executionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var operation = adapter.ExecuteAsync(request, cancellationToken);
            try
            {
                var outcome = await operation.WaitAsync(timeout, cancellationToken).ConfigureAwait(false);
                var result = new CommandResult(request.Id, outcome.Error is null ? CommandStatus.Completed : CommandStatus.Failed, outcome.Message, started, DateTimeOffset.UtcNow, outcome.Data, outcome.Error);
                ledger.Remember(result);
                return result;
            }
            catch (TimeoutException)
            {
                var error = new RovaError("COMMAND_TIMEOUT", sideEffect
                    ? "İşlem zaman aşımına uğradı; sonucu doğrulanamadığı için tekrar çalıştırılmadı."
                    : "İşlem zaman aşımına uğradı.", "timeout");
                var result = new CommandResult(request.Id, sideEffect ? CommandStatus.Unknown : CommandStatus.Failed, error.Message, started, DateTimeOffset.UtcNow, null, error);
                ledger.Remember(result);
                return result;
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            var error = new RovaError("COMMAND_FAILED", "Komut çalıştırılamadı.", "tool_failure");
            var result = new CommandResult(request.Id, CommandStatus.Failed, error.Message, started, DateTimeOffset.UtcNow, null, error);
            ledger.Remember(result);
            return result;
        }
        finally
        {
            executionGate.Release();
        }
    }
}

public sealed class BackendRelayConnection
{
    private readonly JsonSerializerOptions jsonOptions = JsonOptions.Default;
    private readonly Uri endpoint;
    private readonly WindowsCommandEngine engine;
    private readonly DeviceInfo deviceInfo;
    private readonly string? commandSigningToken;
    private readonly Action<bool> onConnectionStateChange;
    private ClientWebSocket? socket;
    private CancellationTokenSource? lifetime;

    public BackendRelayConnection(
        Uri endpoint,
        WindowsCommandEngine engine,
        DeviceInfo deviceInfo,
        string? commandSigningToken = null,
        Action<bool>? onConnectionStateChange = null)
    {
        this.endpoint = endpoint;
        this.engine = engine;
        this.deviceInfo = deviceInfo;
        this.commandSigningToken = commandSigningToken;
        this.onConnectionStateChange = onConnectionStateChange ?? (_ => { });
    }

    public async Task RunAsync(string token, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(token)) throw new ArgumentException("A backend token is required.", nameof(token));
        var delays = new[] { 1, 2, 4, 8, 16, 30 };
        var attempt = 0;
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await ConnectOnceAsync(token, cancellationToken).ConfigureAwait(false);
                attempt = 0;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
            catch
            {
                onConnectionStateChange(false);
                var delay = delays[Math.Min(attempt++, delays.Length - 1)];
                await Task.Delay(TimeSpan.FromSeconds(delay), cancellationToken).ConfigureAwait(false);
            }
        }
    }

    private async Task ConnectOnceAsync(string token, CancellationToken cancellationToken)
    {
        using var client = new ClientWebSocket();
        client.Options.SetRequestHeader("Authorization", "Bearer " + token);
        client.Options.KeepAliveInterval = TimeSpan.FromSeconds(20);
        await client.ConnectAsync(endpoint, cancellationToken).ConfigureAwait(false);
        socket = client;
        lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        await SendJsonAsync(new
        {
            type = "register",
            protocolVersion = 2,
            deviceId = deviceInfo.Id,
            displayName = deviceInfo.DisplayName,
            platform = deviceInfo.Platform,
            capabilities = deviceInfo.Capabilities,
            applicationTargets = deviceInfo.ApplicationTargets,
            authorities = deviceInfo.Authorities
        }, lifetime.Token).ConfigureAwait(false);
        onConnectionStateChange(true);
        await ReceiveLoopAsync(lifetime.Token).ConfigureAwait(false);
    }

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        var buffer = new byte[128 * 1024];
        while (!cancellationToken.IsCancellationRequested && socket is { State: WebSocketState.Open } current)
        {
            using var message = new MemoryStream();
            WebSocketReceiveResult result;
            do
            {
                result = await current.ReceiveAsync(buffer, cancellationToken).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close) return;
                message.Write(buffer, 0, result.Count);
            } while (!result.EndOfMessage);
            using var document = JsonDocument.Parse(message.ToArray());
            var root = document.RootElement;
            var type = root.TryGetProperty("type", out var typeValue) ? typeValue.GetString() : null;
            if (type is "interactiveCommand") await HandleInteractiveCommandAsync(root, cancellationToken).ConfigureAwait(false);
            else if (type is "automationStep") await HandleAutomationStepAsync(root, cancellationToken).ConfigureAwait(false);
            else if (type is "automationRun") await HandleLegacyAutomationAsync(root, cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task HandleInteractiveCommandAsync(JsonElement root, CancellationToken cancellationToken)
    {
        var commandId = root.GetProperty("commandId").GetString() ?? string.Empty;
        var request = root.GetProperty("request").Deserialize<CommandRequest>(jsonOptions) ?? throw new JsonException("Missing command request.");
        if (string.IsNullOrWhiteSpace(commandSigningToken) || !CommandRequestSecurity.VerifySignature(request, commandSigningToken))
        {
            var now = DateTimeOffset.UtcNow;
            var error = new RovaError("INVALID_SIGNATURE", "Komut doğrulanamadı.", "permission");
            var denied = new CommandResult(request.Id, CommandStatus.Denied, error.Message, now, now, null, error);
            await SendJsonAsync(new { type = "interactiveCommandResult", commandId, result = denied }, cancellationToken).ConfigureAwait(false);
            return;
        }
        var result = await engine.ExecuteAsync(request, cancellationToken).ConfigureAwait(false);
        await SendJsonAsync(new { type = "interactiveCommandResult", commandId, result }, cancellationToken).ConfigureAwait(false);
    }

    private async Task HandleAutomationStepAsync(JsonElement root, CancellationToken cancellationToken)
    {
        var runId = root.GetProperty("runId").GetInt32();
        var stepId = root.GetProperty("stepId").GetInt32();
        var commandId = root.GetProperty("commandId").GetString() ?? string.Empty;
        var step = root.GetProperty("step");
        await SendJsonAsync(new { type = "automationStepAck", protocolVersion = 2, runId, stepId, commandId }, cancellationToken).ConfigureAwait(false);
        if (!Guid.TryParse(commandId, out _))
        {
            var error = new RovaError("INVALID_COMMAND_ID", "Otomasyon komut kimliği geçersiz.", "validation");
            await SendJsonAsync(new
            {
                type = "automationStepResult",
                protocolVersion = 2,
                runId,
                stepId,
                commandId,
                status = "denied",
                message = error.Message,
                error
            }, cancellationToken).ConfigureAwait(false);
            return;
        }
        var isDestructive = step.TryGetProperty("isDestructive", out var destructiveValue) && destructiveValue.ValueKind == JsonValueKind.True;
        var requiresPresence = step.TryGetProperty("requiresUserPresence", out var presenceValue) && presenceValue.ValueKind == JsonValueKind.True;
        if (isDestructive || requiresPresence)
        {
            var error = new RovaError("AUTOMATION_STEP_BLOCKED", "Bu otomasyon adımı kullanıcı onayı gerektiriyor.", "permission");
            await SendJsonAsync(new
            {
                type = "automationStepResult",
                protocolVersion = 2,
                runId,
                stepId,
                commandId,
                status = "denied",
                message = error.Message,
                error
            }, cancellationToken).ConfigureAwait(false);
            return;
        }
        var request = new CommandRequest(
            commandId,
            step.GetProperty("type").GetString() ?? throw new JsonException("Missing automation type."),
            step.GetProperty("payload").Clone(),
            DateTimeOffset.UtcNow);
        var result = await engine.ExecuteAsync(request, cancellationToken).ConfigureAwait(false);
        await SendJsonAsync(new { type = "automationStepResult", protocolVersion = 2, runId, stepId, commandId, status = result.Status.ToString().ToLowerInvariant(), message = result.Message, error = result.Error }, cancellationToken).ConfigureAwait(false);
    }

    private async Task HandleLegacyAutomationAsync(JsonElement root, CancellationToken cancellationToken)
    {
        var runId = root.GetProperty("runId").GetInt32();
        if (!root.TryGetProperty("steps", out var steps) || steps.ValueKind != JsonValueKind.Array) return;
        var index = 0;
        foreach (var step in steps.EnumerateArray())
        {
            var isDestructive = step.TryGetProperty("isDestructive", out var destructiveValue) && destructiveValue.ValueKind == JsonValueKind.True;
            var requiresPresence = step.TryGetProperty("requiresUserPresence", out var presenceValue) && presenceValue.ValueKind == JsonValueKind.True;
            if (isDestructive || requiresPresence) { index++; continue; }
            var type = step.GetProperty("type").GetString();
            if (string.IsNullOrWhiteSpace(type) || !step.TryGetProperty("payload", out var payload)) { index++; continue; }
            var commandId = StableLegacyCommandId(runId, index);
            await engine.ExecuteAsync(new CommandRequest(commandId, type, payload.Clone(), DateTimeOffset.UtcNow), cancellationToken).ConfigureAwait(false);
            index++;
        }
    }

    private static string StableLegacyCommandId(int runId, int stepIndex)
    {
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes($"legacy-automation:{runId}:{stepIndex}"));
        return new Guid(digest[..16]).ToString();
    }

    private async Task SendJsonAsync(object value, CancellationToken cancellationToken)
    {
        var current = socket ?? throw new InvalidOperationException("Relay socket is not connected.");
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, jsonOptions);
        await current.SendAsync(bytes, WebSocketMessageType.Text, true, cancellationToken).ConfigureAwait(false);
    }
}

internal static class JsonOptions
{
    public static JsonSerializerOptions Default { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };
}

public static class CommandRequestSecurity
{
    public static bool VerifySignature(CommandRequest request, string token)
    {
        if (!Guid.TryParse(request.Id, out var id) || string.IsNullOrWhiteSpace(request.Nonce) || request.Nonce.Length > 200 || string.IsNullOrWhiteSpace(token)) return false;
        if (request.CreatedAt < DateTimeOffset.UtcNow.AddMinutes(-10) || request.CreatedAt > DateTimeOffset.UtcNow.AddMinutes(10)) return false;

        var message = $"{id.ToString().ToUpperInvariant()}:{request.Type}:{request.Nonce}";
        using var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(token));
        var expected = hmac.ComputeHash(Encoding.UTF8.GetBytes(message));
        byte[] actual;
        try { actual = Convert.FromHexString(request.Signature ?? string.Empty); }
        catch (FormatException) { return false; }
        return CryptographicOperations.FixedTimeEquals(actual, expected);
    }
}
