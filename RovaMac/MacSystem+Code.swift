import AppKit
import Darwin
import Foundation

/// Running code in a sandbox and the process helper it shares.
extension MacSystem {
    static func executeCode(_ payload: CodeExecutionPayload) -> (data: CommandData?, error: RovaError?) {
        if payload.scope.lowercased() == "computer" {
            return executeComputerTerminal(payload)
        }
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

    static func executeTerminalCommand(
        _ command: String,
        workingDirectory: String,
        timeoutSeconds: Int,
        processStarted: @escaping @Sendable (Int32) -> Void
    ) -> (data: CommandData?, error: RovaError?) {
        let payload = CodeExecutionPayload(language: "shell", code: command, timeoutSeconds: timeoutSeconds, allowNetwork: true, scope: "computer", shell: "zsh", workingDirectory: workingDirectory)
        return executeComputerTerminal(payload, processStarted: processStarted)
    }

    static func terminateTerminalProcess(_ processIdentifier: Int32) {
        guard processIdentifier > 0 else { return }
        if kill(-processIdentifier, SIGTERM) != 0 { _ = kill(processIdentifier, SIGTERM) }
        // The process group is scoped to this terminal process; kill the remainder immediately so
        // a child cannot keep running after the user pressed Stop.
        _ = kill(-processIdentifier, SIGKILL)
        _ = kill(processIdentifier, SIGKILL)
    }

    static func applyTerminalPatch(filePath: String, patch: String, expectedPatchPath: String) -> (diff: String?, error: RovaError?) {
        guard !patch.isEmpty, patch.utf8.count <= 120_000, !patch.contains("\0"),
              let current = try? String(contentsOfFile: filePath, encoding: .utf8),
              let result = applyUnifiedPatch(patch, to: current, expectedPath: expectedPatchPath),
              !result.isEmpty, result != current else {
            return (nil, RovaError(code: "TERMINAL_PATCH_REJECTED", message: "Yama mevcut dosyayla bağlam eşleşmedi ya da güvenli tek dosya biçiminde değil.", category: "validation"))
        }
        do {
            try Data(result.utf8).write(to: URL(fileURLWithPath: filePath), options: [.atomic])
            return (patch, nil)
        } catch {
            return (nil, localFileError(code: "TERMINAL_PATCH_WRITE_FAILED", fallback: "Yama dosyaya yazılamadı.", error: error))
        }
    }

    private static func applyUnifiedPatch(_ patch: String, to current: String, expectedPath: String) -> String? {
        let patchLines = patch.components(separatedBy: "\n")
        guard patchLines.count >= 4,
              patchLines[0].hasPrefix("--- "), patchLines[1].hasPrefix("+++ ") else { return nil }
        func normalizedHeader(_ value: String, prefix: String) -> String? {
            guard value.hasPrefix(prefix) else { return nil }
            let raw = String(value.dropFirst(prefix.count)).split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard raw != "/dev/null", !raw.split(separator: "/").contains(".."), !raw.hasPrefix("/") || raw == expectedPath else { return nil }
            let stripped = raw.hasPrefix("a/") || raw.hasPrefix("b/") ? String(raw.dropFirst(2)) : raw
            let expected = expectedPath.hasPrefix("a/") || expectedPath.hasPrefix("b/") ? String(expectedPath.dropFirst(2)) : expectedPath
            return stripped == expected ? stripped : nil
        }
        guard normalizedHeader(patchLines[0], prefix: "--- ") != nil,
              normalizedHeader(patchLines[1], prefix: "+++ ") != nil else { return nil }

        let hadTrailingNewline = current.hasSuffix("\n")
        var original = current.components(separatedBy: "\n")
        if hadTrailingNewline { original.removeLast() }
        var output: [String] = []
        var sourceIndex = 0
        var index = 2
        var sawHunk = false
        let hunkRegex = try? NSRegularExpression(pattern: "^@@ -(\\d+)(?:,(\\d+))? \\+(\\d+)(?:,(\\d+))? @@")
        while index < patchLines.count {
            if patchLines[index].isEmpty && index == patchLines.count - 1 { break }
            guard let match = hunkRegex?.firstMatch(in: patchLines[index], range: NSRange(patchLines[index].startIndex..., in: patchLines[index])),
                  let oldStartRange = Range(match.range(at: 1), in: patchLines[index]),
                  let oldStart = Int(patchLines[index][oldStartRange]) else { return nil }
            let oldCount: Int
            if match.range(at: 2).location == NSNotFound {
                oldCount = 1
            } else if let oldCountRange = Range(match.range(at: 2), in: patchLines[index]), let parsedCount = Int(patchLines[index][oldCountRange]) {
                oldCount = parsedCount
            } else {
                return nil
            }
            let oldCursor = oldCount == 0 && oldStart == 0 ? 0 : max(0, oldStart - 1)
            guard oldCursor >= sourceIndex, oldCursor <= original.count else { return nil }
            output.append(contentsOf: original[sourceIndex..<oldCursor])
            sourceIndex = oldCursor
            index += 1
            var consumedOld = 0
            var consumedNew = 0
            sawHunk = true
            while index < patchLines.count && !patchLines[index].hasPrefix("@@ ") {
                let line = patchLines[index]
                if line.hasPrefix("\\ No newline at end of file") { index += 1; continue }
                guard let marker = line.first else { return nil }
                let content = String(line.dropFirst())
                switch marker {
                case " ":
                    guard sourceIndex < original.count, original[sourceIndex] == content else { return nil }
                    output.append(content); sourceIndex += 1; consumedOld += 1; consumedNew += 1
                case "-":
                    guard sourceIndex < original.count, original[sourceIndex] == content else { return nil }
                    sourceIndex += 1; consumedOld += 1
                case "+":
                    output.append(content); consumedNew += 1
                default:
                    return nil
                }
                index += 1
            }
            guard consumedOld == oldCount else { return nil }
        }
        guard sawHunk else { return nil }
        output.append(contentsOf: original[sourceIndex...])
        return output.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
    }

    /// Explicit terminal scope for a user-approved PC task. The historical sandbox path above
    /// remains the default; this branch is deliberately opt-in so old requests cannot silently
    /// gain access to the user's files or applications.
    private static func executeComputerTerminal(_ payload: CodeExecutionPayload, processStarted: (@Sendable (Int32) -> Void)? = nil) -> (data: CommandData?, error: RovaError?) {
        let directoryPath = payload.workingDirectory ?? NSHomeDirectory()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return (nil, RovaError(code: "INVALID_WORKING_DIRECTORY", message: "Çalışma klasörü bulunamadı.", category: "validation"))
        }

        let shell = (payload.shell ?? "default").lowercased()
        let environment = terminalEnvironment(workingDirectory: directoryPath)
        let snapshot: ProcessSnapshot
        switch payload.language.lowercased() {
        case "shell":
            let executable: String
            switch shell {
            case "bash": executable = "/bin/bash"
            case "zsh", "default": executable = "/bin/zsh"
            default:
                return (nil, RovaError(code: "UNSUPPORTED_SHELL", message: "Bu shell Mac'te desteklenmiyor.", category: "validation"))
            }
            snapshot = runProcess(
                executable: executable,
                arguments: ["-lc", payload.code, "wiqo-terminal"] + payload.arguments,
                timeoutSeconds: payload.timeoutSeconds,
                workingDirectory: URL(fileURLWithPath: directoryPath),
                environment: environment,
                processStarted: processStarted
            )
        case "python", "javascript":
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiqo-terminal-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let extensionName = payload.language.lowercased() == "python" ? "py" : "js"
                let script = directory.appendingPathComponent("main.\(extensionName)")
                try Data(payload.code.utf8).write(to: script, options: [.atomic])
                let executable = payload.language.lowercased() == "python" ? "/usr/bin/env" : "/usr/bin/env"
                let interpreter = payload.language.lowercased() == "python" ? "python3" : "node"
                snapshot = runProcess(
                    executable: executable,
                    arguments: [interpreter, script.path] + payload.arguments,
                    timeoutSeconds: payload.timeoutSeconds,
                    workingDirectory: URL(fileURLWithPath: directoryPath),
                    environment: environment
                )
            } catch {
                return (nil, localFileError(code: "TERMINAL_PREPARE_FAILED", fallback: "Terminal komutu hazırlanamadı.", error: error))
            }
        default:
            return (nil, RovaError(code: "UNSUPPORTED_LANGUAGE", message: "Yalnızca Python, JavaScript veya shell çalıştırılabilir.", category: "validation"))
        }

