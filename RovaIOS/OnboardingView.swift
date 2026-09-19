import SwiftUI

/// The first-login guide stays in one sheet while it explains the only setup dependency: the
/// Mac app must be installed before the phone can scan a pairing QR code.
struct WiqoWelcomeView: View {
    let onDismiss: () -> Void
    let onConnect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .welcome

    private enum Step {
        case welcome
        case download
    }

    var body: some View {
        Group {
            switch step {
            case .welcome:
                welcomeStep
            case .download:
                downloadStep
            }
        }
        .padding(24)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: step)
    }

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Wiqo'ya hoş geldin")
                .font(.title2.weight(.bold))

            Text("Bilgisayarını telefonundan, konuşarak yönet.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                guideRow("Sesi kıs", systemImage: "speaker.wave.1.fill")
                guideRow("Bir uygulamayı kapat", systemImage: "xmark.app.fill")
                guideRow("Bir dosya bul", systemImage: "doc.text.magnifyingglass")
            }
            .padding(.top, 4)

            Text("PC'ni bağlamak için önce Mac uygulamasını indirmen gerekiyor.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Button("Bağla") {
                step = .download
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)

            Button("Şimdi değil", action: onDismiss)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }

    private var downloadStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Önce Wiqo'yu bilgisayarına indir")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            Text("wiqoai.com'a gir, Mac uygulamasını indirip aç. Sonra bu telefondan QR kodu tara.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Link(destination: WiqoWebsite.downloadURL) {
                Label("wiqoai.com'u aç", systemImage: "safari")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("QR taramaya geç", action: onConnect)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

            Button("Şimdi değil", action: onDismiss)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }

    private func guideRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text("\u{201C}\(title)\u{201D}")
                .font(.subheadline.weight(.medium))
            Spacer()
        }
    }
}
