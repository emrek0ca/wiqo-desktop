import Foundation

/// Runs a file plan (rova-backend docs/plan-packet.md): the steps in order, each one held to the
/// rules it would meet on its own, stopping at the first one that fails. The phone approved the
/// whole plan once; nothing here widens what it said.
extension MacSystem {
    static func runFilePlan(_ plan: FilePlanPayload, transferToken: String?) async -> (data: CommandData?, message: String, error: RovaError?) {
        var results: [PlanStepResult] = []
        var files: [String: [FileSystemEntry]] = [:]
        var failure: String?

        for step in plan.steps {
            if let failure {
                results.append(PlanStepResult(id: step.id, op: step.op, status: "skipped", message: "Önceki adım başarısız: \(failure)"))
                continue
            }
            let outcome = await runPlanStep(step, files: files, transferToken: transferToken)
            if let found = outcome.files { files[step.id] = found }
            results.append(outcome.result)
            if outcome.result.status != "completed" { failure = "\(step.id) — \(outcome.result.message)" }
        }
        let done = results.filter { $0.status == "completed" }.count
        let message = failure == nil ? "Plan tamamlandı (\(done)/\(results.count) adım)." : "Plan durdu: \(failure!)"
        let error = failure.map { RovaError(code: "PLAN_STEP_FAILED", message: $0, category: "tool_failure") }
        return (.planResult(PlanResult(steps: results)), message, error)
    }

    private struct PlanStepOutcome {
        let result: PlanStepResult
        var files: [FileSystemEntry]?
    }

    private static func capability(for operation: String) -> String {
        switch operation {
        case "search", "list": return "device.files.list"
        case "read", "send": return "device.files.read"
        case "move": return "device.files.move"
        default: return "device.files.copy" // convert, copy
        }
    }

    private static func runPlanStep(_ step: FilePlanStep, files: [String: [FileSystemEntry]], transferToken: String?) async -> PlanStepOutcome {
        func fail(_ message: String) -> PlanStepOutcome {
            PlanStepOutcome(result: PlanStepResult(id: step.id, op: step.op, status: "failed", message: message))
        }
        guard await MainActor.run(body: { CapabilityStore.shared.isEnabled(capability(for: step.op)) }) else {
            return fail("Bu işlem Wiqo'nun Yetenekler ayarında kapalı.")
        }
        // A binding names the first file of an earlier step's result, resolved from this Mac's own results.
        var path: String?
        // "$s1*": every file the earlier step found, one after another (move, copy, convert).
        if let raw = step.path, raw.hasPrefix("$"), raw.hasSuffix("*") {
            let found = (files[String(raw.dropFirst().dropLast())] ?? []).filter { !$0.isDirectory }.prefix(20)
            guard !found.isEmpty else { return fail("Önceki adımın sonucunda dosya yok.") }
            var made: [FileSystemEntry] = []
            for entry in found {
                guard RovaValidation.isValidLocalPath(entry.path), !RovaOwnFolders.isSensitive(entry.path) else { return fail("\(entry.name) plan içinde kullanılamaz.") }
                let one = FilePlanStep(id: step.id, op: step.op, path: entry.path, destination: step.op == "convert" ? nil : step.destination.map { ($0 as NSString).appendingPathComponent(entry.name) })
                let outcome = await runPlanStep(one, files: [:], transferToken: nil)
                guard outcome.result.status == "completed" else { return fail("\(entry.name): \(outcome.result.message)") }
                made += outcome.files ?? []
            }
            let verb = step.op == "move" ? "taşındı" : step.op == "copy" ? "kopyalandı" : "çevrildi"
            return complete("\(found.count) dosya \(verb).", files: made.isEmpty ? nil : made)
        }
        if let raw = step.path {
            if raw.hasPrefix("$") {
                guard let bound = files[String(raw.dropFirst())]?.first?.path else { return fail("Önceki adımın sonucunda dosya yok.") }
                guard RovaValidation.isValidLocalPath(bound), !RovaOwnFolders.isSensitive(bound) else { return fail("Bağlanan dosya plan içinde kullanılamaz.") }
                path = bound
            } else {
                path = raw
            }
        }
        func complete(_ message: String, files: [FileSystemEntry]? = nil, text: String? = nil, artifactId: String? = nil, transferId: String? = nil) -> PlanStepOutcome {
            PlanStepOutcome(result: PlanStepResult(id: step.id, op: step.op, status: "completed", message: message, files: files, text: text, artifactId: artifactId, transferId: transferId), files: files)
        }

        switch step.op {
        case "search":
            let payload = FileSearchPayload(query: step.query ?? "", folder: step.folder, kind: step.kind, modifiedWithinDays: step.modifiedWithinDays, sort: step.sort, alternatives: step.alternatives)
            let outcome = await MacFileSearch.search(payload)
            if let error = outcome.error { return fail(error.message) }
            guard case .files(let found)? = outcome.data else { return fail("Arama sonucu okunamadı.") }
            return complete(outcome.message, files: found)
        case "list":
            guard let path else { return fail("Klasör yolu yok.") }
            let outcome = listFiles(LocalFileOperationPayload(path: path))
            if let error = outcome.error { return fail(error.message) }
            guard case .files(let found)? = outcome.data else { return fail("Klasör içeriği okunamadı.") }
            return complete("\(found.count) dosya.", files: found)
        case "read":
            guard let path else { return fail("Dosya yolu yok.") }
            let outcome = readFile(LocalFileOperationPayload(path: path))
            if let error = outcome.error { return fail(error.message) }
            guard case .fileData(let content)? = outcome.data else { return fail("Dosya içeriği okunamadı.") }
            return complete("Dosya okundu.", text: String((content.text ?? "").prefix(4_000)))
        case "convert":
            guard let path else { return fail("Dosya yolu yok.") }
            let outcome = await convertFile(LocalFileOperationPayload(path: path, destination: step.destination))
            if let error = outcome.error { return fail(error.message) }
            guard case .files(let made)? = outcome.data else { return fail("Çeviri sonucu okunamadı.") }
            return complete(outcome.message, files: made)
        case "send":
            guard let path, let transferToken, let transfer = step.transferId, let transferID = UUID(uuidString: transfer) else { return fail("Dosya yolu veya aktarım bağlantısı yok.") }
            let outcome = await sendFileToPhone(LocalFileOperationPayload(path: path), commandID: transferID, accessToken: transferToken)
            if let error = outcome.error { return fail(error.message) }
            guard case .fileTransfer(let artifactID)? = outcome.data else { return fail("Aktarım sonucu okunamadı.") }
            return complete("Dosya telefona gönderildi.", artifactId: artifactID, transferId: transfer)
        default: // move, copy
            guard let path, let destination = step.destination else { return fail("Kaynak veya hedef yok.") }
            let payload = LocalFileOperationPayload(path: path, destination: destination)
            let error = step.op == "move" ? moveFile(payload) : copyFile(payload)
            return error.map { fail($0.message) } ?? complete(step.op == "move" ? "Dosya taşındı." : "Dosya kopyalandı.")
        }
    }
}
