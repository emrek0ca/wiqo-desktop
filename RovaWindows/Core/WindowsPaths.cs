namespace RovaWindows;

/// Where the companion keeps its state: settings and secrets roam with the user profile, logs and
/// the result ledger stay on this machine.
public static class WindowsPaths
{
    public static string RoamingDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Wiqo");
    public static string LocalDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Wiqo");
    public static string LogDirectory => Path.Combine(LocalDirectory, "logs");
    public static string UserProfile => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public static string Desktop => Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
}
