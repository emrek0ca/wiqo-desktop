import Combine
import Foundation
import Network
import OSLog
import ServiceManagement

@MainActor
final class MacRuntime: ObservableObject {
    private let logger = Logger(subsystem: "com.rova.local", category: "connection")
    private let authLogger = Logger(subsystem: "com.rova.local", category: "auth")
    private let commandLogger = Logger(subsystem: "com.rova.local", category: "command")
    private let errorLogger = Logger(subsystem: "com.rova.local", category: "error")
    @Published private(set) var serviceState: MacServiceState = .starting
    @Published private(set) var serviceError: String?
    @Published private(set) var pairingCode = "------"
    @Published private(set) var pairingExpiresAt = Date.distantPast
    @Published private(set) var pairedDeviceName: String?
    @Published private(set) var pairedDeviceID: UUID?
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var connectedDeviceID: UUID?
    @Published private(set) var localIPAddress = "Kullanılamıyor"
    @Published private(set) var certificateFingerprint = ""
    @Published var launchAtLogin = false
    @Published private(set) var automations: [MacAutomation] = []
    @Published private(set) var isLoadingAutomations = false
    @Published private(set) var automationsError: String?
    @Published private(set) var automationPermissions: [MacAutomationPermission] = []
    @Published private(set) var isRefreshingPermissions = false
    @Published private(set) var isWarmingAutomationPermissions = false
    @Published private(set) var permissionActionMessage: String?
    @Published private(set) var installedWiqoShortcuts: Set<WiqoShortcut> = []
    @Published private(set) var shortcutInstallMessage: String?

    let port: UInt16 = 47831
    let deviceID: UUID
    private var server: MacServer?
    private let engine = MacCommandEngine()
    private var identity: RovaTLSIdentity?
    private var token: String?
    private var startTask: Task<Void, Never>?
    private var shortcutInstallRefreshTask: Task<Void, Never>?
    private var sessions: [ObjectIdentifier: MacClientSession] = [:]
    private var authenticatedSessionID: ObjectIdentifier?
    private var sessionFailedPairingAttempts: [ObjectIdentifier: Int] = [:]
    private static let maxPairingAttemptsPerSession = 3
    private lazy var backendChannel = MacBackendChannel(
        engine: engine,
        runtimeStatus: { [weak self] in self?.serviceState.rawValue ?? "unknown" },
        deviceInfo: { [weak self] in self?.deviceInfo ?? DeviceInfo(id: UUID(), displayName: "Wiqo Mac", hostname: "Mac", localIPAddress: "Kullanılamıyor", port: 47831, serviceStatus: "unknown", availableApplications: []) },
        pairedDeviceToken: { [weak self] in self?.token }
    )

