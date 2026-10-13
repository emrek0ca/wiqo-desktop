using System.Text.Json;
using RovaWindows.Operations;
using RovaWindows.Terminal;
using Xunit;

namespace RovaWindows.Tests;

public class WireTests
{
    [Fact]
    public void DatesAreWholeSecondUtcForSwiftDecoders()
    {
        var json = WireJson.Serialize(new { at = new DateTimeOffset(2026, 9, 27, 13, 5, 9, 123, TimeSpan.FromHours(3)) });
        Assert.Equal("{\"at\":\"2026-09-27T10:05:09Z\"}", json);
    }

    [Fact]
    public void NullFieldsAreOmittedAndTurkishIsNotEscaped()
    {
        Assert.Equal("{\"message\":\"Dosya okundu ğüşİ\"}", WireJson.Serialize(new { message = "Dosya okundu ğüşİ", error = (string?)null }));
    }

    [Fact]
    public void CatalogComesFromTheSharedManifest()
    {
        Assert.True(OperationCatalog.Entries["deleteFile"].IsDestructive);
        Assert.True(OperationCatalog.Entries["getClipboardText"].RequiresUserPresence);
        Assert.False(OperationCatalog.PermitsUnattended("readFile"));
        Assert.False(OperationCatalog.PermitsUnattended("quitApplication"));
        Assert.True(OperationCatalog.PermitsUnattended("openURL"));
        Assert.Equal(TimeSpan.FromSeconds(120), OperationCatalog.Timeout("sendFileToPhone"));
    }
}

public class ValidationTests
{
    private static JsonElement Payload(string kind, object? value) => JsonSerializer.SerializeToElement(new { kind, value });

    [Theory]
    [InlineData(@"C:\Users\Ada\notlar.txt", true)]
    [InlineData("C:/Users/Ada/proje", true)]
    [InlineData(@"~\Desktop\a.txt", true)]
    [InlineData(@"C:\Users\..\Windows", false)]
    [InlineData(@"\\server\share\x", false)]
    [InlineData("relative\\x.txt", false)]
    [InlineData(@"C:\Users\Ada\CON.txt", false)]
    [InlineData(@"C:\Users\Ada\a|b.txt", false)]
    public void LocalPaths(string path, bool valid) => Assert.Equal(valid, WindowsValidation.IsValidLocalPath(path));

    [Theory]
    [InlineData("rapor.docx", true)]
    [InlineData("çalışma notları.txt", true)]
    [InlineData("a/b.txt", false)]
    [InlineData("NUL", false)]
    [InlineData("x:y.txt", false)]
    [InlineData("..", false)]
    public void DesktopFilenames(string name, bool valid) => Assert.Equal(valid, WindowsValidation.IsValidDesktopFilename(name));

    [Fact]
    public void PayloadRulesMatchTheMac()
    {
        Assert.Null(WindowsValidation.Validate("setVolume", Payload("volume", 40)));
        Assert.NotNull(WindowsValidation.Validate("setVolume", Payload("volume", 140)));
        Assert.NotNull(WindowsValidation.Validate("openURL", Payload("url", "file:///C:/Windows")));
        Assert.Null(WindowsValidation.Validate("openURL", Payload("url", "https://wiqo.app")));
        Assert.NotNull(WindowsValidation.Validate("ping", Payload("url", "x")));
        Assert.Null(WindowsValidation.Validate("ping", Payload("none", null)));
        Assert.NotNull(WindowsValidation.Validate("controlApplication", Payload("applicationControl", new { action = "open", target = "Chrome", force = true })));
        Assert.Null(WindowsValidation.Validate("controlApplication", Payload("applicationControl", new { action = "quit", target = "Chrome", force = true })));
        Assert.Null(WindowsValidation.Validate("lockMac", Payload("none", null)));
    }

