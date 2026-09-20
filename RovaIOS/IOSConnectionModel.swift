import Combine
import Foundation
import LocalAuthentication
import Network
import Security
import UIKit

enum IOSConnectionState: String {
    case disconnected
    case connecting
    case connected
    case failed
}

enum ConnectionQuality: Equatable, Sendable {
    case unknown
    case weak
    case good
    case excellent

    /// Derives a quality bucket from a round-trip ping latency measured over the local network.
    static func forLatency(ms: Int) -> ConnectionQuality {
        switch ms {
        case ..<60: return .excellent
        case ..<200: return .good
        default: return .weak
        }
    }

    var label: String {
        switch self {
        case .unknown: return ""
        case .weak: return "Zayıf"
        case .good: return "İyi"
        case .excellent: return "Mükemmel"
        }
    }

    var symbolName: String {
        switch self {
        case .unknown: return "wifi.slash"
        case .weak: return "wifi.exclamationmark"
        case .good, .excellent: return "wifi"
        }
    }
}

struct IOSActivity: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let date = Date()
}

@MainActor
final class IOSConnectionModel: ObservableObject {
    @Published private(set) var state: IOSConnectionState = .disconnected
    @Published private(set) var deviceInfo: DeviceInfo?
    @Published private(set) var systemStatus: SystemStatus?
    @Published private(set) var lastPingLatencyMs: Int?
    @Published private(set) var connectionQuality: ConnectionQuality = .unknown
    @Published private(set) var activities: [IOSActivity] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isPaired = false
    @Published private(set) var isPairing = false
    @Published private(set) var isReconnecting = false
    /// Set right after a command succeeds through the backend relay instead of the direct local
    /// connection (see sendViaBackendRelay) - lets the UI say "bağlı, internet üzerinden" instead
    /// of quietly leaving the user thinking they're on the fast local path, or worse, "offline"
    /// even though the command just worked.
    @Published private(set) var isUsingRelay = false

    /// Transport details stay internal; the UI gets one small, stable vocabulary.
    var userFacingConnectionLabel: String {
        guard isPaired else { return "PC kapalı" }
        if isReconnecting || state == .connecting { return "Yeniden bağlanıyor" }
        if state == .connected { return isUsingRelay ? "İnternet üzerinden bağlı" : "Bağlı" }
        return "PC kapalı"
    }

    var userFacingConnectionError: String {
        "PC’ye ulaşılamıyor. Açık ve internete bağlı olduğundan emin olun."
    }

    private let deviceID: UUID
    private var token: String?
    private var certificateFingerprint: String?
    private var savedEndpoint: SavedEndpoint?
    // The Mac device ID is separate from this phone's pairing-request ID. Persisting it lets the
    // relay target the same Mac after the app restarts, even when the direct local socket is not
    // reachable on the current network.
    private var pairedMacDeviceID: UUID?
    private var connection: NWConnection?
    private var connectionGeneration: UInt64 = 0
    private var pairingTimeoutTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var receiveBuffer = Data()
    private var authenticated = false
    private var mode: ConnectionMode = .authenticated
    private var pending: [UUID: CheckedContinuation<CommandResult, Error>] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var heartbeatTask: Task<Void, Never>?
    private var relayProbeTask: Task<Void, Never>?
    private var browser: NWBrowser?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.wiqo.path-monitor", qos: .utility)
    private var pathAvailable = true
    private var pathSignature: String?
    private let discoveryQueue = DispatchQueue(label: "com.wiqo.discovery", qos: .utility)
    private var discoveredServiceName: String?

