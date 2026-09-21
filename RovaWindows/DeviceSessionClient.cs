using System.Net.Http.Json;

namespace RovaWindows;

public sealed record DeviceSessionCredentials(
    string AccessToken,
    string RefreshToken,
    int AccessTokenExpiresIn,
    DateTimeOffset RefreshTokenExpiresAt);

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
        return await ReadAsync(request, cancellationToken).ConfigureAwait(false);
    }

    private async Task<DeviceSessionCredentials?> ReadAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode) return null;
        return await response.Content.ReadFromJsonAsync<DeviceSessionCredentials>(cancellationToken).ConfigureAwait(false);
    }
}
