import Foundation

/// Plans, subscription and the StoreKit hand-off to the backend.
extension RovaBackendClient {
    // MARK: - Billing

    /// The UUID handed to StoreKit with a purchase (Apple's appAccountToken) so notifications name this account.
    static func fetchStoreKitAccountToken() async throws -> UUID {
        struct Response: Decodable { let token: String }
        let response = try await authorizedGet("billing/storekit/account-token", as: Response.self)
        guard let token = UUID(uuidString: response.token) else { throw RovaBackendError.network(String(localized: "İstek anlaşılamadı.")) }
        return token
    }

    /// The plans the paywall lists, with the limits the backend enforces.
    static func fetchPlans() async throws -> [WiqoPlan] {
        struct Response: Decodable { let plans: [WiqoPlan] }
        return try await authorizedGet("billing/plans", as: Response.self).plans
    }

    static func fetchSubscription() async throws -> SubscriptionInfo {
        try await authorizedGet("billing/subscription", as: SubscriptionInfo.self)
    }

    /// Forwards a StoreKit transaction's raw JWS to the backend right after a purchase - the
    /// backend independently re-verifies it against Apple's root certificate before granting
    /// anything (see rova-backend/src/billing/subscriptions.ts). The response carries the account's
    /// new plan and usage, so the app can show it at once.
    static func verifyStoreKitTransaction(_ signedTransaction: String) async throws -> SubscriptionInfo? {
        struct Response: Decodable { let ok: Bool; let subscription: SubscriptionInfo? }
        return try await authorizedPost("billing/storekit/verify", body: ["signedTransaction": signedTransaction], as: Response.self).subscription
    }

    static func fetchDevices() async throws -> [DeviceStatus] {
        struct Response: Decodable { let devices: [DeviceStatus] }
        // Presence changes independently of account/device metadata; a cached `online` value
        // must never be presented as current after a disconnect or wake.
        return try await authorizedGet("devices", as: Response.self).devices
    }