    init() {
        let key = "rova.mac.device-id"
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) {
            deviceID = id
        } else {
            let id = UUID()
            UserDefaults.standard.set(id.uuidString, forKey: key)
            deviceID = id
        }
        pairedDeviceName = UserDefaults.standard.string(forKey: "rova.mac.paired-name")
        if let value = UserDefaults.standard.string(forKey: "rova.mac.paired-id") { pairedDeviceID = UUID(uuidString: value) }
        token = try? RovaKeychainStore.load(account: "paired-device-token").flatMap { String(data: $0, encoding: .utf8) }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshPairingCode()
        backendChannel.connectWithStoredTokenIfAvailable()
        refreshPermissions()
    }

    func start() {
        guard startTask == nil else { return }
        ClipboardWatcher.shared.start()
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try RovaTLSIdentityStore.loadOrCreate() }
            }.value
            switch result {
            case .success(let identity):
                self.identity = identity
                self.certificateFingerprint = identity.certificateFingerprint
                self.localIPAddress = MacSystem.localIPv4Address()
                self.configureServer(identity: identity)
            case .failure(let error):
                self.errorLogger.error("TLS identity setup failed: \(error.localizedDescription, privacy: .public)")
                self.serviceState = .failed
                self.serviceError = "TLS servisi başlatılamadı: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        closeAllSessions()
        server?.stop()
        server = nil
        serviceState = .stopped
    }

    func regeneratePairing() {
        refreshPairingCode()
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
        permissionActionMessage = "İzin istekleri hazırlanıyor…"
        let accessibilityGranted = MacSystem.requestAccessibilityAccess()
        let screenRecordingGranted = MacSystem.requestScreenRecordingAccess()
        let results = await Task.detached(priority: .userInitiated) {
            MacSystem.warmUpAutomationPermissions()
        }.value
        let calendarGranted = await MacSystem.requestCalendarAccessForWarmUp()
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
        do { try RovaKeychainStore.delete(account: "paired-device-token") } catch { serviceError = "Cihaz yetkisi kaldırılamadı." }
        token = nil
        pairedDeviceName = nil
        pairedDeviceID = nil
        UserDefaults.standard.removeObject(forKey: "rova.mac.paired-name")
        UserDefaults.standard.removeObject(forKey: "rova.mac.paired-id")
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

    var backendSessionActive: Bool {
        guard let data = try? RovaKeychainStore.load(account: "rova-backend-token"),
              let backendToken = String(data: data, encoding: .utf8) else { return false }
        return !backendToken.isEmpty
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
            displayName: Host.current().localizedName ?? "Bu Mac",
            hostname: Host.current().name ?? "Mac",
            localIPAddress: localIPAddress,
            port: port,
            serviceStatus: serviceState.rawValue,
            availableApplications: MacSystem.availableApplications(),
            applicationTargets: MacSystem.applicationTargets(),
            // The full set comes from RovaCommandAuthority.allCapabilities (derived from
            // CommandType itself, see Validation.swift) rather than a second hand-typed list here -
            // adding a new command type can no longer silently forget to also advertise it.
            // "runtime.status" is never user-toggleable (harmless read-only status), so it's
            // exempted from filtering; every other capability respects the Yetenekler settings.
            capabilities: ["runtime.status"] + CapabilityStore.shared.filter(
                Array(RovaCommandAuthority.allCapabilities.subtracting(["runtime.status"]))
            ),
            authorities: MacSystem.capabilityAuthorities()
        )
    }

    private func configureServer(identity: RovaTLSIdentity) {
        let server = MacServer(port: port, identity: identity)
        server.onState = { [weak self] state, error in
            Task { @MainActor in
                self?.serviceState = state
                self?.serviceError = error
                if state == .running { self?.localIPAddress = MacSystem.localIPv4Address() }
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
            Task { @MainActor in self?.handle(envelope, on: session) }
        }
        self.server = server
        server.start()
    }

    private func handle(_ envelope: WireEnvelope, on session: MacClientSession) {
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
                session.send(WireEnvelope(requestID: envelope.requestID, message: .failure(RovaError(code: "PAIRING_EXPIRED", message: "Eşleşme kodunun süresi doldu veya geçersiz."))))
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
                try RovaKeychainStore.save(Data(newToken.utf8), account: "paired-device-token")
                token = newToken
                pairedDeviceName = name
                pairedDeviceID = request.deviceID
                UserDefaults.standard.set(name, forKey: "rova.mac.paired-name")
                UserDefaults.standard.set(request.deviceID.uuidString, forKey: "rova.mac.paired-id")
                let response = PairingResponse(token: newToken, deviceID: request.deviceID, certificateFingerprint: certificateFingerprint)
                session.send(WireEnvelope(requestID: envelope.requestID, message: .pairAccepted(response)))
                authLogger.info("Pairing accepted")
            } catch {
                errorLogger.error("Pairing failed")
                session.send(WireEnvelope(requestID: envelope.requestID, message: .failure(RovaError(code: "PAIRING_FAILED", message: "Eşleşme tamamlanamadı."))))
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
                    errorLogger.error("Capability \(request.type.rawValue, privacy: .public) \(result.status.rawValue, privacy: .public): \(result.message, privacy: .public)")
                }
                session.send(WireEnvelope(requestID: envelope.requestID, message: .result(result)))
            }
        case .backendToken(let backendToken):
            guard session.isAuthenticated else {
                authLogger.warning("Backend token rejected before authentication")
                return
            }
            backendChannel.connect(token: backendToken)
        default:
            authLogger.warning("Unsupported message rejected")
            session.send(WireEnvelope(requestID: envelope.requestID, message: .failure(RovaError(code: "UNSUPPORTED_MESSAGE", message: "Mesaj desteklenmiyor."))))
        }
    }

    private func refreshPairingCode() {
        pairingCode = (try? RovaCrypto.randomPairingCode()) ?? "------"
        pairingExpiresAt = Date().addingTimeInterval(300)
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
