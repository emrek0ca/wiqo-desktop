using System.Net.NetworkInformation;
using Microsoft.Win32;
using RovaWindows.Operations;

namespace RovaWindows.App;

/// The companion's lifetime, independent of any window: pairing, the relay connection, and the
/// Windows events that must reconnect it at once (resume from sleep, network change, a settings
/// change that alters what the registration advertises).
internal sealed class CompanionHost : IAsyncDisposable
{
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(30) };
    private readonly CancellationTokenSource lifetime = new();
    private CancellationTokenSource? loopCancel;
    private Task? loop;
    private Timer? networkDebounce;

    internal RovaWindows.Projects.WindowsProjectSync Projects { get; }
    private Task? projectLoop;

    internal WindowsRuntime Runtime { get; }
    internal DeviceSessionClient Sessions { get; }
    internal ProtocolV2Client Client { get; }
    internal ConnectionState State { get; private set; } = ConnectionState.Disconnected;
    internal event Action<ConnectionState>? StateChanged;

    internal CompanionHost()
    {
        Runtime = new WindowsRuntime(desktopController: new WindowsDesktopControlAdapter());
        Sessions = new DeviceSessionClient(http);
        Client = new ProtocolV2Client(Runtime, Sessions);
        Projects = new(Sessions.BaseUri, ct => State == ConnectionState.Connected ? Client.AccessTokenAsync(ct) : Task.FromResult<string?>(null));
        Client.StateChanged += OnStateChanged;
        Client.Activity += message => Log.Info(message);
        Runtime.Settings.Changed += () => Client.Reconnect();
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        NetworkChange.NetworkAddressChanged += OnNetworkChanged;
        NetworkChange.NetworkAvailabilityChanged += OnNetworkChanged;
    }

    internal bool IsPaired => DeviceSessionClient.HasStoredPairing;

    internal void Start()
    {
        projectLoop ??= Task.Run(async () =>
        {
            try { await Projects.RunAsync(lifetime.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { }
        });
        if (DeviceSessionClient.LoadStoredCredentials() is { } credentials && IsPaired) StartLoop(credentials);
        else OnStateChanged(ConnectionState.NeedsPairing);
    }

    /// One pairing attempt: a QR the phone scans, polled every two seconds until it is claimed,
    /// expires or the window is closed. On success the relay starts with the new credentials.
    internal async Task<bool> PairAsync(WindowsRelayPairingQr session, CancellationToken cancellationToken)
    {
        while (DateTimeOffset.UtcNow < session.ExpiresAt && !cancellationToken.IsCancellationRequested)
        {
            try
            {
                if (await Sessions.PollRelayPairingAsync(session, cancellationToken).ConfigureAwait(false) is { } credentials)
                {
                    Log.Info("Telefon eşlendi.");
                    StartLoop(credentials);
                    if (!AutoStart.IsEnabled) AutoStart.Set(true);
                    return true;
                }
            }
            catch (InvalidOperationException) { return false; } // expired on the server
            catch (HttpRequestException error) { Log.Error("Eşleme sorgusu", error); }
            await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken).ConfigureAwait(false);
        }
        return false;
    }

    internal Task<WindowsRelayPairingQr> CreatePairingAsync(CancellationToken cancellationToken) =>
        Sessions.CreateRelayPairingQrAsync(Runtime.DeviceId, Runtime.DisplayName, cancellationToken);

    internal async Task UnpairAsync()
    {
        await StopLoopAsync().ConfigureAwait(false);
        DeviceSessionClient.ForgetPairing();
        Runtime.SetPairingToken(null);
        Log.Info("Eşleşme kaldırıldı.");
        OnStateChanged(ConnectionState.NeedsPairing);
    }

    private void StartLoop(DeviceSessionCredentials credentials)
    {
        loopCancel?.Cancel();
        var cancel = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        loopCancel = cancel;
        loop = Task.Run(async () =>
        {
            try { await Client.RunAsync(credentials, cancel.Token).ConfigureAwait(false); }
            catch (Exception error) when (error is not OperationCanceledException) { Log.Error("Bağlantı döngüsü", error); }
        });
    }

    private async Task StopLoopAsync()
    {
        loopCancel?.Cancel();
        if (loop is { } running)
        {
            try { await running.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false); } catch { }
        }
        loop = null;
    }

    private void OnStateChanged(ConnectionState next)
    {
        State = next;
        Log.Info($"Durum: {next}");
        StateChanged?.Invoke(next);
    }

    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Resume) Client.Reconnect();
    }

    /// Wi-Fi changes arrive as a burst of events; reconnect once when it settles.
    private void OnNetworkChanged(object? sender, EventArgs e)
    {
        networkDebounce?.Dispose();
        networkDebounce = new Timer(_ => Client.Reconnect(), null, TimeSpan.FromSeconds(3), Timeout.InfiniteTimeSpan);
    }

    public async ValueTask DisposeAsync()
    {
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
        NetworkChange.NetworkAvailabilityChanged -= OnNetworkChanged;
        networkDebounce?.Dispose();
        lifetime.Cancel();
        await StopLoopAsync().ConfigureAwait(false);
        if (projectLoop is not null) { try { await projectLoop.ConfigureAwait(false); } catch (OperationCanceledException) { } }
        Projects.Dispose();
        await Client.DisposeAsync().ConfigureAwait(false);
        await Runtime.DisposeAsync().ConfigureAwait(false);
        http.Dispose();
    }
}
