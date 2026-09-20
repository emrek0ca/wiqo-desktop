import SwiftUI

/// Shared visual language for Wiqo's card-based UI. Keep the visual tokens here so the history,
/// chat, and Mac-control surfaces read as one product.
enum RovaDesign {
    static let cardRadius: CGFloat = 20
    static let chipRadius: CGFloat = 15
    static let bubbleRadius: CGFloat = 20
    static let cardSpacing: CGFloat = 12
    static let screenPadding: CGFloat = 16
    // A fixed navy reads as near-black in dark mode (its own luminance barely rises), making any
    // text/icon/tint that uses it nearly invisible on a dark background - this resolves to the
    // brand navy in light mode and a light, still on-brand tint in dark mode instead.
    static let ink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.78, green: 0.83, blue: 0.90, alpha: 1)
            : UIColor(red: 0.055, green: 0.12, blue: 0.20, alpha: 1)
    })
    static let signal = Color(red: 0.55, green: 0.78, blue: 0.16)
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let cardSurface = Color(uiColor: .secondarySystemGroupedBackground)
}

/// A clean, borderless card surface - the base building block of the redesigned screens.
struct RovaCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10, content: { content })
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RovaDesign.cardSurface, in: RoundedRectangle(cornerRadius: RovaDesign.cardRadius, style: .continuous))
            .shadow(color: .black.opacity(0.055), radius: 12, y: 5)
    }
}

/// A small pill-shaped tappable chip, used for suggestion prompts and quick actions.
struct RovaChip: View {
    let title: String
    var systemImage: String?
    var tint: Color = RovaDesign.ink
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
        .buttonStyle(RovaPressStyle())
    }
}

/// A square-ish icon action tile for the horizontal quick-action row (lock, sleep, mute, ...).
struct RovaActionTile: View {
    let title: String
    let systemImage: String
    var tint: Color = RovaDesign.ink
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
            .frame(minWidth: 84, minHeight: 76)
            .padding(.horizontal, 8)
            .background(RovaDesign.cardSurface, in: RoundedRectangle(cornerRadius: RovaDesign.chipRadius, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
        }
        .buttonStyle(RovaPressStyle())
    }
}

/// The compact, icon-only connection signal for the main chat top bar - a laptop
/// glyph with a small status dot instead of a full text pill, closer to how ChatGPT/Gemini keep
/// their top bar minimal.
struct RovaConnectionIcon: View {
    @ObservedObject var model: IOSConnectionModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.primary)
            Circle()
                .fill(RovaConnectionStatus.color(for: model))
                .frame(width: 7, height: 7)
                .offset(x: 3, y: -2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PC bağlantısı: \(RovaConnectionStatus.label(for: model))")
    }
}

@MainActor
enum RovaConnectionStatus {
    static func label(for model: IOSConnectionModel) -> String {
        if !model.isPaired { return "PC ekle" }
        return model.userFacingConnectionLabel
    }

    static func color(for model: IOSConnectionModel) -> Color {
        if !model.isPaired { return .secondary }
        if model.isReconnecting { return .orange }
        if model.isUsingRelay, model.state != .connected { return .blue }
        switch model.state {
        case .connected: return RovaDesign.signal
        case .connecting: return .orange
        case .failed, .disconnected: return .red
        }
    }
}

private struct RovaPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
