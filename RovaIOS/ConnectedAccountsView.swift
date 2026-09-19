import AuthenticationServices
import SwiftUI

/// Drives one ASWebAuthenticationSession at a time and hands back whatever URL the "wiqo://"
/// custom scheme redirect (see rova-backend's routes/oauth.ts) carried - the session intercepts
/// that navigation itself and never actually loads it, so this is the only way the outcome
/// (success/error/provider/message) gets back into the app.
@MainActor
private final class OAuthSessionRunner: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }

    func run(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "wiqo") { [weak self] callbackURL, error in
                self?.session = nil
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: RovaBackendError.invalidResponse)
                }
            }
            session.presentationContextProvider = self
            // Sharing the system browser's existing Google/Notion session is exactly what makes
            // this feel like one tap instead of a fresh login every time - the account being
            // connected is deliberately the user's own real one, kept isolated per-app only
            // matters for privacy-sensitive sign-in-with flows, not for granting API access.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: RovaBackendError.invalidResponse)
            }
        }
    }
}

struct ConnectedAccountsView: View {
    @State private var connections: [RovaBackendClient.OAuthConnection] = []
    @State private var isLoading = true
    @State private var connectingProvider: String?
    @State private var errorMessage: String?
    @State private var runner = OAuthSessionRunner()

    private let providers: [(id: String, name: String, icon: String, description: String)] = [
        ("google", "Google", "calendar", "Takvim, Gmail, Docs, Sheets, Drive, Kişiler - PC bağlı olmasa bile çalışır"),
        ("notion", "Notion", "doc.text", "Sayfa arama, okuma ve oluşturma")
    ]

    private func connection(for provider: String) -> RovaBackendClient.OAuthConnection? {
        connections.first { $0.provider == provider }
    }

    var body: some View {
        List {
            Section {
                Text("Wiqo'nun bu hesaplara erişimi yalnızca kendi kullanıcı hesabına özeldir; bağlantıyı istediğin an buradan kesebilirsin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(providers, id: \.id) { provider in
                    row(for: provider)
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Bağlı Hesaplar")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(for provider: (id: String, name: String, icon: String, description: String)) -> some View {
        let connected = connection(for: provider.id)
        return HStack(spacing: 12) {
            Image(systemName: provider.icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).font(.subheadline.weight(.medium))
                Text(connected != nil ? (connected?.accountLabel ?? "Bağlı") : provider.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if connectingProvider == provider.id {
                ProgressView()
            } else if connected != nil {
                Button("Kes", role: .destructive) {
                    Task { await disconnect(provider.id) }
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
            } else {
                Button("Bağlan") {
                    Task { await connect(provider.id) }
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        connections = (try? await RovaBackendClient.fetchOAuthConnections()) ?? []
    }

    private func connect(_ provider: String) async {
        errorMessage = nil
        connectingProvider = provider
        defer { connectingProvider = nil }
        do {
            let authURL = try await RovaBackendClient.startOAuth(provider: provider)
            let callbackURL = try await runner.run(url: authURL)
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
            let status = components?.queryItems?.first(where: { $0.name == "status" })?.value
            if status == "success" {
                await load()
            } else {
                let message = components?.queryItems?.first(where: { $0.name == "message" })?.value
                errorMessage = message ?? "Bağlantı tamamlanamadı."
            }
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            // The user closed the sheet themselves - not an error worth showing.
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Bağlantı başlatılamadı."
        }
    }

    private func disconnect(_ provider: String) async {
        errorMessage = nil
        do {
            try await RovaBackendClient.disconnectOAuth(provider: provider)
            connections.removeAll { $0.provider == provider }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Bağlantı kesilemedi."
        }
    }
}