    init() {
        if let stored = try? RovaKeychainStore.load(account: "ios-device-id"),
           let string = String(data: stored, encoding: .utf8),
           let id = UUID(uuidString: string) {
            deviceID = id
        } else {
            let id = UUID()
            deviceID = id
            try? RovaKeychainStore.save(Data(id.uuidString.utf8), account: "ios-device-id")
        }
        token = try? RovaKeychainStore.load(account: "ios-device-token").flatMap { String(data: $0, encoding: .utf8) }
        certificateFingerprint = try? RovaKeychainStore.load(account: "ios-certificate-fingerprint").flatMap { String(data: $0, encoding: .utf8) }
        if let data = UserDefaults.standard.data(forKey: "rova.ios.endpoint"), let saved = try? JSONDecoder().decode(SavedEndpoint.self, from: data) {
            savedEndpoint = saved
        }
        if let value = UserDefaults.standard.string(forKey: "rova.ios.mac-device-id") {
            pairedMacDeviceID = UUID(uuidString: value)
        }
        isPaired = token != nil && ((certificateFingerprint != nil && savedEndpoint != nil) || pairedMacDeviceID != nil)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let signature = "\(path.status):\(path.availableInterfaces.map(\.name).sorted().joined(separator: ","))"
            Task { @MainActor [weak self] in
                self?.handleNetworkPath(available: available, signature: signature)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
        startDiscovery()
    }

    deinit {
        pathMonitor.cancel()
    }

    func pair(using payload: PairingPayload) {
        guard RovaValidation.isPairingPayloadValid(payload) else {
            fail("Geçersiz pairing QR kodu.")
            return
        }
        guard payload.expiresAt > Date() else {
            fail("Eşleşme QR kodunun süresi doldu.")
            return
        }
        connectionGeneration += 1
        let currentGen = connectionGeneration
        pairingTimeoutTask?.cancel()
        isPairing = true
        isReconnecting = false
        mode = .pairing(payload)
        lastError = nil

        // Explicit 10-second timeout for pairing / TLS handshake
        pairingTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled, self.connectionGeneration == currentGen, self.isPairing else { return }
            self.handlePairingTimeout()
        }

        connect(host: payload.host, port: payload.port, fingerprint: payload.certificateFingerprint)
    }

    private func handlePairingTimeout() {
        guard isPairing else { return }
        pairingTimeoutTask = nil
        isPairing = false
        connection?.cancel()
        connection = nil
        authenticated = false
        state = .failed
        lastError = "Eşleşme zaman aşımına uğradı."
        appendActivity(title: "Eşleşme", detail: "Zaman aşımına uğradı")
    }

    func connect() {
        guard let endpoint = savedEndpoint, let fingerprint = certificateFingerprint else {
            if isPaired {
                isUsingRelay = true
                state = .connecting
                scheduleRelayProbe()
            } else {
                state = .disconnected
            }
            return
        }
        if state == .connected {
            // Called opportunistically (e.g. app returning to foreground). Probe liveness
            // rather than no-op: a stale socket that silently died while backgrounded will
            // time out and self-heal via `timeout(_:message:)` instead of staying stuck.
            Task { [weak self] in _ = await self?.send(.ping) }
            return
        }
        guard state != .connecting else { return }
        mode = .authenticated
        connect(host: endpoint.host, port: endpoint.port, fingerprint: fingerprint)
    }

    func retry() {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        isPairing = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        isReconnecting = false
        stopHeartbeat()
        connection?.cancel()
        connection = nil
        authenticated = false
        state = .disconnected
        startDiscovery()
        connect()
    }

    func disconnect() {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        isPairing = false
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        stopHeartbeat()
        connection?.cancel()
        connection = nil
        authenticated = false
        state = .disconnected
        failPending(IOSConnectionError.disconnected)
    }

    func forgetPairing() {
        disconnect()
        try? RovaKeychainStore.delete(account: "ios-device-token")
        try? RovaKeychainStore.delete(account: "ios-certificate-fingerprint")
        token = nil
        certificateFingerprint = nil
        savedEndpoint = nil
        pairedMacDeviceID = nil
        UserDefaults.standard.removeObject(forKey: "rova.ios.endpoint")
        UserDefaults.standard.removeObject(forKey: "rova.ios.mac-device-id")
        isPaired = false
        deviceInfo = nil
        systemStatus = nil
        lastPingLatencyMs = nil
        connectionQuality = .unknown
        isReconnecting = false
    }

