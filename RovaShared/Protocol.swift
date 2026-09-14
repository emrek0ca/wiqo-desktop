import Foundation

public enum CommandStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case running
    case completed
    case failed
    case denied
}

public enum CommandType: String, Codable, CaseIterable, Sendable {
    case getSystemStatus
    case openApplication
    case openURL
    case lockMac
    case sleepMac
    case displaySleep
    case setBrightness
    case setVolume
    case toggleMute
    case mediaControl
    case setClipboardText
    case quitApplication
    case saveTextFile
    case ping
}

public enum MediaAction: String, Codable, CaseIterable, Sendable {
    case playPause
    case nextTrack
    case previousTrack
}

public enum ApplicationID: String, Codable, CaseIterable, Sendable {
    case safari
    case xcode
    case terminal
    case finder
    case visualStudioCode
    case mail
    case music
    case messages
    case notes
    case systemSettings

    public var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .xcode: return "Xcode"
        case .terminal: return "Terminal"
        case .finder: return "Finder"
        case .visualStudioCode: return "Visual Studio Code"
        case .mail: return "Mail"
        case .music: return "Music"
        case .messages: return "Messages"
        case .notes: return "Notes"
        case .systemSettings: return "System Settings"
        }
    }
}

public struct TextFilePayload: Codable, Equatable, Sendable {
    public let filename: String
    public let content: String

    public init(filename: String, content: String) {
        self.filename = filename
        self.content = content
    }
}

public enum CommandPayload: Codable, Equatable, Sendable {
    case none
    case application(ApplicationID)
    case url(String)
    case volume(Int)
    case media(MediaAction)
    case brightness(Int)
    case clipboardText(String)
    case textFile(TextFilePayload)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case none, application, url, volume, media, brightness, clipboardText, textFile }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .none:
            self = .none
        case .application:
            self = .application(try container.decode(ApplicationID.self, forKey: .value))
        case .url:
            self = .url(try container.decode(String.self, forKey: .value))
        case .volume:
            self = .volume(try container.decode(Int.self, forKey: .value))
        case .media:
            self = .media(try container.decode(MediaAction.self, forKey: .value))
        case .brightness:
            self = .brightness(try container.decode(Int.self, forKey: .value))
        case .clipboardText:
            self = .clipboardText(try container.decode(String.self, forKey: .value))
        case .textFile:
            self = .textFile(try container.decode(TextFilePayload.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case .application(let id):
            try container.encode(Kind.application, forKey: .kind)
            try container.encode(id, forKey: .value)
        case .url(let value):
            try container.encode(Kind.url, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .volume(let level):
            try container.encode(Kind.volume, forKey: .kind)
            try container.encode(level, forKey: .value)
        case .media(let action):
            try container.encode(Kind.media, forKey: .kind)
            try container.encode(action, forKey: .value)
        case .brightness(let level):
            try container.encode(Kind.brightness, forKey: .kind)
            try container.encode(level, forKey: .value)
        case .clipboardText(let text):
            try container.encode(Kind.clipboardText, forKey: .kind)
            try container.encode(text, forKey: .value)
        case .textFile(let payload):
            try container.encode(Kind.textFile, forKey: .kind)
            try container.encode(payload, forKey: .value)
        }
    }
}

public struct ApplicationInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: ApplicationID
    public let name: String

    public init(id: ApplicationID, name: String = "") {
        self.id = id
        self.name = name.isEmpty ? id.displayName : name
    }
}

public struct SystemStatus: Codable, Equatable, Sendable {
    public let hostname: String
    public let macOSVersion: String
    public let batteryPercentage: Int?
    public let isCharging: Bool?
    public let uptimeSeconds: Double
    public let runtimeStatus: String
    public let volumePercentage: Int?
    public let brightnessPercentage: Int?

    public init(
        hostname: String,
        macOSVersion: String,
        batteryPercentage: Int?,
        isCharging: Bool?,
        uptimeSeconds: Double,
        runtimeStatus: String,
        volumePercentage: Int? = nil,
        brightnessPercentage: Int? = nil
    ) {
        self.hostname = hostname
        self.macOSVersion = macOSVersion
        self.batteryPercentage = batteryPercentage
        self.isCharging = isCharging
        self.uptimeSeconds = uptimeSeconds
        self.runtimeStatus = runtimeStatus
        self.volumePercentage = volumePercentage
        self.brightnessPercentage = brightnessPercentage
    }
}

public struct PingData: Codable, Equatable, Sendable {
    public let serverTime: Date

    public init(serverTime: Date = Date()) {
        self.serverTime = serverTime
    }
}

public struct RovaError: Codable, Equatable, Sendable, Error {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct CommandResult: Codable, Equatable, Sendable {
    public let commandID: UUID
    public let status: CommandStatus
    public let message: String
    public let startedAt: Date
    public let finishedAt: Date
    public let data: CommandData?
    public let error: RovaError?

