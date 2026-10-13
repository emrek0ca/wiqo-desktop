import SwiftUI
import WebKit

/// Runs a Python project on the phone itself with Pyodide (CPython compiled to WebAssembly, loaded from jsDelivr, cached by the web view), so the
/// server's sandbox is only the fallback. Numpy, pandas, scipy, matplotlib and scikit-learn come as Pyodide's own packages, found from the
/// program's imports. Anything it cannot do (a package Pyodide does not have, no network for the first load, a timeout) returns nil and the
/// caller runs the project on the server exactly as before: this path can only make a run cheaper, never make it fail.
/// Off until switched on (`UserDefaults` key `wiqo.act.pyodide`): it has not been measured on a device yet.
@MainActor
final class ActPyodideRunner: NSObject {
    static let shared = ActPyodideRunner()
    static let defaultsKey = "wiqo.act.pyodide"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    private static let version = "0.26.4"
    private var webView: WKWebView?
    private var running = false

    private var page: String {
        """
        <!doctype html><html><head><meta charset="utf-8"></head><body>
        <script src="https://cdn.jsdelivr.net/pyodide/v\(Self.version)/full/pyodide.js"></script>
        <script>
        let py = null;
        window.wiqoRun = async function (filesJSON, entryPath) {
          if (!py) py = await loadPyodide({ indexURL: "https://cdn.jsdelivr.net/pyodide/v\(Self.version)/full/" });
          const files = JSON.parse(filesJSON);
          let entry = "";
          for (const file of files) {
            const flat = file.path.replace(/\\//g, "_");
            py.FS.writeFile("/home/pyodide/" + flat, file.content);
            if (file.path === entryPath) entry = file.content;
          }
          let out = "", err = "", code = 0;
          py.setStdout({ batched: (s) => { out += s + "\\n"; } });
          py.setStderr({ batched: (s) => { err += s + "\\n"; } });
          const started = performance.now();
          try {
            await py.loadPackagesFromImports(entry);
            py.runPython("import os, sys; os.chdir('/home/pyodide'); sys.path.insert(0, '/home/pyodide')");
            await py.runPythonAsync(entry);
          } catch (e) { err += String(e); code = 1; }
          return JSON.stringify({ exitCode: code, stdout: out, stderr: err, durationMs: Math.round(performance.now() - started) });
        };
        window.wiqoRunTimed = function (filesJSON, entryPath, limitMs) {
          return Promise.race([
            window.wiqoRun(filesJSON, entryPath),
            new Promise((resolve) => setTimeout(() => resolve(JSON.stringify({ exitCode: 124, timedOut: true, stdout: "", stderr: "timeout", durationMs: limitMs })), limitMs))
          ]);
        };
        </script></body></html>
        """
    }

    /// nil: the server should run it.
    func run(files: [(path: String, content: String)], timeout: TimeInterval = 25) async -> ActHub.RunResult? {
        guard !running, let entry = files.first(where: { $0.path == "main.py" })?.path ?? files.first(where: { $0.path.hasSuffix(".py") })?.path else { return nil }
        // A package outside Pyodide's set, or one that needs a real pip install: the sandbox has it or says so.
        if files.contains(where: { $0.path == "requirements.txt" && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return nil }
        running = true
        defer { running = false }
        let view = existingOrNewWebView()
        do {
            try await load(view, timeout: 15)
            let payload = try JSONSerialization.data(withJSONObject: files.map { ["path": $0.path, "content": $0.content] })
            let json = String(decoding: payload, as: UTF8.self)
            // The time limit lives in the page (a race inside JavaScript), so there is no second task on this side to isolate or cancel.
            let result = try await view.callAsyncJavaScript(
                "return await window.wiqoRunTimed(filesJSON, entryPath, limitMs)",
                arguments: ["filesJSON": json, "entryPath": entry, "limitMs": Int(timeout * 1000)],
                in: nil,
                contentWorld: .page
            )
            let value = result as? String
            guard let value, let data = value.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = object["exitCode"] as? Int else { discard(); return nil }
            if object["timedOut"] as? Bool == true { discard(); return nil }
            let stderr = object["stderr"] as? String ?? ""
            // Pyodide lacks the package: not the program's fault, so the server decides.
            if code != 0, stderr.contains("ModuleNotFoundError") || stderr.contains("No module named") { return nil }
            return ActHub.RunResult(exitCode: code, timedOut: false, stdout: object["stdout"] as? String ?? "", stderr: stderr, durationMs: object["durationMs"] as? Int ?? 0)
        } catch {
            discard()
            return nil
        }
    }

    private func existingOrNewWebView() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        view.isHidden = true
        // Timers in a web view that is on no screen can be throttled to nothing: it sits, invisible and 1 pt wide, in the app's window.
        if let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first { window.addSubview(view) }
        webView = view
        return view
    }

    private var loaded = false

    private func load(_ view: WKWebView, timeout: TimeInterval) async throws {
        if loaded { return }
        view.loadHTMLString(page, baseURL: URL(string: "https://cdn.jsdelivr.net/"))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let ready = try? await view.evaluateJavaScript("typeof loadPyodide === 'function' && typeof window.wiqoRunTimed === 'function'") as? Bool
            if ready == true { loaded = true; return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw URLError(.timedOut)
    }

    /// After a failure the next run starts from a fresh page.
    private func discard() {
        webView?.removeFromSuperview()
        webView = nil
        loaded = false
    }
}
