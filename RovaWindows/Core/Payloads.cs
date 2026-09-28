using System.Text.Json;

namespace RovaWindows;

// CommandPayload values (RovaShared/Protocol.swift), read case-insensitively from { kind, value }.
public sealed record TextFilePayload(string Filename = "", string Content = "");
public sealed record FileMovePayload(string Source = "", string Destination = "");
public sealed record LocalFileOperationPayload(string Path = "", string? Destination = null, string? Content = null, bool Overwrite = false, bool Recursive = false, int Page = 0, int PageSize = 100);
public sealed record FileSearchPayload(string Query = "", string? Cursor = null);
public sealed record ArtifactFilePayload(string ArtifactId = "", string Filename = "", string MimeType = "", string DownloadUrl = "", bool Overwrite = false, long? ByteCount = null, string? Sha256 = null);
public sealed record ScreenCapturePayload(uint? DisplayId = null, int MaxWidth = 1600);
public sealed record ApplicationControlPayload(string Action = "", string Target = "", string? BundleIdentifier = null, bool Force = false);
public sealed record ComputerBrowserPayload(
    string TaskId = "",
    string Action = "",
    string? Url = null,
    string? TargetBy = null,
    string? Target = null,
    string? Role = null,
    string? Value = null,
    string? Direction = null);
public sealed record BrowserTaskPayload(string TaskId = "");

public static class PayloadReader
{
    public static string Kind(JsonElement payload) =>
        payload.ValueKind == JsonValueKind.Object && payload.TryGetProperty("kind", out var kind) && kind.ValueKind == JsonValueKind.String ? kind.GetString() ?? "" : "";

    public static bool TryValue(JsonElement payload, string expectedKind, out JsonElement value)
    {
        value = default;
        return Kind(payload) == expectedKind && payload.TryGetProperty("value", out value);
    }

    public static string? String(JsonElement payload, string expectedKind) =>
        TryValue(payload, expectedKind, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    public static int? Integer(JsonElement payload, string expectedKind) =>
        TryValue(payload, expectedKind, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) ? number : null;

    public static T? Object<T>(JsonElement payload, string expectedKind) where T : class
    {
        if (!TryValue(payload, expectedKind, out var value) || value.ValueKind != JsonValueKind.Object) return null;
        try
        {
            // Swift encodes these keys as "artifactID"/"downloadURL"/"displayID"; normalize them.
            var normalized = new Dictionary<string, JsonElement>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in value.EnumerateObject())
                normalized[property.Name.Replace("ID", "Id", StringComparison.Ordinal).Replace("URL", "Url", StringComparison.Ordinal)] = property.Value;
            return JsonSerializer.SerializeToElement(normalized).Deserialize<T>(WireJson.Options);
        }
        catch (JsonException) { return null; }
    }
}
