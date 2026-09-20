import SwiftUI
import UIKit

// MARK: - Haptics

/// Small physical confirmations. Used sparingly: a finished action, a refused one, a selection.
@MainActor
enum WiqoHaptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func failure() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}

// MARK: - Blur transition

private struct WiqoBlurFade: ViewModifier {
    var radius: CGFloat
    var opacity: Double

    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity)
    }
}

extension AnyTransition {
    /// Content swaps by dissolving through a soft blur, so a changing label never just "jumps".
    static var wiqoBlur: AnyTransition {
        .modifier(active: WiqoBlurFade(radius: 5, opacity: 0), identity: WiqoBlurFade(radius: 0, opacity: 1))
    }
}

// MARK: - Rise-in (staggered entrance)

private struct WiqoRiseIn: ViewModifier {
    let delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .blur(radius: shown ? 0 : 4)
            .onAppear {
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(WiqoMotion.ease(0.6).delay(delay)) { shown = true }
                }
            }
    }
}

extension View {
    /// Enters by rising a few points out of blur. Give lines increasing delays to stagger them.
    func wiqoRiseIn(delay: Double = 0) -> some View {
        modifier(WiqoRiseIn(delay: delay))
    }
}

// MARK: - Shake (error feedback)

private struct WiqoShakeEffect: GeometryEffect {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(progress * .pi * 6), y: 0))
    }
}

private struct WiqoShake: ViewModifier {
    let trigger: Int
    @State private var progress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .modifier(WiqoShakeEffect(progress: progress))
            .onChange(of: trigger) { _, _ in
                guard !reduceMotion else { return }
                progress = 0
                withAnimation(.linear(duration: 0.4)) { progress = 1 }
            }
    }
}

extension View {
    /// Nudges the view side to side each time `trigger` changes - the refusal a wrong entry gets.
    func wiqoShake(trigger: Int) -> some View {
        modifier(WiqoShake(trigger: trigger))
    }
}

// MARK: - Fields and actions

/// The frame around a text field: a quiet well that lights up while focused and turns red on error.
struct WiqoField<Content: View>: View {
    var isFocused = false
    var hasError = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1.5)
            }
            .wiqoAnimation(WiqoMotion.ease(0.2), value: isFocused)
            .wiqoAnimation(WiqoMotion.ease(0.2), value: hasError)
    }

    private var borderColor: Color {
        if hasError { return WiqoTheme.red.opacity(0.7) }
        return isFocused ? WiqoTheme.ink.opacity(0.5) : .clear
    }
}

/// A full-width pill action whose label dissolves into a spinner while it works.
struct WiqoActionButton: View {
    let title: String
    var kind: WiqoPillButtonStyle.Kind = .accent
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button {
            if !isLoading { action() }
        } label: {
            ZStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(kind == .accent ? Color(uiColor: .systemBackground) : nil)
                        .transition(.wiqoBlur)
                } else {
                    Text(title)
                        .transition(.wiqoBlur)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.wiqoPill(kind))
        .wiqoAnimation(WiqoMotion.ease(0.25), value: isLoading)
    }
}

// MARK: - Sliding pill tabs

/// A row of options with one solid pill that glides to the selected item.
struct WiqoPillTabs<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var systemImage: String?

        var id: Value { value }
    }

    let options: [Option]
    @Binding var selection: Value
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = option.value == selection
                Button {
                    guard !isSelected else { return }
                    WiqoHaptics.selection()
                    withAnimation(reduceMotion ? nil : WiqoMotion.ease(0.3)) { selection = option.value }
                } label: {
                    HStack(spacing: 6) {
                        if let systemImage = option.systemImage {
                            Image(systemName: systemImage)
                        }
                        Text(option.title)
                    }
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : Color.secondary)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(WiqoTheme.ink)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(WiqoTheme.inset, in: Capsule())
    }
}

// MARK: - One-time code

/// Six boxes for a verification code. A hidden field takes the typing, so the number pad, paste and
/// the iOS "from Messages" suggestion all work.
struct WiqoOTPField: View {
    @Binding var code: String
    var length = 6
    var hasError = false
    var autoFocus = false

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .accessibilityLabel("\(length) haneli kod")

            HStack(spacing: 8) {
                ForEach(0..<length, id: \.self) { index in
                    box(at: index)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
            .accessibilityHidden(true)
        }
        .onChange(of: code) { _, newValue in
            let cleaned = String(newValue.filter(\.isNumber).prefix(length))
            if cleaned != newValue { code = cleaned }
        }
        .task {
            guard autoFocus else { return }
            // Let the sheet or step finish appearing, or the keyboard request is dropped.
            try? await Task.sleep(nanoseconds: 350_000_000)
            isFocused = true
        }
    }

