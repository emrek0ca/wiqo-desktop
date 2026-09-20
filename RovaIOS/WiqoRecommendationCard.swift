import SwiftUI

/// A suggestion from Wiqo with the choice to take it or leave it. One clear action, one quiet way
/// out.
struct WiqoRecommendationCard: View {
    let title: String
    let message: String
    let primaryTitle: String
    var dismissTitle = "Kapat"
    let onPrimary: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(WiqoTheme.line).frame(height: 0.5)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(dismissTitle, action: onDismiss)
                    .buttonStyle(.wiqoPill(.ghost))
                Button(primaryTitle, action: onPrimary)
                    .buttonStyle(.wiqoPill(.accent))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .wiqoCard()
        .transition(reduceMotion ? .identity : .wiqoFadeUp)
    }
}
