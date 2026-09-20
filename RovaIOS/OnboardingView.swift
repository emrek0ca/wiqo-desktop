import SwiftUI

/// The first-login guide stays in one sheet while it explains the only setup dependency: the
/// Mac app must be installed before the phone can scan a pairing QR code. Lines rise in one after
/// another and the two steps slide past each other, so the first two minutes feel guided rather
/// than like a form.
struct WiqoWelcomeView: View {
    let onDismiss: () -> Void
    let onConnect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var step: Step = .welcome

    private enum Step: Int {
        case welcome
        case download
    }

    private var slide: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case .welcome:
                    welcomeStep
                        .transition(slide)
                case .download:
                    downloadStep
                        .transition(slide)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            stepDots
                .padding(.top, 12)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .wiqoAnimation(WiqoMotion.slide(0.45), value: step)
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach([Step.welcome, Step.download], id: \.rawValue) { item in
                Capsule()
                    .fill(item == step ? WiqoTheme.ink : WiqoTheme.lineStrong)
                    .frame(width: item == step ? 18 : 6, height: 6)
            }
        }
        .wiqoAnimation(WiqoMotion.ease(0.3), value: step)
        .accessibilityHidden(true)
    }

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .nonRepeating)
                .accessibilityHidden(true)
                .wiqoRiseIn()

            Text("Wiqo'ya hoş geldin")
                .font(.title2.weight(.bold))
                .wiqoRiseIn(delay: 0.08)

            Text("Bilgisayarını telefonundan, konuşarak yönet.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .wiqoRiseIn(delay: 0.16)

            VStack(alignment: .leading, spacing: 10) {
                guideRow("Sesi kıs", systemImage: "speaker.wave.1.fill")
                    .wiqoRiseIn(delay: 0.26)
                guideRow("Bir uygulamayı kapat", systemImage: "xmark.app.fill")
                    .wiqoRiseIn(delay: 0.34)
                guideRow("Bir dosya bul", systemImage: "doc.text.magnifyingglass")
                    .wiqoRiseIn(delay: 0.42)
            }
            .padding(.top, 4)

            Spacer(minLength: 8)

            Text("PC'ni bağlamak için önce Mac uygulamasını indirmen gerekiyor.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .wiqoRiseIn(delay: 0.5)

            WiqoActionButton(title: "Bağla") { step = .download }
                .wiqoRiseIn(delay: 0.56)

            Button("Şimdi değil", action: onDismiss)
                .buttonStyle(.wiqoPill(.ghost))
        }
    }

    private var downloadStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
                .wiqoRiseIn()

            Text("Önce Wiqo'yu bilgisayarına indir")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .wiqoRiseIn(delay: 0.08)

            Text("wiqoai.com'a gir, Mac uygulamasını indirip aç. Sonra bu telefondan QR kodu tara.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .wiqoRiseIn(delay: 0.16)

            Spacer(minLength: 8)

            WiqoActionButton(title: "wiqoai.com'u aç") { openURL(WiqoWebsite.downloadURL) }
                .wiqoRiseIn(delay: 0.28)

            WiqoActionButton(title: "QR taramaya geç", kind: .secondary, action: onConnect)
                .wiqoRiseIn(delay: 0.34)

            HStack(spacing: 4) {
                Button("Geri") { step = .welcome }
                Text("·").foregroundStyle(.tertiary)
                Button("Şimdi değil", action: onDismiss)
            }
            .buttonStyle(.plain)
            .font(.footnote.weight(.medium))
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