    static func registerFileTransfer(commandID: UUID, deviceID: UUID) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["commandId": commandID.uuidString, "deviceId": deviceID.uuidString])
        _ = try await authorizedJSON("file-transfers/intents", method: "POST", body: body)
    }

    struct DeviceEvent: Decodable {
        let type: String
        let device: DeviceStatus
    }

    static func observeDeviceEvents(_ onEvent: @escaping @MainActor @Sendable (DeviceEvent) -> Void) async throws {
        guard let token else { throw RovaBackendError.notAuthenticated }
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent("devices/events"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw RovaBackendError.invalidResponse }
        if http.statusCode == 401 { throw RovaBackendError.notAuthenticated }
        guard http.statusCode == 200 else { throw RovaBackendError.network(String(localized: "Cihaz bağlantısı izlenemiyor.")) }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: "),
                  let data = String(line.dropFirst(6)).data(using: .utf8),
                  let event = try? JSONDecoder().decode(DeviceEvent.self, from: data) else { continue }
            await onEvent(event)
        }
    }

    struct AccountInfo: Decodable {
        let email: String
        let isFoundingMember: Bool
    }

    static func fetchAccountInfo() async throws -> AccountInfo {
        try await authorizedGet("auth/me", as: AccountInfo.self)
    }

    /// A code someone can hand a friend - redeeming one credits both sides a Pro bonus (see
    /// rova-backend's grantReferralBonus). Every account always has a few unused ones; the
    /// backend self-provisions a fresh batch the first time this is read.
    struct InviteCode: Decodable, Identifiable {
        var id: String { code }
        let code: String
        let used: Bool
        let createdAt: String
    }

    static func fetchInviteCodes() async throws -> [InviteCode] {
        struct Response: Decodable { let codes: [InviteCode] }
        return try await authorizedGet("auth/invite-codes", as: Response.self).codes
    }

    /// A real Google/Notion account connection (see rova-backend's routes/oauth.ts) - never the
    /// tokens themselves, just enough to show "bağlı: ___" and let the user disconnect it.
    struct OAuthConnection: Decodable, Identifiable {
        var id: String { provider }
        let provider: String
        let accountLabel: String?
        let connectedAt: String
        let accessLevel: String?
        /// "needs_reconnect" when the provider refused the stored authorisation (older servers send nothing).
        let status: String?
    }

    /// An app the person can connect, as the server lists it: a provider added on the server shows up here without an app update.
    struct OAuthProviderInfo: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let symbol: String
        let summary: String?
        let available: Bool?

        static let builtIn: [OAuthProviderInfo] = [
            OAuthProviderInfo(id: "google", name: "Google", symbol: "envelope.badge", summary: "Gmail, Takvim ve Drive", available: true),
            OAuthProviderInfo(id: "notion", name: "Notion", symbol: "doc.text", summary: String(localized: "Sayfalar ve notlar"), available: true),
            OAuthProviderInfo(id: "slack", name: "Slack", symbol: "number", summary: "Kanallar ve mesajlar", available: false),
            OAuthProviderInfo(id: "github", name: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", summary: "Depolar ve issue'lar", available: false),
            OAuthProviderInfo(id: "linear", name: "Linear", symbol: "list.bullet.rectangle", summary: "Issue ve ekipler", available: false),
            OAuthProviderInfo(id: "dropbox", name: "Dropbox", symbol: "shippingbox", summary: "Dosyalar ve klasörler", available: false),
            OAuthProviderInfo(id: "microsoft", name: "Microsoft 365", symbol: "square.grid.2x2", summary: "OneDrive dosyaları", available: false),
            OAuthProviderInfo(id: "jira", name: "Jira", symbol: "checkmark.square", summary: "Projeler ve issue'lar", available: false),
            OAuthProviderInfo(id: "gitlab", name: "GitLab", symbol: "chevron.left.forwardslash.chevron.right", summary: "Projeler ve issue'lar", available: false),
            OAuthProviderInfo(id: "asana", name: "Asana", symbol: "checklist", summary: "Projeler ve görevler", available: false)
        ]
    }

    /// The server's catalogue, or the built-in pair when the server is older or unreachable.
    static func fetchOAuthProviders() async -> [OAuthProviderInfo] {
        struct Response: Decodable { let providers: [OAuthProviderInfo] }
        guard let providers = try? await authorizedGet("oauth/providers", as: Response.self).providers, !providers.isEmpty else {
            return OAuthProviderInfo.builtIn
        }
        return providers
    }

    static func fetchOAuthConnections() async throws -> [OAuthConnection] {
        struct Response: Decodable { let connections: [OAuthConnection] }
        return try await authorizedGet("oauth", as: Response.self).connections
    }

    struct ConnectionCapability: Decodable, Identifiable {
        var id: String { "\(source):\(owner):\(name)" }
        let source: String
        let owner: String
        let name: String
        let description: String
        let effect: String
        let status: String
    }

    static func fetchConnectionCapabilities() async throws -> [ConnectionCapability] {
        struct Response: Decodable { let capabilities: [ConnectionCapability] }
        return try await authorizedGet("oauth/capabilities", as: Response.self).capabilities
    }

    /// Returns the provider's own consent URL to open in an ASWebAuthenticationSession - this
    /// request itself carries the real Authorization header (a webview navigation couldn't), and
    /// the state that ties the resulting callback back to this account is embedded server-side.
    static func startOAuth(provider: String) async throws -> URL {
        struct Response: Decodable { let url: String }
        let response = try await authorizedGet("oauth/\(provider)/start", as: Response.self)
        guard let url = URL(string: response.url) else { throw RovaBackendError.invalidResponse }
        return url
    }

    /// A remote MCP server the user connected (backend src/mcp/). The key never comes back.
    struct McpServer: Decodable, Identifiable, Sendable {
        let id: Int
        let name: String
        let url: String
        let hasToken: Bool
        let toolCount: Int?
        let toolsCheckedAt: Int?
    }

    struct McpHealth: Decodable {
        let status: String
        let toolCount: Int?
    }

    static func checkMcpServer(id: Int) async throws -> McpHealth {
        try await authorizedGet("mcp/servers/\(id)/health", as: McpHealth.self)
    }

    static func fetchMcpServers() async throws -> [McpServer] {
        struct Response: Decodable { let servers: [McpServer] }
        return try await authorizedGet("mcp/servers", as: Response.self).servers
    }

    /// The backend connects and lists the server's tools before keeping it, so a wrong address or
    /// key fails here with a readable message instead of at the first use.
    static func addMcpServer(name: String, url: String, authToken: String?) async throws -> Int {
        struct Response: Decodable { let toolCount: Int }
        var body: [String: Any] = ["name": name, "url": url]
        if let authToken, !authToken.isEmpty { body["authToken"] = authToken }
        return try await authorizedPost("mcp/servers", body: body, as: Response.self).toolCount
    }

    /// Messaging apps linked to this account (backend src/channels/).
    struct ChannelStatus: Decodable, Sendable {
        struct Telegram: Decodable, Sendable { let available: Bool; let bot: String? }
        struct Link: Decodable, Identifiable, Sendable { let id: Int; let channel: String; let label: String? }
        let telegram: Telegram
        let links: [Link]
    }

    static func fetchChannels() async throws -> ChannelStatus {
        try await authorizedGet("channels", as: ChannelStatus.self)
    }

    /// A one-time link that opens the Telegram bot with the code already in it.
    static func startTelegramLink() async throws -> URL {
        struct Response: Decodable { let url: String }
        let response = try await authorizedPost("channels/telegram/link-code", body: [:], as: Response.self)
        guard let url = URL(string: response.url), url.scheme == "https", url.host == "t.me" else { throw RovaBackendError.invalidResponse }
        return url
    }

    static func unlinkChannel(id: Int) async throws {
        _ = try await authorizedMutate("channels/\(id)", method: "DELETE")
    }

    static func deleteMcpServer(id: Int) async throws {
        _ = try await authorizedMutate("mcp/servers/\(id)", method: "DELETE")
    }

    static func disconnectOAuth(provider: String) async throws {
        _ = try await authorizedMutate("oauth/\(provider)", method: "DELETE")
    }

    static func setOAuthAccessLevel(provider: String, level: String) async throws {
        guard level == "read" || level == "write", provider == "google" || provider == "notion" else { throw RovaBackendError.invalidResponse }
        _ = try await authorizedPut("oauth/\(provider)/access", body: ["accessLevel": level])
    }

    /// Sets (or, with `nil`/empty, clears) a user-chosen name for one paired PC - lets more than
    /// one paired PC be told apart ("Ofis PC", "Ev PC") instead of both showing the same
    /// hostname-derived name.
    @discardableResult
    static func renameDevice(id: String, name: String?) async throws -> DeviceStatus {
        struct Response: Decodable { let device: DeviceStatus }
        let value: Any = name ?? NSNull()
        let body = try JSONSerialization.data(withJSONObject: ["displayName": value])
        let data = try await authorizedJSON("devices/\(id)", method: "PATCH", body: body)
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw RovaBackendError.invalidResponse }
        WiqoMobileReadCache.shared.invalidate(mobileReadCacheKey("devices"))
        return decoded.device
    }

    /// Removes a PC from this account's "Bağlı cihazlar" list - the backend relay registry only,
    /// not the phone's own direct pairing (see IOSConnectionModel.forgetPairing for that).
    static func deleteDevice(id: String) async throws {
        _ = try await authorizedMutate("devices/\(id)", method: "DELETE")
        WiqoMobileReadCache.shared.invalidate(mobileReadCacheKey("devices"))
    }

    /// The interactive fallback used when the direct local connection to the paired PC isn't
    /// available (different network, PC just woke up, etc.) - relays the same already-confirmed
    /// CommandRequest through the PC's own persistent backend connection (the one automations
    /// already use) and returns the real CommandResult once the PC replies. `deviceId` targets a
    /// specific paired PC. Callers must never select an arbitrary online PC.
    static func sendDeviceCommand(_ request: CommandRequest, deviceId: String) async throws -> CommandResult {
        let body = try Self.iso8601Encoder.encode(request)
        let path = "devices/\(deviceId)/command"
        let timeout: TimeInterval = switch RovaOperationManifest.entry(for: request.type).timeoutClass {
        case .short, .medium: 35
        case .long: request.type == .sendFileToPhone ? 130 : 75
        }
        let data = try await authorizedJSON(path, method: "POST", body: body, timeout: timeout)
        do {
            return try Self.iso8601Decoder.decode(CommandResult.self, from: data)
        } catch {
            throw RovaBackendError.invalidResponse
        }
    }

    struct RelayPairingClaim: Decodable {
        let deviceId: String
        let displayName: String
        let platform: String
        let pairingToken: String
    }

    /// Claims the short-lived QR bootstrap session. The backend binds the Mac to this signed-in
    /// account; the returned pairing token is only for the existing per-command signature path.
    static func claimRelayPairing(sessionID: String, secret: String) async throws -> RelayPairingClaim {
        let body = try JSONSerialization.data(withJSONObject: ["secret": secret])
        let data = try await authorizedJSON("device-pairing/sessions/\(sessionID)/claim", method: "POST", body: body)
        do { return try JSONDecoder().decode(RelayPairingClaim.self, from: data) }
        catch { throw RovaBackendError.invalidResponse }
    }

    /// CommandRequest/CommandResult carry Date fields encoded as ISO-8601 strings everywhere else
    /// in this protocol (see RovaShared/Framing.swift's RovaWireCodec) - matched here so this
    /// relay path round-trips the same values the direct connection would have produced.
    private static let iso8601Encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let iso8601Decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func refreshProactiveSuggestions() async throws -> [ProactiveSuggestion] {
        struct Response: Decodable { let suggestions: [ProactiveSuggestion] }
        return try await authorizedPost("proactive/refresh", body: [:], as: Response.self).suggestions
    }

    static func updateProactiveSuggestion(id: Int, action: String) async throws {
        guard action == "accept" || action == "dismiss" else { return }
        _ = try await authorizedMutate("proactive/suggestions/\(id)/\(action)", method: "POST")
    }
}
