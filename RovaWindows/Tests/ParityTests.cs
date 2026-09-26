using System.Text.Json;
using Xunit;

namespace RovaWindows.Tests;

/// The Windows manifest must advertise exactly what the shared catalogue (RovaShared, exported to
/// contracts/companion/operations.json) marks as Windows-supported - no more, no less.
public class ParityTests
{
    private static readonly JsonElement[] Operations = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "operations.json")))
        .RootElement.GetProperty("operations").EnumerateArray().ToArray();

    private static IEnumerable<JsonElement> WindowsEntries() => Operations.Where(item =>
        item.GetProperty("supportedPlatforms").EnumerateArray().Any(platform => platform.GetString() == "windows"));

    [Fact]
    public void OperationsMatchSharedCatalogue() =>
        Assert.Equal(WindowsEntries().Select(item => item.GetProperty("operation").GetString()!).Order(), WindowsCapabilityManifest.Operations.Order());

    [Fact]
    public void CapabilitiesMatchSharedCatalogue() =>
        Assert.Equal(WindowsEntries().Select(item => item.GetProperty("capability").GetString()!).Distinct().Order(), WindowsCapabilityManifest.Capabilities.Order());

    [Fact]
    public void EveryOperationMapsToItsCatalogueCapability()
    {
        foreach (var item in WindowsEntries())
            Assert.Equal(item.GetProperty("capability").GetString(), WindowsCapabilityManifest.CapabilityFor(item.GetProperty("operation").GetString()!));
    }
}
