import Foundation

private enum MacExecutionLane: Sendable {
    case readOnly
    case sideEffect
}

private actor MacExecutionGate {
    private struct Waiter {
        let id: UUID
        let lane: MacExecutionLane
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let maximumConcurrentReads = 4
    private let maximumQueuedCommands = 64
    private let maximumQueueWaitNanoseconds: UInt64 = 5_000_000_000
    private var activeReads = 0
    private var activeSideEffects = 0
    private var waiters: [Waiter] = []

    func acquire(_ lane: MacExecutionLane) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard waiters.isEmpty, canStart(lane) else {
            guard waiters.count < maximumQueuedCommands else { return false }
            let id = UUID()
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: self?.maximumQueueWaitNanoseconds ?? 0)
                    guard !Task.isCancelled else { return }
                    await self?.expire(id)
                } catch {
                    // The command acquired a slot or was cancelled before the queue deadline.
                }
            }
            let result = await withTaskCancellationHandler(operation: {
                await waitForSlot(id: id, lane: lane)
            }, onCancel: {
                Task { [weak self] in await self?.cancel(id) }
            })
            timeoutTask.cancel()
            return result
        }
        if canStart(lane) {
            start(lane)
            return true
        }
        return false
    }

    func release(_ lane: MacExecutionLane) {
        switch lane {
        case .readOnly:
            activeReads = max(0, activeReads - 1)
        case .sideEffect:
            activeSideEffects = max(0, activeSideEffects - 1)
        }
        drain()
    }

    private func canStart(_ lane: MacExecutionLane) -> Bool {
        switch lane {
        case .readOnly:
            return activeSideEffects == 0 && activeReads < maximumConcurrentReads
        case .sideEffect:
            return activeSideEffects == 0 && activeReads == 0
        }
    }

    private func start(_ lane: MacExecutionLane) {
        switch lane {
        case .readOnly: activeReads += 1
        case .sideEffect: activeSideEffects += 1
        }
    }

    private func waitForSlot(id: UUID, lane: MacExecutionLane) async -> Bool {
        guard !Task.isCancelled else { return false }
        if waiters.isEmpty, canStart(lane) {
            start(lane)
            return true
        }
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: id, lane: lane, continuation: continuation))
            drain()
        }
    }

    private func expire(_ id: UUID) {
        resumeWaiter(id, returning: false)
    }

    private func cancel(_ id: UUID) {
        resumeWaiter(id, returning: false)
    }

    private func resumeWaiter(_ id: UUID, returning result: Bool) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: result)
        drain()
    }

    private func drain() {
        while let waiter = waiters.first, canStart(waiter.lane) {
            waiters.removeFirst()
            start(waiter.lane)
            waiter.continuation.resume(returning: true)
        }
    }
}

private enum MacOperationWaitResult: Sendable {
    case completed(data: CommandData?, message: String, error: RovaError?)
    case timedOut
}