    [Fact]
    public void CardlessTerminalReadIsLimitedToVisibleProfileFoldersAndScratch()
    {
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var visible = Path.Combine(profile, $"WiqoReadTest-{Guid.NewGuid():N}");
        var hidden = Path.Combine(profile, $".WiqoReadTest-{Guid.NewGuid():N}");
        Directory.CreateDirectory(visible);
        Directory.CreateDirectory(hidden);
        try
        {
            Assert.Equal(Path.GetFullPath(visible), RovaTerminalPolicy.ReadFolderWithoutGrant(visible));
            Assert.Null(RovaTerminalPolicy.ReadFolderWithoutGrant(profile));
            Assert.Null(RovaTerminalPolicy.ReadFolderWithoutGrant(hidden));
            Assert.NotNull(RovaTerminalPolicy.ReadFolderWithoutGrant("@scratch"));
        }
        finally
        {
            Directory.Delete(visible, recursive: true);
            Directory.Delete(hidden, recursive: true);
        }
    }

    [Fact]
    public void ArtifactsOnlyFromTheWiqoBackend()
    {
        var good = new { artifactID = "0123456789abcdef0123-4567", filename = "rapor.pdf", mimeType = "application/pdf", downloadURL = "https://api.wiqoai.com/copilot/artifacts/0123456789abcdef0123-4567", overwrite = false };
        Assert.Null(WindowsValidation.Validate("saveArtifact", Payload("artifactFile", good)));
        Assert.NotNull(WindowsValidation.Validate("saveArtifact", Payload("artifactFile", good with { downloadURL = "https://evil.example/x" })));
    }

    [Fact]
    public void SwiftKeyNamesAreRead()
    {
        var artifact = PayloadReader.Object<ArtifactFilePayload>(Payload("artifactFile", new { artifactID = "abc", downloadURL = "https://api.wiqoai.com/a", filename = "a.txt", mimeType = "text/plain", overwrite = true }), "artifactFile");
        Assert.Equal("abc", artifact!.ArtifactId);
        Assert.Equal("https://api.wiqoai.com/a", artifact.DownloadUrl);
        Assert.True(artifact.Overwrite);
        var file = PayloadReader.Object<LocalFileOperationPayload>(Payload("fileOperation", new { path = @"C:\x" }), "fileOperation");
        Assert.Equal(100, file!.PageSize);
    }
}

public class ApplicationMatchingTests
{
    [Fact]
    public void ScoresLikeTheMac()
    {
        Assert.Equal(1.0, ApplicationOperations.Score("Google Chrome", "google chrome"));
        Assert.Equal(0.93, ApplicationOperations.Score("Visual Studio Code", "visual studio"));
        Assert.True(ApplicationOperations.Score("Spotify", "spotfy") > 0.3);
    }

    [Fact]
    public void TurkishNamesAndAliasesResolve()
    {
        Assert.Equal("hesap makinesi", ApplicationOperations.Normalize("Hesap Makinesi"));
        Assert.Equal("dosya gezgini", ApplicationOperations.Normalize("  Dosya   Gezgini "));
        var apps = new[]
        {
            new InstalledApplication("Hesap Makinesi", "Microsoft.WindowsCalculator!App", "shell:AppsFolder\\x"),
            new InstalledApplication("Google Chrome", "Chrome", "shell:AppsFolder\\y"),
            new InstalledApplication("Not Defteri", "Notepad", "shell:AppsFolder\\z")
        };
        Assert.Equal("Hesap Makinesi", ApplicationOperations.Rank(apps, "calculator")[0].App.Name);
        Assert.Equal("Google Chrome", ApplicationOperations.Rank(apps, "chrome")[0].App.Name);
        Assert.Equal("Not Defteri", ApplicationOperations.Rank(apps, ApplicationOperations.Normalize("Not defteri"))[0].App.Name);
    }

    [Fact]
    public void SearchFoldsDiacritics() => Assert.Equal("rapor ozeti", FileSearch.Fold("Rapör Özeti"));
}

public class FileSearchTests
{
    private static string Make(TempFolder folder, string relative, double daysAgo = 0, string text = "A")
    {
        var path = Path.Combine(folder.Path, relative.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
        File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddDays(-daysAgo));
        return path;
    }

    private static FileSearch.Spec Spec(TempFolder folder, string query = "", string? kind = null, int? days = null, bool content = false, bool recent = false) =>
        new(FileSearch.Tokens(query), [folder.Path], kind, days is { } d ? DateTimeOffset.UtcNow.AddDays(-d) : null, content, recent);

