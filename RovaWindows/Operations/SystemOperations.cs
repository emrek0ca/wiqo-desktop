using Microsoft.Win32;
using RovaWindows.Native;

namespace RovaWindows.Operations;

/// Status, power, sound, media, clipboard and screen - the MacSystem+Device counterparts. Result
/// shapes are the Mac's CommandData values (SystemStatus, PingData, ScreenshotContent, ...).
internal static class SystemOperations
{
    internal static Outcome Ping() => Outcome.WithData("ping", new { serverTime = DateTimeOffset.UtcNow }, "Pong.");

    internal static Outcome Status(string runtimeStatus)
    {
        int? battery = null;
        bool? charging = null;
        if (NativeMethods.GetSystemPowerStatus(out var power) && power.BatteryFlag != 128 /* no battery */ && power.BatteryLifePercent <= 100)
        {
            battery = power.BatteryLifePercent;
            charging = power.AcLineStatus == 1;
        }
        int? volume = null;
        try { volume = CoreAudio.GetVolumePercent(); } catch { }
        var status = new
        {
            hostname = Environment.MachineName,
            // The Mac field name is kept for the wire; it carries the Windows version here.
            macOSVersion = WindowsVersion(),
            batteryPercentage = battery,
            isCharging = charging,
            uptimeSeconds = NativeMethods.GetTickCount64() / 1000.0,
            runtimeStatus,
            volumePercentage = volume,
            brightnessPercentage = (int?)null
        };
        return Outcome.WithData("systemStatus", status, "Windows sistem durumu hazır.");
    }

    internal static Outcome Lock() =>
        NativeMethods.LockWorkStation() ? Outcome.Ok("Bilgisayar kilitlendi.") : Outcome.Fail("LOCK_FAILED", "Bilgisayar kilitlenemedi.");

    internal static Outcome Sleep()
    {
        // Returns after the machine wakes up again; the result then reports what happened.
        return NativeMethods.SetSuspendState(false, false, false)
            ? Outcome.Ok("Bilgisayar uyku moduna alındı.")
            : Outcome.Fail("SLEEP_FAILED", "Bilgisayar uyku moduna alınamadı; uyku bu cihazda kapalı olabilir.");
    }

    internal static Outcome DisplaySleep() =>
        NativeMethods.PostMessage(NativeMethods.HwndBroadcast, NativeMethods.WmSysCommand, (IntPtr)NativeMethods.ScMonitorPower, (IntPtr)2)
            ? Outcome.Ok("Ekran uyku moduna alındı.")
            : Outcome.Fail("DISPLAY_SLEEP_FAILED", "Ekran uyku moduna alınamadı.");

    internal static Outcome SetVolume(int level)
    {
        try
        {
            var after = CoreAudio.SetVolumePercent(level);
            return Math.Abs(after - level) <= 1
                ? Outcome.Ok($"Ses %{after} yapıldı.")
                : Outcome.Fail("VOLUME_NOT_APPLIED", $"Ses ayarlandı ama %{after} okundu; hedef %{level} idi.");
        }
        catch (Exception error) when (error is InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            return Outcome.Fail("AUDIO_UNAVAILABLE", "Ses aygıtı bulunamadı veya ayarlanamadı.");
        }
    }

    internal static Outcome ToggleMute()
    {
        try
        {
            var muted = CoreAudio.ToggleMute();
            return Outcome.Ok(muted ? "Ses kapatıldı." : "Ses açıldı.");
        }
        catch (Exception error) when (error is InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            return Outcome.Fail("AUDIO_UNAVAILABLE", "Ses aygıtı bulunamadı veya ayarlanamadı.");
        }
    }

    internal static Outcome Media(string action) =>
        MediaKeys.Press(action) ? Outcome.Ok("Medya komutu uygulandı.") : Outcome.Fail("MEDIA_FAILED", "Medya komutu gönderilemedi.");

    internal static Outcome SetClipboard(string text)
    {
        try
        {
            WindowsClipboard.SetText(text);
            // Read back, like the Mac's clipboard_readback verification.
            return WindowsClipboard.GetText() == text
                ? Outcome.Ok("Metin Windows panosuna kopyalandı.")
                : Outcome.Fail("CLIPBOARD_NOT_VERIFIED", "Metin panoya yazıldı ama geri okunamadı.");
        }
        catch (Exception error) when (error is InvalidOperationException or OutOfMemoryException)
        {
            return Outcome.Fail("CLIPBOARD_BUSY", error.Message);
        }
    }

    internal static Outcome GetClipboard()
    {
        try
        {
            var text = WindowsClipboard.GetText();
            if (string.IsNullOrEmpty(text)) return Outcome.Fail("CLIPBOARD_EMPTY", "Panoda metin yok.");
            return Outcome.WithData("clipboardText", text.Length > 50_000 ? text[..50_000] : text, "Pano içeriği okundu.");
        }
        catch (InvalidOperationException error)
        {
            return Outcome.Fail("CLIPBOARD_BUSY", error.Message);
        }
    }

    internal static Outcome Screenshot(int maxWidth)
    {
        var captured = ScreenCapture.Capture(maxWidth);
        if (captured is null) return Outcome.Fail("SCREENSHOT_FAILED", "Ekran görüntüsü alınamadı veya sınırın altına sıkıştırılamadı.");
        var value = new
        {
            filename = $"wiqo-screen-{Guid.NewGuid()}.jpg",
            mimeType = "image/jpeg",
            dataBase64 = Convert.ToBase64String(captured.Jpeg),
            width = captured.Width,
            height = captured.Height
        };
        return Outcome.WithData("screenshot", value, "Ekran görüntüsü hazır.");
    }

    /// "Windows 11 Pro 23H2 (22631)". ProductName still says "Windows 10" on Windows 11; the build
    /// number is the reliable signal (22000+ is Windows 11).
    internal static string WindowsVersion()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion");
            var product = key?.GetValue("ProductName") as string ?? "Windows";
            var display = key?.GetValue("DisplayVersion") as string ?? "";
            var build = key?.GetValue("CurrentBuild") as string ?? Environment.OSVersion.Version.Build.ToString();
            if (int.TryParse(build, out var number) && number >= 22000) product = product.Replace("Windows 10", "Windows 11", StringComparison.Ordinal);
            return $"{product} {display} ({build})".Replace("  ", " ", StringComparison.Ordinal);
        }
        catch { return Environment.OSVersion.VersionString; }
    }
}
