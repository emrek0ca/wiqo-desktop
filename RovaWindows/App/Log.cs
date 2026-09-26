using System.Globalization;

namespace RovaWindows.App;

/// A small daily log in %LOCALAPPDATA%\Wiqo\logs (7 days kept) for diagnosing a user's machine.
/// Only states, operation names and error types are written - never tokens, paths or content.
internal static class Log
{
    private static readonly object Gate = new();

    internal static string Directory => WindowsPaths.LogDirectory;

    internal static void Info(string message) => Write("INFO", message);

    internal static void Error(string context, Exception error) => Write("ERROR", $"{context}: {error.GetType().Name}: {error.Message}");

    private static void Write(string level, string message)
    {
        try
        {
            lock (Gate)
            {
                System.IO.Directory.CreateDirectory(Directory);
                var path = Path.Combine(Directory, $"wiqo-{DateTime.Now:yyyyMMdd}.log");
                File.AppendAllText(path, $"{DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture)} {level} {message}{Environment.NewLine}");
                foreach (var old in new DirectoryInfo(Directory).GetFiles("wiqo-*.log").OrderByDescending(file => file.Name).Skip(7)) old.Delete();
            }
        }
        catch { }
    }
}
