namespace RovaWindows;

/// RovaError on the Mac: code, message, category.
public sealed record WireError(string Code, string Message, string Category = "tool_failure");

/// What an operation produced, before it becomes a CommandResult: data is { kind, value } exactly
/// as CommandData encodes on the Mac, so the backend and the phone read both companions the same.
public sealed record Outcome(string Message, object? Data = null, WireError? Error = null)
{
    public static Outcome Ok(string message, object? data = null) => new(message, data);
    public static Outcome Fail(string code, string message, string category = "tool_failure") => new(message, null, new WireError(code, message, category));
    public static Outcome WithData(string kind, object value, string message) => new(message, new { kind, value });
}