    /// Relay bootstrap pairing is intentionally separate from the local TLS QR. It binds the
    /// existing phone account to the Mac over the backend, then reuses the same signed
    /// CommandRequest/CommandResult path for every later operation.
    func pair(using payload: RelayPairingPayload) {
        guard payload.expiresAt > Date() else {
            fail("Eşleşme QR kodunun süresi doldu.")
            return
        }
        isPairing = true
        isReconnecting = true
        isUsingRelay = true
        state = .connecting
        lastError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let claim = try await RovaBackendClient.claimRelayPairing(sessionID: payload.sessionID, secret: payload.secret)
                guard let deviceID = UUID(uuidString: claim.deviceId) else { throw RovaBackendError.invalidResponse }
                try RovaKeychainStore.save(Data(claim.pairingToken.utf8), account: "ios-device-token")
                try RovaKeychainStore.save(Data("relay".utf8), account: "ios-certificate-fingerprint")
                token = claim.pairingToken
                pairedMacDeviceID = deviceID
                UserDefaults.standard.set(deviceID.uuidString, forKey: "rova.ios.mac-device-id")
                UserDefaults.standard.removeObject(forKey: "rova.ios.endpoint")
                certificateFingerprint = "relay"
                isPaired = true
                isPairing = false
                appendActivity(title: "Eşleşme", detail: "İnternet bağlantısı hazır")
                scheduleRelayProbe()
            } catch {
                isPairing = false
                isReconnecting = false
                isUsingRelay = false
                state = .failed
                lastError = (error as? LocalizedError)?.errorDescription ?? "Eşleşme tamamlanamadı."
            }
        }
    }

    func authenticateBiometrics(reason: String = "Wiqo komutunu onaylayın") async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) ||
              context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return true
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }

    func send(_ type: CommandType, payload: CommandPayload = .none, commandID: UUID? = nil) async -> CommandResult {
        let resolvedCommandID = commandID ?? UUID()
        guard isPaired else { return failureResult(id: resolvedCommandID, error: RovaError(code: "NOT_PAIRED", message: "Önce PC ile eşleşin.")) }
        guard authenticated, let connection else {
            connect()
            // Same local network isn't a hard requirement any more: if the PC is reachable
            // through its own backend connection (the one automations already rely on), the
            // command still goes through - just a little slower than the direct path.
            return await sendViaBackendRelay(type: type, payload: payload, commandID: resolvedCommandID)
        }
        let now = Date()
        let nonce = try? RovaCrypto.randomToken()
        let signature = token.map { RovaValidation.signRequest(id: resolvedCommandID, type: type, nonce: nonce ?? "", token: $0) }
        let request = CommandRequest(id: resolvedCommandID, type: type, payload: payload, createdAt: now, signature: signature, nonce: nonce)
        if let validationError = RovaValidation.validate(request) {
            return failureResult(id: request.id, error: validationError)
        }
        appendActivity(title: title(for: request), detail: "Çalışıyor…")
        let startTime = Date()
        do {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                pending[request.id] = continuation
                guard let data = try? RovaWireCodec.encode(WireEnvelope(requestID: request.id, message: .command(request))) else {
                    pending.removeValue(forKey: request.id)
                    continuation.resume(returning: self.failureResult(id: request.id, error: RovaError(code: "ENCODE_FAILED", message: "Komut hazırlanamadı.")))
                    return
                }
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    if error != nil { Task { @MainActor in self?.timeout(request.id, message: "Bağlantı koptu.") } }
                })
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    self?.timeout(request.id, message: "Komut zaman aşımına uğradı.")
                }
            }
            // The socket looked alive (authenticated, non-nil connection) but a 10s timeout means
            // it was actually dead (sleep/wake, Wi-Fi handoff, NAT drop) - timeout() has already
            // torn the direct connection down by this point, so retry exactly the way a command
            // that started with no connection at all already does, instead of surfacing a failure
            // the relay could have avoided. Ping is exempt: it exists to measure the direct path
            // itself, so a relay retry would misreport connection quality rather than fix it.
            if type != .ping, result.error?.code == "TIMEOUT" {
                return await sendViaBackendRelay(type: type, payload: payload, commandID: resolvedCommandID)
            }
            if let error = result.error {
                self.lastError = error.message
            }
            if type == .ping {
                if let error = result.error {
                    connectionQuality = .weak
                    appendActivity(title: "Ping", detail: error.message)
                } else {
                    let latencyMs = max(0, Int(Date().timeIntervalSince(startTime) * 1000))
                    lastPingLatencyMs = latencyMs
                    connectionQuality = .forLatency(ms: latencyMs)
                    appendActivity(title: "Ping", detail: "Pong (\(latencyMs) ms)")
                }
            } else if case .systemStatus(let status) = result.data {
                systemStatus = status
                let batteryStr = status.batteryPercentage.map { "\($0)%" } ?? "N/A"
                appendActivity(title: title(for: request), detail: "\(status.macOSVersion) • Pil: \(batteryStr)")
            } else {
                appendActivity(title: title(for: request), detail: result.message)
            }
            return result
        } catch {
            let rovaError = (error as? RovaError) ?? RovaError(code: "COMMAND_FAILED", message: error.localizedDescription.isEmpty ? "Komut başarısız oldu." : error.localizedDescription)
            let result = failureResult(id: request.id, error: rovaError)
            self.lastError = rovaError.message
            appendActivity(title: title(for: request), detail: rovaError.message)
            return result
        }
    }

    func sleepMac() async -> CommandResult {
        await send(.sleepMac)
    }

    func displaySleep() async -> CommandResult {
        await send(.displaySleep)
    }

    func setBrightness(_ level: Int) async -> CommandResult {
        await send(.setBrightness, payload: .brightness(level))
    }

    func setVolume(_ level: Int) async -> CommandResult {
        await send(.setVolume, payload: .volume(level))
    }

    func toggleMute() async -> CommandResult {
        await send(.toggleMute)
    }

    func mediaControl(_ action: MediaAction) async -> CommandResult {
        await send(.mediaControl, payload: .media(action))
    }

    func setClipboardText(_ text: String) async -> CommandResult {
        await send(.setClipboardText, payload: .clipboardText(text))
    }

    func quitApplication(_ id: ApplicationID) async -> CommandResult {
        await send(.quitApplication, payload: .application(id))
    }

    func controlApplication(_ action: ApplicationControlAction, target: String, bundleIdentifier: String? = nil, force: Bool = false) async -> CommandResult {
        await send(
            .controlApplication,
            payload: .applicationControl(ApplicationControlPayload(action: action, target: target, bundleIdentifier: bundleIdentifier, force: force))
        )
    }

    private func connect(host: String, port: UInt16, fingerprint: String) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            fail("Port geçersiz.")
            return
        }
        connect(to: .hostPort(host: NWEndpoint.Host(host), port: endpointPort), fingerprint: fingerprint)
    }

    private func connect(to endpoint: NWEndpoint, fingerprint: String) {
        connectionGeneration += 1
        let currentGen = connectionGeneration
        connection?.cancel()
        receiveBuffer.removeAll(keepingCapacity: false)
        authenticated = false
        state = .connecting
        let parameters = Self.makeTLSParameters(fingerprint: fingerprint)
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection, self.connectionGeneration == currentGen else { return }
                self.handleConnectionState(state, for: connection)
            }
        }
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled, self.connectionGeneration == currentGen else { return }
            if self.state == .connecting {
                self.connection?.cancel()
                self.connection = nil
                self.state = .disconnected
                self.scheduleReconnect()
            }
        }
        connection.start(queue: DispatchQueue(label: "com.wiqo.connection", qos: .userInitiated))
    }

    /// Builds TLS options outside the main-actor isolation domain.
    ///
    /// `sec_protocol_options_set_verify_block` invokes its C block on the queue
    /// supplied as the third argument.  Keeping this factory nonisolated is
    /// important in Swift 6: a closure created inside a `@MainActor` method can
    /// otherwise carry main-actor isolation even though Network.framework calls
    /// it from the verification queue, which trips libdispatch's queue assertion
    /// during the first pairing handshake.
    private nonisolated static func makeTLSParameters(fingerprint: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, completion in
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let certificate = (SecTrustCopyCertificateChain(reference) as? [SecCertificate])?.first,
                  let certificateData = SecCertificateCopyData(certificate) as Data? else {
                completion(false)
                return
            }
            completion(RovaCrypto.sha256Hex(certificateData) == fingerprint)
        }, DispatchQueue(label: "com.wiqo.tls.verify", qos: .userInitiated))
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 6
        return NWParameters(tls: tls, tcp: tcp)
    }

    private func handleConnectionState(_ newState: NWConnection.State, for source: NWConnection) {
        guard connection === source else { return }
        switch newState {
        case .ready:
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            isReconnecting = false
            receiveNext(on: source)
            if let remote = source.currentPath?.remoteEndpoint, case let .hostPort(host, port) = remote {
                let hostString: String
                switch host {
                case .ipv4(let addr): hostString = "\(addr)"
                case .ipv6(let addr): hostString = "\(addr)"
                case .name(let name, _): hostString = name
                @unknown default: hostString = "\(host)"
                }
                if let fingerprint = certificateFingerprint {
                    self.savedEndpoint = SavedEndpoint(host: hostString, port: port.rawValue, fingerprint: fingerprint)
                    if let data = try? JSONEncoder().encode(self.savedEndpoint) {
                        UserDefaults.standard.set(data, forKey: "rova.ios.endpoint")
                    }
                }
            }
            switch mode {
            case .pairing(let payload):
                sendEnvelope(
                    WireEnvelope(message: .pair(PairingRequest(code: payload.pairingCode, deviceName: UIDevice.current.name, deviceID: deviceID))),
                    on: source
                )
            case .authenticated:
                guard let token else { return }
                sendEnvelope(
                    WireEnvelope(message: .authenticate(AuthenticationRequest(token: token, deviceID: deviceID))),
                    on: source
                )
            }
        case .waiting:
            // Transient (Wi-Fi handoff, path still pending) - state/isReconnecting already
            // reflect this in the UI. PC connectivity is optional, so this never interrupts the
            // user with a message there's nothing for them to do about.
            break
        case .failed(let error):
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            stopHeartbeat()
            state = .failed
            authenticated = false
            // Loud only while the user is actively watching a pairing attempt; once paired, every
            // later reconnect is automatic and silent - chat keeps working from the phone either
            // way, so "can't reach the PC right now" is a status, not an error to nag about.
            let isActivePairingAttempt: Bool = { if case .pairing = mode { return true } else { return false } }()
            fail(error.localizedDescription.isEmpty ? "Bağlantı kurulamadı." : "PC bağlantısı kurulamadı.", silent: !isActivePairingAttempt)
            scheduleReconnect()
        case .cancelled:
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            stopHeartbeat()
            state = .disconnected
            authenticated = false
            isPairing = false
            connectionQuality = .unknown
        default:
            break
        }
    }

    private func receiveNext(on source: NWConnection) {
        guard connection === source else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: RovaValidation.maxFrameSize + 4) { [weak self, source] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connection === source else { return }
                if let data, !data.isEmpty {
                    do {
                        for frame in try RovaFrameCodec.appendAndExtract(data, from: &self.receiveBuffer) {
                            self.handle(try RovaWireCodec.decode(frame))
                        }
                    } catch {
                        self.fail("Geçersiz servis mesajı.")
                        self.connection?.cancel()
                        return
                    }
                }
                if complete || error != nil {
                    self.authenticated = false
                    self.state = .disconnected
                    self.failPending(IOSConnectionError.disconnected)
                    self.scheduleReconnect()
                } else {
                    self.receiveNext(on: source)
                }
            }
        }
    }

    private func handle(_ envelope: WireEnvelope) {
        switch envelope.message {
        case .hello(let info):
            deviceInfo = info
            if isPaired { persistMacDeviceID(info.id) }
        case .pairAccepted(let response):
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            do {
                try RovaKeychainStore.save(Data(response.token.utf8), account: "ios-device-token")
                try RovaKeychainStore.save(Data(response.certificateFingerprint.utf8), account: "ios-certificate-fingerprint")
            } catch {
                fail("Token güvenle saklanamadı.")
                return
            }
            token = response.token
            certificateFingerprint = response.certificateFingerprint
            if case .pairing(let payload) = mode {
                savedEndpoint = SavedEndpoint(host: payload.host, port: payload.port, fingerprint: payload.certificateFingerprint)
                if let savedEndpoint, let data = try? JSONEncoder().encode(savedEndpoint) { UserDefaults.standard.set(data, forKey: "rova.ios.endpoint") }
            }
            isPaired = true
            isUsingRelay = false
            if let deviceInfo { persistMacDeviceID(deviceInfo.id) }
            isPairing = false
            state = .disconnected
            connection?.cancel()
            mode = .authenticated
            appendActivity(title: "Eşleşme", detail: "Tamamlandı")
            connect()
        case .authenticated(let response):
            authenticated = true
            isUsingRelay = false
            rememberMacDevice(response.deviceInfo)
            state = .connected
            startHeartbeat()
            Task { [weak self] in _ = await self?.send(.getSystemStatus) }
            sendBackendTokenIfAvailable()
        case .result(let result):
            if case .systemStatus(let status) = result.data {
                systemStatus = status
            }
            if let continuation = pending.removeValue(forKey: result.commandID) {
                continuation.resume(returning: result)
            }
        case .failure(let error):
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            if case .pairing = mode {
                isPairing = false
                connection?.cancel()
            }
            lastError = error.message
            if let continuation = pending.removeValue(forKey: envelope.requestID) { continuation.resume(throwing: error) }
        default:
            break
        }
    }

    /// Hands the Mac this device's current Rova backend login session, once, over the existing
    /// authenticated local connection - lets the Mac open its own persistent channel to the
    /// backend (for automations that fire with no iPhone around) without a separate Mac login.
    /// Safe to call opportunistically (e.g. right after Mac auth, or right after a fresh Rova
    /// login) - it's a no-op if there's no Mac connection or no backend session yet.
    func sendBackendTokenIfAvailable() {
        guard state == .connected, let token = RovaBackendClient.token else { return }
        sendEnvelope(WireEnvelope(message: .backendToken(token)))
    }

    private func sendEnvelope(_ envelope: WireEnvelope, on source: NWConnection? = nil) {
        guard let active = source ?? connection,
              connection === active,
              let data = try? RovaWireCodec.encode(envelope) else { return }
        active.send(content: data, completion: .contentProcessed { [weak self, active] error in
            if error != nil {
                Task { @MainActor in
                    guard let self, self.connection === active else { return }
                    self.scheduleReconnect()
                }
            }
        })
    }

    private func timeout(_ id: UUID, message: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        let result = failureResult(id: id, error: RovaError(code: "TIMEOUT", message: message))
        continuation.resume(returning: result)
        // A healthy local socket never takes 10s to answer. A timeout means the connection
        // is silently dead (Wi-Fi handoff, sleep/wake, NAT drop) even though NWConnection may
        // still report .ready. Tear it down and reconnect instead of leaving the UI stuck on
        // "Connected" with every further command failing the same way.
        if state == .connected {
            stopHeartbeat()
            connectionQuality = .unknown
            connection?.cancel()
            connection = nil
            authenticated = false
            state = .disconnected
            scheduleReconnect()
        }
    }

    /// Sends a background ping while connected so a dead socket (Wi-Fi handoff, sleep/wake,
    /// NAT drop) is caught within seconds instead of waiting for the user to issue a command,
    /// and so `connectionQuality` stays a live signal rather than a one-time measurement.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled, self.state == .connected else { return }
                _ = await self.send(.ping)
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func scheduleRelayProbe() {
        guard isPaired, isUsingRelay, relayProbeTask == nil else { return }
        relayProbeTask = Task { @MainActor [weak self] in
            defer { self?.relayProbeTask = nil }
            for delay in [0, 1, 2, 4, 8, 16, 30] {
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) }
                guard let self, !Task.isCancelled, self.isPaired, self.state != .connected else { return }
                let result = await self.send(.ping)
                if result.error == nil { return }
            }
        }
    }

    private func failPending(_ error: Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    private func scheduleReconnect() {
        guard isPaired, reconnectTask == nil, state != .connected else { return }
        guard pathAvailable else {
            isReconnecting = true
            return
        }
        let delays = [1, 2, 4, 8, 16, 30]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        isReconnecting = true
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finishReconnect()
        }
    }

    private func finishReconnect() {
        reconnectTask = nil
        guard pathAvailable else {
            isReconnecting = true
            return
        }
        connect()
    }

    private func handleNetworkPath(available: Bool, signature: String) {
        let changed = pathSignature != nil && pathSignature != signature
        pathSignature = signature
        pathAvailable = available

        guard isPaired else { return }
        if !available {
            isReconnecting = true
            if state == .connected || state == .connecting {
                connection?.cancel()
                connection = nil
                authenticated = false
                state = .disconnected
                failPending(IOSConnectionError.disconnected)
            }
            return
        }

        // A changed interface invalidates the local route (Wi-Fi handoff, sleep/wake). The next
        // command can use the relay while the local socket is rebuilt in the background.
        if changed && !isUsingRelay && state == .connected {
            stopHeartbeat()
            connection?.cancel()
            connection = nil
            authenticated = false
            state = .disconnected
            isReconnecting = true
            scheduleReconnect()
        } else if state != .connected {
            reconnectAttempt = 0
            scheduleReconnect()
        }
    }

    /// `silent` skips surfacing `message` to the UI - used for a routine background reconnect
    /// failure of an already-paired PC, which chat doesn't need PC connectivity to keep working
    /// through anyway, as opposed to a failure the user is actively watching for (pairing a PC
    /// for the first time).
    private func fail(_ message: String, silent: Bool = false) {
        if !silent { lastError = isPaired ? userFacingConnectionError : message }
        state = .failed
        isPairing = false
        stopHeartbeat()
        connectionQuality = .unknown
        failPending(IOSConnectionError.failed)
    }

    /// Collapses a repeat of the exact same state (title AND detail unchanged - "Bağlantı:
    /// Çalışıyor..." after a reconnect attempt is the common case) into the existing top row
    /// instead of piling up an identical one - the log is meant to show what CHANGED, and a wall
    /// of duplicate lines buries the one row (a real error) someone's actually looking for.
    private func appendActivity(title: String, detail: String) {
        if let first = activities.first, first.title == title, first.detail == detail {
            activities[0] = IOSActivity(title: title, detail: detail)
            return
        }
        activities.insert(IOSActivity(title: title, detail: detail), at: 0)
        if activities.count > 20 { activities.removeLast() }
    }

    private func title(for request: CommandRequest) -> String {
        switch request.type {
        case .getSystemStatus: return "Sistem durumu"
        case .openApplication: return "Uygulama aç"
        case .controlApplication: return "Uygulama kontrolü"
        case .quitApplication: return "Uygulamayı kapat"
        case .openURL: return "URL aç"
        case .lockMac: return "PC'yi kilitle"
        case .sleepMac: return "PC'yi uyut"
        case .displaySleep: return "Ekranı uyut"
        case .setBrightness: return "Parlaklık"
        case .setVolume: return "Ses"
        case .toggleMute: return "Sessiz"
        case .mediaControl: return "Medya"
        case .setClipboardText: return "Pano"
        case .saveTextFile: return "Dosya kaydet"
        case .ping: return "Bağlantı"
        case .sendMessage: return "Mesaj gönder"
        case .listCalendarEvents: return "Takvim listesi"
        case .createCalendarEvent: return "Takvim etkinliği oluştur"
        case .listReminders: return "Hatırlatıcılar"
        case .createReminder: return "Hatırlatıcı oluştur"
        case .completeReminder: return "Hatırlatıcıyı tamamla"
        case .getClipboardText: return "Panoyu oku"
        case .getClipboardHistory: return "Pano geçmişi"
        case .createNote: return "Not oluştur"
        case .sendEmail: return "E-posta gönder"
        case .listDesktopFiles: return "Masaüstü dosyaları"
        case .readDesktopFile: return "Masaüstü dosyası oku"
        case .moveDesktopFile: return "Masaüstü dosyası taşı"
        case .renameDesktopFile: return "Masaüstü dosyası adlandır"
        case .saveArtifact: return "Belge kaydet"
        case .readDocument: return "Belge oku"
        case .editDocument: return "Belge düzenle"
        case .openApplicationByName: return "Uygulama aç"
        case .listFiles: return "Dosyaları listele"
        case .readFile: return "Dosya oku"
        case .writeFile: return "Dosya yaz"
        case .moveFile: return "Dosya taşı"
        case .copyFile: return "Dosya kopyala"
        case .deleteFile: return "Dosya sil"
        case .executeCode: return "Kod çalıştır"
        case .captureScreen: return "Ekran görüntüsü"
        case .runShortcut: return "Shortcut çalıştır"
        case .controlUIElement: return "Arayüz kontrolü"
        case .clickScreen: return "Ekrana tıkla"
        case .listRunningApplications: return "Açık uygulamalar"
        }
    }

    private func failureResult(id: UUID, error: RovaError) -> CommandResult {
        let now = Date()
        return CommandResult(commandID: id, status: .failed, message: error.message, startedAt: now, finishedAt: now, error: error)
    }

    /// Builds and validates the exact same CommandRequest the direct path would send, then routes
    /// it through the backend relay (see RovaBackendClient.sendDeviceCommand) instead. Used only
    /// when the direct local connection isn't up; a signed-in Wiqo account gets the request as far
    /// as the Mac's persistent backend socket, but the Mac itself only trusts the device-pairing
    /// token - so this signs the request exactly like the direct path does, rather than relying on
    /// account auth alone to stand in for device-pairing trust the Mac never actually granted it.
    private func sendViaBackendRelay(type: CommandType, payload: CommandPayload, commandID: UUID) async -> CommandResult {
        guard RovaBackendClient.isAuthenticated else {
            return failureResult(id: commandID, error: RovaError(code: "OFFLINE", message: "PC bağlı değil."))
        }
        let nonce = try? RovaCrypto.randomToken()
        let signature = token.map { RovaValidation.signRequest(id: commandID, type: type, nonce: nonce ?? "", token: $0) }
        let request = CommandRequest(id: commandID, type: type, payload: payload, signature: signature, nonce: nonce)
        if let validationError = RovaValidation.validate(request) {
            return failureResult(id: request.id, error: validationError)
        }
        appendActivity(title: title(for: request), detail: "PC yerel ağda değil, sunucu üzerinden deneniyor…")
        do {
            let result = try await RovaBackendClient.sendDeviceCommand(request, deviceId: pairedMacDeviceID?.uuidString ?? deviceInfo?.id.uuidString)
            isUsingRelay = result.error == nil
            if result.error == nil {
                state = .connected
                isReconnecting = false
                startHeartbeat()
            }
            if let error = result.error { self.lastError = error.message }
            appendActivity(title: title(for: request), detail: result.message)
            return result
        } catch {
            isUsingRelay = false
            let message = (error as? LocalizedError)?.errorDescription ?? "PC'ye ulaşılamadı."
            self.lastError = message
            appendActivity(title: title(for: request), detail: message)
            return failureResult(id: request.id, error: RovaError(code: "RELAY_FAILED", message: message))
        }
    }

    private func rememberMacDevice(_ info: DeviceInfo) {
        deviceInfo = info
        persistMacDeviceID(info.id)
    }

    private func persistMacDeviceID(_ id: UUID) {
        pairedMacDeviceID = id
        UserDefaults.standard.set(id.uuidString, forKey: "rova.ios.mac-device-id")
    }

    private func startDiscovery() {
        browser?.cancel()
        let browser = NWBrowser(for: .bonjour(type: "_rova._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleDiscoveryState(state)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let result = results.first else { return }
            let endpoint = result.endpoint
            let name: String
            if case let .service(serviceName, _, _, _) = endpoint {
                name = serviceName
            } else {
                name = "Wiqo PC"
            }
            Task { @MainActor in
                self?.handleDiscoveryResult(endpoint: endpoint, serviceName: name)
            }
        }
        self.browser = browser
        browser.start(queue: discoveryQueue)
    }

    private func handleDiscoveryState(_ state: NWBrowser.State) {
        if case .failed = state {
            browser?.cancel()
            browser = nil
            guard isPaired else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.browser == nil, self.isPaired else { return }
                self.startDiscovery()
            }
        }
    }

    private func handleDiscoveryResult(endpoint: NWEndpoint, serviceName: String) {
        guard isPaired, let fingerprint = certificateFingerprint else { return }
        // Bonjour re-broadcasts periodically (network changes, TTL refresh); only act on it
        // when we are not already connected or mid-handshake, otherwise every re-broadcast
        // cancels and restarts an in-flight connection attempt, which reads as a flaky link.
        guard state == .disconnected || state == .failed else { return }
        discoveredServiceName = serviceName
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        connect(to: endpoint, fingerprint: fingerprint)
    }
}

private struct SavedEndpoint: Codable, Sendable {
    let host: String
    let port: UInt16
    let fingerprint: String
}

private enum ConnectionMode {
    case pairing(PairingPayload)
    case authenticated
}

/// Conforms to LocalizedError specifically so `error.localizedDescription` (the fallback `send()`
/// uses for any error that isn't already a RovaError - see its catch block) never falls through to
/// Foundation's default NSError bridging, which for a plain enum with no Error/CustomNSError
/// conformance produces exactly the raw, undebuggable-looking text a user reported seeing:
/// "(RovaIOS.(unknown context at $ADDRESS).IOSConnectionError hatası 0.)".
private enum IOSConnectionError: LocalizedError {
    case disconnected
    case failed

    var errorDescription: String? {
        switch self {
        case .disconnected: return "Mac ile bağlantı kesildi."
        case .failed: return "Mac ile bağlantı kurulamadı."
        }
    }
}
