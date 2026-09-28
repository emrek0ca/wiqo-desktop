using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace RovaWindows.App;

/// Connection status, the capability groups (turning one off stops advertising and running it),
/// the terminal switch, start-with-Windows, and pairing.
public partial class SettingsWindow : Window
{
    private static readonly Dictionary<string, string> Descriptions = new(StringComparer.Ordinal)
    {
        ["apps"] = "Uygulama açma, öne getirme, kapatma ve açık uygulamaları listeleme.",
        ["system"] = "Kilitleme, uyku, ekranı kapatma, ses ve medya kontrolü.",
        ["files"] = "Dosya listeleme, okuma, yazma, taşıma ve Geri Dönüşüm Kutusu'na silme.",
        ["documents"] = "Wiqo'nun hazırladığı dosyaları masaüstüne kaydetme.",
        ["screen"] = "Ekran görüntüsü alma.",
        ["clipboard"] = "Panoya metin yazma ve panodaki metni okuma.",
        ["web"] = "Bağlantıları varsayılan tarayıcıda açma."
    };

    private readonly CompanionHost host;
    private readonly Action showPairing;
    private bool loading;

    internal SettingsWindow(CompanionHost host, Action showPairing)
    {
        this.host = host;
        this.showPairing = showPairing;
        InitializeComponent();
        loading = true;
        foreach (var group in CapabilitySettings.Groups) GroupList.Children.Add(GroupSwitch(group));
        TerminalSwitch.IsChecked = host.Runtime.Settings.TerminalEnabled;
        AgentSwitch.IsChecked = host.Runtime.Settings.AgentFullAccess;
        AutoStartSwitch.IsChecked = AutoStart.IsEnabled;
        loading = false;
        DeviceText.Text = host.Runtime.DisplayName;
        VersionText.Text = $"Sürüm {typeof(SettingsWindow).Assembly.GetName().Version?.ToString(3)}";
        Update(host.State);
    }

    internal void Update(ConnectionState state)
    {
        var (text, brush) = state switch
        {
            ConnectionState.Connected => ("Bağlı - telefonundan gelen isteklere hazır", "Ok"),
            ConnectionState.Connecting => ("Bağlanıyor…", "Warn"),
            ConnectionState.NeedsPairing => ("Telefon bağlı değil", "Danger"),
            _ => ("Bağlantı yok - yeniden deneniyor", "Warn")
        };
        StatusText.Text = text;
        StatusDot.Fill = (Brush)FindResource(brush);
        PairButton.Content = host.IsPaired ? "Eşleşmeyi kaldır" : "Telefonu bağla";
        PairButton.Foreground = host.IsPaired ? (Brush)FindResource("Danger") : (Brush)FindResource("Ink");
    }

    private UIElement GroupSwitch(CapabilityGroup group)
    {
        var content = new StackPanel();
        content.Children.Add(new TextBlock { Text = group.Title, FontWeight = FontWeights.SemiBold });
        content.Children.Add(new TextBlock { Text = Descriptions.GetValueOrDefault(group.Id, ""), Style = (Style)FindResource("Body"), FontSize = 12 });
        var toggle = new CheckBox { Content = content, Style = (Style)FindResource("Switch"), IsChecked = host.Runtime.Settings.IsGroupEnabled(group), Margin = new Thickness(0, 8, 0, 8) };
        toggle.Checked += (_, _) => { if (!loading) host.Runtime.Settings.SetGroup(group, true); };
        toggle.Unchecked += (_, _) => { if (!loading) host.Runtime.Settings.SetGroup(group, false); };
        return toggle;
    }

    private void OnTerminalChanged(object sender, RoutedEventArgs e)
    {
        if (!loading) host.Runtime.Settings.TerminalEnabled = TerminalSwitch.IsChecked == true;
    }

    private void OnAgentChanged(object sender, RoutedEventArgs e)
    {
        if (!loading) host.Runtime.Settings.AgentFullAccess = AgentSwitch.IsChecked == true;
    }

    private void OnAutoStartChanged(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        try { AutoStart.Set(AutoStartSwitch.IsChecked == true); }
        catch (Exception error) { Log.Error("Otomatik başlatma", error); }
    }

    private async void OnPairToggle(object sender, RoutedEventArgs e)
    {
        if (!host.IsPaired)
        {
            showPairing();
            return;
        }
        var answer = MessageBox.Show(this, "Bu bilgisayarın telefonunla eşleşmesi kaldırılsın mı? Wiqo yeniden bağlanana kadar bu bilgisayarda işlem yapamaz.",
            "Eşleşmeyi kaldır", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
        if (answer != MessageBoxResult.Yes) return;
        await host.UnpairAsync();
        Update(host.State);
    }

    private void OnOpenLogs(object sender, RoutedEventArgs e)
    {
        System.IO.Directory.CreateDirectory(Log.Directory);
        Process.Start(new ProcessStartInfo("explorer.exe", Log.Directory) { UseShellExecute = true })?.Dispose();
    }
}
