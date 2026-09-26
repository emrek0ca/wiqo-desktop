using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace RovaWindows.App;

/// The notification-area icon: the Wiqo mark with a status dot (green connected, amber
/// connecting/offline, red pairing needed) and the companion's menu.
internal sealed class TrayIcon : IDisposable
{
    private readonly NotifyIcon icon;
    private readonly ToolStripMenuItem status;
    private readonly ToolStripMenuItem autoStart;
    private readonly Icon baseIcon;
    private Icon? current;

    internal TrayIcon(CompanionHost host, Action showMain, Action showPairing, Action showSettings, Action quit)
    {
        using (var stream = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/Assets/wiqo.ico"))!.Stream)
            baseIcon = new Icon(stream, SystemInformation.SmallIconSize);
        status = new ToolStripMenuItem("Başlatılıyor…") { Enabled = false };
        autoStart = new ToolStripMenuItem("Bilgisayar açılınca başlat") { CheckOnClick = true, Checked = AutoStart.IsEnabled };
        autoStart.CheckedChanged += (_, _) => AutoStart.Set(autoStart.Checked);
        var menu = new ContextMenuStrip();
        menu.Items.AddRange(new ToolStripItem[]
        {
            status,
            new ToolStripSeparator(),
            new ToolStripMenuItem("Telefonu bağla…", null, (_, _) => showPairing()),
            new ToolStripMenuItem("Ayarlar…", null, (_, _) => showSettings()),
            autoStart,
            new ToolStripMenuItem("Günlükleri aç", null, (_, _) => OpenLogs()),
            new ToolStripSeparator(),
            new ToolStripMenuItem("Wiqo'dan çık", null, (_, _) => quit())
        });
        menu.Opening += (_, _) => autoStart.Checked = AutoStart.IsEnabled;
        icon = new NotifyIcon { ContextMenuStrip = menu, Visible = true, Text = "Wiqo" };
        icon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) showMain(); };
        Update(host.State);
    }

    internal void Update(ConnectionState state)
    {
        var (text, color) = state switch
        {
            ConnectionState.Connected => ("Bağlı - telefondan komut bekliyor", Color.FromArgb(22, 163, 74)),
            ConnectionState.Connecting => ("Bağlanıyor…", Color.FromArgb(217, 119, 6)),
            ConnectionState.NeedsPairing => ("Telefon bağlı değil", Color.FromArgb(220, 38, 38)),
            _ => ("Bağlantı yok - yeniden deneniyor", Color.FromArgb(217, 119, 6))
        };
        status.Text = text;
        icon.Text = $"Wiqo - {text}";
        var next = WithDot(color);
        icon.Icon = next;
        current?.Dispose();
        current = next;
    }

    internal void Notify(string message) => icon.ShowBalloonTip(4000, "Wiqo", message, ToolTipIcon.None);

    private Icon WithDot(Color color)
    {
        var size = SystemInformation.SmallIconSize;
        using var bitmap = new Bitmap(size.Width, size.Height);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            graphics.DrawIcon(baseIcon, new Rectangle(Point.Empty, size));
            var dot = Math.Max(6, size.Width * 7 / 16);
            var bounds = new Rectangle(size.Width - dot, size.Height - dot, dot - 1, dot - 1);
            using var brush = new SolidBrush(color);
            using var border = new Pen(Color.White, Math.Max(1, size.Width / 16f));
            graphics.FillEllipse(brush, bounds);
            graphics.DrawEllipse(border, bounds);
        }
        var handle = bitmap.GetHicon();
        try { return (Icon)Icon.FromHandle(handle).Clone(); }
        finally { NativeIcon.DestroyIcon(handle); }
    }

    private static void OpenLogs()
    {
        Directory.CreateDirectory(Log.Directory);
        Process.Start(new ProcessStartInfo("explorer.exe", Log.Directory) { UseShellExecute = true })?.Dispose();
    }

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
        current?.Dispose();
        baseIcon.Dispose();
    }

    private static class NativeIcon
    {
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
        internal static extern bool DestroyIcon(IntPtr handle);
    }
}
