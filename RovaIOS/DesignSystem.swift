import SwiftUI

/// Shared visual language for Rova's card-based UI - one place for radii/spacing so the chat
/// screen and the Mac control screen read as the same app instead of two different ones.
enum RovaDesign {
    static let cardRadius: CGFloat = 22
    static let chipRadius: CGFloat = 18
    static let bubbleRadius: CGFloat = 22
    static let cardSpacing: CGFloat = 14
    static let screenPadding: CGFloat = 16
}

/// A clean, borderless card surface - the base building block of the redesigned screens.
struct RovaCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10, content: { content })
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: RovaDesign.cardRadius, style: .continuous))
    }
}

/// A small pill-shaped tappable chip, used for suggestion prompts and quick actions.
struct RovaChip: View {
    let title: String
    var systemImage: String?
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: RovaDesign.chipRadius, style: .continuous))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

/// A square-ish icon action tile for the horizontal quick-action row (lock, sleep, mute, ...).
struct RovaActionTile: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(isDestructive ? .red : tint)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: 84, height: 76)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: RovaDesign.chipRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
