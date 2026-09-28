import AppKit
import Darwin
import Foundation

/// Running code in a sandbox and the process helper it shares.
extension MacSystem {
    static func executeCode(_ payload: CodeExecutionPayload) -> (data: CommandData?, error: RovaError?) {
        if payload.scope.lowercased() == "computer" {
            return executeComputerTerminal(payload)
        }
        // Sandbox subpath rules use the filesystem's canonical path. Foundation's
        // resolvingSymlinksInPath() leaves /var/folders unchanged on macOS, while the
        // sandbox resolves it to /private/var/folders and denies main.sh there.
        let rawTemporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rova-code-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: rawTemporaryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: rawTemporaryDirectory) }
            guard let canonicalPath = realpath(rawTemporaryDirectory.path, nil) else {
                return (nil, RovaError(code: "CODE_SANDBOX_FAILED", message: "Kod için geçici klasör doğrulanamadı.", category: "tool_failure"))
            }
            defer { free(canonicalPath) }
            let temporaryDirectory = URL(fileURLWithPath: String(cString: canonicalPath), isDirectory: true)
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
            // Which file is patched is decided by filePath (already resolved inside the grant);
            // the header only has to name the same file: equal, or a path suffix of it
            // ("a/src/x.ts" for "/Users/ada/app/src/x.ts" or "src/x.ts" for "x.ts" in src/).
            if stripped == expected { return stripped }
            if expected.hasSuffix("/" + stripped) || stripped.hasSuffix("/" + expected) { return stripped }
            return nil
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
            return (nil, RovaError(code: "INVALID_WORKING_DIRECTORY", message: "Çalışma klasörü bulunamadı: \(directoryPath). Önce klasörü oluştur ya da var olan bir klasör ver.", category: "validation"))
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
        // The user's interactive PATH first: nvm/pyenv/asdf/conda add their tools in ~/.zshrc, which
        // the `zsh -lc` below never reads - the usual cause of "command not found" for node/python.
        result["PATH"] = interactivePath ?? result["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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


// MARK: - Terminal session v2 (plans, session folder, files, search, profile)

extension MacSystem {
    /// The user's interactive-shell PATH, resolved once (5 s cap) and reused for every terminal
    /// command. Only PATH is taken from the interactive shell - never other variables or secrets.
    static let interactivePath: String? = {
        let snapshot = runProcess(
            executable: "/bin/zsh",
            arguments: ["-ilc", "printf '__WIQO_PATH__%s' \"$PATH\""],
            timeoutSeconds: 5,
            environment: ["HOME": NSHomeDirectory(), "USER": NSUserName(), "TERM": "dumb"]
        )
        guard !snapshot.timedOut else { return nil }
        let text = String(decoding: snapshot.stdout, as: UTF8.self)
        guard let range = text.range(of: "__WIQO_PATH__", options: .backwards) else { return nil }
        let value = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }()

    private static let cwdMarker = "__WIQO_PWD__"

    /// Runs one terminal command and reports the folder the shell ended in, so a `cd` carries over
    /// to the next command of the session. The marker line is removed from the output.
    static func executeTerminalCommandTrackingDirectory(
        _ command: String,
        workingDirectory: String,
        timeoutSeconds: Int,
        processStarted: @escaping @Sendable (Int32) -> Void
    ) -> (data: CommandData?, error: RovaError?, endDirectory: String?) {
        let wrapped = "\(command)\n__wiqo_rc=$?; printf '\\n\(cwdMarker)%s\\n' \"$PWD\"; exit $__wiqo_rc"
        let outcome = executeTerminalCommand(wrapped, workingDirectory: workingDirectory, timeoutSeconds: timeoutSeconds, processStarted: processStarted)
        guard case let .processOutput(output)? = outcome.data else { return (outcome.data, outcome.error, nil) }
        var endDirectory: String?
        var stdout = output.stdout
        if let range = stdout.range(of: "\n\(cwdMarker)", options: .backwards) ?? stdout.range(of: cwdMarker, options: .backwards) {
            let tail = stdout[range.upperBound...]
            endDirectory = tail.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map { String($0).trimmingCharacters(in: .whitespaces) }
            stdout = String(stdout[..<range.lowerBound])
        }
        let cleaned = ProcessOutputContent(language: output.language, exitCode: output.exitCode, stdout: stdout, stderr: output.stderr, truncated: output.truncated, durationMs: output.durationMs)
        return (.processOutput(cleaned), outcome.error, endDirectory)
    }

    /// Reads a UTF-8 text file (line range, numbered), masking credentials before it leaves the Mac.
    static func readTerminalFile(_ path: String, startLine: Int?, endLine: Int?) -> (text: String?, totalLines: Int, error: RovaError?) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 2_000_000 else {
            return (nil, 0, RovaError(code: "TERMINAL_FILE_TOO_LARGE", message: "Dosya okunamadı ya da 2 MB'tan büyük.", category: "validation"))
        }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return (nil, 0, RovaError(code: "TERMINAL_FILE_NOT_TEXT", message: "Dosya UTF-8 metin değil.", category: "validation"))
        }
        let lines = content.components(separatedBy: "\n")
        let first = max(1, startLine ?? 1)
        let last = min(lines.count, max(first, endLine ?? (first + 399)))
        guard first <= lines.count else { return ("", lines.count, nil) }
        var text = ""
        for index in (first - 1)..<last {
            text += "\(index + 1)\t\(lines[index])\n"
            if text.utf8.count > 60_000 { text += "[... 60 KB sınırı; daha dar satır aralığı iste ...]\n"; break }
        }
        return (RovaTerminalPolicy.redactSecrets(text), lines.count, nil)
    }

    /// Creates or replaces a text file atomically (path already resolved inside the grant).
    /// A JSON file that parsed before the change must still parse after it (measured: models
    /// dropped a comma in package.json and then gave up at the `npm` error). JSONC files such as
    /// a commented tsconfig never parsed, so they are left alone.
    private static func brokenJSON(path: String, before: String?, after: String, display: String) -> RovaError? {
        guard path.lowercased().hasSuffix(".json"), let before,
              (try? JSONSerialization.jsonObject(with: Data(before.utf8), options: [.fragmentsAllowed])) != nil else { return nil }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(after.utf8), options: [.fragmentsAllowed])
            return nil
        } catch {
            let reason = ((error as NSError).userInfo["NSDebugDescription"] as? String) ?? "geçersiz JSON"
            return RovaError(code: "TERMINAL_EDIT_INVALID_JSON", message: "\(display): değişiklik sonrası JSON geçersiz olurdu (\(reason)); hiçbir dosya değiştirilmedi. Virgül ve parantezleri kontrol edip tekrar dene.", category: "validation")
        }
    }

    static func writeTerminalFile(_ path: String, content: String) -> (created: Bool, error: RovaError?) {
        guard content.utf8.count <= 400_000, !content.contains("\0") else {
            return (false, RovaError(code: "TERMINAL_FILE_TOO_LARGE", message: "Yazılacak içerik 400 KB'tan büyük ya da ikili.", category: "validation"))
        }
        let existed = FileManager.default.fileExists(atPath: path)
        if existed, let error = brokenJSON(path: path, before: try? String(contentsOfFile: path, encoding: .utf8), after: content, display: (path as NSString).lastPathComponent) {
            return (false, error)
        }
        do {
            try Data(content.utf8).write(to: URL(fileURLWithPath: path), options: [.atomic])
            return (!existed, nil)
        } catch {
            return (false, localFileError(code: "TERMINAL_FILE_WRITE_FAILED", fallback: "Dosya yazılamadı.", error: error))
        }
    }

    /// Validates every file edit first and writes only when all of them apply: never half a change.
    static func applyTerminalEdits(_ edits: [(path: String, patch: String, display: String)]) -> (diff: String?, error: RovaError?) {
        var updated: [(path: String, content: String)] = []
        for edit in edits {
            guard let current = try? String(contentsOfFile: edit.path, encoding: .utf8),
                  let result = applyUnifiedPatch(edit.patch, to: current, expectedPath: edit.display),
                  !result.isEmpty, result != current else {
                return (nil, RovaError(code: "TERMINAL_PATCH_REJECTED", message: "\(edit.display): yama dosyanın güncel içeriğiyle eşleşmedi; hiçbir dosya değiştirilmedi.", category: "validation"))
            }
            if let error = brokenJSON(path: edit.path, before: current, after: result, display: edit.display) { return (nil, error) }
            updated.append((edit.path, result))
        }
        for item in updated {
            do {
                try Data(item.content.utf8).write(to: URL(fileURLWithPath: item.path), options: [.atomic])
            } catch {
                return (nil, localFileError(code: "TERMINAL_PATCH_WRITE_FAILED", fallback: "Yama yazılamadı.", error: error))
            }
        }
        return (edits.map(\.patch).joined(separator: "\n"), nil)
    }

    /// Exact find-and-replace edits (the form models get right far more often than unified diffs):
    /// each `find` must occur exactly once unless `replaceAll`; every edit is checked first and
    /// files are written only when all of them apply.
    static func applyTerminalReplacements(_ edits: [(path: String, display: String, find: String, replace: String, replaceAll: Bool)]) -> (summary: String?, error: RovaError?) {
        var contents: [String: String] = [:]
        var originals: [String: String] = [:]
        var order: [String] = []
        var counts: [String: Int] = [:]
        for edit in edits {
            guard !edit.find.isEmpty else {
                return (nil, RovaError(code: "TERMINAL_EDIT_INVALID", message: "\(edit.display): aranacak metin boş; hiçbir dosya değiştirilmedi.", category: "validation"))
            }
            if contents[edit.path] == nil {
                guard let text = try? String(contentsOfFile: edit.path, encoding: .utf8) else {
                    return (nil, RovaError(code: "TERMINAL_FILE_NOT_TEXT", message: "\(edit.display) okunamadı; hiçbir dosya değiştirilmedi.", category: "validation"))
                }
                contents[edit.path] = text
                originals[edit.path] = text
                order.append(edit.path)
            }
            let current = contents[edit.path]!
            let occurrences = current.components(separatedBy: edit.find).count - 1
            if occurrences == 0 {
                return (nil, RovaError(code: "TERMINAL_EDIT_NOT_FOUND", message: "\(edit.display): aranan metin dosyada birebir bulunamadı (boşluk ve girinti dahil); dosyayı read_file ile okuyup tekrar dene. Hiçbir dosya değiştirilmedi.", category: "validation"))
            }
            if occurrences > 1 && !edit.replaceAll {
                return (nil, RovaError(code: "TERMINAL_EDIT_AMBIGUOUS", message: "\(edit.display): aranan metin \(occurrences) kez geçiyor; daha uzun, tek geçen bir parça ver ya da replaceAll kullan. Hiçbir dosya değiştirilmedi.", category: "validation"))
            }
            contents[edit.path] = edit.replaceAll ? current.replacingOccurrences(of: edit.find, with: edit.replace) : current.replacingCharacters(in: current.range(of: edit.find)!, with: edit.replace)
            counts[edit.display, default: 0] += edit.replaceAll ? occurrences : 1
        }
        for path in order {
            if let error = brokenJSON(path: path, before: originals[path], after: contents[path]!, display: (path as NSString).lastPathComponent) { return (nil, error) }
        }
        for path in order {
            do {
                try Data(contents[path]!.utf8).write(to: URL(fileURLWithPath: path), options: [.atomic])
            } catch {
                return (nil, localFileError(code: "TERMINAL_FILE_WRITE_FAILED", fallback: "Dosya yazılamadı.", error: error))
            }
        }
        return (counts.map { "\($0.key): \($0.value) değişiklik" }.sorted().joined(separator: "\n"), nil)
    }

    /// Searches file contents under `directory` without a shell (arguments are passed as-is, so
    /// the pattern can never become a command): ripgrep when installed, grep otherwise.
    static func searchTerminalFiles(pattern: String, directory: String, glob: String?) -> (text: String?, error: RovaError?) {
        guard !pattern.isEmpty, pattern.count <= 200, !pattern.contains("\0") else {
            return (nil, RovaError(code: "TERMINAL_SEARCH_INVALID", message: "Arama kalıbı boş ya da çok uzun.", category: "validation"))
        }
        let searchPath = interactivePath ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let ripgrep = searchPath.split(separator: ":").map { "\($0)/rg" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        let environment = ["PATH": searchPath, "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
        let snapshot: ProcessSnapshot
        if let ripgrep {
            var arguments = ["--line-number", "--no-heading", "--color", "never", "--max-count", "20", "--max-columns", "300", "-g", "!.git", "-g", "!node_modules"]
            if let glob, !glob.isEmpty, glob.count <= 100 { arguments += ["-g", glob] }
            arguments += ["--", pattern, "."]
            snapshot = runProcess(executable: ripgrep, arguments: arguments, timeoutSeconds: 20, workingDirectory: URL(fileURLWithPath: directory), environment: environment)
        } else {
            var arguments = ["-rnI", "--exclude-dir=.git", "--exclude-dir=node_modules", "-m", "20"]
            if let glob, !glob.isEmpty, glob.count <= 100 { arguments.append("--include=\(glob)") }
            arguments += ["-e", pattern, "."]
            snapshot = runProcess(executable: "/usr/bin/grep", arguments: arguments, timeoutSeconds: 20, workingDirectory: URL(fileURLWithPath: directory), environment: environment)
        }
        if snapshot.timedOut {
            return (nil, RovaError(code: "TERMINAL_SEARCH_TIMEOUT", message: "Arama 20 saniyede bitmedi; daha dar bir klasör veya kalıp dene.", category: "timeout"))
        }
        let lines = String(decoding: snapshot.stdout, as: UTF8.self).split(separator: "\n").prefix(200).joined(separator: "\n")
        return (RovaTerminalPolicy.redactSecrets(lines.isEmpty ? "(eşleşme yok)" : lines), nil)
    }

    /// A short description of this Mac's developer environment for the model: OS, shell, which
    /// toolchains exist (with versions) and the git projects in the usual folders (names only).
    /// Computed off the main thread once per launch; sent only when terminal sessions are enabled.
    static func terminalProfile() -> [String: Any] {
        let tools: [(String, String)] = [
            ("node", "--version"), ("npm", "--version"), ("pnpm", "--version"), ("yarn", "--version"), ("bun", "--version"),
            ("python3", "--version"), ("pip3", "--version"), ("git", "--version"), ("brew", "--version"), ("docker", "--version"),
            ("go", "version"), ("cargo", "--version"), ("swift", "--version"), ("xcodebuild", "-version"), ("java", "-version"), ("ruby", "--version"), ("rg", "--version")
        ]
        let script = tools.map { name, flag in
            "if p=$(command -v \(name) 2>/dev/null); then v=$(\(name) \(flag) 2>&1 | head -1); printf '%s|%s|%s\\n' \"\(name)\" \"$p\" \"$v\"; fi"
        }.joined(separator: "; ")
        var environment = ["HOME": NSHomeDirectory(), "USER": NSUserName(), "TERM": "dumb"]
        if let interactivePath { environment["PATH"] = interactivePath }
        let snapshot = runProcess(executable: "/bin/zsh", arguments: ["-lc", script], timeoutSeconds: 12, environment: environment)
        let home = NSHomeDirectory()
        let toolLines = String(decoding: snapshot.stdout, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            let version = parts[2].replacingOccurrences(of: "version", with: "").trimmingCharacters(in: .whitespaces).prefix(40)
            return "\(parts[0]) \(version)"
        }
        var projects: [String] = []
        for folder in ["Desktop", "Documents", "Developer", "Projects", "Code", "code", "src", "GitHub"] {
            let base = URL(fileURLWithPath: home).appendingPathComponent(folder)
            guard let children = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for child in children where FileManager.default.fileExists(atPath: child.appendingPathComponent(".git").path) {
                projects.append("~/\(folder)/\(child.lastPathComponent)")
                if projects.count >= 12 { break }
            }
            if projects.count >= 12 { break }
        }
        return [
            "os": "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)",
            "arch": {
                var info = utsname()
                uname(&info)
                return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }(),
            "shell": "zsh",
            "tools": Array(toolLines.prefix(20)),
            "projects": projects
        ]
    }
}
