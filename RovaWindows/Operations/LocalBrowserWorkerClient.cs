using System.Collections.Concurrent;
using System.Diagnostics;
using System.ComponentModel;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RovaWindows.Operations;

/// Lazy JSONL bridge to the optional Playwright worker. The worker owns task-scoped, ephemeral
/// contexts; this adapter never reads or writes a user's normal browser profile.
internal sealed class LocalBrowserWorkerClient : IAsyncDisposable
{
    private static readonly JsonSerializerOptions BrowserJson = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };
    private sealed record BrowserRequest(
        string Id,
        string Action,
        string TaskId,
        string? Url = null,
        string? TargetBy = null,
        string? Target = null,
        string? Role = null,
        string? Value = null,
        string? Direction = null,
        string? CancelRequestId = null);

    private sealed record BrowserResult(
        string? TaskId,
        string? Action,
        string? Url,
        string? Title,
        string? Text,
        bool? Truncated,
        bool? Verified,
        bool? Closed);

    private sealed record BrowserError(string Code, string Message);
    private sealed record BrowserEnvelope(string Id, bool Ok, BrowserResult? Result, BrowserError? Error);

    private readonly ConcurrentDictionary<string, TaskCompletionSource<BrowserEnvelope>> pending = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim startGate = new(1, 1);
    private readonly SemaphoreSlim writeGate = new(1, 1);
    private readonly object processLock = new();
    private Process? process;
    private StreamWriter? input;

    internal async Task<Outcome> ExecuteAsync(ComputerBrowserPayload payload, CancellationToken cancellationToken)
    {
        var request = new BrowserRequest(
            Guid.NewGuid().ToString(), payload.Action, payload.TaskId, payload.Url,
            payload.TargetBy, payload.Target, payload.Role, payload.Value, payload.Direction);
        try
        {
            var envelope = await SendAsync(request, cancellationToken).ConfigureAwait(false);
            if (!envelope.Ok || envelope.Result?.TaskId is not { Length: > 0 } taskId)
                return FromError(envelope.Error);
            return Outcome.WithData("computerBrowser", new
            {
                taskId,
                action = envelope.Result.Action,
                url = envelope.Result.Url,
                title = envelope.Result.Title,
                text = envelope.Result.Text,
                truncated = envelope.Result.Truncated,
                verified = envelope.Result.Verified
            }, "Tarayıcı işlemi tamamlandı ve sonucu doğrulandı.");
        }
        catch (OperationCanceledException)
        {
            return Outcome.Fail("BROWSER_CANCELLED", "Tarayıcı işlemi iptal edildi.", "cancelled");
        }
        catch (Exception error) when (error is FileNotFoundException or Win32Exception)
        {
            return Outcome.Fail("BROWSER_RUNTIME_MISSING", "PC'de yerel tarayıcı çalışma zamanı bulunamadı.", "unavailable");
        }
        catch (Exception)
        {
            return Outcome.Fail("BROWSER_FAILED", "Tarayıcı işlemi tamamlanamadı.");
        }
    }

    internal async Task<Outcome> CloseAsync(string taskId, CancellationToken cancellationToken)
    {
        try
        {
            var envelope = await SendAsync(new BrowserRequest(Guid.NewGuid().ToString(), "closeTask", taskId), cancellationToken).ConfigureAwait(false);
            if (!envelope.Ok || envelope.Result?.TaskId is not { Length: > 0 } id)
                return FromError(envelope.Error);
            return Outcome.WithData("browserTask", new { taskId = id, closed = envelope.Result.Closed ?? true }, "Göreve özel tarayıcı oturumu kapatıldı.");
        }
        catch (OperationCanceledException)
        {
            return Outcome.Fail("BROWSER_CANCELLED", "Tarayıcı işlemi iptal edildi.", "cancelled");
        }
        catch (Exception)
        {
            return Outcome.Fail("BROWSER_FAILED", "Tarayıcı oturumu kapatılamadı.");
        }
    }

    private async Task<BrowserEnvelope> SendAsync(BrowserRequest request, CancellationToken cancellationToken)
    {
        var completion = new TaskCompletionSource<BrowserEnvelope>(TaskCreationOptions.RunContinuationsAsynchronously);
        await startGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            EnsureStarted();
            if (!pending.TryAdd(request.Id, completion)) throw new InvalidOperationException("Duplicate browser request id.");
            var processSnapshot = process ?? throw new InvalidOperationException("Browser worker did not start.");
            await writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                if (processSnapshot.HasExited) throw new InvalidOperationException("Browser worker exited.");
                await input!.WriteLineAsync(JsonSerializer.Serialize(request, BrowserJson)).ConfigureAwait(false);
                await input.FlushAsync(cancellationToken).ConfigureAwait(false);
            }
            finally { writeGate.Release(); }
        }
        catch
        {
            pending.TryRemove(request.Id, out _);
            throw;
        }
        finally { startGate.Release(); }

        try { return await completion.Task.WaitAsync(cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException)
        {
            pending.TryRemove(request.Id, out _);
            await SendCancelAsync(request.Id, request.TaskId).ConfigureAwait(false);
            throw;
        }
    }

    private void EnsureStarted()
    {
        lock (processLock)
        {
            if (process is { HasExited: false }) return;
            var workerPath = Path.Combine(AppContext.BaseDirectory, "BrowserWorker", "index.mjs");
            if (!File.Exists(workerPath)) throw new FileNotFoundException("Optional browser worker is missing.");

            var packageRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Wiqo", "BrowserWorker");
            Directory.CreateDirectory(packageRoot);
            var start = new ProcessStartInfo("node")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardInputEncoding = System.Text.Encoding.UTF8,
                StandardOutputEncoding = System.Text.Encoding.UTF8,
                StandardErrorEncoding = System.Text.Encoding.UTF8
            };
            start.ArgumentList.Add(workerPath);
            start.Environment["WIQO_BROWSER_WORKER_PACKAGE_ROOT"] = packageRoot;
            start.Environment["PLAYWRIGHT_BROWSERS_PATH"] = Path.Combine(packageRoot, ".browsers");

            var child = new Process { StartInfo = start, EnableRaisingEvents = true };
            child.OutputDataReceived += (_, eventArgs) => { if (eventArgs.Data is { } line) Receive(line); };
            // Drain and discard stderr; it may contain runtime diagnostics and must never become
            // model context, user-visible output, or application logs.
            child.ErrorDataReceived += (_, _) => { };
            child.Exited += (_, _) => WorkerExited(child);
            if (!child.Start()) throw new InvalidOperationException("Browser worker failed to start.");
            process = child;
            input = child.StandardInput;
            child.BeginOutputReadLine();
            child.BeginErrorReadLine();
        }
    }

    private void Receive(string line)
    {
        BrowserEnvelope? envelope;
        try { envelope = JsonSerializer.Deserialize<BrowserEnvelope>(line, BrowserJson); }
        catch (JsonException) { return; }
        if (envelope is not null && pending.TryRemove(envelope.Id, out var completion))
            completion.TrySetResult(envelope);
    }

    private async Task SendCancelAsync(string requestId, string taskId)
    {
        var cancel = new BrowserRequest(Guid.NewGuid().ToString(), "cancel", taskId, CancelRequestId: requestId);
        try
        {
            await writeGate.WaitAsync().ConfigureAwait(false);
            try
            {
                if (process is { HasExited: false } && input is not null)
                {
                    await input.WriteLineAsync(JsonSerializer.Serialize(cancel, BrowserJson)).ConfigureAwait(false);
                    await input.FlushAsync().ConfigureAwait(false);
                }
            }
            finally { writeGate.Release(); }
        }
        catch (Exception) { /* The worker enforces an idle/task TTL even if cancellation transport failed. */ }
    }

    private void WorkerExited(Process child)
    {
        lock (processLock)
        {
            if (ReferenceEquals(process, child))
            {
                process = null;
                input = null;
            }
        }
        foreach (var entry in pending.ToArray())
            if (pending.TryRemove(entry.Key, out var completion))
                completion.TrySetException(new InvalidOperationException("Browser worker exited."));
        child.Dispose();
    }

    private static Outcome FromError(BrowserError? error)
    {
        var code = error?.Code ?? "BROWSER_FAILED";
        var message = error?.Message ?? "Tarayıcı işlemi tamamlanamadı.";
        var category = code.Contains("TIMEOUT", StringComparison.Ordinal) ? "timeout"
            : code.Contains("BLOCKED", StringComparison.Ordinal) || code.Contains("UNSAFE", StringComparison.Ordinal) ? "permission"
            : "tool_failure";
        return Outcome.Fail(code, message, category);
    }

    public async ValueTask DisposeAsync()
    {
        Process? child;
        lock (processLock) child = process;
        if (child is { HasExited: false })
        {
            try
            {
                var shutdown = new BrowserRequest(Guid.NewGuid().ToString(), "shutdown", Guid.NewGuid().ToString());
                await writeGate.WaitAsync().ConfigureAwait(false);
                try
                {
                    if (input is not null)
                    {
                        await input.WriteLineAsync(JsonSerializer.Serialize(shutdown, BrowserJson)).ConfigureAwait(false);
                        await input.FlushAsync().ConfigureAwait(false);
                    }
                }
                finally { writeGate.Release(); }
            }
            catch (Exception) { try { child.Kill(entireProcessTree: true); } catch (Exception) { } }
        }
        startGate.Dispose();
        writeGate.Dispose();
    }
}