    private static string[] Names(FileSearch.Spec spec) => FileSearch.Scan(spec, CancellationToken.None, out _).Select(hit => hit.Name).Order().ToArray();

    [Fact]
    public void FindsByNameKindAndDateAndSkipsOtherProgramsFiles()
    {
        using var folder = new TempFolder();
        Make(folder, "rapor-mart.pdf", 2);
        Make(folder, "rapor-ocak.pdf", 60);
        Make(folder, "Alt/rapor.docx", 1);
        Make(folder, "notlar.txt");
        Make(folder, "proje/node_modules/paket/rapor.pdf");
        Make(folder, "proje/DerivedData/x/rapor.pdf");

        Assert.Equal(["rapor-mart.pdf", "rapor-ocak.pdf", "rapor.docx"], Names(Spec(folder, "rapor")));
        Assert.Equal(["rapor-mart.pdf", "rapor-ocak.pdf"], Names(Spec(folder, "rapor", kind: "pdf")));
        Assert.Equal(["rapor-mart.pdf", "rapor.docx"], Names(Spec(folder, "rapor", days: 7)));
        Assert.Equal(["notlar.txt"], Names(Spec(folder, kind: "text", days: 1)));
        Assert.Equal(["rapor-mart.pdf"], Names(Spec(folder, "mart ra")));
    }

    [Fact]
    public void KeyMaterialStaysOutOfEverySearch()
    {
        using var folder = new TempFolder();
        Make(folder, "anahtar/id_rsa");
        Make(folder, "banka parola.txt");
        var privateKey = Make(folder, "AuthKey_ABC123.p8", text: "synthetic test credential");
        Make(folder, "rapor.pdf");
        Assert.Equal(["rapor.pdf"], Names(Spec(folder, kind: "pdf")));
        Assert.Empty(Names(Spec(folder, "parola")));
        Assert.Empty(Names(Spec(folder, "ABC123")));
        Assert.Equal("SENSITIVE_FILE_BLOCKED", FileOperations.Read(new LocalFileOperationPayload(privateKey)).Error?.Code);
    }

    [Fact]
    public void ContentSearchLooksInsideTextFiles()
    {
        using var folder = new TempFolder();
        Make(folder, "a.txt", text: "Kira sözleşmesi imzalandı");
        Make(folder, "b.txt", text: "market listesi");
        Assert.Equal(["a.txt"], Names(Spec(folder, "kira", content: true)));
        Assert.Empty(Names(Spec(folder, "kira")));
    }

    [Fact]
    public void RankingPutsTheNameThatIsTheQueryFirstAndRecentSortsNewestFirst()
    {
        using var folder = new TempFolder();
        Make(folder, "fatura-eylul-2026.pdf", 0);
        Make(folder, "fatura.pdf", 30);
        var query = FileSearch.Scan(Spec(folder, "fatura"), CancellationToken.None, out _);
        Assert.Equal("fatura.pdf", FileSearch.Rank(query, Spec(folder, "fatura"))[0].Name);
        Assert.Equal("fatura-eylul-2026.pdf", FileSearch.Rank(query, Spec(folder, "fatura", recent: true))[0].Name);
    }

    [Fact]
    public void SearchValidationMatchesTheMacRule()
    {
        static WireError? Check(FileSearchPayload search) =>
            WindowsValidation.Validate("searchFiles", System.Text.Json.JsonSerializer.SerializeToElement(new { kind = "fileSearch", value = search }, WireJson.Options));
        Assert.Null(Check(new FileSearchPayload("fatura")));
        Assert.Null(Check(new FileSearchPayload("", Kind: "pdf", ModifiedWithinDays: 7)));
        Assert.Null(Check(new FileSearchPayload("x", Cursor: "o:24")));
        Assert.NotNull(Check(new FileSearchPayload("")));
        Assert.NotNull(Check(new FileSearchPayload("x", Kind: "exe")));
        Assert.NotNull(Check(new FileSearchPayload("x", ModifiedWithinDays: 0)));
        Assert.NotNull(Check(new FileSearchPayload("x", Cursor: "o:abc")));
    }

