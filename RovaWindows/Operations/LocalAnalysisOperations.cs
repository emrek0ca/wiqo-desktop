using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace RovaWindows.Operations;

/// Fixed-script, read-only adapters for optional local analysis dependencies. Libraries are
/// discovered and imported only when this capability is called; runtime startup stays minimal.
internal static class LocalAnalysisOperations
{
    private static readonly ConcurrentDictionary<string, IReadOnlyDictionary<string, string>> WorkspaceSnapshots = new(StringComparer.OrdinalIgnoreCase);
    private static readonly ConcurrentDictionary<string, object> ResultCache = new(StringComparer.Ordinal);
    private static readonly ConcurrentQueue<string> ResultCacheOrder = new();
    private const int ResultCacheCapacity = 32;

    public static async Task<Outcome> Execute(LocalAnalysisPayload payload, CancellationToken cancellationToken)
    {
        if (payload.Action == "workspaceDiff") return WorkspaceDiff(payload);
        var path = payload.Path is null ? null : ResolvePath(payload.Path, requireDirectory: false);
        if (payload.Path is not null && path is null) return Outcome.Fail("LOCAL_PATH_INVALID", "Yerel analiz yolu bulunamadı veya güvenli değil.", "validation");
        var cacheKey = CacheKey(payload, path);
        if (cacheKey is not null && ResultCache.TryGetValue(cacheKey, out var cached))
            return Outcome.WithData("localAnalysis", cached, "Yerel analiz önbellekten hazırlandı.");
        var request = JsonSerializer.SerializeToUtf8Bytes(new
        {
            action = payload.Action,
            path,
            query = payload.Query,
            expression = payload.Expression,
            variables = payload.Variables,
            limit = payload.Limit
        }, WireJson.Options);
        var encoded = Convert.ToBase64String(request);
        var worker = await RunPython(encoded, cancellationToken).ConfigureAwait(false);
        if (worker is null) return Outcome.Fail("LOCAL_ANALYSIS_RUNTIME_MISSING", "Python yerel analiz çalışma zamanı bulunamadı.", "unavailable");
        if (worker.Value.TimedOut) return Outcome.Fail("LOCAL_ANALYSIS_TIMEOUT", "Yerel analiz için ayrılan süre doldu.", "timeout");
        if (worker.Value.ExitCode != 0) return Outcome.Fail("LOCAL_ANALYSIS_FAILED", "Yerel analiz tamamlanamadı.");
        try
        {
            using var document = JsonDocument.Parse(worker.Value.Output);
            var root = document.RootElement;
            if (!root.TryGetProperty("ok", out var ok) || !ok.GetBoolean())
            {
                var code = root.TryGetProperty("errorCode", out var codeNode) ? codeNode.GetString() : "LOCAL_ANALYSIS_FAILED";
                var message = root.TryGetProperty("errorMessage", out var messageNode) ? messageNode.GetString() : "Yerel analiz bağımlılığı kullanılamıyor.";
                return Outcome.Fail(code ?? "LOCAL_ANALYSIS_FAILED", message ?? "Yerel analiz bağımlılığı kullanılamıyor.", code == "DEPENDENCY_MISSING" ? "unavailable" : "tool_failure");
            }
            var value = new Dictionary<string, object?>
            {
                ["action"] = payload.Action,
                ["adapter"] = root.TryGetProperty("adapter", out var adapter) ? adapter.GetString() ?? "python" : "python",
                ["available"] = !root.TryGetProperty("available", out var available) || available.GetBoolean(),
                ["text"] = root.TryGetProperty("text", out var text) ? text.GetString() : null,
                ["columns"] = Strings(root, "columns"),
                ["rows"] = Rows(root),
                ["changedFiles"] = Array.Empty<string>(),
                ["dependencies"] = Dependencies(root),
                ["truncated"] = root.TryGetProperty("truncated", out var truncated) && truncated.GetBoolean()
            };
            if (cacheKey is not null) Cache(cacheKey, value);
            return Outcome.WithData("localAnalysis", value, "Yerel analiz tamamlandı.");
        }
        catch (JsonException)
        {
            return Outcome.Fail("LOCAL_ANALYSIS_FAILED", "Yerel analiz geçerli bir sonuç üretmedi.");
        }
    }

