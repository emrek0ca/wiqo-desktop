using System.Windows;
using System.Windows.Threading;

namespace RovaWindows.App;

/// Wiqo for Windows: one instance per user, living in the notification area. Launched by the user
/// it shows pairing (or settings when already paired); launched at sign-in it stays in the tray.
public partial class WiqoApp : Application
{
    private const string InstanceName = "Local\\Wiqo.Companion";
    private Mutex? instance;
    private EventWaitHandle? showSignal;
    private CompanionHost? host;
    private TrayIcon? tray;
    private PairingWindow? pairingWindow;
    private SettingsWindow? settingsWindow;
    private ProjectsWindow? projectsWindow;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // The theme must be in place before any window resolves its StaticResource styles.
        if (Resources["WiqoWindow"] is null)
            Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/Wiqo;component/Theme.xaml", UriKind.Absolute) });
        instance = new Mutex(true, InstanceName, out var first);
        showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, InstanceName + ".Show");
        if (!first)
        {
            // Already running: bring its window forward instead of starting a second companion.
            showSignal.Set();
            Shutdown();
            return;
        }
        DispatcherUnhandledException += (_, args) => { Log.Error("Arayüz", args.Exception); args.Handled = true; };
        AppDomain.CurrentDomain.UnhandledException += (_, args) => { if (args.ExceptionObject is Exception error) Log.Error("Uygulama", error); };
        TaskScheduler.UnobservedTaskException += (_, args) => { Log.Error("Görev", args.Exception); args.SetObserved(); };

        Log.Info($"Wiqo {typeof(WiqoApp).Assembly.GetName().Version} başladı.");
        host = new CompanionHost();
        tray = new TrayIcon(host, ShowMain, ShowPairing, ShowSettings, ShowProjects, Quit);
        host.StateChanged += state => Dispatcher.BeginInvoke(() => OnStateChanged(state));
        host.Start();

        var background = e.Args.Contains(AutoStart.BackgroundArgument, StringComparer.OrdinalIgnoreCase);
        if (!background) ShowMain();
        else if (!host.IsPaired) tray.Notify("Wiqo'yu kullanmak için telefonunu bağla.");

        var waiter = new Thread(() =>
        {
            while (showSignal.WaitOne()) Dispatcher.BeginInvoke(ShowMain);
        }) { IsBackground = true, Name = "Wiqo show signal" };
        waiter.Start();
    }

    private void OnStateChanged(ConnectionState state)
    {
        tray?.Update(state);
        settingsWindow?.Update(state);
        if (state == ConnectionState.NeedsPairing && pairingWindow is null && settingsWindow is null) tray?.Notify("Telefon eşleşmesi sona erdi; yeniden bağla.");
    }

    private void ShowMain()
    {
        if (host is null) return;
        if (host.IsPaired) ShowSettings(); else ShowPairing();
    }

    private void ShowPairing()
    {
        if (host is null) return;
        if (pairingWindow is not null) { pairingWindow.Activate(); return; }
        pairingWindow = new PairingWindow(host);
        pairingWindow.Closed += (_, _) =>
        {
            var paired = pairingWindow?.Paired == true;
            pairingWindow = null;
            if (paired) tray?.Notify("Wiqo bu bilgisayara bağlandı.");
        };
        pairingWindow.Show();
        pairingWindow.Activate();
    }

    private void ShowSettings()
    {
        if (host is null) return;
        if (settingsWindow is not null) { settingsWindow.Activate(); return; }
        settingsWindow = new SettingsWindow(host, ShowPairing);
        settingsWindow.Closed += (_, _) => settingsWindow = null;
        settingsWindow.Show();
        settingsWindow.Activate();
    }

    private void ShowProjects()
    {
        if (host is null) return;
        if (projectsWindow is not null) { projectsWindow.Activate(); return; }
        projectsWindow = new ProjectsWindow(host.Projects);
        projectsWindow.Closed += (_, _) => projectsWindow = null;
        projectsWindow.Show();
    }

    private async void Quit()
    {
        tray?.Dispose();
        if (host is not null)
        {
            try { await host.DisposeAsync(); } catch (Exception error) { Log.Error("Kapanış", error); }
        }
        Log.Info("Wiqo kapandı.");
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        instance?.Dispose();
        showSignal?.Dispose();
        base.OnExit(e);
    }
}
