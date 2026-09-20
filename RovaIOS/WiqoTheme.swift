import SwiftUI

/// Design tokens, motion and small surfaces shared by Wiqo's agent UI (tool chips, approval,
/// code, recommendation and context cards). One soft surface scale, semantic tints and a single
/// easing curve, so every card that appears in a conversation reads as the same product.
enum WiqoTheme {
    static let ink = RovaDesign.ink
    static let surface = RovaDesign.cardSurface
    /// Recessed fill for chips and code wells.
    static let inset = Color(uiColor: .tertiarySystemFill)
    static let line = Color.primary.opacity(0.08)
    static let lineStrong = Color.primary.opacity(0.18)
    static let ink3 = Color(uiColor: .tertiaryLabel)

    static let green = Color.green
    static let red = Color.red
    static let orange = Color.orange

    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10

    /// The soft wash behind a semantic colour (success pill, added diff line, ...).
    static func tint(_ color: Color) -> Color { color.opacity(0.12) }
}

enum WiqoMotion {
    /// The shared ease-out curve: quick to respond, long soft landing.
    static func ease(_ duration: Double = 0.35) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }

    /// Used when a card grows or shrinks to fit new content.
    static func slide(_ duration: Double = 0.36) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }
}

struct WiqoOffsetFade: ViewModifier {
    var y: CGFloat
    var opacity: Double

    func body(content: Content) -> some View {
        content.offset(y: y).opacity(opacity)
    }
}

extension AnyTransition {
    /// Rises 8pt while fading in - how cards and rows enter the conversation.
    static var wiqoFadeUp: AnyTransition {
        .modifier(active: WiqoOffsetFade(y: 8, opacity: 0), identity: WiqoOffsetFade(y: 0, opacity: 1))
    }

    /// A small confirmation pill "pops" in from slightly smaller.
    static var wiqoPop: AnyTransition {
        .scale(scale: 0.94).combined(with: .opacity)
    }
}

private struct WiqoAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that stays still when the user asked for reduced motion.
    func wiqoAnimation<Value: Equatable>(_ animation: Animation = WiqoMotion.ease(), value: Value) -> some View {
        modifier(WiqoAnimationModifier(animation: animation, value: value))
    }

    /// The card surface: a quiet fill, a hairline edge and a very soft lift.
    func wiqoCard(radius: CGFloat = WiqoTheme.cardRadius) -> some View {
        background(WiqoTheme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(WiqoTheme.line, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }
}

/// Pill-shaped actions used in card footers: one solid "accent" per card, quiet ones around it.
struct WiqoPillButtonStyle: ButtonStyle {
    enum Kind {
        case accent
        case secondary
        case ghost
    }

    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(background, in: Capsule())
            .overlay {
                if kind == .secondary {
                    Capsule().strokeBorder(WiqoTheme.line, lineWidth: 0.5)
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .accent: return Color(uiColor: .systemBackground)
        case .secondary: return .primary
        case .ghost: return .secondary
        }
    }

    private var background: Color {
        switch kind {
        case .accent: return WiqoTheme.ink
        case .secondary: return WiqoTheme.surface
        case .ghost: return .clear
        }
    }
}

extension ButtonStyle where Self == WiqoPillButtonStyle {
    static func wiqoPill(_ kind: WiqoPillButtonStyle.Kind = .secondary) -> WiqoPillButtonStyle {
        WiqoPillButtonStyle(kind: kind)
    }
}
