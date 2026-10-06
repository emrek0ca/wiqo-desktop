import Foundation

/// Turns verified PC results into the sentence the user reads. The backend answers a device-only
/// request with a short "doing it now" line and no second model call; once the Mac reports back,
/// this writes what really happened in plain first-person Turkish ("Sesi sonuna kadar açtım.")
/// instead of the Mac's log-style messages ("… kapatıldı ve doğrulandı.").
enum DeviceOutcomeNarrator {
    /// One line per finished step, in order. Failures use the Mac's own error message, which is
    /// already written for the user. Nil when there is nothing finished to report.
    static func text(steps: [PlannedCommand], results: [UUID: CommandResult]) -> String? {
        var lines: [String] = []
        for step in steps where step.type != .executeCode {
            guard let result = results[step.id] else { continue }
            let line: String
            if result.status == .completed, result.error == nil {
                line = successLine(step: step, result: result)
            } else {
                line = result.error?.message ?? result.message
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !lines.contains(trimmed) { lines.append(trimmed) }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// File evidence renders locally, without paying for another model turn.
    static func fileWidget(step: PlannedCommand, result: CommandResult) -> RovaBackendClient.CopilotResultWidget? {
        guard [.saveTextFile, .writeFile, .saveArtifact, .editDocument].contains(step.type),
              result.status == .completed, result.error == nil,
              case .files(let files) = result.data, !files.isEmpty else { return nil }
        let object: [String: Any] = [
            "type": "list", "domain": "files", "title": "Doğrulanan dosya",
            "widgetId": "file-evidence-\(step.id.uuidString)", "total": files.count,
            "items": files.map { file in ["id": file.path, "title": file.name, "subtitle": file.path, "meta": "\(file.byteCount) bayt"] }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(RovaBackendClient.CopilotResultWidget.self, from: data)
    }

    private static func successLine(step: PlannedCommand, result: CommandResult) -> String {
        switch (step.type, step.payload) {
        case (.setVolume, .volume(let level)):
            if level >= 100 { return "Sesi sonuna kadar açtım." }
            if level <= 0 { return "Sesi kapattım." }
            return "Sesi %\(level) yaptım."
        case (.setBrightness, .brightness(let level)):
            return level >= 100 ? "Parlaklığı sonuna kadar açtım." : "Parlaklığı %\(level) yaptım."
        case (.toggleMute, _):
            return "Sessiz tuşuna bastım."
        case (.mediaControl, .media(let action)):
            switch action {
            case .nextTrack: return "Sonraki parçaya geçtim."
            case .previousTrack: return "Önceki parçaya döndüm."
            case .playPause: return "Oynat/duraklat tuşuna bastım."
            }
        case (.controlApplication, .applicationControl(let payload)):
            let name: String
            let changed: Bool
            if case .applicationControl(let content) = result.data {
                name = content.resolvedName
                changed = content.changed
            } else {
                name = payload.target
                changed = true
            }
            switch payload.action {
            case .open: return "\(name) açıldı."
            case .activate: return "\(name) öne geldi."
            case .quit: return changed ? "\(name) kapatıldı." : "\(name) zaten kapalıydı."
            }
        case (.lockMac, _): return "PC'yi kilitledim."
        case (.sleepMac, _): return "PC'yi uyku moduna aldım."
        case (.displaySleep, _): return "Ekranı kapattım."
        case (.openURL, _): return "Bağlantıyı açtım."
        case (.setClipboardText, _): return "Panoya kopyaladım."
        default:
            return result.message
        }
    }
}
