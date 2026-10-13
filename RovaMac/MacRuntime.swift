import Combine
import AppKit
import Foundation
import Network
import OSLog
import ServiceManagement

private struct MacDeviceInfoSnapshot: Sendable {
    let availableApplications: [ApplicationInfo]
    let applicationTargets: [DeviceApplicationTarget]
    let capabilities: [String]
    let authorities: [DeviceCapabilityAuthority]
}

private actor PairedDeviceTokenStore {
    private let account = MacStorage.pairedTokenAccount

    func load() -> String? {
        guard let data = try? RovaKeychainStore.load(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) throws {
        try RovaKeychainStore.save(Data(token.utf8), account: account)
    }

    func delete() throws {
        try RovaKeychainStore.delete(account: account)
    }
}

@MainActor
final class MacRuntime: ObservableObject {
    private let logger = Logger(subsystem: "com.wiqo.mac", category: "connection")
    private let authLogger = Logger(subsystem: "com.wiqo.mac", category: "auth")
    private let commandLogger = Logger(subsystem: "com.wiqo.mac", category: "command")
    private let errorLogger = Logger(subsystem: "com.wiqo.mac", category: "error")
    @Published private(set) var serviceState: MacServiceState = .starting
    @Published private(set) var serviceError: String?
    @Published private(set) var pairingCode = "------"
    @Published private(set) var pairingExpiresAt = Date.distantPast
    @Published private(set) var pairedDeviceName: String?
    @Published private(set) var pairedDeviceID: UUID?
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var connectedDeviceID: UUID?
    @Published private(set) var localIPAddress = MacNetwork.unavailableAddress
    @Published private(set) var certificateFingerprint = ""
    @Published var launchAtLogin = false
    /// "Wiqo Projeleri" folder sync with the account's other devices (see MacProjectSync).
    @Published private(set) var projectSyncStatus = "Senkron kapalı"
    private var projectSyncStatusTask: Task<Void, Never>?
    private lazy var projectSync = MacProjectSync(apiBase: MacBackendChannel.apiBaseURL, flavor: MacStorage.flavor, allowRun: { UserDefaults.standard.bool(forKey: MacStorage.runProjectsKey) }) { [weak self] in
        await self?.backendChannel.accessTokenForFileTransfer()
    }
    /// The key that makes Act projects private; it arrives from the iPhone or is typed in as a recovery code.
    @Published private(set) var hasProjectKey = ActKeyStore.load(flavor: MacStorage.flavor) != nil
    @Published private(set) var automations: [MacAutomation] = []
    @Published private(set) var isLoadingAutomations = false
    @Published private(set) var automationsError: String?
    @Published private(set) var automationPermissions: [MacAutomationPermission] = []
    @Published private(set) var isRefreshingPermissions = false
    @Published private(set) var isWarmingAutomationPermissions = false
    @Published private(set) var permissionActionMessage: String?
    @Published private(set) var installedWiqoShortcuts: Set<WiqoShortcut> = []
    @Published private(set) var shortcutInstallMessage: String?
    @Published private(set) var backendSessionActive = false
    @Published private(set) var relayPairing: RelayPairingState = .preparing
    /// What start-up is doing right now, shown in the menu so a slow or stuck step is visible.
    @Published private(set) var startupDetail: String?

    /// Paired with a phone over the local network or over the internet.
    var isPaired: Bool { pairedDeviceID != nil || pairedDeviceName != nil }
    /// A phone is reachable right now, directly or through the backend.
    var isPhoneConnected: Bool { connectedDeviceID != nil || backendSessionActive }

    private var cachedAvailableApplications: [ApplicationInfo] = []
    private var cachedApplicationTargets: [DeviceApplicationTarget] = []
    private var cachedCapabilities: [String] = ["runtime.status"]
    private var cachedAuthorities: [DeviceCapabilityAuthority] = []

    let port: UInt16 = 47831
    let deviceID: UUID
    private var server: MacServer?
    private let engine = MacCommandEngine()
    private let pairedDeviceTokenStore = PairedDeviceTokenStore()
    private var identity: RovaTLSIdentity?
    private var token: String?
    private var startTask: Task<Void, Never>?
    private var deviceInfoRefreshTask: Task<Void, Never>?
    private var applicationChangeRefreshTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var agentAccessObserver: AnyCancellable?
    private var taskGrantObserver: AnyCancellable?
    private var shortcutInstallRefreshTask: Task<Void, Never>?
    private var pairingRenewalTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private lazy var relayPairingService = MacRelayPairing(
        api: .live(baseURL: MacBackendChannel.apiBaseURL, deviceID: deviceID, displayName: MacNetwork.computerName),
        onState: { [weak self] state in self?.relayPairing = state },
        onClaimed: { [weak self] pairingToken, backendToken, deviceAccessToken, deviceRefreshToken in
            await self?.relayPairingClaimed(pairingToken: pairingToken, backendToken: backendToken, deviceAccessToken: deviceAccessToken, deviceRefreshToken: deviceRefreshToken)
        }
    )
    private var sessions: [ObjectIdentifier: MacClientSession] = [:]
    private var authenticatedSessionID: ObjectIdentifier?
    private var sessionFailedPairingAttempts: [ObjectIdentifier: Int] = [:]
    private static let maxPairingAttemptsPerSession = 3
    private lazy var backendChannel = MacBackendChannel(
        engine: engine,
        runtimeStatus: { [weak self] in self?.serviceState.rawValue ?? "unknown" },
        deviceInfo: { [weak self] in self?.deviceInfo ?? DeviceInfo(id: UUID(), displayName: "Wiqo Mac", hostname: "Mac", localIPAddress: "Kullanılamıyor", port: 47831, serviceStatus: "unknown", availableApplications: []) },
        pairedDeviceToken: { [weak self] in self?.token },
        onConnectionStateChange: { [weak self] isConnected in
            self?.backendSessionActive = isConnected
        }
    )

    init() {
        if let value = UserDefaults.standard.string(forKey: MacStorage.deviceIDKey), let id = UUID(uuidString: value) {
            deviceID = id
        } else {
            let id = UUID()
            UserDefaults.standard.set(id.uuidString, forKey: MacStorage.deviceIDKey)
            deviceID = id
        }
        pairedDeviceName = UserDefaults.standard.string(forKey: MacStorage.pairedNameKey)
        if let value = UserDefaults.standard.string(forKey: MacStorage.pairedIDKey) { pairedDeviceID = UUID(uuidString: value) }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshPairingCode()
        refreshPermissions()
    }

    func start() {
        guard startTask == nil else { return }
        serviceState = .starting
        serviceError = nil
        startupDetail = "Sertifika hazırlanıyor…"
        ClipboardWatcher.shared.start()
        startNetworkMonitor()
        startTask = Task { @MainActor [weak self] in
            await self?.bringUp()
            await self?.requestInitialPermissionsIfNeeded()
        }
    }

    /// Start the macOS permission requests once during onboarding. macOS owns each native
    /// approval separately; the Settings screen remains the place to retry or enable manual-only
    /// permissions such as Full Disk Access.
    private func requestInitialPermissionsIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: MacStorage.initialPermissionsRequestedKey) else { return }
        defaults.set(true, forKey: MacStorage.initialPermissionsRequestedKey)
        await warmUpAutomationPermissions()
    }

    /// The listener and the pairing code come first: a phone that scans the QR code must find
    /// something listening. The slow parts (scanning installed apps, reconnecting to the backend)
    /// run afterwards, and every step that can block on the keychain has a time limit.
    private func bringUp() async {
        await engine.setFileTransferTokenProvider { [weak self] in
            await self?.backendChannel.accessTokenForFileTransfer()
        }
        let tokenStore = pairedDeviceTokenStore
        async let storedToken = MacTimeout.run(seconds: 10, priority: .utility) { await tokenStore.load() }
        let loaded = await MacTimeout.run(seconds: 10) { Result { try RovaTLSIdentityStore.loadOrCreate() } }
        let paired = await storedToken ?? nil
        guard !Task.isCancelled else { return }

        switch loaded {
        case .none:
            fail("Anahtar Zinciri 10 saniyede yanıt vermedi. Açık bir izin penceresi varsa onayla, sonra yeniden dene.")
        case .some(.failure(let error)):
            errorLogger.error("TLS identity setup failed: \(error.localizedDescription, privacy: .public)")
            fail("TLS servisi başlatılamadı: \(error.localizedDescription)")
        case .some(.success(let identity)):
            token = token ?? paired
            self.identity = identity
            certificateFingerprint = identity.certificateFingerprint
            configureServer(identity: identity)
            if token == nil { relayPairingService.start() }
            refreshLocalAddress()
            await finishSetup()
        }
    }

    private func finishSetup() async {
        startupDetail = "Uygulamalar taranıyor…"
        await refreshDeviceInfo()
        guard !Task.isCancelled else { return }
        startDeviceInfoRefresh()
        startupDetail = "Wiqo hesabına bağlanıyor…"
        _ = await backendChannel.connectWithStoredTokenIfAvailable()
        startupDetail = nil
        await projectSync.start()
        projectSyncStatusTask?.cancel()
        projectSyncStatusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let self { self.projectSyncStatus = await self.projectSync.status }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func setProjectKey(_ keys: ActKeys) {
        try? ActKeyStore.save(keys, flavor: MacStorage.flavor)
        hasProjectKey = true
    }

    /// Returns false when the recovery code is not valid.
    func useRecoveryCode(_ code: String) -> Bool {
        guard let keys = ActKeys.fromRecoveryCode(code) else { return false }
        setProjectKey(keys)
        return true
    }

    /// Opens the folder that holds the synced projects in Finder.
    func openProjectsFolder() {
        Task { @MainActor in
            let folder = await projectSync.folder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    private func fail(_ message: String) {
        serviceState = .failed
        serviceError = message
        startupDetail = nil
    }

    func stop() {
        projectSyncStatusTask?.cancel()
        projectSyncStatusTask = nil
        Task { await projectSync.stop() }
        Task { await engine.shutdownBrowserWorker() }
        startTask?.cancel()
        startTask = nil
        deviceInfoRefreshTask?.cancel()
        deviceInfoRefreshTask = nil
        applicationChangeRefreshTask?.cancel()
        applicationChangeRefreshTask = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        closeAllSessions()
        ClipboardWatcher.shared.stop()
        backendChannel.stopConnection()
        relayPairingService.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
        server?.stop()
        server = nil
        serviceState = .stopped
        startupDetail = nil
    }

    func restart() {
        stop()
        start()
    }

    /// Starts over with a new certificate, for when the stored one cannot be used. Phones paired
    /// over the local network have to pair again.
    func resetCertificateAndRestart() {
        stop()
        Task { @MainActor [weak self] in
            _ = await MacTimeout.run(seconds: 10) { RovaTLSIdentityStore.reset() }
            self?.start()
        }
    }

    private func startNetworkMonitor() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.refreshLocalAddress() }
        }
        monitor.start(queue: DispatchQueue(label: "com.wiqo.mac.path-monitor", qos: .utility))
        pathMonitor = monitor
    }

    private func refreshLocalAddress() {
        Task { @MainActor [weak self] in
            let address = await Task.detached(priority: .utility) { MacNetwork.currentAddress() }.value
            self?.localIPAddress = address
        }
    }

    func regeneratePairing() {
        serviceError = nil
        refreshPairingCode()
        relayPairingService.start()
    }

    func refreshPermissions() {
        guard !isRefreshingPermissions else { return }
        isRefreshingPermissions = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await Task.detached(priority: .utility) {
                (
                    MacSystem.automationPermissionSnapshot(),
                    MacSystem.installedWiqoShortcuts()
                )
            }.value
            self.automationPermissions = snapshot.0
            self.installedWiqoShortcuts = snapshot.1
            self.isRefreshingPermissions = false
        }
    }

    func warmUpAutomationPermissions() async {
        guard !isWarmingAutomationPermissions else { return }
        isWarmingAutomationPermissions = true
        permissionActionMessage = "Gerekli izinleri kontrol ediyorum…"
        let accessibilityGranted = MacSystem.requestAccessibilityAccess()
        let screenRecordingGranted = MacSystem.requestScreenRecordingAccess()
        let results = await Task.detached(priority: .userInitiated) {
            MacSystem.warmUpAutomationPermissions()
        }.value
        let calendarGranted = await MacSystem.requestCalendarAccessForWarmUp()
        MacSystem.registerForFullDiskAccess()
        let fullDiskGranted = MacSystem.hasFullDiskAccess()
        automationPermissions = results
        installedWiqoShortcuts = await Task.detached(priority: .utility) {
            MacSystem.installedWiqoShortcuts()
        }.value
        isWarmingAutomationPermissions = false
        let granted = results.filter(\.granted).count
        permissionActionMessage = "Otomasyon \(granted)/\(results.count), Erişilebilirlik: \(accessibilityGranted ? "açık" : "kapalı"), Ekran: \(screenRecordingGranted ? "açık" : "kapalı"), Tam Disk: \(fullDiskGranted ? "açık" : "kapalı"), Takvim: \(calendarGranted ? "açık" : "kapalı")."
    }

    func installWiqoShortcuts() {
        let result = MacSystem.openWiqoShortcutsForInstallation()
        installedWiqoShortcuts = MacSystem.installedWiqoShortcuts()
        if !result.missingResources.isEmpty {
            shortcutInstallMessage = "Shortcut kaynakları eksik: \(result.missingResources.map(\.displayName).joined(separator: ", "))."
        } else if !result.openedForApproval.isEmpty {
            shortcutInstallMessage = "Shortcuts uygulamasında \(result.openedForApproval.count) Shortcut için ekleme onayı bekleniyor."
        } else if !result.alreadyInstalled.isEmpty {
            shortcutInstallMessage = "Wiqo Shortcut'ları zaten kurulu."
        } else {
            shortcutInstallMessage = "Kurulacak Shortcut bulunamadı."
        }
        shortcutInstallRefreshTask?.cancel()
        shortcutInstallRefreshTask = Task { @MainActor [weak self] in
            for delay in [1, 3, 7, 12] {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                let installed = await Task.detached(priority: .utility) {
                    MacSystem.installedWiqoShortcuts()
                }.value
                self.installedWiqoShortcuts = installed
                if installed.count == WiqoShortcut.allCases.count { return }
            }
        }
    }

    func revokeCurrentDevice() {
        closeAllSessions()
        let tokenStore = pairedDeviceTokenStore
        Task { @MainActor [weak self] in
            await self?.backendChannel.disconnect()
            do {
                try await tokenStore.delete()
            } catch {
                self?.serviceError = "Cihaz yetkisi kaldırılamadı."
            }
        }
        token = nil
        pairedDeviceName = nil
        pairedDeviceID = nil
        UserDefaults.standard.removeObject(forKey: MacStorage.pairedNameKey)
        UserDefaults.standard.removeObject(forKey: MacStorage.pairedIDKey)
        relayPairing = .preparing
    }

    func revokeAllDevices() {
        revokeCurrentDevice()
        refreshPairingCode()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = false
            serviceError = "Launch at Login ayarlanamadı."
        }
    }

    var pairingPayload: PairingPayload? {
        guard !certificateFingerprint.isEmpty else { return nil }
        return PairingPayload(
            host: localIPAddress,
            port: port,
            certificateFingerprint: certificateFingerprint,
            pairingCode: pairingCode,
            expiresAt: pairingExpiresAt
        )
    }

    /// The phone claimed the internet pairing code: keep the token it will sign commands with and
    /// sign in to the backend with the account it belongs to.
    private func relayPairingClaimed(pairingToken: String, backendToken: String?, deviceAccessToken: String?, deviceRefreshToken: String?) async -> String? {
        do {
            try await pairedDeviceTokenStore.save(pairingToken)
        } catch {
            errorLogger.error("Relay pairing token could not be stored")
            let status = (error as? RovaKeychainError).flatMap { error -> OSStatus? in
                guard case .status(let status) = error else { return nil }
                return status
            }
            let detail = status.map { " (Keychain hata kodu: \($0))" } ?? ""
            let message = "Eşleşme Mac'e kaydedilemedi. Wiqo'ya Anahtar Zinciri erişimi verip yeniden dene.\(detail)"
            serviceError = message
            return message
        }
        token = pairingToken
        pairedDeviceName = "iPhone"
        UserDefaults.standard.set("iPhone", forKey: MacStorage.pairedNameKey)
        relayPairing = .paired
        guard let accessToken = deviceAccessToken ?? backendToken else {
            let message = "Eşleşme alındı ama sunucu oturum anahtarı gelmedi. Yeni QR oluşturup tekrar dene."
            serviceError = message
            return message
        }
        await backendChannel.connect(token: accessToken, refreshToken: deviceRefreshToken)
        return nil
    }

    func refreshAutomations() async {
        guard backendSessionActive else {
            automations = []
            automationsError = "Wiqo hesabı iPhone üzerinden bağlanmamış."
            return
        }
        isLoadingAutomations = true
        automationsError = nil
        defer { isLoadingAutomations = false }
        do {
            automations = try await backendChannel.fetchAutomations()
        } catch {
            automationsError = (error as? LocalizedError)?.errorDescription ?? "Otomasyonlar alınamadı."
        }
    }

    func cancelAutomation(_ automation: MacAutomation) async {
        do {
            try await backendChannel.cancelAutomation(id: automation.id)
            automations.removeAll { $0.id == automation.id }
        } catch {
            automationsError = (error as? LocalizedError)?.errorDescription ?? "Otomasyon iptal edilemedi."
        }
    }

    var deviceInfo: DeviceInfo {
        DeviceInfo(
            id: deviceID,
            displayName: MacNetwork.computerName,
            hostname: MacNetwork.hostName,
            localIPAddress: localIPAddress,
            port: port,
            serviceStatus: serviceState.rawValue,
            availableApplications: cachedAvailableApplications,
            applicationTargets: cachedApplicationTargets,
            capabilities: CapabilityStore.shared.filter(cachedCapabilities),
            authorities: cachedAuthorities.filter { CapabilityStore.shared.isEnabled($0.capability) }
        )
    }

    private func refreshDeviceInfo() async {
        // The command authority is the single source for operation -> capability mapping. The
        // expensive application/permission scans happen once before registration, not every time
        // the backend asks for a DeviceInfo snapshot.
        let allCapabilities = RovaOperationManifest.advertisedCapabilities(for: .macOS)
        // A scan that stalls (a permission prompt, a slow disk) keeps the previous snapshot.
        guard let snapshot = await MacTimeout.run(seconds: 20, priority: .utility, {
            MacDeviceInfoSnapshot(
                availableApplications: MacSystem.availableApplications(),
                applicationTargets: MacSystem.applicationTargets(),
                capabilities: allCapabilities.sorted(),
                authorities: MacSystem.capabilityAuthorities()
            )
        }) else {
            errorLogger.error("Device scan did not finish in time; keeping the previous snapshot")
            return
        }
        let changed = snapshot.availableApplications != cachedAvailableApplications
            || snapshot.applicationTargets != cachedApplicationTargets
            || snapshot.capabilities != cachedCapabilities
            || snapshot.authorities != cachedAuthorities
        cachedAvailableApplications = snapshot.availableApplications
        cachedApplicationTargets = snapshot.applicationTargets
        cachedCapabilities = snapshot.capabilities
        cachedAuthorities = snapshot.authorities
        // Re-registering every 30 s with an identical catalog was pure noise on the socket.
        if changed { broadcastDeviceInfo() }
    }

    /// An app that was just installed, opened or quit reaches the planner within ~2 s instead of
    /// waiting for the next 30 s scan - otherwise "az önce kurduğum X'i aç" failed as unknown.
    private func observeApplicationChanges() {
        if agentAccessObserver == nil {
            // The backend learns about full access from the registration's feature list.
            agentAccessObserver = AgentAccessStore.shared.$isEnabled.dropFirst().removeDuplicates().sink { [weak self] _ in
                Task { @MainActor in self?.broadcastDeviceInfo() }
            }
            // A task grant from the phone (or its end) changes the feature list the same way.
            taskGrantObserver = AgentAccessStore.shared.$taskGrant.dropFirst().removeDuplicates().sink { [weak self] _ in
                Task { @MainActor in self?.broadcastDeviceInfo() }
            }
        }
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleApplicationCatalogRefresh() }
            }
        }
    }

    private func scheduleApplicationCatalogRefresh() {
        applicationChangeRefreshTask?.cancel()
        applicationChangeRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            MacSystem.invalidateInstalledApplications()
            await self.refreshDeviceInfo()
        }
    }

    /// Pushes the just-scanned catalog to whoever already has a snapshot from before the scan
    /// finished. The listener and pairing code intentionally come up before this scan does (see
    /// `bringUp()`), so a phone that connects in that window - or one that has been connected for
    /// a while, as apps open and close - would otherwise be stuck forever with the empty catalog
    /// it got at `.hello`/`.authenticated` time: every "kapat"/"aç" on a real app then fails with
    /// "uygulama kataloğu alınamadı", because the tool never has a catalog to validate against.
    private func broadcastDeviceInfo() {
        let info = deviceInfo
        for session in sessions.values {
            session.send(WireEnvelope(message: .hello(info)))
        }
        if backendSessionActive { backendChannel.resendRegistration() }
    }

    private func startDeviceInfoRefresh() {
        observeApplicationChanges()
        deviceInfoRefreshTask?.cancel()
        deviceInfoRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                await self.refreshDeviceInfo()
            }
        }
    }

    private func configureServer(identity: RovaTLSIdentity) {
        let server = MacServer(port: port, identity: identity)
        server.onState = { [weak self, weak server] state, error in
            Task { @MainActor in
                // A replaced listener reports its shutdown late; only the current one counts.
                guard let self, let server, self.server === server else { return }
                self.serviceState = state
                self.serviceError = error
                if state == .running { self.refreshLocalAddress() }
            }
        }
        server.onConnection = { [weak self] session in
            Task { @MainActor in
                guard let self else { return }
                self.sessions[ObjectIdentifier(session)] = session
                self.logger.info("Client connected")
                session.send(WireEnvelope(message: .hello(self.deviceInfo)))
            }
        }
        server.onSessionClosed = { [weak self] session in
            Task { @MainActor in
                self?.removeSession(session)
            }
        }
        server.onEnvelope = { [weak self] session, envelope in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handle(envelope, on: session)
            }
        }
        self.server = server
        server.start()
    }

    private func handle(_ envelope: WireEnvelope, on session: MacClientSession) async {
        switch envelope.message {
        case .pair(let request):
            let sessionID = ObjectIdentifier(session)
            let attempts = sessionFailedPairingAttempts[sessionID, default: 0]
            guard attempts < Self.maxPairingAttemptsPerSession else {
                authLogger.warning("Pairing rejected: rate limit exceeded for session")
                session.send(WireEnvelope(requestID: envelope.requestID, message: .failure(RovaError(code: "PAIRING_RATE_LIMITED", message: "Çok fazla başarısız deneme. Lütfen bekleyin."))))
                session.close()
                return
            }
            guard isPairingCodeValid(request.code) else {
                sessionFailedPairingAttempts[sessionID] = attempts + 1
                authLogger.warning("Pairing rejected: expired or invalid code")
                session.send(WireEnvelope(requestID: envelope.requestID, message: .failure(RovaError(code: "PAIRING_EXPIRED", message: "Bağlantı kodu geçersiz veya süresi doldu."))))
                if attempts + 1 >= Self.maxPairingAttemptsPerSession {
                    session.close()
                }
                return
            }
            sessionFailedPairingAttempts.removeValue(forKey: sessionID)
            let name = request.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 128 else {
                authLogger.warning("Pairing rejected: invalid device name")
                session.send(WireEnvelope(requestID: envelope.requestID, message: .failure(RovaError(code: "INVALID_DEVICE", message: "Cihaz bilgisi geçersiz."))))
                return
            }
            closeOtherSessions(except: session)
            do {
                let newToken = try RovaCrypto.randomToken()
                try await pairedDeviceTokenStore.save(newToken)
                token = newToken
                pairedDeviceName = name
                pairedDeviceID = request.deviceID
                UserDefaults.standard.set(name, forKey: MacStorage.pairedNameKey)
                UserDefaults.standard.set(request.deviceID.uuidString, forKey: MacStorage.pairedIDKey)
                let response = PairingResponse(token: newToken, deviceID: request.deviceID, certificateFingerprint: certificateFingerprint)
                session.send(WireEnvelope(requestID: envelope.requestID, message: .pairAccepted(response)))
                authLogger.info("Pairing accepted")
            } catch {
                errorLogger.error("Pairing failed")
                session.send(WireEnvelope(requestID: envelope.requestID, message: .failure(RovaError(code: "PAIRING_FAILED", message: "Bağlantı kurulamadı."))))
            }
        case .authenticate(let request):
            guard let token, let pairedDeviceID,
                  RovaValidation.isValidToken(request.token, expected: token, deviceID: request.deviceID, expectedDeviceID: pairedDeviceID) else {
                authLogger.warning("Authentication rejected")
                session.send(WireEnvelope(requestID: envelope.requestID, message: .failure(RovaError(code: "INVALID_TOKEN", message: "Cihaz doğrulanamadı."))))
                session.close()
                return
            }
            session.setAuthenticated(true)
            authenticatedSessionID = ObjectIdentifier(session)
            connectedDeviceID = pairedDeviceID
            connectedDeviceName = pairedDeviceName
            authLogger.info("Authentication accepted")
            session.send(WireEnvelope(requestID: envelope.requestID, message: .authenticated(AuthenticationResponse(deviceInfo: deviceInfo))))
        case .command(let request):
            guard session.isAuthenticated else {
                authLogger.warning("Command rejected before authentication")
                session.send(WireEnvelope(requestID: envelope.requestID, message: .failure(RovaError(code: "AUTH_REQUIRED", message: "Önce cihaz doğrulaması gerekir."))))
                return
            }
            if request.signatureVersion != 2 {
                authLogger.warning("Legacy command signature version rejected")
                session.send(WireEnvelope(requestID: envelope.requestID, message: .failure(RovaError(code: "SIGNATURE_VERSION_REQUIRED", message: "Güvenli komut imzası için Wiqo iPhone uygulamasını güncelleyin.", category: "permission"))))
                return
            }
            // Every command must carry a valid signature - a nil signature used to mean "skip
            // verification," which silently accepted anything on an already-authenticated session
            // instead of proving the caller still holds the pairing token per command. There is no
            // longer any legitimate caller (direct or relayed) that omits one.
            guard let token = self.token, RovaValidation.verifyRequestSignature(request: request, token: token) else {
                authLogger.warning("Command signature verification failed")
                session.send(WireEnvelope(requestID: envelope.requestID, message: .failure(RovaError(code: "INVALID_SIGNATURE", message: "Komut kriptografik imzası geçersiz."))))
                return
            }
            commandLogger.info("Executing capability \(request.type.rawValue, privacy: .public)")
            let currentStatus = serviceState.rawValue
            Task { [engine, errorLogger] in
                let result = await engine.execute(request, runtimeStatus: currentStatus)
                if result.status == .failed || result.status == .denied || result.status == .unknown {
                    errorLogger.error("Capability \(request.type.rawValue, privacy: .public) \(result.status.rawValue, privacy: .public), error_code=\(result.error?.code ?? "unknown", privacy: .public)")
                }
                session.send(WireEnvelope(requestID: envelope.requestID, message: .result(result)))
            }
        case .backendToken(let backendToken):
            guard session.isAuthenticated else {
                authLogger.warning("Backend token rejected before authentication")
                return
            }
            await backendChannel.connect(token: backendToken)
        case .projectKey(let encoded):
            guard session.isAuthenticated else {
                authLogger.warning("Project key rejected before authentication")
                return
            }
            if let data = Data(base64Encoded: encoded), let keys = ActKeys(master: data) { setProjectKey(keys) }
        default:
            authLogger.warning("Unsupported message rejected")
            session.send(WireEnvelope(requestID: envelope.requestID, message: .failure(RovaError(code: "UNSUPPORTED_MESSAGE", message: "Mesaj desteklenmiyor."))))
        }
    }

    private func refreshPairingCode() {
        pairingCode = (try? RovaCrypto.randomPairingCode()) ?? "------"
        pairingExpiresAt = Date().addingTimeInterval(300)
        // The code on screen must not outlive its validity, or a phone scans a dead QR code.
        pairingRenewalTask?.cancel()
        pairingRenewalTask = Task { @MainActor [weak self] in
            guard let expiresAt = self?.pairingExpiresAt else { return }
            try? await Task.sleep(for: .seconds(max(1, expiresAt.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.refreshPairingCode()
        }
    }

    private func isPairingCodeValid(_ code: String) -> Bool {
        guard pairingExpiresAt > Date() else { refreshPairingCode(); return false }
        let payload = PairingPayload(host: localIPAddress, port: port, certificateFingerprint: certificateFingerprint, pairingCode: pairingCode, expiresAt: pairingExpiresAt)
        if !RovaValidation.isPairingPayloadValid(payload) { refreshPairingCode(); return false }
        return RovaCrypto.constantTimeEquals(code, pairingCode)
    }

    private func closeOtherSessions(except current: MacClientSession) {
        let stale = sessions.filter { $0.value !== current }
        for (id, session) in stale {
            session.close()
            removeSession(id: id)
        }
    }

    private func closeAllSessions() {
        for session in sessions.values { session.close() }
        sessions.removeAll()
        sessionFailedPairingAttempts.removeAll()
        authenticatedSessionID = nil
        connectedDeviceID = nil
        connectedDeviceName = nil
    }

    private func removeSession(_ session: MacClientSession) {
        removeSession(id: ObjectIdentifier(session))
    }

    private func removeSession(id: ObjectIdentifier) {
        sessions.removeValue(forKey: id)
        sessionFailedPairingAttempts.removeValue(forKey: id)
        guard authenticatedSessionID == id else { return }
        authenticatedSessionID = nil
        connectedDeviceID = nil
        connectedDeviceName = nil
    }
}