    public init(
        commandID: UUID,
        status: CommandStatus,
        message: String,
        startedAt: Date,
        finishedAt: Date,
        data: CommandData? = nil,
        error: RovaError? = nil
    ) {
        self.commandID = commandID
        self.status = status
        self.message = message
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.data = data
        self.error = error
    }
}

public enum CommandData: Codable, Equatable, Sendable {
    case systemStatus(SystemStatus)
    case applications([ApplicationInfo])
    case ping(PingData)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case systemStatus, applications, ping }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .systemStatus:
            self = .systemStatus(try container.decode(SystemStatus.self, forKey: .value))
        case .applications:
            self = .applications(try container.decode([ApplicationInfo].self, forKey: .value))
        case .ping:
            self = .ping(try container.decode(PingData.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .systemStatus(let value):
            try container.encode(Kind.systemStatus, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .applications(let value):
            try container.encode(Kind.applications, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .ping(let value):
            try container.encode(Kind.ping, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

public struct CommandRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let type: CommandType
    public let payload: CommandPayload
    public let createdAt: Date
    public let signature: String?
    public let nonce: String?

    public init(
        id: UUID = UUID(),
        type: CommandType,
        payload: CommandPayload = .none,
        createdAt: Date = Date(),
        signature: String? = nil,
        nonce: String? = nil
    ) {
        self.id = id
        self.type = type
        self.payload = payload
        self.createdAt = createdAt
        self.signature = signature
        self.nonce = nonce
    }
}

public struct DeviceInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let hostname: String
    public let localIPAddress: String
    public let port: UInt16
    public let serviceStatus: String
    public let availableApplications: [ApplicationInfo]
    /// "macOS" today; a future Windows companion reports "windows" here. Nothing in the wire
    /// protocol keys off this yet - it exists so a client can eventually branch on it (icons,
    /// available capabilities) without another protocol change.
    public let platform: String

    public init(
        id: UUID,
        displayName: String,
        hostname: String,
        localIPAddress: String,
        port: UInt16,
        serviceStatus: String,
        availableApplications: [ApplicationInfo],
        platform: String = "macOS"
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.localIPAddress = localIPAddress
        self.port = port
        self.serviceStatus = serviceStatus
        self.availableApplications = availableApplications
        self.platform = platform
    }
}

public struct PairingPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let host: String
    public let port: UInt16
    public let certificateFingerprint: String
    public let pairingCode: String
    public let expiresAt: Date

    public init(version: Int = 1, host: String, port: UInt16, certificateFingerprint: String, pairingCode: String, expiresAt: Date) {
        self.version = version
        self.host = host
        self.port = port
        self.certificateFingerprint = certificateFingerprint
        self.pairingCode = pairingCode
        self.expiresAt = expiresAt
    }
}

public struct PairingRequest: Codable, Equatable, Sendable {
    public let code: String
    public let deviceName: String
    public let deviceID: UUID

    public init(code: String, deviceName: String, deviceID: UUID) {
        self.code = code
        self.deviceName = deviceName
        self.deviceID = deviceID
    }
}

public struct PairingResponse: Codable, Equatable, Sendable {
    public let token: String
    public let deviceID: UUID
    public let certificateFingerprint: String

    public init(token: String, deviceID: UUID, certificateFingerprint: String) {
        self.token = token
        self.deviceID = deviceID
        self.certificateFingerprint = certificateFingerprint
    }
}

public struct AuthenticationRequest: Codable, Equatable, Sendable {
    public let token: String
    public let deviceID: UUID

    public init(token: String, deviceID: UUID) {
        self.token = token
        self.deviceID = deviceID
    }
}

public struct AuthenticationResponse: Codable, Equatable, Sendable {
    public let deviceInfo: DeviceInfo

    public init(deviceInfo: DeviceInfo) {
        self.deviceInfo = deviceInfo
    }
}

public enum WireMessage: Codable, Equatable, Sendable {
    case hello(DeviceInfo)
    case pair(PairingRequest)
    case pairAccepted(PairingResponse)
    case authenticate(AuthenticationRequest)
    case authenticated(AuthenticationResponse)
    case command(CommandRequest)
    case result(CommandResult)
    case failure(RovaError)
    /// The iPhone hands its Rova backend login session to the Mac over this already-authenticated
    /// local connection, once, so the Mac can open its own persistent channel to the backend
    /// (see MacBackendChannel) without needing a separate Mac-side login screen.
    case backendToken(String)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable {
        case hello, pair, pairAccepted, authenticate, authenticated, command, result, failure, backendToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .hello: self = .hello(try container.decode(DeviceInfo.self, forKey: .value))
        case .pair: self = .pair(try container.decode(PairingRequest.self, forKey: .value))
        case .pairAccepted: self = .pairAccepted(try container.decode(PairingResponse.self, forKey: .value))
        case .authenticate: self = .authenticate(try container.decode(AuthenticationRequest.self, forKey: .value))
        case .authenticated: self = .authenticated(try container.decode(AuthenticationResponse.self, forKey: .value))
        case .command: self = .command(try container.decode(CommandRequest.self, forKey: .value))
        case .result: self = .result(try container.decode(CommandResult.self, forKey: .value))
        case .failure: self = .failure(try container.decode(RovaError.self, forKey: .value))
        case .backendToken: self = .backendToken(try container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let value): try container.encode(Kind.hello, forKey: .kind); try container.encode(value, forKey: .value)
        case .pair(let value): try container.encode(Kind.pair, forKey: .kind); try container.encode(value, forKey: .value)
        case .pairAccepted(let value): try container.encode(Kind.pairAccepted, forKey: .kind); try container.encode(value, forKey: .value)
        case .authenticate(let value): try container.encode(Kind.authenticate, forKey: .kind); try container.encode(value, forKey: .value)
        case .authenticated(let value): try container.encode(Kind.authenticated, forKey: .kind); try container.encode(value, forKey: .value)
        case .command(let value): try container.encode(Kind.command, forKey: .kind); try container.encode(value, forKey: .value)
        case .result(let value): try container.encode(Kind.result, forKey: .kind); try container.encode(value, forKey: .value)
        case .backendToken(let value): try container.encode(Kind.backendToken, forKey: .kind); try container.encode(value, forKey: .value)
        case .failure(let value): try container.encode(Kind.failure, forKey: .kind); try container.encode(value, forKey: .value)
        }
    }
}

public struct WireEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let message: WireMessage

    public init(version: Int = 1, requestID: UUID = UUID(), message: WireMessage) {
        self.version = version
        self.requestID = requestID
        self.message = message
    }
}
