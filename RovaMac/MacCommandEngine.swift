import Foundation

actor MacCommandEngine {
    private let ledger: CommandLedger
    private var completed: [UUID: CommandResult]
    private var running: [UUID: Date] = [:]

    init(ledger: CommandLedger = CommandLedger()) {
        self.ledger = ledger
        self.completed = ledger.load()
    }

    func execute(_ request: CommandRequest, runtimeStatus: String) async -> CommandResult {
        // 1. Duplicate check takes highest priority: regardless of payload/type changes, same ID is never re-executed.
        if let previous = completed[request.id] { return previous }
        if let startedAt = running[request.id] {
            return CommandResult(
                commandID: request.id,
                status: .running,
                message: "Komut çalışıyor.",
                startedAt: startedAt,
                finishedAt: startedAt
            )
        }

        // 2. Validate timestamp skew and payload/command type fail-closed.
        if !RovaValidation.isRequestTimestampValid(request.createdAt) {
            let result = denied(request.id, error: RovaError(code: "EXPIRED_REQUEST", message: "Komut zaman damgası geçersiz veya süresi dolmuş."))
            completed[request.id] = result
            ledger.save(completed)
            return result
        }

        if let validationError = RovaValidation.validate(request) {
            let result = denied(request.id, error: validationError)
            completed[request.id] = result
            ledger.save(completed)
            return result
        }

        // 3. Write-ahead persist 'running' state BEFORE performing any side-effect on macOS.
        let startedAt = Date()
        running[request.id] = startedAt
        ledger.recordRunning(commandID: request.id, startedAt: startedAt, currentCompleted: completed)

        // 4. Perform actual side-effect on MainActor.
        let outcome = await perform(request, runtimeStatus: runtimeStatus)
        let finishedAt = Date()
        let result = CommandResult(
            commandID: request.id,
            status: outcome.error == nil ? .completed : .failed,
            message: outcome.message,
            startedAt: startedAt,
            finishedAt: finishedAt,
            data: outcome.data,
            error: outcome.error
        )
        running.removeValue(forKey: request.id)
        completed[request.id] = result
        ledger.save(completed)
        return result
    }

    private func perform(_ request: CommandRequest, runtimeStatus: String) async -> (data: CommandData?, message: String, error: RovaError?) {
        switch request.type {
        case .getSystemStatus:
            let status = await MainActor.run { MacSystem.systemStatus(runtimeStatus: runtimeStatus) }
            return (.systemStatus(status), "Mac sistem durumu hazır.", nil)
        case .openApplication:
            guard case .application(let id) = request.payload else {
                return (nil, "Geçersiz uygulama isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Uygulama seçimi geçersiz."))
            }
            let error = await MainActor.run { MacSystem.openApplication(id) }
            return (nil, error == nil ? "\(id.displayName) açıldı." : error!.message, error)
        case .quitApplication:
            guard case .application(let id) = request.payload else {
                return (nil, "Geçersiz uygulama isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Kapatılacak uygulama seçimi geçersiz."))
            }
            let error = await MainActor.run { MacSystem.quitApplication(id) }
            return (nil, error == nil ? "\(id.displayName) kapatıldı." : error!.message, error)
        case .openURL:
            guard case .url(let value) = request.payload else {
                return (nil, "Geçersiz URL isteği.", RovaError(code: "INVALID_PAYLOAD", message: "URL payload’ı geçersiz."))
            }
            let error = await MainActor.run { MacSystem.openURL(value) }
            return (nil, error == nil ? "URL açıldı." : error!.message, error)
        case .lockMac:
            let error = await MainActor.run { MacSystem.lockMac() }
            return (nil, error == nil ? "Mac kilitlendi." : error!.message, error)
        case .sleepMac:
            let error = await MainActor.run { MacSystem.sleepMac() }
            return (nil, error == nil ? "Mac uyku moduna alındı." : error!.message, error)
        case .displaySleep:
            let error = await MainActor.run { MacSystem.displaySleep() }
            return (nil, error == nil ? "Mac ekranı uyku moduna alındı." : error!.message, error)
        case .setBrightness:
            guard case .brightness(let level) = request.payload else {
                return (nil, "Geçersiz parlaklık seviyesi.", RovaError(code: "INVALID_PAYLOAD", message: "Parlaklık seviyesi geçersiz."))
            }
            let error = await MainActor.run { MacSystem.setBrightness(level) }
            return (nil, error == nil ? "Parlaklık %\(level) yapıldı." : error!.message, error)
        case .setVolume:
            guard case .volume(let level) = request.payload else {
                return (nil, "Geçersiz ses seviyesi.", RovaError(code: "INVALID_PAYLOAD", message: "Ses seviyesi geçersiz."))
            }
            let error = await MainActor.run { MacSystem.setVolume(level) }
            return (nil, error == nil ? "Ses %\(level) yapıldı." : error!.message, error)
        case .toggleMute:
            let error = await MainActor.run { MacSystem.toggleMute() }
            return (nil, error == nil ? "Ses durumu değiştirildi." : error!.message, error)
        case .mediaControl:
            guard case .media(let action) = request.payload else {
                return (nil, "Geçersiz medya komutu.", RovaError(code: "INVALID_PAYLOAD", message: "Medya komutu geçersiz."))
            }
            let error = await MainActor.run { MacSystem.mediaControl(action) }
            return (nil, error == nil ? "Medya komutu uygulandı." : error!.message, error)
        case .setClipboardText:
            guard case .clipboardText(let text) = request.payload else {
                return (nil, "Geçersiz pano metni.", RovaError(code: "INVALID_PAYLOAD", message: "Pano metni geçersiz."))
            }
            let error = await MainActor.run { MacSystem.setClipboardText(text) }
            return (nil, error == nil ? "Metin Mac panosuna kopyalandı." : error!.message, error)
        case .saveTextFile:
            guard case .textFile(let file) = request.payload else {
                return (nil, "Geçersiz dosya isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Dosya isteği geçersiz."))
            }
            let error = MacSystem.saveTextFile(file)
            return (nil, error == nil ? "\(file.filename) masaüstüne kaydedildi." : error!.message, error)
        case .ping:
            return (.ping(PingData()), "Pong.", nil)
        }
    }

    private func denied(_ commandID: UUID, error: RovaError) -> CommandResult {
        let now = Date()
        return CommandResult(commandID: commandID, status: .denied, message: error.message, startedAt: now, finishedAt: now, error: error)
    }
}
