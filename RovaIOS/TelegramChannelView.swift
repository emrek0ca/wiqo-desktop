import SwiftUI

/// Telegram as a second way to reach Wiqo: link a chat with a one-time code, unlink it here. The
/// chat can read and write through the connected accounts; anything that needs an approval or the
/// computer stays in this app.
struct TelegramChannelSection: View {
    @Environment(\.openURL) private var openURL
    @State private var status: RovaBackendClient.ChannelStatus?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        if let status, status.telegram.available {
            VStack(alignment: .leading, spacing: 8) {
                WiqoSettingsGroup(title: "Telegram") {
                    ForEach(status.links.filter { $0.channel == "telegram" }) { link in
                        WiqoRow(systemImage: "paperplane.fill", title: link.label ?? "Telegram sohbeti", subtitle: "Bağlı", showsDivider: true) {
                            Button("Kaldır") { Task { await unlink(link) } }
                                .buttonStyle(.wiqoPill(.secondary))
                        }
                    }
                    WiqoRow(
                        systemImage: "plus",
                        title: "Telegram'dan yaz",
                        subtitle: "Botu aç, Başlat'a dokun; sohbet hesabına bağlanır",
                        showsDivider: false
                    ) {
                        if isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Bağla") { Task { await link() } }
                                .buttonStyle(.wiqoPill(.accent))
                        }
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
        } else {
            Color.clear.frame(height: 0).task { await load() }
        }
    }

    private func load() async {
        status = try? await RovaBackendClient.fetchChannels()
    }

    private func link() async {
        isWorking = true
        defer { isWorking = false }
        do {
            openURL(try await RovaBackendClient.startTelegramLink())
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Telegram bağlantısı başlatılamadı."
        }
    }

    private func unlink(_ link: RovaBackendClient.ChannelStatus.Link) async {
        do {
            try await RovaBackendClient.unlinkChannel(id: link.id)
            await load()
            WiqoToastCenter.shared.show("Bağlantı kaldırıldı")
        } catch {
            errorMessage = "Bağlantı kaldırılamadı."
        }
    }
}