        // Terminal output can contain credentials (env dumps, config files); they are masked here,
        // before the result leaves this Mac on either the phone or the backend path.
        let stdout = RovaTerminalPolicy.redactSecrets(String(decoding: snapshot.stdout, as: UTF8.self))
        let stderr = RovaTerminalPolicy.redactSecrets(String(decoding: snapshot.stderr, as: UTF8.self))
        let output = ProcessOutputContent(
            language: payload.language,
            exitCode: snapshot.timedOut ? -1 : snapshot.exitCode,
            stdout: stdout,
            stderr: stderr,
            truncated: snapshot.truncated,
            durationMs: snapshot.durationMs
        )
        if snapshot.timedOut {
            return (.processOutput(output), RovaError(code: "CODE_TIMEOUT", message: "Terminal komutu zaman aşımına uğradı; sonucu doğrulanamadı.", category: "timeout"))
        }
        if snapshot.exitCode != 0 {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.isEmpty ? "Terminal komutu çıkış kodu \(snapshot.exitCode) ile sonlandı." : "Terminal komutu hata verdi: \(detail.prefix(300))"
            return (.processOutput(output), RovaError(code: "CODE_FAILED", message: message, category: "tool_failure"))
        }
        return (.processOutput(output), nil)
    }

    private static func terminalEnvironment(workingDirectory: String) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let allowed = ["PATH", "HOME", "USER", "LANG", "LC_ALL"]
        var result = allowed.reduce(into: [String: String]()) { values, key in
            if let value = inherited[key] { values[key] = value }
        }
        result["PATH"] = result["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        result["PWD"] = workingDirectory
        return result
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
        // that grants filesystem or network access on its own. App launching and Apple Events are
        // intentionally absent: isolated code must not escape into UI/app control. Those actions
        // use the explicit computer scope and its structural user-presence gate.
        return """
        (version 1) (deny default) \
        (allow process*) (allow sysctl-read) (allow mach-lookup) (allow iokit-open) (allow signal) \
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
        environment: [String: String]? = nil,
        processStarted: (@Sendable (Int32) -> Void)? = nil
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
            let ownsProcessGroup = setpgid(process.processIdentifier, process.processIdentifier) == 0
            processStarted?(process.processIdentifier)
            _ = fcntl(stdoutPipe.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
            _ = fcntl(stderrPipe.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
            let deadline = Date().addingTimeInterval(TimeInterval(max(1, timeoutSeconds)))
            while process.isRunning {
                drainProcessPipe(stdoutPipe.fileHandleForReading, into: &stdout, truncated: &truncated)
                drainProcessPipe(stderrPipe.fileHandleForReading, into: &stderr, truncated: &truncated)
                if process.isRunning && Date() >= deadline {
                    timedOut = true
                    if ownsProcessGroup {
                        kill(-process.processIdentifier, SIGTERM)
                    } else {
                        process.terminate()
                    }
                    Thread.sleep(forTimeInterval: 0.15)
                    if process.isRunning {
                        kill(ownsProcessGroup ? -process.processIdentifier : process.processIdentifier, SIGKILL)
                    }
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
