using System.Globalization;
using System.Text.RegularExpressions;

namespace RovaWindows.Terminal;

/// A single-file unified diff applied to text in memory: every context and removed line must
/// match exactly, the headers must name the expected file, and the result keeps the original's
/// line endings. Returns null when the patch does not fit (nothing is written by this class).
internal static class UnifiedPatch
{
    private static readonly Regex Hunk = new(@"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));

    internal static string? Apply(string original, string requestPath, string patch)
    {
        var newline = original.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";
        var normalized = original.Replace("\r\n", "\n", StringComparison.Ordinal);
        var hadTrailing = normalized.EndsWith('\n');
        var source = normalized.Split('\n').ToList();
        if (hadTrailing) source.RemoveAt(source.Count - 1);
        var lines = patch.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        if (lines.Length < 4 || !HeaderMatches(lines[0], "--- ", requestPath) || !HeaderMatches(lines[1], "+++ ", requestPath)) return null;
        var output = new List<string>();
        var sourceIndex = 0;
        var index = 2;
        var sawHunk = false;
        while (index < lines.Length)
        {
            if (index == lines.Length - 1 && lines[index].Length == 0) break;
            var match = Hunk.Match(lines[index]);
            if (!match.Success) return null;
            var oldStart = int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture);
            var oldCount = match.Groups[2].Success ? int.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture) : 1;
            var oldCursor = oldCount == 0 && oldStart == 0 ? 0 : Math.Max(0, oldStart - 1);
            if (oldCursor < sourceIndex || oldCursor > source.Count) return null;
            output.AddRange(source.Skip(sourceIndex).Take(oldCursor - sourceIndex));
            sourceIndex = oldCursor;
            sawHunk = true;
            index++;
            var consumedOld = 0;
            while (index < lines.Length && !lines[index].StartsWith("@@ ", StringComparison.Ordinal))
            {
                var line = lines[index];
                if (line.StartsWith("\\ No newline at end of file", StringComparison.Ordinal)) { index++; continue; }
                if (line.Length == 0)
                {
                    if (index == lines.Length - 1) break;
                    return null;
                }
                var content = line[1..];
                switch (line[0])
                {
                    case ' ':
                        if (sourceIndex >= source.Count || source[sourceIndex] != content) return null;
                        output.Add(content); sourceIndex++; consumedOld++; break;
                    case '-':
                        if (sourceIndex >= source.Count || source[sourceIndex] != content) return null;
                        sourceIndex++; consumedOld++; break;
                    case '+': output.Add(content); break;
                    default: return null;
                }
                index++;
            }
            if (consumedOld != oldCount) return null;
        }
        if (!sawHunk) return null;
        output.AddRange(source.Skip(sourceIndex));
        var result = string.Join(newline, output) + (hadTrailing ? newline : "");
        return result.Length == 0 || result == original ? null : result;
    }

    /// "a/src/x.ts", "src/x.ts" or a suffix of the requested path, never /dev/null or "..".
    private static bool HeaderMatches(string line, string prefix, string expected)
    {
        if (!line.StartsWith(prefix, StringComparison.Ordinal)) return false;
        var path = line[prefix.Length..].Split('\t')[0].Trim().Replace('\\', '/');
        if (path == "/dev/null" || path.Split('/', StringSplitOptions.RemoveEmptyEntries).Any(part => part == "..")) return false;
        if (path.StartsWith("a/", StringComparison.Ordinal) || path.StartsWith("b/", StringComparison.Ordinal)) path = path[2..];
        var wanted = expected.Replace('\\', '/');
        if (wanted.StartsWith("a/", StringComparison.Ordinal) || wanted.StartsWith("b/", StringComparison.Ordinal)) wanted = wanted[2..];
        return path.Equals(wanted, StringComparison.OrdinalIgnoreCase) ||
               wanted.EndsWith("/" + path, StringComparison.OrdinalIgnoreCase) || path.EndsWith("/" + wanted, StringComparison.OrdinalIgnoreCase);
    }
}
