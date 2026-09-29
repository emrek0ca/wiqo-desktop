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

    private let providers: [(id: String, name: String, icon: String)] = [
        ("google", "Google", "calendar"),
        ("notion", "Notion", "doc.text")
    ]

    private func connection(for provider: String) -> RovaBackendClient.OAuthConnection? {
        connections.first { $0.provider == provider }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WiqoSettingsGroup {
                    ForEach(providers, id: \.id) { provider in
                        row(for: provider, isLast: provider.id == providers.last?.id)
                    }
                }

                ForEach(providers, id: \.id) { provider in
                    if let connected = connection(for: provider.id) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(provider.name) erişimi").font(.subheadline.weight(.medium))
                            Picker("\(provider.name) erişimi", selection: Binding(
                                get: { connected.accessLevel ?? "write" },
                                set: { level in Task { await changeAccess(provider.id, to: level) } }
                            )) {
                                Text("Sadece oku").tag("read")
                                Text("Oku ve yaz").tag("write")
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }

                McpServersSection()

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(WiqoTheme.red)
                        .padding(.horizontal, 6)
                        .transition(.wiqoBlur)
                }
            }
            .padding(RovaDesign.screenPadding)
            .wiqoAnimation(WiqoMotion.slide(), value: errorMessage)
        }
        .background(RovaDesign.canvas)
        .navigationTitle("Bağlı Hesaplar")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(for provider: (id: String, name: String, icon: String), isLast: Bool) -> some View {
        let connected = connection(for: provider.id)
        return WiqoRow(
            systemImage: provider.icon,
            title: provider.name,
            subtitle: connected != nil ? (connected?.accountLabel ?? "Bağlı") : "Bağlı değil",
            showsDivider: !isLast
        ) {
            if connectingProvider == provider.id {
                ProgressView().controlSize(.small)
            } else if isLoading && connections.isEmpty {
                WiqoSkeleton(width: 56, height: 28)
            } else if connected != nil {
                Button("Kes") {
                    Task { await disconnect(provider.id) }
                }
                .buttonStyle(.wiqoPill(.secondary))
            } else {
                Button("Bağlan") {
                    Task { await connect(provider.id) }
                }
                .buttonStyle(.wiqoPill(.accent))
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            connections = try await RovaBackendClient.fetchOAuthConnections()
            errorMessage = nil
        } catch {
            errorMessage = "Bağlı hesaplar yüklenemedi. Yeniden denemek için aşağı çek."
        }
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
                WiqoToastCenter.shared.show("Hesap bağlandı", kind: .success)
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
            WiqoToastCenter.shared.show("Bağlantı kesildi")
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Bağlantı kesilemedi."
        }
    }

    private func changeAccess(_ provider: String, to level: String) async {
        errorMessage = nil
        do {
            try await RovaBackendClient.setOAuthAccessLevel(provider: provider, level: level)
            await load()
        } catch {
            errorMessage = "Erişim seviyesi değiştirilemedi. Tekrar dene."
        }
    }
}
