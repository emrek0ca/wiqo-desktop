import SwiftUI

/// The first-login guide takes the user straight to the Mac's pairing code.
struct WiqoWelcomeView: View {
    let onDismiss: () -> Void
    let onConnect: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("PC'ni bağla")
                .font(.title2.weight(.bold))

            Text("PC'nde Wiqo'yu aç, ekrandaki QR kodu tara ve ilk komutunu ver.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            WiqoActionButton(title: "PC uygulamasını indir") {
                openURL(WiqoWebsite.downloadURL)
            }

            WiqoActionButton(title: "QR kodu tara", kind: .secondary, action: onConnect)

            Button("Şimdi değil", action: onDismiss)
                .buttonStyle(.plain)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
