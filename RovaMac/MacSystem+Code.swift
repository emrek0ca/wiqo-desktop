import AppKit
import Darwin
import Foundation

/// Running code in a sandbox and the process helper it shares.
extension MacSystem {
    static func executeCode(_ payload: CodeExecutionPayload) -> (data: CommandData?, error: RovaError?) {
        // `/private/tmp/...` and `/tmp/...` refer to the same inode, but the sandbox's `subpath`
        // rules match against the resolved path - a profile built from the raw `/var/folders/...`
        // URL (which is really a symlink through `/private/var`) silently denies the very
        // directory the script lives in. Resolving up front is what makes every subpath rule
        // below actually apply to the directory the script runs from.
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rova-code-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
            let fileExtension: String
            switch payload.language.lowercased() {
            case "python": fileExtension = "py"
            case "javascript": fileExtension = "js"
            case "shell": fileExtension = "sh"
            default:
                return (nil, RovaError(code: "UNSUPPORTED_LANGUAGE", message: "Yalnızca Python, JavaScript veya shell çalıştırılabilir.", category: "tool_failure"))
            }
            let scriptURL = temporaryDirectory.appendingPathComponent("main.\(fileExtension)")
            try Data(payload.code.utf8).write(to: scriptURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

            let command: [String]
            switch payload.language.lowercased() {
            case "python": command = ["/usr/bin/env", "python3", scriptURL.path] + payload.arguments
            case "javascript": command = ["/usr/bin/env", "node", scriptURL.path] + payload.arguments
            case "shell": command = ["/bin/sh", scriptURL.path] + payload.arguments
            default: command = []
            }
            let profile = sandboxProfile(for: temporaryDirectory, allowNetwork: payload.allowNetwork)
            // Process has no public pre-exec hook on macOS, so a fixed shell wrapper applies the
            // CPU-time limit and then execs the already-separated argv vector - user code never
            // becomes part of this shell string. (There is no virtual-memory limit: Darwin's
            // `ulimit -v` is a no-op for RLIMIT_AS - it always fails with EINVAL and every
            // interpreter still runs unbounded - so it only added silent stderr noise here.)
            let limiter = "ulimit -t \(payload.timeoutSeconds); exec \"$@\""
            let arguments = ["-p", profile, "/bin/sh", "-c", limiter, "rova-code"] + command
            // A GUI app launched by launchd gets a minimal PATH/cwd that usually omits Homebrew
            // and always predates the script's own directory - both `env python3`/`env node`
            // lookups and the sandbox's own directory-traversal checks need better defaults than
            // that inherited environment provides.
            let environment: [String: String] = [
                "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": NSHomeDirectory(),
                "TMPDIR": temporaryDirectory.path + "/",
                "LANG": "en_US.UTF-8",
                // bash/sh call getcwd() at shell-init to populate $PWD unless it's already set to
                // a value that stats to the same directory - the sandbox profile above only grants
                // file-read-DATA (not just metadata) on this run's own directory, not on its
                // ancestors, so getcwd()'s directory-walk fallback fails there with "cannot access
                // parent directories" even though the actual chdir (`workingDirectory` below)
                // already succeeded. Pre-seeding $PWD sidesteps that call entirely instead of
                // loosening the sandbox to grant directory-listing on every ancestor up to /.
                "PWD": temporaryDirectory.path
            ]
            let snapshot = runProcess(
                executable: "/usr/bin/sandbox-exec",
                arguments: arguments,
                timeoutSeconds: payload.timeoutSeconds,
                workingDirectory: temporaryDirectory,
                environment: environment
            )
            let stdout = String(decoding: snapshot.stdout, as: UTF8.self)
            let stderr = String(decoding: snapshot.stderr, as: UTF8.self)
            let output = ProcessOutputContent(language: payload.language, exitCode: snapshot.timedOut ? -1 : snapshot.exitCode, stdout: stdout, stderr: stderr, truncated: snapshot.truncated, durationMs: snapshot.durationMs)
            if snapshot.timedOut {
                return (.processOutput(output), RovaError(code: "CODE_TIMEOUT", message: "Kod çalıştırma süresi doldu.", category: "timeout"))
            }
            if snapshot.exitCode != 0 {
                // A shell-init cwd warning (harmless, unrelated to the script's own failure - see
                // the PWD comment above) was eating the whole 300-char budget and hiding the actual
                // reason underneath it. Drop that specific noise before truncating so the model
                // sees the real error instead of two repeated "shell-init:" lines.
                let meaningfulLines = stderr
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .filter { !$0.hasPrefix("shell-init: error retrieving current directory") }
                let detail = meaningfulLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                let message = detail.isEmpty ? "Kod hata ile sonlandı (çıkış kodu \(snapshot.exitCode))." : "Kod hata ile sonlandı: \(detail.prefix(300))"
                return (.processOutput(output), RovaError(code: "CODE_FAILED", message: message, category: "tool_failure"))
            }
            return (.processOutput(output), nil)
        } catch {
            return (nil, localFileError(code: "CODE_SANDBOX_FAILED", fallback: "Kod izole ortamda başlatılamadı.", error: error))
        }
    }

