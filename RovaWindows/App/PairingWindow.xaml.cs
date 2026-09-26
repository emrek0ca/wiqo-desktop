using System.IO;
using System.Windows;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using QRCoder;

namespace RovaWindows.App;

/// Shows the relay pairing QR, counts down its lifetime, renews it when it expires and closes on
/// success. Closing the window stops polling at once.
public partial class PairingWindow : Window
{
    private readonly CompanionHost host;
    private readonly DispatcherTimer countdown = new() { Interval = TimeSpan.FromSeconds(1) };
    private CancellationTokenSource? attempt;
    private DateTimeOffset expiresAt;

    internal bool Paired { get; private set; }

    internal PairingWindow(CompanionHost host)
    {
        this.host = host;
        InitializeComponent();
        countdown.Tick += (_, _) => UpdateCountdown();
        Loaded += (_, _) => _ = RunAsync();
        Closed += (_, _) => { attempt?.Cancel(); countdown.Stop(); };
    }

    private async Task RunAsync()
    {
        attempt?.Cancel();
        var cancel = new CancellationTokenSource();
        attempt = cancel;
        RefreshButton.IsEnabled = false;
        // A few renewals cover a user who walks away for a while; after that they press "Yeni kod".
        for (var round = 0; round < 6 && !cancel.IsCancellationRequested; round++)
        {
            WindowsRelayPairingQr session;
            try
            {
                StatusText.Text = "Kod hazırlanıyor…";
                session = await host.CreatePairingAsync(cancel.Token);
            }
            catch (OperationCanceledException) { return; }
            catch (Exception error)
            {
                Log.Error("Eşleme kodu", error);
                StatusText.Text = "Wiqo sunucusuna ulaşılamadı. İnternet bağlantını kontrol et.";
                RefreshButton.IsEnabled = true;
                return;
            }
            ShowQr(session.Value);
            expiresAt = session.ExpiresAt;
            countdown.Start();
            UpdateCountdown();
            RefreshButton.IsEnabled = true;
            bool paired;
            try { paired = await host.PairAsync(session, cancel.Token); }
            catch (OperationCanceledException) { return; }
            catch (Exception error)
            {
                Log.Error("Eşleme", error);
                countdown.Stop();
                StatusText.Text = "Eşleşme tamamlanamadı. Yeni kod oluşturup tekrar dene.";
                RefreshButton.IsEnabled = true;
                return;
            }
            if (paired)
            {
                Paired = true;
                countdown.Stop();
                SuccessOverlay.Visibility = Visibility.Visible;
                StatusText.Text = "Telefonun bu bilgisayara bağlandı.";
                await Task.Delay(1500);
                Close();
                return;
            }
        }
        countdown.Stop();
        StatusText.Text = "Kodun süresi doldu.";
    }

    private void ShowQr(string value)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(value, QRCodeGenerator.ECCLevel.Q);
        var png = new PngByteQRCode(data).GetGraphic(12, [17, 17, 17], [255, 255, 255], drawQuietZones: true);
        var image = new BitmapImage();
        using (var stream = new MemoryStream(png))
        {
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.StreamSource = stream;
            image.EndInit();
        }
        image.Freeze();
        QrImage.Source = image;
        QrPlaceholder.Visibility = Visibility.Collapsed;
    }

    private void UpdateCountdown()
    {
        var left = expiresAt - DateTimeOffset.UtcNow;
        StatusText.Text = left > TimeSpan.Zero ? $"Telefonun bekleniyor · kod {left:m\\:ss} geçerli" : "Yeni kod hazırlanıyor…";
    }

    private void OnRefresh(object sender, RoutedEventArgs e) => _ = RunAsync();
}
