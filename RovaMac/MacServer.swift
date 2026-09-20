import Foundation
import Network
import OSLog

enum MacServiceState: String, Sendable {
    case stopped
    case starting
    case running
    case failed
}

final class MacServer: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.wiqo.mac", category: "connection")
    private let port: NWEndpoint.Port
    private let identity: RovaTLSIdentity
    private let queue = DispatchQueue(label: "com.wiqo.mac.listener", qos: .userInitiated)
    private var listener: NWListener?

    var onState: (@Sendable (MacServiceState, String?) -> Void)?
    var onConnection: (@Sendable (MacClientSession) -> Void)?
    var onEnvelope: (@Sendable (MacClientSession, WireEnvelope) -> Void)?
    var onSessionClosed: (@Sendable (MacClientSession) -> Void)?

    init(port: UInt16, identity: RovaTLSIdentity) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 47831
        self.identity = identity
    }

    func start() {
        logger.info("Starting listener on port \(self.port.rawValue, privacy: .public)")
        onState?(.starting, nil)
        do {
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
            guard let localIdentity = sec_identity_create(identity.identity) else {
                throw RovaTLSError.identityCreationFailed
            }
            sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, localIdentity)
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 10
            tcpOptions.keepaliveInterval = 5
            tcpOptions.keepaliveCount = 3
            let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: port)
            listener.service = NWListener.Service(name: MacNetwork.computerName, type: "_rova._tcp", domain: nil)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.logger.info("Accepted local connection")
                let session = MacClientSession(
                    connection: connection,
                    queue: self.queue,
                    onEnvelope: { [weak self] session, envelope in self?.onEnvelope?(session, envelope) },
                    onClose: { [weak self] session in
                        self?.logger.info("Connection closed")
                        self?.onSessionClosed?(session)
                    }
                )
                self.onConnection?(session)
                session.start()
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.onState?(.running, nil)
                case .failed(let error):
                    self?.logger.error("Listener failed: \(error.localizedDescription, privacy: .public)")
                    self?.onState?(.failed, error.localizedDescription)
                case .cancelled: self?.onState?(.stopped, nil)
                default: break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            onState?(.failed, error.localizedDescription)
        }
    }

    func stop() {
        logger.info("Stopping listener")
        listener?.cancel()
        listener = nil
        onState?(.stopped, nil)
    }
}

final class MacClientSession: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onEnvelope: @Sendable (MacClientSession, WireEnvelope) -> Void
    private let onClose: @Sendable (MacClientSession) -> Void
    private var receiveBuffer = Data()
    private var closed = false
    private let stateLock = NSLock()
    private let authLock = NSLock()
    private var authenticated = false

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        onEnvelope: @escaping @Sendable (MacClientSession, WireEnvelope) -> Void,
        onClose: @escaping @Sendable (MacClientSession) -> Void = { _ in }
    ) {
        self.connection = connection
        self.queue = queue
        self.onEnvelope = onEnvelope
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.close() }
        }
        connection.start(queue: queue)
        receiveNext()
    }

    func send(_ envelope: WireEnvelope) {
        guard !isClosed, let data = try? RovaWireCodec.encode(envelope) else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    func close() {
        guard markClosed() else { return }
        connection.cancel()
        onClose(self)
    }

    var isAuthenticated: Bool {
        authLock.lock(); defer { authLock.unlock() }
        return authenticated
    }

    func setAuthenticated(_ value: Bool) {
        authLock.lock(); authenticated = value; authLock.unlock()
    }

    private func receiveNext() {
        guard !isClosed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: RovaValidation.maxFrameSize + 4) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                do {
                    let frames = try RovaFrameCodec.appendAndExtract(data, from: &self.receiveBuffer)
                    for frame in frames {
                        let envelope = try RovaWireCodec.decode(frame)
                        self.onEnvelope(self, envelope)
                    }
                } catch {
                    self.close()
                    return
                }
            }
            if isComplete || error != nil { self.close() } else { self.receiveNext() }
        }
    }

    private var isClosed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return closed
    }

    private func markClosed() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !closed else { return false }
        closed = true
        return true
    }
}
