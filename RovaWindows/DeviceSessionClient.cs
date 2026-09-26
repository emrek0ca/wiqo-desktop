using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RovaWindows;

public sealed record DeviceSessionCredentials(
    string AccessToken,
    string RefreshToken,
    int AccessTokenExpiresIn,
    DateTimeOffset RefreshTokenExpiresAt);

public sealed record WindowsRelayPairingQr(string Value, string SessionId, string Secret, DateTimeOffset ExpiresAt);

/// HTTP-only device credential bootstrap/rotation. Account credentials never enter the persistent
/// WebSocket once this adapter has issued a scoped device session.
public sealed class DeviceSessionClient
{
    private readonly HttpClient http;
    private readonly Uri baseUri;

    public DeviceSessionClient(HttpClient http, Uri? baseUri = null)
    {
        this.http = http;
        this.baseUri = baseUri ?? new Uri("https://api.wiqoai.com/");
    }

    public Uri BaseUri => baseUri;

    public async Task<WindowsRelayPairingQr> CreateRelayPairingQrAsync(string deviceId, string displayName, CancellationToken cancellationToken = default)
    {
        using var response = await http.PostAsJsonAsync(new Uri(baseUri, "device-pairing/sessions"), new
        {
            deviceId,
            displayName,
            platform = "windows"
        }, cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false));
        var root = document.RootElement;
        var sessionId = root.GetProperty("sessionId").GetString() ?? throw new InvalidDataException("Pairing session id is missing.");
        var secret = root.GetProperty("secret").GetString() ?? throw new InvalidDataException("Pairing session secret is missing.");
        var expiresAt = root.GetProperty("expiresAt").GetDateTimeOffset();
        if (secret.Length < 32) throw new InvalidDataException("Pairing secret is invalid.");
        // Swift JSONDecoder.iso8601 expects the same whole-second UTC form emitted by JSONEncoder.
        var qrExpiry = expiresAt.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture);
        var payload = JsonSerializer.SerializeToUtf8Bytes(new RelayPairingPayloadWire(1, sessionId, secret, qrExpiry), new JsonSerializerOptions(JsonSerializerDefaults.Web));
        var encoded = Convert.ToBase64String(payload).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        return new WindowsRelayPairingQr("rova-relay:v1:" + encoded, sessionId, secret, expiresAt);
    }

    /// Returns null while waiting or when the backend asks the companion to respect poll pacing.
    /// Claimed pairing and rotating device credentials are saved with current-user DPAPI.
    public async Task<DeviceSessionCredentials?> PollRelayPairingAsync(WindowsRelayPairingQr session, CancellationToken cancellationToken = default)
    {
        using var response = await http.PostAsJsonAsync(new Uri(baseUri, $"device-pairing/sessions/{Uri.EscapeDataString(session.SessionId)}/poll"), new { secret = session.Secret }, cancellationToken).ConfigureAwait(false);
        if ((int)response.StatusCode == 429) return null;
        if (response.StatusCode is System.Net.HttpStatusCode.NotFound or System.Net.HttpStatusCode.Gone)
            throw new InvalidOperationException("Eşleşme kodunun süresi doldu; yeni QR oluşturun.");
        response.EnsureSuccessStatusCode();
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false));
        var root = document.RootElement;
        if (!root.TryGetProperty("status", out var status) || status.ValueKind != JsonValueKind.String) throw new InvalidDataException("Eşleşme yanıtı geçersiz.");
        if (status.GetString() == "waiting") return null;
        if (status.GetString() != "claimed") throw new InvalidDataException("Eşleşme yanıtı geçersiz.");
        var pairingToken = root.GetProperty("pairingToken").GetString();
        var expiresIn = root.TryGetProperty("accessTokenExpiresIn", out var accessExpiry) && accessExpiry.TryGetInt32(out var seconds)
            ? seconds : 15 * 60;
        var credentials = new DeviceSessionCredentials(
            root.GetProperty("deviceAccessToken").GetString() ?? "",
            root.GetProperty("deviceRefreshToken").GetString() ?? "",
            expiresIn,
            root.GetProperty("deviceTokenExpiresAt").GetDateTimeOffset());
        if (string.IsNullOrWhiteSpace(pairingToken) || credentials.AccessToken.Length == 0 || credentials.RefreshToken.Length == 0)
            throw new InvalidDataException("Eşleşme kimlik bilgileri eksik.");
        WindowsSecretStore.SavePairingToken(pairingToken);
        WindowsSecretStore.SaveCredentials(credentials);
        return credentials;
    }

    public async Task<DeviceSessionCredentials?> BootstrapAsync(string accountToken, string deviceId, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(baseUri, "device-sessions/bootstrap"));
        request.Headers.Authorization = new("Bearer", accountToken);
        request.Content = JsonContent.Create(new { deviceId });
        return await ReadAsync(request, cancellationToken).ConfigureAwait(false);
    }

    public async Task<DeviceSessionCredentials?> RefreshAsync(string deviceId, string refreshToken, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(baseUri, "device-sessions/refresh"))
        {
            Content = JsonContent.Create(new { deviceId, refreshToken })
        };
        var credentials = await ReadAsync(request, cancellationToken).ConfigureAwait(false);
        if (credentials is not null) WindowsSecretStore.SaveCredentials(credentials);
        return credentials;
    }

    public static DeviceSessionCredentials? LoadStoredCredentials() => WindowsSecretStore.LoadCredentials();

    /// Paired on this Windows account: a pairing token (signs terminal grants) and a device session.
    public static bool HasStoredPairing => WindowsSecretStore.LoadPairingToken() is not null && WindowsSecretStore.LoadCredentials() is not null;

    /// null only when the backend says the credentials are invalid (400/401/403) - the host then
    /// asks for a new pairing. Network trouble and server errors throw, so a flaky connection is
    /// retried instead of forcing the user to scan a QR code again.
    private async Task<DeviceSessionCredentials?> ReadAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        if (response.StatusCode is System.Net.HttpStatusCode.BadRequest or System.Net.HttpStatusCode.Unauthorized or System.Net.HttpStatusCode.Forbidden) return null;
        if (!response.IsSuccessStatusCode) throw new HttpRequestException($"Cihaz oturumu yenilenemedi ({(int)response.StatusCode}).", null, response.StatusCode);
        var credentials = await response.Content.ReadFromJsonAsync<DeviceSessionCredentials>(cancellationToken).ConfigureAwait(false);
        return credentials is { AccessToken.Length: > 0, RefreshToken.Length: > 0 } ? credentials : throw new HttpRequestException("Cihaz oturumu yanıtı eksik.");
    }

    public static void ForgetPairing() => WindowsSecretStore.Clear();
}

internal sealed record RelayPairingPayloadWire(
    int Version,
    [property: JsonPropertyName("sessionID")] string SessionId,
    string Secret,
    string ExpiresAt);