    private static func sandboxProfile(for directory: URL, allowNetwork: Bool) -> String {
        let escapedDirectory = directory.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let networkRule = allowNetwork ? "(allow network*)" : "(deny network*)"
        // `file-read-metadata` (stat/access/readlink - never file content) is left unscoped: the
        // sandbox needs it on arbitrary ancestor directories just to resolve the script's own
        // path and the interpreter's, and macOS has no separate "traverse this directory" rule.
        // Content reads (`file-read-data`) stay confined to the interpreter/toolchain locations
        // below plus this run's own directory. `mach-lookup`/`iokit-open`/`signal` are required
        // for essentially any dynamically-linked macOS binary to even launch under `deny default`
        // (dyld and libSystem talk to several system services before `main()` runs) - none of
        // that grants filesystem or network access on its own. `lsopen`/`appleevent-send` are
        // what let a script use `open -a "App"` or `osascript`/AppleScript to control another
        // app (the model's terminal-based fallback for anything computer_application can't
        // resolve) - without them Launch Services and Apple Events both fail closed inside the
        // sandbox even though the app is actually installed and running. Neither one bypasses
        // macOS's own per-app Automation permission prompt; the user still approves that once,
        // the same as any AppleScript control elsewhere in this app.
        return """
        (version 1) (deny default) \
        (allow process*) (allow sysctl-read) (allow mach-lookup) (allow iokit-open) (allow signal) \
        (allow lsopen) (allow appleevent-send) \
        (allow file-read-metadata) \
        (allow file-read-data \
          (literal "/") \
          (subpath "/System") (subpath "/Library") (subpath "/Applications") \
          (subpath "/usr") (subpath "/bin") \
          (subpath "/opt/homebrew") (subpath "/usr/local") \
          (subpath "/private/etc") (subpath "/private/var/db") \
          (subpath "\(escapedDirectory)")) \
        (allow file-write* (subpath "\(escapedDirectory)")) \
        \(networkRule)
        """
    }

    struct ProcessSnapshot {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
        let timedOut: Bool
        let truncated: Bool
        let durationMs: Int
    }

    static func runProcess(
        executable: String,
        arguments: [String],
        timeoutSeconds: Int,
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) -> ProcessSnapshot {
        let started = Date()
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        if let environment { process.environment = environment }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        var stdout = Data()
        var stderr = Data()
        var truncated = false
        var timedOut = false

        do {
            try process.run()
            _ = fcntl(stdoutPipe.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
            _ = fcntl(stderrPipe.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
            let deadline = Date().addingTimeInterval(TimeInterval(max(1, timeoutSeconds)))
            while process.isRunning {
                drainProcessPipe(stdoutPipe.fileHandleForReading, into: &stdout, truncated: &truncated)
                drainProcessPipe(stderrPipe.fileHandleForReading, into: &stderr, truncated: &truncated)
                if process.isRunning && Date() >= deadline {
                    timedOut = true
                    process.terminate()
                    Thread.sleep(forTimeInterval: 0.15)
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                if process.isRunning { Thread.sleep(forTimeInterval: 0.01) }
            }
            process.waitUntilExit()
            drainProcessPipe(stdoutPipe.fileHandleForReading, into: &stdout, truncated: &truncated)
            drainProcessPipe(stderrPipe.fileHandleForReading, into: &stderr, truncated: &truncated)
        } catch {
            stderr.append(Data("İşlem başlatılamadı.".utf8))
            return ProcessSnapshot(stdout: stdout, stderr: stderr, exitCode: -1, timedOut: false, truncated: truncated, durationMs: Int(Date().timeIntervalSince(started) * 1_000))
        }
        return ProcessSnapshot(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus, timedOut: timedOut, truncated: truncated, durationMs: Int(Date().timeIntervalSince(started) * 1_000))
    }

    private static func drainProcessPipe(_ handle: FileHandle, into data: inout Data, truncated: inout Bool) {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(handle.fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count > 0 else { return }
            let bytesRead = Int(count)
            let bytesBefore = data.count
            if data.count < maxProcessOutputBytes {
                let remaining = maxProcessOutputBytes - data.count
                data.append(contentsOf: buffer.prefix(min(bytesRead, remaining)))
            }
            if bytesBefore >= maxProcessOutputBytes || bytesRead > maxProcessOutputBytes - bytesBefore { truncated = true }
        }
    }
}
