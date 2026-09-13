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
    @Published private(set) var localIPAddress = "Unavailable"
    @Published private(set) var certificateFingerprint = ""
    @Published var launchAtLogin = false

    let port: UInt16 = 47831
    let deviceID: UUID
    private var server: MacServer?
    private let engine = MacCommandEngine()
    private var identity: RovaTLSIdentity?
    private var token: String?
    private var startTask: Task<Void, Never>?
    private var sessions: [ObjectIdentifier: MacClientSession] = [:]
    private var authenticatedSessionID: ObjectIdentifier?
    private var sessionFailedPairingAttempts: [ObjectIdentifier: Int] = [:]
    private static let maxPairingAttemptsPerSession = 3

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
    }

    func start() {
        guard startTask == nil else { return }
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

    var deviceInfo: DeviceInfo {
        DeviceInfo(
            id: deviceID,
            displayName: Host.current().localizedName ?? "This Mac",
            hostname: Host.current().name ?? "Mac",
            localIPAddress: localIPAddress,
            port: port,
            serviceStatus: serviceState.rawValue,
            availableApplications: MacSystem.availableApplications()
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
                session.send(WireEnvelope(requestID: envelope.requestID, message: .failure(RovaError(code: "PAIRING_EXPIRED", message: "Pairing kodunun süresi doldu veya geçersiz."))))
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
                session.send(WireEnvelope(requestID: envelope.requestID, message: .failure(RovaError(code: "PAIRING_FAILED", message: "Pairing tamamlanamadı."))))
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
            if let token = self.token, request.signature != nil {
                guard RovaValidation.verifyRequestSignature(request: request, token: token) else {
                    authLogger.warning("Command signature verification failed")
                    session.send(WireEnvelope(requestID: envelope.requestID, message: .failure(RovaError(code: "INVALID_SIGNATURE", message: "Komut kriptografik imzası geçersiz."))))
                    return
                }
            }
            commandLogger.info("Executing capability \(request.type.rawValue, privacy: .public)")
            let currentStatus = serviceState.rawValue
            Task { [engine] in
                let result = await engine.execute(request, runtimeStatus: currentStatus)
                session.send(WireEnvelope(requestID: envelope.requestID, message: .result(result)))
            }
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