    private func box(at index: Int) -> some View {
        let characters = Array(code)
        let isCurrent = isFocused && index == min(characters.count, length - 1)
        return ZStack {
            if index < characters.count {
                Text(String(characters[index]))
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .id("\(index)-\(characters[index])")
                    .transition(reduceMotion ? .identity : .wiqoBlur)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hasError ? WiqoTheme.red.opacity(0.7) : (isCurrent ? WiqoTheme.ink.opacity(0.5) : .clear), lineWidth: 1.5)
        }
        .wiqoAnimation(WiqoMotion.ease(0.2), value: code)
    }
}

// MARK: - Thinking and loading

/// Text with a soft highlight sweeping across it: "something is happening right now".
struct WiqoShimmerText: View {
    let text: String
    @State private var phase: CGFloat = -0.6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, Color.primary.opacity(0.65), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: proxy.size.width * phase)
                    }
                    .mask(Text(text))
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.7).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

/// A status sentence ("PC'ye bağlanıyorum") that shimmers while it is current and swaps to the next
/// one through a blur, instead of a spinner and a generic "thinking" label.
struct WiqoStatusLine: View {
    let text: String

    var body: some View {
        WiqoShimmerText(text: text)
            .id(text)
            .transition(.wiqoBlur)
            .wiqoAnimation(WiqoMotion.ease(0.3), value: text)
    }
}

/// A placeholder bar that pulses while real content loads.
struct WiqoSkeleton: View {
    var width: CGFloat?
    var height: CGFloat = 14
    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(WiqoTheme.inset)
            .frame(width: width, height: height)
            .opacity(dimmed ? 0.45 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dimmed = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Success check

private struct WiqoCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.54))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.78))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.86, y: rect.minY + rect.height * 0.24))
        return path
    }
}

/// A check mark that draws itself on.
struct WiqoCheckmark: View {
    var color: Color = WiqoTheme.green
    var lineWidth: CGFloat = 3
    @State private var trim: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WiqoCheckShape()
            .trim(from: 0, to: trim)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .onAppear {
                if reduceMotion {
                    trim = 1
                } else {
                    withAnimation(WiqoMotion.ease(0.5)) { trim = 1 }
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Toast

struct WiqoToast: Identifiable, Equatable {
    enum Kind { case info, success, failure }

    let id = UUID()
    let message: String
    var kind: Kind = .info
}

/// One place for short, non-blocking feedback ("Kopyalandı", "PC bağlandı"). Replaces alerts that
/// interrupt for something the user only needs to notice.
@MainActor
final class WiqoToastCenter: ObservableObject {
    static let shared = WiqoToastCenter()

    @Published private(set) var current: WiqoToast?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, kind: WiqoToast.Kind = .info) {
        dismissTask?.cancel()
        let toast = WiqoToast(message: message, kind: kind)
        current = toast
        switch kind {
        case .success: WiqoHaptics.success()
        case .failure: WiqoHaptics.failure()
        case .info: break
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled, self?.current?.id == toast.id else { return }
            self?.current = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

private struct WiqoToastView: View {
    let toast: WiqoToast

    private var symbol: String {
        switch toast.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.circle.fill"
        }
    }

    private var tint: Color {
        switch toast.kind {
        case .info: return .secondary
        case .success: return WiqoTheme.green
        case .failure: return WiqoTheme.red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(WiqoTheme.line, lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
    }
}

private struct WiqoToastHost: ViewModifier {
    @ObservedObject private var center = WiqoToastCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast = center.current {
                    WiqoToastView(toast: toast)
                        .padding(.top, 6)
                        .padding(.horizontal, 16)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .modifier(active: WiqoToastPose(offset: -24, scale: 0.94, blur: 6, opacity: 0), identity: WiqoToastPose(offset: 0, scale: 1, blur: 0, opacity: 1)),
                            removal: .opacity
                        ))
                        .onTapGesture { center.dismiss() }
                }
            }
            .animation(reduceMotion ? nil : WiqoMotion.ease(0.45), value: center.current?.id)
    }
}

private struct WiqoToastPose: ViewModifier {
    var offset: CGFloat
    var scale: CGFloat
    var blur: CGFloat
    var opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .scaleEffect(scale)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

extension View {
    /// Installs the app-wide toast presenter. Add once, near the root.
    func wiqoToastHost() -> some View {
        modifier(WiqoToastHost())
    }
}
