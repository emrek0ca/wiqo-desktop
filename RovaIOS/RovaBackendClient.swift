import Foundation

/// A single step of an AI-generated plan, already translated into the exact same
/// `CommandType`/`CommandPayload` pair the manual UI buttons send. The backend is the only
/// place that talks to Groq and holds the shared API key; the app never sees it.
struct PlannedCommand: Identifiable {
    let id = UUID()
    let type: CommandType
    let payload: CommandPayload
    let summary: String
    let isDestructive: Bool
}

/// Where the app's copilot/auth requests go. Fixed - there is exactly one Rova backend, and it
/// is not meant to be user-configurable in the shipped app.
enum RovaBackendConfig {
    static let baseURL = URL(string: "https://84-247-172-213.sslip.io")!
}

enum RovaBackendError: Error, LocalizedError {
    case notAuthenticated
    case network(String)
    case invalidResponse
    case declined(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Önce Rova hesabına giriş yap."
        case .network(let message): return message
        case .invalidResponse: return "Sunucudan geçersiz yanıt alındı."
        case .declined(let reason): return reason
        }
    }
}

/// Talks to Rova's own backend (see the `rova-backend` project) instead of any third-party AI
/// API directly. The backend owns the shared Groq key server-side and gates access behind a
/// login; this app only ever carries its own session token, stored in Keychain like the Mac
/// pairing token already is. This is the single integration point for both account handling and
/// the AI copilot feature.
enum RovaBackendClient {
    private static let tokenAccount = "rova-backend-token"

    static var isAuthenticated: Bool { token != nil }

    static var token: String? {
        guard let data = try? RovaKeychainStore.load(account: tokenAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func signOut() {
        try? RovaKeychainStore.delete(account: tokenAccount)
    }

    @discardableResult
    static func register(email: String, password: String) async throws -> String {
        try await authenticate(path: "auth/register", email: email, password: password)
    }

    @discardableResult
    static func login(email: String, password: String) async throws -> String {
        try await authenticate(path: "auth/login", email: email, password: password)
    }

    private static func authenticate(path: String, email: String, password: String) async throws -> String {
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])

        let (data, response) = try await send(request)
        struct AuthResponse: Decodable { let token: String }
        let decoded = try decode(AuthResponse.self, from: data, response: response)
        try RovaKeychainStore.save(Data(decoded.token.utf8), account: tokenAccount)
        return decoded.token
    }

    static func plan(for text: String, availableApps: [ApplicationID]) async throws -> [PlannedCommand] {
        guard let token else { throw RovaBackendError.notAuthenticated }
        var request = URLRequest(url: RovaBackendConfig.baseURL.appendingPathComponent("copilot/plan"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["text": text, "availableApps": availableApps.map(\.rawValue)]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request)
        if response.statusCode == 401 {
            signOut()
            throw RovaBackendError.notAuthenticated
        }
        struct StepResponse: Decodable {
            let type: CommandType
            let payload: CommandPayload
            let summary: String
            let isDestructive: Bool
        }
        struct PlanResponse: Decodable { let steps: [StepResponse] }
        let decoded = try decode(PlanResponse.self, from: data, response: response)
        return decoded.steps.map {
            PlannedCommand(type: $0.type, payload: $0.payload, summary: $0.summary, isDestructive: $0.isDestructive)
        }
    }

    // MARK: - Shared plumbing

    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RovaBackendError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw RovaBackendError.invalidResponse }
        return (data, http)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, response: HTTPURLResponse) throws -> T {
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(BackendErrorEnvelope.self, from: data))?.error.message
            if response.statusCode == 422 {
                throw RovaBackendError.declined(message ?? "İstek anlaşılamadı.")
            }
            throw RovaBackendError.network(message ?? "İstek başarısız oldu (kod \(response.statusCode)).")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RovaBackendError.invalidResponse
        }
    }
}

private struct BackendErrorEnvelope: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
}
