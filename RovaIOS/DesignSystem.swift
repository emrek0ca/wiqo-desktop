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
    static let brandInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.78, green: 0.83, blue: 0.90, alpha: 1)
            : UIColor(red: 0.055, green: 0.12, blue: 0.20, alpha: 1)
    })
    /// The accent the person picked (Ayarlar > Görünüm): the app's tint, so every use follows the choice on Chat, Act and the sidebar.
    static var ink: Color { Color.accentColor }
    static let signal = Color(red: 0.55, green: 0.78, blue: 0.16)
    /// The one background of every screen (Settings, sheets, the paywall, Act) - white in light mode, black in dark.
    static let canvas = Color(uiColor: .systemBackground)
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
            .wiqoCard(radius: RovaDesign.cardRadius)
    }
}

enum WiqoToolChipTone: Equatable {
    case neutral
    case active
    case success
    case attention
    case failure

    var tint: Color {
        switch self {
        case .neutral: return .secondary
        case .active: return RovaDesign.ink
        case .success: return .green
        case .attention: return .orange
        case .failure: return .red
        }
    }

    var systemImage: String {
        switch self {
        case .neutral: return "circle"
        case .active: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .attention: return "hand.raised.fill"
        case .failure: return "exclamationmark.circle.fill"
        }
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
            .wiqoCard(radius: RovaDesign.chipRadius)
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
        Image(systemName: "laptopcomputer")
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(model.isPaired ? Color.primary.opacity(0.85) : Color.secondary)
            .overlay(alignment: .bottomTrailing) {
                // One small dot, set off from the glyph by a ring of the background colour; none while no PC is paired.
                if model.isPaired {
                    Circle()
                        .fill(RovaConnectionStatus.color(for: model))
                        .frame(width: 6, height: 6)
                        .padding(1.5)
                        .background(Color(uiColor: .systemBackground), in: Circle())
                        .offset(x: 5, y: 4)
                }
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
        if model.isReconnecting { return Color(red: 0.85, green: 0.62, blue: 0.28) }
        if model.isUsingRelay, model.state != .connected { return Color(red: 0.36, green: 0.52, blue: 0.70) }
        switch model.state {
        case .connected: return Color(red: 0.33, green: 0.62, blue: 0.42)
        case .connecting: return Color(red: 0.85, green: 0.62, blue: 0.28)
        case .failed, .disconnected: return Color(red: 0.78, green: 0.34, blue: 0.32)
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
