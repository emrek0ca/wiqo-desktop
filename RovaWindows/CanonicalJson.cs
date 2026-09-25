using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace RovaWindows;

/// Minimal RFC 8785 canonical JSON serializer for signed CommandRequest payloads.
internal static class CanonicalJson
{
    private static readonly JsonSerializerOptions StringOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    internal static string Serialize(JsonElement value)
    {
        var builder = new StringBuilder();
        Write(value, builder);
        return builder.ToString();
    }

    private static void Write(JsonElement value, StringBuilder output)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                output.Append('{');
                var first = true;
                foreach (var property in value.EnumerateObject().OrderBy(item => item.Name, StringComparer.Ordinal))
                {
                    if (!first) output.Append(',');
                    first = false;
                    output.Append(JsonSerializer.Serialize(property.Name, StringOptions)).Append(':');
                    Write(property.Value, output);
                }
                output.Append('}');
                break;
            case JsonValueKind.Array:
                output.Append('[');
                var firstItem = true;
                foreach (var item in value.EnumerateArray())
                {
                    if (!firstItem) output.Append(',');
                    firstItem = false;
                    Write(item, output);
                }
                output.Append(']');
                break;
            case JsonValueKind.String:
                output.Append(JsonSerializer.Serialize(value.GetString(), StringOptions));
                break;
            case JsonValueKind.Number:
                if (!value.TryGetDouble(out var number) || !double.IsFinite(number)) throw new JsonException("Non-finite signed number.");
                output.Append(CanonicalNumber(number));
                break;
            case JsonValueKind.True: output.Append("true"); break;
            case JsonValueKind.False: output.Append("false"); break;
            case JsonValueKind.Null: output.Append("null"); break;
            default: throw new JsonException("Unsupported canonical JSON value.");
        }
    }

    private static string CanonicalNumber(double value)
    {
        if (value == 0) return "0";
        var sign = value < 0 ? "-" : "";
        var raw = Math.Abs(value).ToString("R", CultureInfo.InvariantCulture).ToLowerInvariant();
        var parts = raw.Split('e', 2);
        var mantissa = parts[0];
        var exponent = parts.Length == 2 && int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedExponent) ? parsedExponent : 0;
        var point = mantissa.IndexOf('.');
        var decimalPosition = point >= 0 ? point : mantissa.Length;
        var digits = mantissa.Replace(".", "", StringComparison.Ordinal);
        decimalPosition += exponent;
        while (digits.Length > 0 && digits[0] == '0') { digits = digits[1..]; decimalPosition--; }
        while (digits.Length > 0 && digits[^1] == '0') digits = digits[..^1];
        if (digits.Length == 0) return "0";
        if (decimalPosition > 0 && decimalPosition <= 21)
            return sign + (digits.Length <= decimalPosition ? digits + new string('0', decimalPosition - digits.Length) : digits[..decimalPosition] + "." + digits[decimalPosition..]);
        if (decimalPosition <= 0 && decimalPosition > -6)
            return sign + "0." + new string('0', -decimalPosition) + digits;
        var scientificExponent = decimalPosition - 1;
        var coefficient = digits.Length == 1 ? digits : digits[0] + "." + digits[1..];
        return sign + coefficient + "e" + (scientificExponent >= 0 ? "+" : "") + scientificExponent.ToString(CultureInfo.InvariantCulture);
    }
}
