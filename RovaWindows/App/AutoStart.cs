using Microsoft.Win32;

namespace RovaWindows.App;

/// "Start with Windows" for this user only (HKCU Run), launched quietly into the tray.
internal static class AutoStart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Wiqo";
    internal const string BackgroundArgument = "--background";

    internal static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string value && value.Contains(Environment.ProcessPath ?? "\u0000", StringComparison.OrdinalIgnoreCase);
        }
    }

    internal static void Set(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled && Environment.ProcessPath is { } path) key.SetValue(ValueName, $"\"{path}\" {BackgroundArgument}");
        else key.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}
