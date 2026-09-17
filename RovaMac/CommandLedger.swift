import Foundation

struct PersistedCommand: Codable, Sendable {
    let commandID: UUID
    let status: CommandStatus
    let result: CommandResult?
    let recordedAt: Date

    enum CodingKeys: String, CodingKey {
        case commandID, status, result, recordedAt
    }

    init(commandID: UUID, status: CommandStatus, result: CommandResult?, recordedAt: Date) {
        self.commandID = commandID
        self.status = status
        self.result = result
        self.recordedAt = recordedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commandID = try container.decode(UUID.self, forKey: .commandID)
        if let decodedStatus = try container.decodeIfPresent(CommandStatus.self, forKey: .status) {
            status = decodedStatus
            result = try container.decodeIfPresent(CommandResult.self, forKey: .result)
            recordedAt = try container.decodeIfPresent(Date.self, forKey: .recordedAt) ?? Date()
        } else {
            let legacyResult = try container.decode(CommandResult.self, forKey: .result)
            status = legacyResult.status
            result = legacyResult
            recordedAt = legacyResult.finishedAt
        }
    }
}

struct CommandLedger: Sendable {
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("Rova", isDirectory: true)
        self.fileURL = directory.appendingPathComponent("command-ledger.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> [UUID: CommandResult] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? decoder.decode([PersistedCommand].self, from: data) else {
            return [:]
        }
        var results: [UUID: CommandResult] = [:]
        var hasUnfinished = false
        for entry in entries {
            if entry.status == .running {
                // The side effect may have happened before the restart, so never replay this ID.
                hasUnfinished = true
                results[entry.commandID] = CommandResult(
                    commandID: entry.commandID,
                    status: .unknown,
                    message: "Komutun sonucu doğrulanamadı; tekrar çalıştırılmadı.",
                    startedAt: entry.recordedAt,
                    finishedAt: entry.recordedAt,
                    error: RovaError(code: "OUTCOME_UNKNOWN", message: "Komut durumu belirsiz; tekrar çalıştırılmadı.", category: "delivery")
                )
            } else if let result = entry.result {
                results[entry.commandID] = result
            }
        }
        if hasUnfinished {
            // Persist the resolved denied states back to disk
            save(results)
        }
        return results
    }

    func recordRunning(commandID: UUID, startedAt: Date, currentCompleted: [UUID: CommandResult]) {
        var entries = currentCompleted.values
            .sorted { $0.finishedAt < $1.finishedAt }
            .map { PersistedCommand(commandID: $0.commandID, status: $0.status, result: $0, recordedAt: $0.finishedAt) }
        entries.append(PersistedCommand(commandID: commandID, status: .running, result: nil, recordedAt: startedAt))
        let trimmed = Array(entries.suffix(128))
        writeEntries(trimmed)
    }

    func save(_ values: [UUID: CommandResult]) {
        let entries = values.values
            .sorted { $0.finishedAt < $1.finishedAt }
            .suffix(128)
            .map { PersistedCommand(commandID: $0.commandID, status: $0.status, result: $0, recordedAt: $0.finishedAt) }
        writeEntries(Array(entries))
    }

    private func writeEntries(_ entries: [PersistedCommand]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Ledger persistence is best effort; command execution remains safe and in-memory dedupe stays active.
        }
    }
}
