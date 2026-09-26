namespace RovaWindows;

/// Links, not reparse points: symbolic links and junctions (LinkTarget != null) could redirect an
/// operation outside the approved folder and are refused. Other reparse points are ordinary files -
/// OneDrive "files on demand" marks every cloud file and folder (often the whole Desktop and
/// Documents) as one, and refusing those would break Wiqo for most Windows 11 users.
public static class PathSafety
{
    public static bool IsLink(string path)
    {
        try
        {
            FileSystemInfo info = Directory.Exists(path) ? new DirectoryInfo(path) : new FileInfo(path);
            if (!info.Exists) return false;
            return (info.Attributes & FileAttributes.ReparsePoint) != 0 && info.LinkTarget is not null;
        }
        catch { return true; }
    }

    /// Any link on the way from the drive root to path.
    public static bool HasLinkComponent(string path)
    {
        try
        {
            var root = Path.GetPathRoot(path);
            if (string.IsNullOrEmpty(root)) return true;
            var current = root;
            foreach (var part in path[root.Length..].Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries))
            {
                current = Path.Combine(current, part);
                if (IsLink(current)) return true;
            }
            return false;
        }
        catch { return true; }
    }
}