    private static string? CacheKey(LocalAnalysisPayload payload, string? path)
    {
        if (payload.Action is "dependencyStatus" or "workspaceDiff") return null;
        var fileStamp = "";
        if (path is not null)
        {
            try
            {
                var info = new FileInfo(path);
                fileStamp = $"{path}|{info.Length}|{info.LastWriteTimeUtc.Ticks}";
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
        }
        return string.Join('\u001f', payload.Action, fileStamp, payload.Query ?? "", payload.Expression ?? "", string.Join(',', payload.Variables ?? Array.Empty<string>()), payload.Limit.ToString());
    }

    private static void Cache(string key, object value)
    {
        if (!ResultCache.TryAdd(key, value)) { ResultCache[key] = value; return; }
        ResultCacheOrder.Enqueue(key);
        while (ResultCache.Count > ResultCacheCapacity && ResultCacheOrder.TryDequeue(out var oldest)) ResultCache.TryRemove(oldest, out _);
    }

    private static Outcome WorkspaceDiff(LocalAnalysisPayload payload)
    {
        var directory = ResolvePath(payload.Path!, requireDirectory: true);
        if (directory is null) return Outcome.Fail("LOCAL_PATH_INVALID", "Çalışma alanı klasörü bulunamadı.", "validation");
        var current = Snapshot(directory);
        var initial = !WorkspaceSnapshots.TryGetValue(directory, out var previous);
        WorkspaceSnapshots[directory] = current;
        string[] changed = initial ? Array.Empty<string>() : previous!.Keys.Union(current.Keys, StringComparer.OrdinalIgnoreCase)
            .Where(name => !previous.TryGetValue(name, out var before) || !current.TryGetValue(name, out var after) || before != after)
            .Order(StringComparer.OrdinalIgnoreCase).ToArray();
        var limit = Math.Clamp(payload.Limit, 1, 500);
        var value = new
        {
            action = payload.Action,
            adapter = "filesystem",
            available = true,
            text = initial ? "Çalışma alanı başlangıç durumu kaydedildi." : null,
            columns = Array.Empty<string>(), rows = Array.Empty<string[]>(),
            changedFiles = changed.Take(limit).ToArray(),
            dependencies = Array.Empty<object>(),
            truncated = changed.Length > limit
        };
        return Outcome.WithData("localAnalysis", value, "Çalışma alanı farkı hazır.");
    }

    private static string? ResolvePath(string raw, bool requireDirectory)
    {
        try
        {
            var expanded = raw.StartsWith("~\\", StringComparison.Ordinal) || raw.StartsWith("~/", StringComparison.Ordinal)
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), raw[2..]) : raw;
            var full = Path.GetFullPath(expanded);
            var home = Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)) + Path.DirectorySeparatorChar;
            if (!full.StartsWith(home, StringComparison.OrdinalIgnoreCase) || !File.Exists(full) && !Directory.Exists(full)) return null;
            var attributes = File.GetAttributes(full);
            if ((attributes & FileAttributes.ReparsePoint) != 0) return null;
            return requireDirectory == Directory.Exists(full) ? full : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
    }

    private static IReadOnlyDictionary<string, string> Snapshot(string directory)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.Hidden | FileAttributes.System | FileAttributes.ReparsePoint, MaxRecursionDepth = 16 };
            var started = Stopwatch.StartNew();
            foreach (var file in Directory.EnumerateFiles(directory, "*", options).Take(20_000))
            {
                if (started.Elapsed > TimeSpan.FromSeconds(1)) break;
                var info = new FileInfo(file);
                result[Path.GetRelativePath(directory, file)] = $"{info.Length}:{info.LastWriteTimeUtc.Ticks}";
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        return result;
    }

    private static string[] Strings(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Array
            ? value.EnumerateArray().Select(item => item.GetString() ?? "").ToArray() : [];

    private static string[][] Rows(JsonElement root) =>
        root.TryGetProperty("rows", out var value) && value.ValueKind == JsonValueKind.Array
            ? value.EnumerateArray().Select(row => row.EnumerateArray().Select(cell => cell.GetString() ?? "").ToArray()).ToArray() : [];

    private static object[] Dependencies(JsonElement root) =>
        root.TryGetProperty("dependencies", out var value) && value.ValueKind == JsonValueKind.Object
            ? value.EnumerateObject().Select(item => (object)new { name = item.Name, available = item.Value.GetBoolean() }).ToArray() : [];

    private static async Task<(int ExitCode, string Output, bool TimedOut)?> RunPython(string payload, CancellationToken cancellationToken)
    {
        foreach (var candidate in new[] { (File: "python", Prefix: Array.Empty<string>()), (File: "py", Prefix: new[] { "-3" }) })
        {
            using var process = new Process();
            process.StartInfo = new ProcessStartInfo(candidate.File) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
            foreach (var argument in candidate.Prefix) process.StartInfo.ArgumentList.Add(argument);
            process.StartInfo.ArgumentList.Add("-c");
            process.StartInfo.ArgumentList.Add(PythonScript);
            process.StartInfo.ArgumentList.Add(payload);
            var inheritedPath = Environment.GetEnvironmentVariable("PATH") ?? "";
            process.StartInfo.Environment.Clear();
            process.StartInfo.Environment["PATH"] = inheritedPath;
            process.StartInfo.Environment["USERPROFILE"] = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            process.StartInfo.Environment["HOME"] = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            process.StartInfo.Environment["TEMP"] = Path.GetTempPath();
            process.StartInfo.Environment["PYTHONUTF8"] = "1";
            try
            {
                if (!process.Start()) continue;
            }
            catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { continue; }
            try
            {
                var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
                var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
                await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
                var output = await outputTask.ConfigureAwait(false);
                _ = await errorTask.ConfigureAwait(false);
                return (process.ExitCode, output, false);
            }
            catch (OperationCanceledException)
            {
                try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
                return (-1, "", true);
            }
        }
        return null;
    }

    private const string PythonScript = """
import base64, importlib.util, json, os, re, sys
def emit(value): sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
request=json.loads(base64.b64decode(sys.argv[1]).decode("utf-8")); action=request.get("action"); limit=max(1,min(int(request.get("limit") or 100),500))
modules={"markitdown":"markitdown","duckdb":"duckdb","sympy":"sympy"}
if action=="dependencyStatus": emit({"ok":True,"adapter":"python","available":True,"dependencies":{n:importlib.util.find_spec(m) is not None for n,m in modules.items()}}); raise SystemExit(0)
required={"extractDocument":"markitdown","queryData":"duckdb","solveSymbolic":"sympy"}.get(action)
if not required or importlib.util.find_spec(modules[required]) is None: emit({"ok":False,"available":False,"errorCode":"DEPENDENCY_MISSING","errorMessage":f"{required or 'İstenen'} yerel analiz bağımlılığı kurulu değil."}); raise SystemExit(0)
try:
 if action=="extractDocument":
  from markitdown import MarkItDown
  result=MarkItDown().convert(request["path"]); text=(getattr(result,"text_content","") or "").strip(); ceiling=min(limit*100,50000); emit({"ok":True,"adapter":"markitdown","available":True,"text":text[:ceiling],"truncated":len(text)>ceiling})
 elif action=="queryData":
  import duckdb
  query=(request.get("query") or "").strip()
  if not re.match(r"^(select|with)\b",query,re.I) or ";" in query or re.search(r"\b(attach|copy|create|delete|drop|export|import|insert|install|load|pragma|update|call|read_[a-z0-9_]*|[a-z0-9_]*scan|httpfs|sqlite|postgres|glob|secret)\b",query,re.I): raise ValueError("unsafe query")
  path=request["path"]; escaped=path.replace("'","''"); extension=os.path.splitext(path)[1].lower(); readers={".csv":"read_csv_auto",".tsv":"read_csv_auto",".json":"read_json_auto",".jsonl":"read_json_auto",".parquet":"read_parquet"}; reader=readers.get(extension)
  if not reader: raise ValueError("unsupported data format")
  con=duckdb.connect(database=":memory:"); con.execute(f"CREATE VIEW data AS SELECT * FROM {reader}('{escaped}')"); cursor=con.execute(query); columns=[item[0] for item in (cursor.description or [])]; values=cursor.fetchmany(limit+1); rows=[["" if value is None else str(value) for value in row] for row in values[:limit]]; emit({"ok":True,"adapter":"duckdb","available":True,"columns":columns,"rows":rows,"truncated":len(values)>limit})
 elif action=="solveSymbolic":
  import sympy as sp
  expression=(request.get("expression") or "").strip()
  if not re.match(r"^[A-Za-z0-9+*/^=(), \t.-]+$",expression) or "__" in expression: raise ValueError("unsafe expression")
  names=request.get("variables") or sorted(set(re.findall(r"\b[A-Za-z][A-Za-z0-9]{0,31}\b",expression))-{"sin","cos","tan","sqrt","exp","log","Abs"}); symbols={name:sp.Symbol(name) for name in names}; locals_map={**symbols,"sin":sp.sin,"cos":sp.cos,"tan":sp.tan,"sqrt":sp.sqrt,"exp":sp.exp,"log":sp.log,"Abs":sp.Abs}
  if "=" in expression: left,right=expression.split("=",1); parsed=sp.Eq(sp.sympify(left.replace("^","**"),locals=locals_map),sp.sympify(right.replace("^","**"),locals=locals_map))
  else: parsed=sp.sympify(expression.replace("^","**"),locals=locals_map)
  result=sp.solve(parsed,list(symbols.values()),dict=True) if symbols else sp.simplify(parsed); rendered=str(result); emit({"ok":True,"adapter":"sympy","available":True,"text":rendered[:50000],"truncated":len(rendered)>50000})
except Exception: emit({"ok":False,"available":True,"errorCode":"LOCAL_ANALYSIS_FAILED","errorMessage":"Yerel analiz girdisi işlenemedi."})
""";
}
