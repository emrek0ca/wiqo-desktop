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
    @Published private(set) var activities: [IOSActivity] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isPaired = false
    @Published private(set) var isPairing = false

    private let deviceID: UUID
    private var token: String?
    private var certificateFingerprint: String?
    private var savedEndpoint: SavedEndpoint?
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
    private var browser: NWBrowser?
    private let discoveryQueue = DispatchQueue(label: "com.rova.discovery", qos: .utility)
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
        isPaired = token != nil && certificateFingerprint != nil && savedEndpoint != nil
        startDiscovery()
    }

    func pair(using payload: PairingPayload) {
        guard RovaValidation.isPairingPayloadValid(payload) else {
            fail("Geçersiz pairing QR kodu.")
            return
        }
        guard payload.expiresAt > Date() else {
            fail("Pairing QR kodunun süresi doldu.")
            return
        }
        connectionGeneration += 1
        let currentGen = connectionGeneration
        pairingTimeoutTask?.cancel()
        isPairing = true
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
        appendActivity(title: "Pairing", detail: "Zaman aşımına uğradı")
    }

    func connect() {
        guard let endpoint = savedEndpoint, let fingerprint = certificateFingerprint else {
            state = .disconnected
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
        UserDefaults.standard.removeObject(forKey: "rova.ios.endpoint")
        isPaired = false
        deviceInfo = nil
        systemStatus = nil
        lastPingLatencyMs = nil
    }

    func authenticateBiometrics(reason: String = "Rova komutunu onaylayın") async -> Bool {
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

    func send(_ type: CommandType, payload: CommandPayload = .none) async -> CommandResult {
        guard isPaired else { return failureResult(id: UUID(), error: RovaError(code: "NOT_PAIRED", message: "Önce Mac ile pair olun.")) }
        guard authenticated, let connection else {
            connect()
            return failureResult(id: UUID(), error: RovaError(code: "OFFLINE", message: "Mac bağlı değil."))
        }
        let now = Date()
        let commandID = UUID()
        let nonce = try? RovaCrypto.randomToken()
        let signature = token.map { RovaValidation.signRequest(id: commandID, type: type, nonce: nonce ?? "", token: $0) }
        let request = CommandRequest(id: commandID, type: type, payload: payload, createdAt: now, signature: signature, nonce: nonce)
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
            if let error = result.error {
                self.lastError = error.message
            }
            if type == .ping {
                let latencyMs = max(0, Int(Date().timeIntervalSince(startTime) * 1000))
                lastPingLatencyMs = latencyMs
                appendActivity(title: "Ping", detail: "Pong (\(latencyMs) ms)")
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
        connection.start(queue: DispatchQueue(label: "com.rova.connection", qos: .userInitiated))
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
        }, DispatchQueue(label: "com.rova.tls.verify", qos: .userInitiated))
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
        case .waiting(let error):
            // Explicitly handle waiting state when network interface changes or path is pending
            lastError = "Ağ bağlantısı bekleniyor..."
        case .failed(let error):
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            state = .failed
            authenticated = false
            fail(error.localizedDescription.isEmpty ? "Bağlantı kurulamadı." : "Mac bağlantısı kurulamadı.")
            scheduleReconnect()
        case .cancelled:
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            state = .disconnected
            authenticated = false
            isPairing = false
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
            isPairing = false
            state = .disconnected
            connection?.cancel()
            mode = .authenticated
            appendActivity(title: "Pairing", detail: "Tamamlandı")
            connect()
        case .authenticated(let response):
            authenticated = true
            deviceInfo = response.deviceInfo
            state = .connected
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
            connection?.cancel()
            connection = nil
            authenticated = false
            state = .disconnected
            lastError = message
            scheduleReconnect()
        }
    }

    private func failPending(_ error: Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    private func scheduleReconnect() {
        guard isPaired, reconnectTask == nil, state != .connected else { return }
        let delays = [1, 2, 4, 8, 16, 30]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finishReconnect()
        }
    }

    private func finishReconnect() {
        reconnectTask = nil
        connect()
    }

    private func fail(_ message: String) {
        lastError = message
        state = .failed
        isPairing = false
        failPending(IOSConnectionError.failed)
    }

    private func appendActivity(title: String, detail: String) {
        activities.insert(IOSActivity(title: title, detail: detail), at: 0)
        if activities.count > 20 { activities.removeLast() }
    }

    private func title(for request: CommandRequest) -> String {
        switch request.type {
        case .getSystemStatus: return "System Status"
        case .openApplication: return "Open Application"
        case .quitApplication: return "Quit App"
        case .openURL: return "Open URL"
        case .lockMac: return "Lock Mac"
        case .sleepMac: return "Sleep Mac"
        case .displaySleep: return "Display Sleep"
        case .setBrightness: return "Brightness"
        case .setVolume: return "Set Volume"
        case .toggleMute: return "Mute"
        case .mediaControl: return "Media Control"
        case .setClipboardText: return "Clipboard"
        case .ping: return "Ping"
        }
    }

    private func failureResult(id: UUID, error: RovaError) -> CommandResult {
        let now = Date()
        return CommandResult(commandID: id, status: .failed, message: error.message, startedAt: now, finishedAt: now, error: error)
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
                name = "Rova Mac"
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

private enum IOSConnectionError: Error {
    case disconnected
    case failed
}
