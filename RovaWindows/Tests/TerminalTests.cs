using System.Text.Json;
using RovaWindows.Terminal;
using Xunit;

namespace RovaWindows.Tests;

public class TerminalFileTests
{
    private static WindowsTerminal Terminal(bool enabled = true) => new(() => Grants.Token, () => enabled);

    private static string Kind(WindowsCommandResult result) => JsonSerializer.SerializeToElement(result.Data, WireJson.Options).GetProperty("kind").GetString()!;
    private static JsonElement Value(WindowsCommandResult result) => JsonSerializer.SerializeToElement(result.Data, WireJson.Options).GetProperty("value");
    private static string Code(WindowsCommandResult result) => ((WireError)result.Error!).Code;

    [Fact]
    public async Task WriteReadEditInsideTheGrant()
    {
        using var folder = new TempFolder();
        await using var terminal = Terminal();
        var grant = Grants.Signed(folder.Path);
        var written = await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "write_file", grant, filePath = "notlar.txt", content = "merhaba\ndünya\n" }));
        Assert.Equal("completed", written.Status);
        Assert.Equal("created", Value(written).GetProperty("text").GetString());

        var edited = await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "edit_file", grant, replacements = new[] { new { filePath = "notlar.txt", find = "merhaba", replace = "selam" } } }));
        Assert.Equal("completed", edited.Status);

        var read = await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "read_file", grant, filePath = "notlar.txt" }));
        Assert.Equal("terminalResult", Kind(read));
        Assert.Equal("1\tselam\n2\tdünya\n3\t\n", Value(read).GetProperty("text").GetString());
    }

    [Fact]
    public void TerminalUndoRestoresOriginalAndRejectsStaleContent()
    {
        using var folder = new TempFolder();
        var path = folder.File("draft.txt", "before");
        var before = File.ReadAllBytes(path);
        File.WriteAllText(path, "after");
        var undoId = TerminalFiles.RegisterUndo(folder.Path, [(path, before, File.ReadAllBytes(path))]);
        Assert.NotNull(undoId);
        File.WriteAllText(path, "newer user edit");
        var stale = TerminalFiles.Undo(undoId!, folder.Path);
        Assert.Equal("TERMINAL_UNDO_STALE", stale.Error?.Code);
        Assert.Equal("newer user edit", File.ReadAllText(path));

        File.WriteAllText(path, "after");
        var freshId = TerminalFiles.RegisterUndo(folder.Path, [(path, before, File.ReadAllBytes(path))]);
        Assert.NotNull(freshId);
        var restored = TerminalFiles.Undo(freshId!, folder.Path);
        Assert.Null(restored.Error);
        Assert.Equal("before", File.ReadAllText(path));
    }

    [Fact]
    public void LocalFileUndoResolvesItsOwnScopeAndIsOneShot()
    {
        using var folder = new TempFolder();
        var path = folder.File("created.txt", "created");
        var undoId = TerminalFiles.RegisterLocalFileUndo(path, null, File.ReadAllBytes(path));
        Assert.NotNull(undoId);
        var undone = TerminalFiles.UndoLocalFile(undoId!);
        Assert.Null(undone.Error);
        Assert.False(File.Exists(path));
        Assert.Equal("TERMINAL_UNDO_INVALID", TerminalFiles.UndoLocalFile(undoId!).Error?.Code);
    }

    [Fact]
    public void LocalFileUndoPreservesNewerContent()
    {
        using var folder = new TempFolder();
        var path = folder.File("draft.txt", "written by Wiqo");
        var undoId = TerminalFiles.RegisterLocalFileUndo(path, System.Text.Encoding.UTF8.GetBytes("before"), File.ReadAllBytes(path));
        Assert.NotNull(undoId);
        File.WriteAllText(path, "newer user edit");

        var result = TerminalFiles.UndoLocalFile(undoId!);
        Assert.Equal("TERMINAL_UNDO_STALE", result.Error?.Code);
        Assert.Equal("newer user edit", File.ReadAllText(path));
    }

    [Fact]
    public void LocalFileMoveUndoRestoresSourceAndRejectsOccupiedSource()
    {
        using var folder = new TempFolder();
        var sourceFolder = Directory.CreateDirectory(Path.Combine(folder.Path, "source")).FullName;
        var targetFolder = Directory.CreateDirectory(Path.Combine(folder.Path, "target")).FullName;
        var source = Path.Combine(sourceFolder, "note.txt");
        var moved = Path.Combine(targetFolder, "note.txt");
        File.WriteAllText(source, "original");
        File.Move(source, moved);
        var undoId = TerminalFiles.RegisterLocalFileMoveUndo(moved, source);
        Assert.NotNull(undoId);

        var undone = TerminalFiles.UndoLocalFile(undoId!);
        Assert.Null(undone.Error);
        Assert.Equal("original", File.ReadAllText(source));
        Assert.False(File.Exists(moved));
        Assert.Equal("TERMINAL_UNDO_INVALID", TerminalFiles.UndoLocalFile(undoId!).Error?.Code);
    }

    [Fact]
    public void LocalFileMoveUndoRecordRejectsReparseSourceAndTargetParents()
    {
        using var folder = new TempFolder();
        var real = Directory.CreateDirectory(Path.Combine(folder.Path, "real")).FullName;
        var linked = Path.Combine(folder.Path, "linked");
        try { Directory.CreateSymbolicLink(linked, real); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or PlatformNotSupportedException) { return; }
        var original = Path.Combine(real, "source.txt");
        var moved = Path.Combine(linked, "moved.txt");
        File.WriteAllText(moved, "content");
        Assert.Null(TerminalFiles.RegisterLocalFileMoveUndo(moved, original));
    }

    [Fact]
    public void LocalFileMoveUndoPreservesNewSourceCollision()
    {
        using var folder = new TempFolder();
        var sourceFolder = Directory.CreateDirectory(Path.Combine(folder.Path, "source")).FullName;
        var targetFolder = Directory.CreateDirectory(Path.Combine(folder.Path, "target")).FullName;
        var source = Path.Combine(sourceFolder, "note.txt");
        var moved = Path.Combine(targetFolder, "note.txt");
        File.WriteAllText(moved, "original");
        var undoId = TerminalFiles.RegisterLocalFileMoveUndo(moved, source);
        Assert.NotNull(undoId);
        File.WriteAllText(source, "new source");

        var result = TerminalFiles.UndoLocalFile(undoId!);
        Assert.Equal("TERMINAL_UNDO_STALE", result.Error?.Code);
        Assert.Equal("new source", File.ReadAllText(source));
        Assert.Equal("original", File.ReadAllText(moved));
    }

    [Fact]
    public async Task OwnFolderFileReadWorksWithoutAGrant()
    {
        var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), $"WiqoReadTest-{Guid.NewGuid():N}");
        Directory.CreateDirectory(folder);
        await using var terminal = Terminal();
        try
        {
            File.WriteAllText(Path.Combine(folder, "note.txt"), "hello");
            var result = await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "read_file", workingDirectory = folder, filePath = "note.txt" }));
            Assert.Equal("completed", result.Status);
            Assert.Contains("hello", Value(result).GetProperty("text").GetString());
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public async Task EditsKeepCrlfAndMatchLfFinds()
    {
        using var folder = new TempFolder();
        var path = folder.File("app.cs", "a\r\nb\r\nc\r\n");
        await using var terminal = Terminal();
        var result = await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "edit_file", grant = Grants.Signed(folder.Path), replacements = new[] { new { filePath = "app.cs", find = "a\nb", replace = "a\nx" } } }));
        Assert.Equal("completed", result.Status);
        Assert.Equal("a\r\nx\r\nc\r\n", File.ReadAllText(path));
    }

    [Fact]
    public async Task WriteKeepsTheFilesLineEndingsAndBom()
    {
        using var folder = new TempFolder();
        var path = Path.Combine(folder.Path, "x.txt");
        File.WriteAllBytes(path, [0xEF, 0xBB, 0xBF, (byte)'a', (byte)'\r', (byte)'\n']);
        await using var terminal = Terminal();
        await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "write_file", grant = Grants.Signed(folder.Path), filePath = "x.txt", content = "b\nc\n" }));
        Assert.Equal(new byte[] { 0xEF, 0xBB, 0xBF, (byte)'b', (byte)'\r', (byte)'\n', (byte)'c', (byte)'\r', (byte)'\n' }, File.ReadAllBytes(path));
    }

    [Fact]
    public async Task ABrokenJsonEditIsRefusedAndTheFileIsUntouched()
    {
        using var folder = new TempFolder();
        var path = folder.File("package.json", "{\n  \"scripts\": {\n    \"test\": \"node test.js\"\n  }\n}\n");
        await using var terminal = Terminal();
        var result = await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "edit_file", grant = Grants.Signed(folder.Path), replacements = new[] { new { filePath = "package.json", find = "\"test\": \"node test.js\"", replace = "\"test\": \"node test.js\" \"lint\": \"x\"" } } }));
        Assert.Equal("failed", result.Status);
        Assert.Equal("TERMINAL_EDIT_INVALID_JSON", Code(result));
        Assert.Contains("\"test\": \"node test.js\"\n", File.ReadAllText(path));
    }

    [Fact]
    public async Task EditIsAllOrNothing()
    {
        using var folder = new TempFolder();
        var first = folder.File("a.txt", "one");
        folder.File("b.txt", "two");
        await using var terminal = Terminal();
        var result = await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new
        {
            action = "edit_file", grant = Grants.Signed(folder.Path),
            replacements = new[] { new { filePath = "a.txt", find = "one", replace = "1" }, new { filePath = "b.txt", find = "missing", replace = "2" } }
        }));
        Assert.Equal("TERMINAL_EDIT_NOT_FOUND", Code(result));
        Assert.Equal("one", File.ReadAllText(first));
    }

    [Fact]
    public async Task SearchFindsLinesWithoutRipgrep()
    {
        using var folder = new TempFolder();
        folder.File("src/math.js", "// TODO: düzelt\nexport const x = 1;\n");
        folder.File("node_modules/lib/index.js", "// TODO inside a dependency\n");
        await using var terminal = Terminal();
        var result = await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "search", grant = Grants.Signed(folder.Path, "read"), pattern = "TODO" }));
        var text = Value(result).GetProperty("text").GetString()!;
        Assert.Contains("src/math.js:1:// TODO: düzelt", text);
        Assert.DoesNotContain("node_modules", text);
    }

    [Fact]
    public async Task UnifiedPatchAppliesOnlyWhenContextMatches()
    {
        using var folder = new TempFolder();
        var path = folder.File("x.txt", "a\nb\nc\n");
        await using var terminal = Terminal();
        var patch = "--- a/x.txt\n+++ b/x.txt\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n";
        var result = await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "apply_patch", grant = Grants.Signed(folder.Path), filePath = "x.txt", patch }));
        Assert.Equal("completed", result.Status);
        Assert.Equal("a\nB\nc\n", File.ReadAllText(path));
        var again = await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "apply_patch", grant = Grants.Signed(folder.Path), filePath = "x.txt", patch }));
        Assert.Equal("TERMINAL_PATCH_REJECTED", Code(again));
    }

    [Fact]
    public async Task SecurityBoundariesHold()
    {
        using var folder = new TempFolder();
        using var outside = new TempFolder();
        outside.File("secret.txt", "x");
        await using var terminal = Terminal();
        var forged = Grants.Signed(folder.Path);
        var tampered = JsonSerializer.SerializeToElement(forged).Deserialize<Dictionary<string, object>>()!;
        tampered["rootDirectory"] = outside.Path;

        Assert.Equal("TERMINAL_GRANT_INVALID", Code(await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "read_file", grant = tampered, filePath = "secret.txt" }))));
        Assert.Equal("TERMINAL_FILE_SCOPE", Code(await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "read_file", grant = forged, filePath = Path.Combine(outside.Path, "secret.txt") }))));
        Assert.Equal("TERMINAL_OUTSIDE_GRANT", Code(await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "search", grant = forged, workingDirectory = outside.Path, pattern = "x" }))));
        Assert.Equal("TERMINAL_READ_ONLY", Code(await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "write_file", grant = Grants.Signed(folder.Path, "read"), filePath = "a.txt", content = "x" }))));
        Assert.Equal("TERMINAL_COMMAND_FORBIDDEN", Code(await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "run", grant = forged, command = "Remove-Item -Recurse -Force C:\\" }))));
        Assert.Equal("TERMINAL_GRANT_INVALID", Code(await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "read_file", grant = Grants.Signed(folder.Path, expiresAt: DateTimeOffset.UtcNow.AddHours(9).ToUnixTimeSeconds()), filePath = "a" }))));

        await using var disabled = Terminal(enabled: false);
        Assert.Equal("TERMINAL_DISABLED", Code(await disabled.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "read_file", grant = forged, filePath = "a" }))));
    }
}

