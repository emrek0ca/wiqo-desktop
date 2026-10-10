import SwiftUI

/// A titled card of rows, the building block of every settings-style screen.
struct WiqoSettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: WiqoTheme.cardRadius, style: .continuous))
            .wiqoGlass()
        }
    }
}

extension View {
    @ViewBuilder
    func wiqoGlass(radius: CGFloat = WiqoTheme.cardRadius) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(WiqoTheme.line, lineWidth: 0.5)
                }
        } else {
            self.background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

struct WiqoChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(WiqoTheme.ink3)
            .accessibilityHidden(true)
    }
}

/// One row: a tinted icon tile, a title with an optional second line, and whatever belongs on the
/// trailing edge (a chevron by default).
enum WiqoBrandIcon {
    static func assetName(for provider: String) -> String? {
        switch provider.lowercased() {
        case "google", "gmail", "calendar", "drive", "contacts": "ConnectorGoogle"
        case "notion": "ConnectorNotion"
        case "slack": "ConnectorSlack"
        case "github": "ConnectorGitHub"
        case "linear": "ConnectorLinear"
        case "dropbox": "ConnectorDropbox"
        case "discord": "ConnectorDiscord"
        default: nil
        }
    }
}

struct WiqoRow<Trailing: View>: View {
    let systemImage: String
    var brand: String? = nil
    var tint: Color = WiqoTheme.ink
    let title: String
    var subtitle: String?
    var isDestructive = false
    var showsDivider = true
    let trailing: Trailing

    init(
        systemImage: String,
        brand: String? = nil,
        tint: Color = WiqoTheme.ink,
        title: String,
        subtitle: String? = nil,
        isDestructive: Bool = false,
        showsDivider: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.systemImage = systemImage
        self.brand = brand
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.isDestructive = isDestructive
        self.showsDivider = showsDivider
        self.trailing = trailing()
    }

    var body: some View {
        let accent = isDestructive ? WiqoTheme.red : tint
        HStack(spacing: 12) {
            if let brand, let asset = WiqoBrandIcon.assetName(for: brand) {
                Image(asset).resizable().scaledToFit()
                    .frame(width: 22, height: 22)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(WiqoTheme.tint(accent), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isDestructive ? WiqoTheme.red : Color.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(WiqoTheme.line)
                    .frame(height: 0.5)
                    .padding(.leading, 54)
            }
        }
        .contentShape(Rectangle())
    }
}

extension WiqoRow where Trailing == WiqoChevron {
    init(
        systemImage: String,
        tint: Color = WiqoTheme.ink,
        title: String,
        subtitle: String? = nil,
        isDestructive: Bool = false,
        showsDivider: Bool = true
    ) {
        self.init(
            systemImage: systemImage,
            tint: tint,
            title: title,
            subtitle: subtitle,
            isDestructive: isDestructive,
            showsDivider: showsDivider
        ) { WiqoChevron() }
    }
}

/// Press feedback for a whole row: the row dims to a soft wash while held.
struct WiqoRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.06) : Color.clear)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// How much of a daily allowance is used. Turns orange near the limit.
struct WiqoUsageBar: View {
    let title: String
    let used: Int
    let limit: Int

    private var fraction: CGFloat {
        guard limit > 0 else { return 0 }
        return min(max(CGFloat(used) / CGFloat(limit), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(used) / \(limit)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(WiqoTheme.inset)
                    Capsule()
                        .fill(fraction >= 0.9 ? WiqoTheme.orange : WiqoTheme.ink)
                        .frame(width: max(proxy.size.width * fraction, fraction > 0 ? 6 : 0))
                }
            }
            .frame(height: 6)
            .wiqoAnimation(WiqoMotion.slide(0.5), value: used)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(used) / \(limit)")
    }
}

/// A whole card that is one button: it eases down slightly while pressed.
struct WiqoCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