private actor MacOperationRace {
    private var resolved: MacOperationWaitResult?
    private var continuation: CheckedContinuation<MacOperationWaitResult, Never>?

    func wait() async -> MacOperationWaitResult {
        if let resolved { return resolved }
        return await withCheckedContinuation { continuation in
            register(continuation)
        }
    }

    func resolve(_ result: MacOperationWaitResult) {
        guard resolved == nil else { return }
        resolved = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func register(_ continuation: CheckedContinuation<MacOperationWaitResult, Never>) {
        if let resolved {
            continuation.resume(returning: resolved)
        } else {
            self.continuation = continuation
        }
    }
}

actor MacCommandEngine {
    private let ledger: CommandLedger
    private let executionGate = MacExecutionGate()
    private var completed: [UUID: CommandResult]
    private var inFlight: [UUID: Task<CommandResult, Never>] = [:]
    private var fileTransferToken: (@Sendable () async -> String?)?

    func setFileTransferTokenProvider(_ provider: @escaping @Sendable () async -> String?) {
        fileTransferToken = provider
    }

    init(ledger: CommandLedger = CommandLedger()) {
        self.ledger = ledger
        self.completed = ledger.load()
    }

    func persistedResults() -> [CommandResult] {
        completed.values.sorted { $0.finishedAt > $1.finishedAt }
    }

    func execute(_ request: CommandRequest, runtimeStatus: String) async -> CommandResult {
        // 1. Duplicate check takes highest priority: regardless of payload/type changes, same ID is never re-executed.
        if let previous = completed[request.id] { return previous }
        if let task = inFlight[request.id] {
            // A relay retry must receive the original outcome, not a second execution or a
            // synthetic "running" result that leaves the phone unsure whether it finished.
            return await task.value
        }

        let task = Task { [self] in
            await executeFresh(request, runtimeStatus: runtimeStatus)
        }
        inFlight[request.id] = task
        let result = await task.value
        inFlight.removeValue(forKey: request.id)
        return result
    }

    private func executeFresh(_ request: CommandRequest, runtimeStatus: String) async -> CommandResult {
        if let previous = completed[request.id] { return previous }

        guard RovaOperationManifest.supports(request.type, on: .macOS) else {
            let result = denied(request.id, error: RovaError(code: "UNSUPPORTED_OPERATION", message: "Bu Mac sürümünde bu işlem desteklenmiyor."))
            remember(result)
            ledger.save(completed)
            return result
        }

        // 2. Validate timestamp skew and payload/command type fail-closed.
        if !RovaValidation.isRequestTimestampValid(request.createdAt) {
            let result = denied(request.id, error: RovaError(code: "EXPIRED_REQUEST", message: "Komut zaman damgası geçersiz veya süresi dolmuş."))
            remember(result)
            ledger.save(completed)
            return result
        }

        if let validationError = RovaValidation.validate(request) {
            let result = denied(request.id, error: validationError)
            remember(result)
            ledger.save(completed)
            return result
        }

        let lane = executionLane(for: request.type)
        guard await executionGate.acquire(lane) else {
            let result = failed(
                request.id,
                message: "Mac şu anda çok sayıda işlem yürütüyor; bu komut henüz çalıştırılmadı.",
                error: RovaError(code: "DEVICE_BUSY", message: "Mac işlem kuyruğu dolu; lütfen biraz sonra tekrar deneyin.", category: "retryable")
            )
            remember(result)
            ledger.save(completed)
            return result
        }

        // 3. Write-ahead persist 'running' state BEFORE performing any side-effect on macOS.
        let startedAt = Date()
        ledger.recordRunning(commandID: request.id, startedAt: startedAt, currentCompleted: completed)

        // 4. Perform the operation away from the UI actor where the underlying API permits it.
        // A timed-out side effect keeps its execution slot until the underlying operation really
        // finishes, so a late result can never race with the next write.
        let waitResult = await performWithTimeout(request, runtimeStatus: runtimeStatus, lane: lane)
        let outcome: (data: CommandData?, message: String, error: RovaError?)
        switch waitResult {
        case .completed(let data, let message, let error):
            outcome = (data, message, error)
        case .timedOut:
            outcome = (
                nil,
                "İşlem zaman aşımına uğradı; sonucu doğrulanamadığı için tekrar çalıştırılmadı.",
                RovaError(code: "COMMAND_TIMEOUT", message: "Komut zaman aşımına uğradı; sonucu doğrulanamadığı için tekrar çalıştırılmadı.", category: "timeout")
            )
        }
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
        remember(result)
        ledger.save(completed)
        return result
    }

    private func performWithTimeout(
        _ request: CommandRequest,
        runtimeStatus: String,
        lane: MacExecutionLane
    ) async -> MacOperationWaitResult {
        let operation = Task { [self] in
            await perform(request, runtimeStatus: runtimeStatus)
        }
        let race = MacOperationRace()
        let observer = Task {
            let outcome = await operation.value
            await race.resolve(.completed(data: outcome.data, message: outcome.message, error: outcome.error))
        }
        let timeout = Task {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds(for: request.type))
                await race.resolve(.timedOut)
            } catch {
                // The operation completed before the deadline.
            }
        }
        let result = await race.wait()
        timeout.cancel()

        switch result {
        case .completed:
            observer.cancel()
            await executionGate.release(lane)
        case .timedOut:
            operation.cancel()
            // Do not release the lane until a non-cooperative synchronous API has returned.
            Task { [executionGate] in
                _ = await operation.value
                await executionGate.release(lane)
            }
        }
        return result
    }

    private func executionLane(for type: CommandType) -> MacExecutionLane {
        switch type {
        case .getSystemStatus, .getClipboardText, .getClipboardHistory,
             .listCalendarEvents, .listReminders, .listDesktopFiles, .readDesktopFile,
             .listFiles, .searchFiles, .readFile, .readDocument, .captureScreen, .listRunningApplications,
             .ping:
            return .readOnly
        default:
            return .sideEffect
        }
    }

    private func timeoutNanoseconds(for type: CommandType) -> UInt64 {
        switch type {
        case .sendFileToPhone:
            return 120_000_000_000
        case .readDocument, .editDocument, .saveArtifact, .executeCode, .runShortcut, .searchFiles:
            return 60_000_000_000
        case .listCalendarEvents, .createCalendarEvent, .listReminders, .createReminder,
             .completeReminder, .listDesktopFiles, .readDesktopFile, .listFiles, .readFile,
             .writeFile, .moveFile, .copyFile, .deleteFile, .saveTextFile:
            return 20_000_000_000
        default:
            return 10_000_000_000
        }
    }

    private func perform(_ request: CommandRequest, runtimeStatus: String) async -> (data: CommandData?, message: String, error: RovaError?) {
        switch request.type {
        case .getSystemStatus:
            let status = await Task.detached(priority: .utility) { MacSystem.systemStatus(runtimeStatus: runtimeStatus) }.value
            return (.systemStatus(status), "Mac sistem durumu hazır.", nil)
        case .openApplication:
            guard case .application(let id) = request.payload else {
                return (nil, "Geçersiz uygulama isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Uygulama seçimi geçersiz."))
            }
            let error = await Task.detached(priority: .userInitiated) { MacSystem.openApplication(id) }.value
            return (nil, error == nil ? "\(id.displayName) açıldı." : error!.message, error)
        case .openApplicationByName:
            guard case .applicationQuery(let query) = request.payload else {
                return (nil, "Geçersiz uygulama arama isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Uygulama adı geçersiz.", category: "tool_failure"))
            }
            let outcome = await MacSystem.openApplicationByName(query)
            return (outcome.data, outcome.error == nil ? "\(query) açıldı." : outcome.error!.message, outcome.error)
        case .controlApplication:
            guard case .applicationControl(let application) = request.payload else {
                return (nil, "Geçersiz uygulama eylemi.", RovaError(code: "INVALID_PAYLOAD", message: "Uygulama eylemi veya hedefi geçersiz.", category: "validation"))
            }
            let outcome = await Task.detached(priority: .userInitiated) {
                await MacSystem.controlApplication(application)
            }.value
            let resolvedName: String
            if case .applicationControl(let content) = outcome.data {
                resolvedName = content.resolvedName
            } else {
                resolvedName = application.target
            }
            let successMessage: String
            switch application.action {
            case .open: successMessage = "\(resolvedName) açıldı ve doğrulandı."
            case .activate: successMessage = "\(resolvedName) öne getirildi ve doğrulandı."
            case .quit:
                if case .applicationControl(let content) = outcome.data, !content.changed {
                    successMessage = "\(resolvedName) zaten açık değildi."
                } else {
                    successMessage = "\(resolvedName) kapatıldı ve doğrulandı."
                }
            }
            return (outcome.data, outcome.error == nil ? successMessage : outcome.error!.message, outcome.error)
        case .quitApplication:
            guard case .application(let id) = request.payload else {
                return (nil, "Geçersiz uygulama isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Kapatılacak uygulama seçimi geçersiz."))
            }
            let error = await Task.detached(priority: .userInitiated) {
                MacSystem.quitApplication(id)
            }.value
            return (nil, error == nil ? "\(id.displayName) kapatıldı." : error!.message, error)
        case .openURL:
            guard case .url(let value) = request.payload else {
                return (nil, "Geçersiz URL isteği.", RovaError(code: "INVALID_PAYLOAD", message: "URL payload’ı geçersiz."))
            }
            let outcome = await MacSystem.openURL(value)
            return (nil, outcome.error?.message ?? (outcome.browser.map { "URL \($0) içinde açıldı." } ?? "URL açıldı."), outcome.error)
        case .lockMac:
            let error = await Task.detached(priority: .userInitiated) { MacSystem.lockMac() }.value
            return (nil, error == nil ? "Mac kilitlendi." : error!.message, error)
        case .sleepMac:
            let error = await Task.detached(priority: .userInitiated) { MacSystem.sleepMac() }.value
            return (nil, error == nil ? "Mac uyku moduna alındı." : error!.message, error)
        case .displaySleep:
            let error = await Task.detached(priority: .userInitiated) { MacSystem.displaySleep() }.value
            return (nil, error == nil ? "Mac ekranı uyku moduna alındı." : error!.message, error)
        case .setBrightness:
            guard case .brightness(let level) = request.payload else {
                return (nil, "Geçersiz parlaklık seviyesi.", RovaError(code: "INVALID_PAYLOAD", message: "Parlaklık seviyesi geçersiz."))
            }
            let error = await Task.detached(priority: .userInitiated) { MacSystem.setBrightness(level) }.value
            return (nil, error == nil ? "Parlaklık %\(level) yapıldı." : error!.message, error)
        case .setVolume:
            guard case .volume(let level) = request.payload else {
                return (nil, "Geçersiz ses seviyesi.", RovaError(code: "INVALID_PAYLOAD", message: "Ses seviyesi geçersiz."))
            }
            let error = await Task.detached(priority: .userInitiated) { MacSystem.setVolume(level) }.value
            return (nil, error == nil ? "Ses %\(level) yapıldı." : error!.message, error)
        case .toggleMute:
            let error = await Task.detached(priority: .userInitiated) { MacSystem.toggleMute() }.value
            return (nil, error == nil ? "Ses durumu değiştirildi." : error!.message, error)
        case .mediaControl:
            guard case .media(let action) = request.payload else {
                return (nil, "Geçersiz medya komutu.", RovaError(code: "INVALID_PAYLOAD", message: "Medya komutu geçersiz."))
            }
            let error = await Task.detached(priority: .userInitiated) {
                MacSystem.mediaControl(action)
            }.value
            return (nil, error == nil ? "Medya komutu uygulandı." : error!.message, error)
        case .setClipboardText:
            guard case .clipboardText(let text) = request.payload else {
                return (nil, "Geçersiz pano metni.", RovaError(code: "INVALID_PAYLOAD", message: "Pano metni geçersiz."))
            }
            let error = await Task.detached(priority: .userInitiated) {
                MacSystem.setClipboardText(text)
            }.value
            return (nil, error == nil ? "Metin Mac panosuna kopyalandı." : error!.message, error)
        case .getClipboardText:
            let outcome = await Task.detached(priority: .utility) {
                MacSystem.getClipboardText()
            }.value
            return (outcome.data, outcome.error == nil ? "Pano içeriği okundu." : outcome.error!.message, outcome.error)
        case .createNote:
            guard case .note(let payload) = request.payload else {
                return (nil, "Geçersiz not isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Not isteği geçersiz."))
            }
            let outcome = await Task.detached(priority: .userInitiated) {
                MacSystem.createNote(payload)
            }.value
            return (outcome.data, outcome.error == nil ? "Not oluşturuldu." : outcome.error!.message, outcome.error)
        case .sendEmail:
            guard case .email(let payload) = request.payload else {
                return (nil, "Geçersiz e-posta isteği.", RovaError(code: "INVALID_PAYLOAD", message: "E-posta isteği geçersiz."))
            }
            let error = await Task.detached(priority: .userInitiated) {
                MacSystem.sendEmail(payload)
            }.value
            return (nil, error == nil ? "E-posta gönderildi." : error!.message, error)
        case .getClipboardHistory:
            let outcome = await MainActor.run { MacSystem.getClipboardHistory() }
            let count = outcome.data.flatMap { data -> Int? in
                if case .clipboardHistory(let entries) = data { return entries.count }
                return nil
            } ?? 0
            return (outcome.data, "Son \(count) pano öğesi bulundu.", nil)
        case .saveTextFile:
            guard case .textFile(let file) = request.payload else {
                return (nil, "Geçersiz dosya isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Dosya isteği geçersiz."))
            }
            let error = await Task.detached(priority: .userInitiated) { MacSystem.saveTextFile(file) }.value
            return (nil, error == nil ? "\(file.filename) masaüstüne kaydedildi." : error!.message, error)
        case .saveArtifact:
            guard case .artifactFile(let artifact) = request.payload else {
                return (nil, "Geçersiz artifact isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Artifact isteği geçersiz."))
            }
            guard let tokenData = try? RovaKeychainStore.load(account: MacStorage.backendAccountTokenAccount),
                  let token = String(data: tokenData, encoding: .utf8),
                  !token.isEmpty else {
                return (nil, "Backend oturumu bulunamadı.", RovaError(code: "BACKEND_AUTH_REQUIRED", message: "Artifact indirmek için Mac backend oturumu gerekli."))
            }
            let error = await MacSystem.saveArtifact(artifact, token: token)
            return (nil, error == nil ? "\(artifact.filename) masaüstüne kaydedildi." : error!.message, error)
        case .readDocument:
            guard case .fileName(let filename) = request.payload else {
                return (nil, "Geçersiz belge okuma isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Belge adı geçersiz."))
            }
            let outcome = await Task.detached(priority: .userInitiated) { MacSystem.readDocument(filename) }.value
            return (outcome.data, outcome.error == nil ? "\(filename) okundu." : outcome.error!.message, outcome.error)
        case .editDocument:
            guard case .document(let document) = request.payload else {
                return (nil, "Geçersiz belge düzenleme isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Belge düzenleme isteği geçersiz."))
            }
            let error = await Task.detached(priority: .userInitiated) { MacSystem.editDocument(document) }.value
            return (nil, error == nil ? "\(document.filename) güncellendi." : error!.message, error)
        case .sendMessage:
            guard case .message(let message) = request.payload else {
                return (nil, "Geçersiz mesaj isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Mesaj isteği geçersiz."))
            }
            let error = await Task.detached(priority: .userInitiated) {
                MacSystem.sendMessage(message)
            }.value
            return (nil, error == nil ? "Mesaj gönderildi." : error!.message, error)
        case .listCalendarEvents:
            let outcome = await Task.detached(priority: .utility) {
                await MacSystem.listCalendarEvents()
            }.value
            let count = outcome.data.flatMap { data -> Int? in
                if case .calendarEvents(let events) = data { return events.count }
                return nil
            } ?? 0
            return (outcome.data, outcome.error == nil ? "\(count) takvim etkinliği bulundu." : outcome.error!.message, outcome.error)
        case .createCalendarEvent:
            guard case .calendarEvent(let event) = request.payload else {
                return (nil, "Geçersiz takvim etkinliği isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Takvim etkinliği isteği geçersiz."))
            }
            let outcome = await Task.detached(priority: .userInitiated) {
                await MacSystem.createCalendarEvent(event)
            }.value
            return (outcome.data, outcome.error == nil ? "Takvim etkinliği oluşturuldu." : outcome.error!.message, outcome.error)
        case .listReminders:
            let outcome = await Task.detached(priority: .utility) {
                await MacSystem.listReminders()
            }.value
            let count = outcome.data.flatMap { data -> Int? in
                if case .reminders(let reminders) = data { return reminders.count }
                return nil
            } ?? 0
            return (outcome.data, outcome.error == nil ? "\(count) hatırlatıcı bulundu." : outcome.error!.message, outcome.error)
        case .createReminder:
            guard case .reminder(let payload) = request.payload else {
                return (nil, "Geçersiz hatırlatıcı isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Hatırlatıcı isteği geçersiz."))
            }
            let outcome = await Task.detached(priority: .userInitiated) {
                await MacSystem.createReminder(payload)
            }.value
            return (outcome.data, outcome.error == nil ? "Hatırlatıcı oluşturuldu." : outcome.error!.message, outcome.error)
        case .completeReminder:
            guard case .completeReminder(let payload) = request.payload else {
                return (nil, "Geçersiz hatırlatıcı isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Hatırlatıcı isteği geçersiz."))
            }
            let outcome = await Task.detached(priority: .userInitiated) {
                await MacSystem.completeReminder(payload)
            }.value
            return (outcome.data, outcome.error == nil ? "Hatırlatıcı tamamlandı." : outcome.error!.message, outcome.error)
        case .listDesktopFiles:
            let outcome = await Task.detached(priority: .utility) { MacSystem.listDesktopFiles() }.value
            let count = outcome.data.flatMap { data -> Int? in
                if case .desktopFiles(let files) = data { return files.count }
                return nil
            } ?? 0
            return (outcome.data, outcome.error == nil ? "Masaüstünde \(count) öğe bulundu." : outcome.error!.message, outcome.error)
        case .readDesktopFile:
            guard case .fileName(let filename) = request.payload else {
                return (nil, "Geçersiz dosya okuma isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Dosya adı geçersiz."))
            }
            let outcome = await Task.detached(priority: .utility) { MacSystem.readDesktopFile(filename) }.value
            return (outcome.data, outcome.error == nil ? "\(filename) okundu." : outcome.error!.message, outcome.error)
        case .moveDesktopFile, .renameDesktopFile:
            guard case .fileMove(let move) = request.payload else {
                return (nil, "Geçersiz dosya taşıma isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Dosya taşıma isteği geçersiz."))
            }
            let error = await Task.detached(priority: .userInitiated) { MacSystem.moveDesktopFile(move) }.value
            let verb = request.type == .renameDesktopFile ? "yeniden adlandırıldı" : "taşındı"
            return (nil, error == nil ? "Dosya \(verb)." : error!.message, error)
        case .ping:
            return (.ping(PingData()), "Pong.", nil)
        case .listFiles:
            guard case .fileOperation(let payload) = request.payload else {
                return (nil, "Geçersiz dosya listeleme isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Dosya yolu geçersiz.", category: "tool_failure"))
            }
            let outcome = await Task.detached(priority: .userInitiated) { MacSystem.listFiles(payload) }.value
            let count = outcome.data.flatMap { data -> Int? in
                if case .files(let files) = data { return files.count }
                return nil
            } ?? 0
            return (outcome.data, outcome.error == nil ? "\(count) dosya bulundu." : outcome.error!.message, outcome.error)
        case .searchFiles:
            guard case .fileSearch(let payload) = request.payload else {
                return (nil, "Arama isteği geçersiz.", RovaError(code: "INVALID_PAYLOAD", message: "Dosya arama isteği geçersiz."))
            }
            let outcome = await MacSystem.searchFiles(payload)
            return (outcome.data, outcome.message, outcome.error)
        case .readFile:
            guard case .fileOperation(let payload) = request.payload else {
                return (nil, "Geçersiz dosya okuma isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Dosya yolu geçersiz.", category: "tool_failure"))
            }
            let outcome = await Task.detached(priority: .userInitiated) { MacSystem.readFile(payload) }.value
            return (outcome.data, outcome.error == nil ? "Dosya okundu." : outcome.error!.message, outcome.error)
        case .sendFileToPhone:
            guard case .fileOperation(let payload) = request.payload, let token = await fileTransferToken?() else {
                return (nil, "Dosya gönderilemedi.", RovaError(code: "TRANSFER_UNAVAILABLE", message: "PC aktarım bağlantısı hazır değil."))
            }
            let outcome = await MacSystem.sendFileToPhone(payload, commandID: request.id, accessToken: token)
            return (outcome.data, outcome.error == nil ? "Dosya telefona gönderildi." : outcome.error!.message, outcome.error)
        case .writeFile:
            guard case .fileOperation(let payload) = request.payload else {
                return (nil, "Geçersiz dosya yazma isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Dosya yolu veya içeriği geçersiz.", category: "tool_failure"))
            }
            let error = await Task.detached(priority: .userInitiated) { MacSystem.writeFile(payload) }.value
            return (nil, error == nil ? "Dosya yazıldı." : error!.message, error)
        case .moveFile:
            guard case .fileOperation(let payload) = request.payload else {
                return (nil, "Geçersiz dosya taşıma isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Dosya yolları geçersiz.", category: "tool_failure"))
            }
            let error = await Task.detached(priority: .userInitiated) { MacSystem.moveFile(payload) }.value
            return (nil, error == nil ? "Dosya taşındı." : error!.message, error)
        case .copyFile:
            guard case .fileOperation(let payload) = request.payload else {
                return (nil, "Geçersiz dosya kopyalama isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Dosya yolları geçersiz.", category: "tool_failure"))
            }
            let error = await Task.detached(priority: .userInitiated) { MacSystem.copyFile(payload) }.value
            return (nil, error == nil ? "Dosya kopyalandı." : error!.message, error)
        case .deleteFile:
            guard case .fileOperation(let payload) = request.payload else {
                return (nil, "Geçersiz dosya silme isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Dosya yolu geçersiz.", category: "tool_failure"))
            }
            let error = await Task.detached(priority: .userInitiated) { MacSystem.deleteFile(payload) }.value
            return (nil, error == nil ? "Dosya silindi." : error!.message, error)
        case .executeCode:
            guard case .codeExecution(let payload) = request.payload else {
                return (nil, "Geçersiz kod çalıştırma isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Kod çalıştırma isteği geçersiz.", category: "tool_failure"))
            }
            let outcome = await Task.detached(priority: .userInitiated) { MacSystem.executeCode(payload) }.value
            let successMessage: String
            if case .processOutput(let output) = outcome.data {
                let preview = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                successMessage = preview.isEmpty ? "Kod çalıştırıldı (çıktı yok)." : "Kod çalıştırıldı: \(preview.prefix(300))"
            } else {
                successMessage = "Kod çalıştırıldı."
            }
            return (outcome.data, outcome.error == nil ? successMessage : outcome.error!.message, outcome.error)
        case .captureScreen:
            guard case .screenCapture(let payload) = request.payload else {
                return (nil, "Geçersiz ekran görüntüsü isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Ekran ayarları geçersiz.", category: "tool_failure"))
            }
            let outcome = await Task.detached(priority: .userInitiated) {
                await MacSystem.captureScreen(payload)
            }.value
            return (outcome.data, outcome.error == nil ? "Ekran görüntüsü hazır." : outcome.error!.message, outcome.error)
        case .runShortcut:
            guard case .shortcut(let payload) = request.payload else {
                return (nil, "Geçersiz Shortcut isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Shortcut payload'ı geçersiz.", category: "validation"))
            }
            let outcome = await Task.detached(priority: .userInitiated) { MacSystem.runShortcut(payload) }.value
            return (outcome.data, outcome.error == nil ? "\(payload.shortcut.displayName) doğrulandı." : outcome.error!.message, outcome.error)
        case .controlUIElement:
            guard case .uiElement(let payload) = request.payload else {
                return (nil, "Geçersiz Accessibility isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Accessibility payload'ı geçersiz.", category: "validation"))
            }
            let outcome = await Task.detached(priority: .userInitiated) { MacSystem.controlUIElement(payload) }.value
            return (outcome.data, outcome.error == nil ? "Accessibility eylemi doğrulandı." : outcome.error!.message, outcome.error)
        case .clickScreen:
            guard case .screenClick(let payload) = request.payload else {
                return (nil, "Geçersiz ekran tıklaması isteği.", RovaError(code: "INVALID_PAYLOAD", message: "Ekran tıklaması payload'ı geçersiz.", category: "validation"))
            }
            let outcome = await Task.detached(priority: .userInitiated) { MacSystem.clickScreen(payload) }.value
            return (outcome.data, outcome.error == nil ? "Ekran tıklaması gönderildi; sonucu yeniden gözlemlemek gerekiyor." : outcome.error!.message, outcome.error)
        case .listRunningApplications:
            let outcome = await Task.detached(priority: .utility) {
                MacSystem.listRunningApplications()
            }.value
            return (outcome.data, outcome.error == nil ? "Açık uygulamalar listelendi." : outcome.error!.message, outcome.error)
        }
    }

    private func denied(_ commandID: UUID, error: RovaError) -> CommandResult {
        let now = Date()
        return CommandResult(commandID: commandID, status: .denied, message: error.message, startedAt: now, finishedAt: now, error: error)
    }

    private func failed(_ commandID: UUID, message: String, error: RovaError) -> CommandResult {
        let now = Date()
        return CommandResult(commandID: commandID, status: .failed, message: message, startedAt: now, finishedAt: now, error: error)
    }

    private func remember(_ result: CommandResult) {
        completed[result.commandID] = result
        guard completed.count > 128 else { return }
        let retainedIDs = Set(
            completed.values
                .sorted { $0.finishedAt > $1.finishedAt }
                .prefix(128)
                .map(\.commandID)
        )
        completed = completed.filter { retainedIDs.contains($0.key) }
    }
}
