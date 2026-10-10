import SwiftUI

/// The user's own MCP servers, under the connected accounts: what is connected, remove it, add
/// one. The backend tests a server before keeping it, so the form reports a wrong address or key
/// straight away. A server is reached by saying its name ("Linear'da issue aç"), so the form asks
/// for a name that is worth saying.
struct McpServersSection: View {
    @State private var servers: [RovaBackendClient.McpServer] = []
    @State private var isLoading = true
    @State private var showsForm = false
    @State private var removingID: Int?
    @State private var checkingID: Int?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WiqoSettingsGroup(title: String(localized: "MCP sunucuları")) {
                if isLoading && servers.isEmpty {
                    WiqoRow(systemImage: "server.rack", title: String(localized: "Yükleniyor"), showsDivider: false) { WiqoSkeleton(width: 56, height: 28) }
                }
                ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                    WiqoRow(
                        systemImage: "server.rack",
                        title: server.name,
                        subtitle: Self.host(server.url) + (server.hasToken ? String(localized: " · anahtarlı") : "")
                            + (server.toolCount.map { " · \($0) araç" } ?? ""),
                        showsDivider: true
                    ) {
                        if removingID == server.id || checkingID == server.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Menu {
                                Button("Bağlantıyı kontrol et") { Task { await check(server) } }
                                Button("Kaldır", role: .destructive) { Task { await remove(server) } }
                            } label: { Image(systemName: "ellipsis.circle") }
                        }
                    }
                }
                WiqoRow(
                    systemImage: "plus",
                    title: String(localized: "Sunucu ekle"),
                    subtitle: servers.isEmpty ? String(localized: "Bir MCP sunucusunu adını söyleyerek kullan") : nil,
                    showsDivider: false
                ) {
                    Button("Ekle") { showsForm = true }
                        .buttonStyle(.wiqoPill(.accent))
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(WiqoTheme.red)
                    .padding(.horizontal, 6)
            }
        }
        .task { await load() }
        .sheet(isPresented: $showsForm) {
            McpServerForm { await load() }
                .presentationDetents([.medium, .large])
        }
    }

    private static func host(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            servers = try await RovaBackendClient.fetchMcpServers()
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "MCP sunucuları yüklenemedi.")
        }
    }

    private func remove(_ server: RovaBackendClient.McpServer) async {
        removingID = server.id
        defer { removingID = nil }
        do {
            try await RovaBackendClient.deleteMcpServer(id: server.id)
            servers.removeAll { $0.id == server.id }
            WiqoToastCenter.shared.show(String(localized: "Sunucu kaldırıldı"))
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "Sunucu kaldırılamadı.")
        }
    }

    private func check(_ server: RovaBackendClient.McpServer) async {
        checkingID = server.id
        defer { checkingID = nil }
        do {
            let health = try await RovaBackendClient.checkMcpServer(id: server.id)
            errorMessage = health.status == "connected" ? nil : String(localized: "MCP sunucusuna ulaşılamadı.")
            if health.status == "connected" { await load() }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "MCP bağlantısı doğrulanamadı.")
        }
    }
}

private struct McpServerForm: View {
    let onAdded: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field { case name, url, token }

    private var canAdd: Bool {
        name.trimmingCharacters(in: .whitespaces).count >= 2 && url.trimmingCharacters(in: .whitespaces).hasPrefix("https://")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("MCP sunucusu ekle")
                    .font(.title3.weight(.semibold))
                Text("Adı, sunucuyu çağırırken söyleyeceğin ad olsun (örneğin Linear). Wiqo eklemeden önce sunucuya bağlanıp araçlarını dener.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                WiqoField(isFocused: focus == .name, hasError: errorMessage != nil) {
                    TextField("Ad", text: $name)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .url }
                }
                WiqoField(isFocused: focus == .url, hasError: errorMessage != nil) {
                    TextField("https://…", text: $url)
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .url)
                        .submitLabel(.next)
                        .onSubmit { focus = .token }
                }
                WiqoField(isFocused: focus == .token, hasError: errorMessage != nil) {
                    SecureField("Anahtar (gerekmiyorsa boş bırak)", text: $token)
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .token)
                        .submitLabel(.go)
                        .onSubmit { Task { await add() } }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(WiqoTheme.red)
                        .transition(.wiqoBlur)
                }

                WiqoActionButton(title: String(localized: "Bağlan ve ekle"), isLoading: isAdding) { Task { await add() } }
                    .disabled(!canAdd)
                    .opacity(canAdd ? 1 : 0.45)
            }
            .padding(RovaDesign.screenPadding)
            .wiqoAnimation(WiqoMotion.slide(), value: errorMessage)
        }
        .background(RovaDesign.canvas)
        .task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            focus = .name
        }
    }

    private func add() async {
        guard canAdd, !isAdding else { return }
        isAdding = true
        errorMessage = nil
        defer { isAdding = false }
        do {
            let toolCount = try await RovaBackendClient.addMcpServer(
                name: name.trimmingCharacters(in: .whitespaces),
                url: url.trimmingCharacters(in: .whitespaces),
                authToken: token.trimmingCharacters(in: .whitespaces)
            )
            await onAdded()
            WiqoToastCenter.shared.show(String(localized: "Bağlandı · \(toolCount) araç"), kind: .success)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "Sunucuya bağlanılamadı.")
        }
    }
}