public class TerminalProcessTests
{
    [PowerShellFact]
    public async Task PowerShellRunsAndTracksTheFolder()
    {
        using var folder = new TempFolder();
        Directory.CreateDirectory(Path.Combine(folder.Path, "alt"));
        var outcome = await TerminalProcess.RunAsync("Set-Location alt; Write-Output 'merhaba ğüş'", "powershell", folder.Path, 30, CancellationToken.None);
        Assert.Equal(0, outcome.ExitCode);
        Assert.Equal("merhaba ğüş", outcome.Stdout.Trim());
        Assert.Equal(Path.Combine(folder.Path, "alt"), outcome.EndDirectory);
    }

    [PowerShellFact]
    public async Task FailuresReportANonZeroExitCode()
    {
        using var folder = new TempFolder();
        var error = await TerminalProcess.RunAsync("Get-Item does-not-exist -ErrorAction Stop", "powershell", folder.Path, 30, CancellationToken.None);
        Assert.NotEqual(0, error.ExitCode);
        Assert.Contains("does-not-exist", error.Stderr + error.Stdout);
        // Like bash's "false; echo after": the last command decides the exit code, stderr shows the error.
        var nonTerminating = await TerminalProcess.RunAsync("Get-Item does-not-exist; Write-Output after", "powershell", folder.Path, 30, CancellationToken.None);
        Assert.Contains("after", nonTerminating.Stdout);
        Assert.Contains("does-not-exist", nonTerminating.Stderr);
        var lastFails = await TerminalProcess.RunAsync("Write-Output before; Get-Item does-not-exist", "powershell", folder.Path, 30, CancellationToken.None);
        Assert.NotEqual(0, lastFails.ExitCode);
        var native = await TerminalProcess.RunAsync(OperatingSystem.IsWindows() ? "cmd /c exit 3" : "/bin/sh -c 'exit 3'", "powershell", folder.Path, 30, CancellationToken.None);
        Assert.Equal(3, native.ExitCode);
        var ok = await TerminalProcess.RunAsync(OperatingSystem.IsWindows() ? "cmd /c exit 0" : "/bin/sh -c 'exit 0'", "powershell", folder.Path, 30, CancellationToken.None);
        Assert.Equal(0, ok.ExitCode);
    }

