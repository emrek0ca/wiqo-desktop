using System.Globalization;
using System.Text;
using System.Text.Json;

namespace RovaWindows;

/// Minimal RFC 8785 canonical JSON serializer for signed CommandRequest payloads.
internal static class CanonicalJson
{
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
                    WriteString(property.Name, output);
                    output.Append(':');
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
                WriteString(value.GetString() ?? "", output);
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

    /// RFC 8785 strings (ECMAScript JSON.stringify): only quote, backslash and control characters are
    /// escaped; every other character, emoji included, is written as is; a lone surrogate becomes
    /// \uXXXX. The .NET encoders escape emoji and U+2028, which broke signatures (vectors.json).
    private static void WriteString(string value, StringBuilder output)
    {
        output.Append('"');
        for (var index = 0; index < value.Length; index++)
        {
            var character = value[index];
            switch (character)
            {
                case '"': output.Append("\\\""); break;
                case '\\': output.Append("\\\\"); break;
                case '\b': output.Append("\\b"); break;
                case '\f': output.Append("\\f"); break;
                case '\n': output.Append("\\n"); break;
                case '\r': output.Append("\\r"); break;
                case '\t': output.Append("\\t"); break;
                default:
                    if (character < 0x20) output.Append("\\u").Append(((int)character).ToString("x4", CultureInfo.InvariantCulture));
                    else if (char.IsHighSurrogate(character) && index + 1 < value.Length && char.IsLowSurrogate(value[index + 1])) output.Append(character).Append(value[++index]);
                    else if (char.IsSurrogate(character)) output.Append("\\u").Append(((int)character).ToString("x4", CultureInfo.InvariantCulture));
                    else output.Append(character);
                    break;
            }
        }
        output.Append('"');
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
