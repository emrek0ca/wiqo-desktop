using System.Text.Json;
using Xunit;

namespace RovaWindows.Tests;

/// The Windows companion against contracts/companion/vectors.json - the same vectors the Mac
/// (contracts/companion/swift) and the backend's reference generator use.
public class ContractVectorTests
{
    private static readonly JsonElement Vectors = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "vectors.json"))).RootElement;

    public static IEnumerable<object[]> Items(string section) =>
        Vectors.GetProperty(section).EnumerateArray().Select((_, index) => new object[] { index });

    [Theory]
    [MemberData(nameof(Items), "canonicalJson")]
    public void CanonicalJsonMatchesReference(int index)
    {
        var item = Vectors.GetProperty("canonicalJson")[index];
        using var input = JsonDocument.Parse(item.GetProperty("input").GetString()!);
        Assert.Equal(item.GetProperty("canonical").GetString(), CanonicalJson.Serialize(input.RootElement));
    }

    [Theory]
    [MemberData(nameof(Items), "terminalGrants")]
    public void TerminalGrantSignatureVerifies(int index)
    {
        var item = Vectors.GetProperty("terminalGrants")[index];
        var now = DateTimeOffset.FromUnixTimeSeconds(item.GetProperty("expiresAt").GetInt64() - 60);
        var token = item.GetProperty("token").GetString();
        Assert.True(RovaTerminalPolicy.VerifyGrant(Grant(item, item.GetProperty("rootDirectory").GetString()!), token, out var root, out _, now));
        Assert.Equal(item.GetProperty("rootDirectory").GetString(), root);
        Assert.False(RovaTerminalPolicy.VerifyGrant(Grant(item, item.GetProperty("rootDirectory").GetString() + "x"), token, out _, out _, now));
    }

    [Theory]
    [MemberData(nameof(Items), "commandSignatures")]
    public void CommandSignatureMatchesReference(int index)
    {
        var item = Vectors.GetProperty("commandSignatures")[index];
        Assert.Equal(item.GetProperty("payloadCanonical").GetString(), CanonicalJson.Serialize(item.GetProperty("payload")));
        var signature = ProtocolV2Client.CommandSignature(
            item.GetProperty("token").GetString()!, Guid.Parse(item.GetProperty("id").GetString()!), item.GetProperty("type").GetString()!,
            item.GetProperty("epochMs").GetInt64(), item.GetProperty("nonce").GetString()!, item.GetProperty("payload"));
        Assert.Equal(item.GetProperty("signature").GetString(), Convert.ToHexString(signature).ToLowerInvariant());
    }

    private static JsonElement Grant(JsonElement item, string root) => JsonSerializer.SerializeToElement(new
    {
        id = item.GetProperty("grantId").GetString(),
        rootDirectory = root,
        mode = item.GetProperty("mode").GetString(),
        expiresAt = item.GetProperty("expiresAt").GetInt64(),
        signature = item.GetProperty("signature").GetString()
    });
}
