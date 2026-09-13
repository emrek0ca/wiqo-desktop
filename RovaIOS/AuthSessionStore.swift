import Foundation

/// Single reactive source of truth for the Rova account session, shared by the app root
/// (which gates the whole app behind login), the auth screen, and anything that needs to sign
/// out or react to a session becoming invalid (e.g. an expired token during a copilot request).
@MainActor
final class AuthSessionStore: ObservableObject {
    @Published private(set) var isAuthenticated: Bool

    init() {
        isAuthenticated = RovaBackendClient.isAuthenticated
    }

    func refresh() {
        isAuthenticated = RovaBackendClient.isAuthenticated
    }

    func signOut() {
        RovaBackendClient.signOut()
        isAuthenticated = false
    }
}