    [WindowsFact]
    public async Task CmdKeepsItsExitCode()
    {
        using var folder = new TempFolder();
        Assert.Equal(3, (await TerminalProcess.RunAsync("exit /b 3", "cmd", folder.Path, 30, CancellationToken.None)).ExitCode);
        var cd = await TerminalProcess.RunAsync("mkdir alt & cd alt", "cmd", folder.Path, 30, CancellationToken.None);
        Assert.Equal(Path.Combine(folder.Path, "alt"), cd.EndDirectory);
    }

    [PowerShellFact]
    public async Task ATimeoutKillsTheProcess()
    {
        using var folder = new TempFolder();
        var outcome = await TerminalProcess.RunAsync("Start-Sleep -Seconds 30", "powershell", folder.Path, 2, CancellationToken.None);
        Assert.True(outcome.TimedOut);
        Assert.True(outcome.DurationMs < 15_000);
    }

    [PowerShellFact]
    public async Task APlanStopsAtTheFirstFailure()
    {
        using var folder = new TempFolder();
        await using var terminal = new WindowsTerminal(() => Grants.Token, () => true);
        var result = await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new
        {
            action = "run_plan", grant = Grants.Signed(folder.Path),
            steps = new object[] { new { command = "New-Item -ItemType Directory deneme | Out-Null; Set-Location deneme" }, new { command = "Get-Item missing -ErrorAction Stop" }, new { command = "Write-Output never" } }
        }));
        var value = JsonSerializer.SerializeToElement(result.Data, WireJson.Options).GetProperty("value");
        Assert.Equal("failed", result.Status);
        Assert.Equal(0, value.GetProperty("steps")[0].GetProperty("exitCode").GetInt32());
        Assert.True(value.GetProperty("steps")[2].GetProperty("skipped").GetBoolean());
        Assert.Equal(Path.Combine(folder.Path, "deneme"), value.GetProperty("workingDirectory").GetString());
    }

    [PowerShellFact]
    public async Task TheSessionFolderCarriesOverAndSecretsStayOut()
    {
        using var folder = new TempFolder();
        Directory.CreateDirectory(Path.Combine(folder.Path, "src"));
        Environment.SetEnvironmentVariable("WIQO_TEST_API_TOKEN", "super-secret");
        await using var terminal = new WindowsTerminal(() => Grants.Token, () => true);
        var grant = Grants.Signed(folder.Path);
        await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "run", grant, command = "Set-Location src" }));
        var where = await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "run", grant, command = "(Get-Location).Path; \"token=$env:WIQO_TEST_API_TOKEN\"" }));
        var stdout = JsonSerializer.SerializeToElement(where.Data, WireJson.Options).GetProperty("value").GetProperty("stdout").GetString()!;
        Assert.Contains(Path.Combine(folder.Path, "src"), stdout);
        Assert.DoesNotContain("super-secret", stdout);
    }

    [WindowsFact]
    public async Task AMissingApprovedFolderIsCreated()
    {
        var root = Path.Combine(WindowsPaths.UserProfile, "wiqo-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            await using var terminal = new WindowsTerminal(() => Grants.Token, () => true);
            var result = await terminal.ExecuteAsync(Guid.NewGuid().ToString(), Grants.Request(new { action = "write_file", grant = Grants.Signed(root), filePath = "notlar.txt", content = "merhaba" }));
            Assert.Equal("completed", result.Status);
            Assert.Equal("merhaba", File.ReadAllText(Path.Combine(root, "notlar.txt")));
        }
        finally { try { Directory.Delete(root, true); } catch { } }
    }
}