    [Fact]
    public void AMissingFolderIsReportedAndAStaleCursorIsRefused()
    {
        using var folder = new TempFolder();
        Assert.Equal("FILE_NOT_FOUND", FileSearch.Search(new FileSearchPayload("x", Folder: Path.Combine(folder.Path, "yok")), CancellationToken.None).Error?.Code);
        Assert.Equal("INVALID_CURSOR", FileSearch.Search(new FileSearchPayload("x", Cursor: Guid.NewGuid().ToString()), CancellationToken.None).Error?.Code);
    }
}

public class LedgerAndSettingsTests
{
    [Fact]
    public void LedgerSurvivesRestartAndKeepsTheLast128()
    {
        using var folder = new TempFolder();
        var path = Path.Combine(folder.Path, "ledger.json");
        var ledger = new ResultLedger(path);
        for (var index = 0; index < 140; index++)
            ledger.Record(new WindowsCommandResult($"id-{index}", "completed", "ok", DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddSeconds(index - 1_000)));
        ledger.RecordRunning("running-id");
        var reloaded = new ResultLedger(path);
        Assert.Equal(128, reloaded.Recent().Count);
        Assert.Equal("unknown", reloaded.Find("running-id")!.Status);
        Assert.Null(reloaded.Find("id-0"));
    }

    [Fact]
    public void DisabledGroupsAreNotAdvertised()
    {
        using var folder = new TempFolder();
        var settings = new CapabilitySettings(Path.Combine(folder.Path, "capabilities.json"));
        var files = CapabilitySettings.Groups.Single(group => group.Id == "files");
        settings.SetGroup(files, false);
        var reloaded = new CapabilitySettings(Path.Combine(folder.Path, "capabilities.json"));
        Assert.False(reloaded.IsEnabled("device.files.delete"));
        Assert.True(reloaded.IsEnabled("runtime.status"));
        Assert.True(reloaded.IsEnabled("device.audio"));
    }

    [Fact]
    public async Task ADisabledCapabilityNeverRuns()
    {
        using var folder = new TempFolder();
        var settings = new CapabilitySettings(Path.Combine(folder.Path, "capabilities.json"));
        settings.SetGroup(CapabilitySettings.Groups.Single(group => group.Id == "web"), false);
        await using var runtime = new WindowsRuntime(settings, new ResultLedger(Path.Combine(folder.Path, "ledger.json")));
        var result = await runtime.ExecuteAsync(Guid.NewGuid().ToString(), "openURL", JsonSerializer.SerializeToElement(new { kind = "url", value = "https://wiqo.app" }));
        Assert.Equal("denied", result.Status);
        Assert.Equal("CAPABILITY_DISABLED", ((WireError)result.Error!).Code);
        Assert.DoesNotContain("device.url.open", runtime.Capabilities);
    }

    [Fact]
    public async Task ACommandIdRunsOnce()
    {
        using var folder = new TempFolder();
        await using var runtime = new WindowsRuntime(new CapabilitySettings(Path.Combine(folder.Path, "c.json")), new ResultLedger(Path.Combine(folder.Path, "l.json")));
        var id = Guid.NewGuid().ToString();
        var first = await runtime.ExecuteAsync(id, "setVolume", JsonSerializer.SerializeToElement(new { kind = "volume", value = 400 }));
        var second = await runtime.ExecuteAsync(id, "setVolume", JsonSerializer.SerializeToElement(new { kind = "volume", value = 40 }));
        Assert.Equal("denied", first.Status);
        Assert.Equal(first.Status, second.Status);
        Assert.Equal(first.Message, second.Message);
    }

    [Fact]
    public async Task UnattendedStepsCannotReadPrivateFiles()
    {
        using var folder = new TempFolder();
        await using var runtime = new WindowsRuntime(new CapabilitySettings(Path.Combine(folder.Path, "c.json")), new ResultLedger(Path.Combine(folder.Path, "l.json")));
        var result = await runtime.ExecuteAsync(Guid.NewGuid().ToString(), "readFile", JsonSerializer.SerializeToElement(new { kind = "fileOperation", value = new { path = @"C:\Users\x.txt" } }), unattended: true);
        Assert.Equal("AUTOMATION_STEP_BLOCKED", ((WireError)result.Error!).Code);
    }
}
