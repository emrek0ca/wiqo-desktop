using System.Text.Json;

namespace RovaWindows;

public sealed record LedgerEntry(string CommandId, string Status, string Message, WireError? Error, DateTimeOffset FinishedAt);

/// The last 128 command outcomes on disk (MacCommandEngine's CommandLedger). A command that
/// finished while the connection dropped is reported on the next connection ("automationReceipts"),
/// and a command id that already ran is never executed a second time - even after a restart.
public sealed class ResultLedger
{
    private const int Limit = 128;
    private readonly string path;
    private readonly object gate = new();
    private readonly Dictionary<string, LedgerEntry> entries;

    public ResultLedger(string? path = null)
    {
        this.path = path ?? Path.Combine(WindowsPaths.LocalDirectory, "command-ledger.json");
        entries = Load(this.path);
    }

    public LedgerEntry? Find(string commandId)
    {
        lock (gate) return entries.TryGetValue(commandId, out var entry) ? entry : null;
    }

    /// Written before a side effect starts: a crash mid-operation reports "unknown", never a replay.
    public void RecordRunning(string commandId) =>
        Record(new LedgerEntry(commandId, "unknown", "İşlem yarıda kaldı; sonucu doğrulanamadı.", new WireError("INTERRUPTED", "Windows işlemi yarıda kaldı; sonucu doğrulanamadı.", "unknown"), DateTimeOffset.UtcNow));

    public void Record(WindowsCommandResult result) =>
        Record(new LedgerEntry(result.CommandId, result.Status, result.Message, result.Error as WireError, result.FinishedAt));

    public IReadOnlyList<LedgerEntry> Recent()
    {
        lock (gate) return entries.Values.OrderByDescending(entry => entry.FinishedAt).Take(Limit).ToArray();
    }

    private void Record(LedgerEntry entry)
    {
        lock (gate)
        {
            entries[entry.CommandId] = entry;
            foreach (var old in entries.Values.OrderByDescending(item => item.FinishedAt).Skip(Limit).Select(item => item.CommandId).ToArray()) entries.Remove(old);
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                var temporary = path + ".tmp";
                File.WriteAllText(temporary, JsonSerializer.Serialize(entries.Values, WireJson.Options));
                File.Move(temporary, path, true);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static Dictionary<string, LedgerEntry> Load(string path)
    {
        try
        {
            var items = JsonSerializer.Deserialize<LedgerEntry[]>(File.ReadAllText(path), WireJson.Options) ?? [];
            return items.Where(item => item.CommandId.Length > 0).GroupBy(item => item.CommandId, StringComparer.OrdinalIgnoreCase)
                .ToDictionary(group => group.Key, group => group.OrderByDescending(item => item.FinishedAt).First(), StringComparer.OrdinalIgnoreCase);
        }
        catch { return new Dictionary<string, LedgerEntry>(StringComparer.OrdinalIgnoreCase); }
    }
}
