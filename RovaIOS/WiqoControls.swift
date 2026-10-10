import AVFoundation
import Combine
import CoreHaptics
import SwiftUI
import UIKit

// MARK: - Haptics

/// Small physical confirmations. Used sparingly: a finished action, a refused one, a selection.
@MainActor
enum WiqoHaptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func failure() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }

    private static var engine: CHHapticEngine?

    /// The microphone opened: a low rumble under the thumb that lifts off and fades over two seconds, like a launch, so the person feels what they are holding.
    /// Core Haptics where the hardware has it; a run of softening taps otherwise.
    static func listeningStart() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            let taps: [(Double, CGFloat)] = [(0, 1.0), (0.10, 0.9), (0.22, 0.85), (0.36, 0.75), (0.52, 0.65), (0.70, 0.55),
                                             (0.90, 0.45), (1.12, 0.35), (1.36, 0.26), (1.62, 0.18), (1.88, 0.10)]
            for (delay, intensity) in taps {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: intensity)
                }
            }
            return
        }
        do {
            if engine == nil {
                let created = try CHHapticEngine()
                created.isAutoShutdownEnabled = true
                created.resetHandler = { [weak created] in try? created?.start() }
                engine = created
            }
            guard let engine else { return }
            try engine.start()
            let length = 2.0
            let events = [
                // Ignition: a firm knock.
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                ], relativeTime: 0),
                // The body of the rumble: deep, long.
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.12)
                ], relativeTime: 0.02, duration: length),
                // Texture on top: the crackle of the engines, which dies away sooner than the rumble.
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.75)
                ], relativeTime: 0.02, duration: 1.3)
            ]
            // Lift-off: quick to full, held, then a long smooth fall to nothing at two seconds.
            let fade = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                .init(relativeTime: 0, value: 0.55),
                .init(relativeTime: 0.12, value: 1.0),
                .init(relativeTime: 0.55, value: 0.92),
                .init(relativeTime: 1.0, value: 0.62),
                .init(relativeTime: 1.5, value: 0.28),
                .init(relativeTime: 1.85, value: 0.08),
                .init(relativeTime: length, value: 0)
            ], relativeTime: 0)
            // The rumble gets a little rounder as it fades.
            let sharpness = CHHapticParameterCurve(parameterID: .hapticSharpnessControl, controlPoints: [
                .init(relativeTime: 0, value: 0.7),
                .init(relativeTime: 0.8, value: 0.4),
                .init(relativeTime: length, value: 0.1)
            ], relativeTime: 0)
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameterCurves: [fade, sharpness]))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.8)
        }
    }
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
    var horizontalPadding: CGFloat = 14
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
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, horizontalPadding)
                    .frame(minHeight: 38)
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
    /// Sheets are separate presentation layers, so each one installs its own host. Only the
    /// topmost host shows the toast; otherwise it would be drawn underneath the sheet.
    @Published private(set) var topLevel = 0
    private var hostLevels: [UUID: Int] = [:]
    private var dismissTask: Task<Void, Never>?

    func register(host id: UUID, level: Int) {
        hostLevels[id] = level
        topLevel = hostLevels.values.max() ?? 0
    }

    func unregister(host id: UUID) {
        hostLevels[id] = nil
        topLevel = hostLevels.values.max() ?? 0
    }

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
    let level: Int
    @ObservedObject private var center = WiqoToastCenter.shared
    @State private var hostID = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onAppear { center.register(host: hostID, level: level) }
            .onDisappear { center.unregister(host: hostID) }
            .overlay(alignment: .top) {
                if let toast = center.current, center.topLevel == level {
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
    /// Installs a toast presenter. The root uses level 0; each sheet that can raise a toast adds
    /// its own with a higher level, so the toast always appears above whatever is on top.
    func wiqoToastHost(level: Int = 0) -> some View {
        modifier(WiqoToastHost(level: level))
    }
}

// MARK: - Confirmations

extension View {
    /// A confirmation that always opens centred on the screen. `confirmationDialog` anchors itself to the view it is
    /// attached to (a popover on newer iOS), so on a scroll view or a whole screen it appears at some unrelated spot.
    /// A cancel button ("Vazgeç") is added here; the actions only need the confirming button.
    func wiqoConfirmation<A: View, M: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        onCancel: @escaping () -> Void = {},
        @ViewBuilder actions: @escaping () -> A,
        @ViewBuilder message: @escaping () -> M
    ) -> some View {
        alert(title, isPresented: isPresented) {
            actions()
            Button("Vazgeç", role: .cancel, action: onCancel)
        } message: {
            message()
        }
    }

    func wiqoConfirmation<A: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        onCancel: @escaping () -> Void = {},
        @ViewBuilder actions: @escaping () -> A
    ) -> some View {
        wiqoConfirmation(title, isPresented: isPresented, onCancel: onCancel, actions: actions) { EmptyView() }
    }

    /// The same for a confirmation about one item: the item is captured when the alert opens, so the confirming
    /// button still has it after the binding is cleared.
    func wiqoConfirmation<Item, A: View, M: View>(
        item: Binding<Item?>,
        title: @escaping (Item) -> String,
        @ViewBuilder actions: @escaping (Item) -> A,
        @ViewBuilder message: @escaping (Item) -> M
    ) -> some View {
        alert(
            item.wrappedValue.map(title) ?? "",
            isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
            presenting: item.wrappedValue
        ) { value in
            actions(value)
            Button("Vazgeç", role: .cancel) {}
        } message: { value in
            message(value)
        }
    }
}

// MARK: - Chat / Act switch

/// What the Chat side is doing, readable from the Home bar without owning the conversation.
@MainActor
final class WiqoChatActivity: ObservableObject {
    static let shared = WiqoChatActivity()
    @Published var isWorking = false
}

extension Notification.Name {
    /// The segment of the screen already showing was tapped again: Chat puts the cursor in the composer.
    static let wiqoFocusComposer = Notification.Name("wiqo.focus-composer")
    /// Act goes back to its project list.
    static let wiqoActHome = Notification.Name("wiqo.act-home")
}

/// The two-way switch in the Home bar: slim, text only, one soft thumb that glides, a small status mark per side (work in progress / something new).
struct WiqoModeSwitch<Value: Hashable>: View {
    enum Badge { case none, working, unread }

    struct Option: Identifiable {
        let value: Value
        let title: String
        var badge: Badge = .none
        var id: Value { value }
    }

    let options: [Option]
    @Binding var selection: Value
    /// The side that is already showing was tapped again.
    var onReselect: (Value) -> Void = { _ in }
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if #available(iOS 26.0, *) {
            glassSwitch
        } else {
            classicSwitch
        }
    }

    private func tap(_ option: Option) {
        WiqoHaptics.selection()
        if option.value == selection {
            onReselect(option.value)
        } else {
            withAnimation(reduceMotion ? nil : WiqoMotion.ease(0.3)) { selection = option.value }
        }
    }

    private func label(_ option: Option, isSelected: Bool) -> some View {
        HStack(spacing: 5) {
            Text(option.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            badge(option.badge)
        }
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .frame(minWidth: 74, minHeight: 32)
        .padding(.horizontal, 4)
    }

    /// iOS 26: the track and the thumb are Liquid Glass; the thumb is a glass lens tinted with the app's accent that morphs from one side to the other.
    @available(iOS 26.0, *)
    private var glassSwitch: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(options) { option in
                    let isSelected = option.value == selection
                    Button { tap(option) } label: {
                        label(option, isSelected: isSelected)
                            .background {
                                if isSelected {
                                    Capsule()
                                        .fill(Color.clear)
                                        .glassEffect(.regular.tint(Color.accentColor.opacity(0.22)).interactive(), in: Capsule())
                                        .glassEffectID("thumb", in: thumb)
                                }
                            }
                            // The visible switch is 32 pt tall; the touch area is the full bar height.
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.vertical, -6)
            .padding(2)
            .glassEffect(.regular, in: Capsule())
        }
    }

    private var classicSwitch: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isSelected = option.value == selection
                Button { tap(option) } label: {
                    label(option, isSelected: isSelected)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color.primary.opacity(0.12))
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, -6)
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    @ViewBuilder
    private func badge(_ badge: Badge) -> some View {
        switch badge {
        case .none:
            EmptyView()
        case .working:
            ProgressView().controlSize(.mini).scaleEffect(0.8)
        case .unread:
            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
        }
    }
}

// MARK: - Voice session

/// What a spoken sentence means. Short, known commands are carried out on the phone at once; anything else is a request for the task.
enum WiqoVoiceIntent: Equatable {
    case stop, undo, repeatLast, confirm, decline
    case showPreview, showCode, showHistory, fullscreen, reload
    case theme(WiqoAppearance.Theme)
    case textSize(Int)
    case apply(String)

    /// The sentence without case, accents or punctuation, so "Geri al!" and "geri al" are the same.
    static func folded(_ spoken: String) -> String {
        spoken.lowercased(with: Locale(identifier: "tr_TR"))
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let table: [(Set<String>, WiqoVoiceIntent)] = [
        (["durdur", "dur", "dur artik", "iptal", "iptal et", "birak", "vazgec"], .stop),
        (["geri al", "son degisikligi geri al", "geri al lutfen"], .undo),
        (["tekrar yap", "bir daha", "bir daha yap", "aynisini yap", "tekrarla"], .repeatLast),
        (["evet", "onayla", "evet yap", "olur", "tamam yap"], .confirm),
        (["hayir", "yapma", "hayir yapma"], .decline),
        (["onizleme", "onizlemeyi goster", "sayfayi goster"], .showPreview),
        (["kod", "kodu goster"], .showCode),
        (["gecmis", "gecmisi goster"], .showHistory),
        (["tam ekran", "tam ekran yap"], .fullscreen),
        (["yenile", "sayfayi yenile"], .reload),
        (["koyu tema", "karanlik mod", "karanlik tema", "koyu mod"], .theme(.dark)),
        (["acik tema", "aydinlik mod", "aydinlik tema", "acik mod"], .theme(.light)),
        (["sistem temasi"], .theme(.system)),
        (["yaziyi buyut", "yazi boyutunu artir", "yazilari buyut"], .textSize(1)),
        (["yaziyi kucult", "yazi boyutunu azalt", "yazilari kucult"], .textSize(-1))
    ]

    static func parse(_ spoken: String) -> WiqoVoiceIntent {
        let words = folded(spoken)
        for (phrases, intent) in table where phrases.contains(words) { return intent }
        return .apply(spoken.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A request that removes or overwrites something: it is read back and waits for "evet" or a tap on the orb.
    static func isRisky(_ spoken: String) -> Bool {
        let words = Set(folded(spoken).split(separator: " ").map(String.init))
        let hot: Set<String> = ["sil", "silsin", "sileyim", "silelim", "kaldir", "temizle", "bosalt", "hepsini"]
        return !words.isDisjoint(with: hot) || folded(spoken).contains("uzerine yaz")
    }
}

extension WiqoAppearance {
    /// "Koyu tema", "yazıyı büyüt": the same settings Ayarlar changes, applied at once (the app root listens to them).
    static func apply(theme: Theme) {
        UserDefaults.standard.set(theme.rawValue, forKey: themeKey)
    }

    static func shiftTextSize(by step: Int) {
        let order: [TextSize] = [.small, .standard, .large]
        let current = TextSize(rawValue: UserDefaults.standard.string(forKey: textKey) ?? "") ?? .standard
        let index = min(max((order.firstIndex(of: current) ?? 1) + step, 0), order.count - 1)
        UserDefaults.standard.set(order[index].rawValue, forKey: textKey)
    }
}

/// A listening session on the microphone: sentences are handed over one after another while the task carries on.
/// Quiet after a sentence is its end; nobody speaking for a long while closes the session.
@MainActor
final class WiqoVoiceSession: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var starting = false
    @Published var micMessage: String?
    @Published var micDenied = false
    /// Counts the sentences handed over (the orb flashes on each).
    @Published private(set) var delivered = 0

    let recorder = WiqoSpeechRecorder()
    var onCommand: (String) -> Void = { _ in }
    private var watch: Task<Void, Never>?
    private var reopen: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    init() {
        recorder.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        recorder.$transcript.dropFirst().sink { [weak self] text in
            guard let self, self.isActive, !text.isEmpty else { return }
            self.arm(after: 1.0)
        }.store(in: &bag)
        // Half duplex: the microphone is closed to the recognizer while Wiqo speaks and opens a moment after it stops
        // (the room still rings for a few hundred milliseconds), with whatever was caught in between thrown away.
        WiqoSpeaker.shared.userIsSpeaking = { [weak self] in
            guard let self else { return false }
            return self.isActive && !self.recorder.transcript.isEmpty
        }
        WiqoSpeaker.shared.$isSpeaking.removeDuplicates().sink { [weak self] speaking in
            guard let self, self.isActive else { return }
            if speaking {
                self.reopen?.cancel()
                self.recorder.setMuted(true)
            } else {
                self.reopen?.cancel()
                self.reopen = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    guard !Task.isCancelled, self.isActive, !WiqoSpeaker.shared.isSpeaking else { return }
                    self.recorder.setMuted(false)
                    _ = self.recorder.rollover()
                }
            }
        }.store(in: &bag)
        recorder.$isRecording.dropFirst().sink { [weak self] recording in
            // The recognizer stopped by itself: hand over what was heard, then close.
            guard let self, !recording, self.isActive else { return }
            Task { await self.finish(send: true) }
        }.store(in: &bag)
    }

    var heard: String { recorder.transcript }
    var level: CGFloat { CGFloat(recorder.level) }

    func start(hints: [String]) {
        guard !starting, !isActive else { return }
        starting = true
        recorder.contextualStrings = Array(hints.prefix(100))
        Task {
            defer { starting = false }
            switch await recorder.start() {
            case .started, .startedWithNetworkFallback:
                WiqoHaptics.listeningStart()
                isActive = true
                arm(after: 12)
                UIAccessibility.post(notification: .announcement, argument: String(localized: "Dinliyorum"))
            case .permissionDenied: micDenied = true
            case .speechUnavailable: micMessage = String(localized: "Konuşma tanıma şu an kullanılamıyor. Siri ve Dikte'nin açık olduğundan emin ol; bu arada yazabilirsin.")
            case .setupFailed: micMessage = String(localized: "Mikrofon başlatılamadı; başka bir uygulama kullanıyor olabilir.")
            }
        }
    }

    /// The sentence heard so far goes out now; the microphone stays open for the next one.
    func deliver() {
        guard isActive else { return }
        WiqoSpeaker.shared.stop()
        let sentence = recorder.rollover()
        guard !sentence.isEmpty else { return }
        // Wiqo's own voice that got through is not a command.
        guard !WiqoSpeaker.shared.isEcho(sentence) else { arm(after: 30); return }
        WiqoHaptics.success()
        delivered += 1
        onCommand(sentence)
        arm(after: 30)
    }

    func finish(send: Bool) async {
        guard isActive else { return }
        watch?.cancel()
        isActive = false
        WiqoSpeaker.shared.stop()
        let sentence = await recorder.stop()
        guard send, !sentence.isEmpty, !WiqoSpeaker.shared.isEcho(sentence) else { return }
        WiqoHaptics.success()
        delivered += 1
        onCommand(sentence)
    }

    private func arm(after seconds: Double) {
        watch?.cancel()
        watch = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, isActive else { return }
            if recorder.transcript.isEmpty { await finish(send: false) } else { deliver() }
        }
    }
}

/// The session's face, in the composer's place: the words as they are heard (or what the task is doing), the orb, a small close,
/// and the sentences waiting their turn as chips that can be removed.
struct WiqoVoiceSessionView: View {
    @ObservedObject var session: WiqoVoiceSession
    @ObservedObject private var speaker = WiqoSpeaker.shared
    var status: String?
    var working: Bool
    var queued: [String] = []
    var onRemoveQueued: (Int) -> Void = { _ in }
    /// The full-screen voice conversation: a larger orb.
    var prominent = false

    var body: some View {
        VStack(spacing: 0) {
            Text(session.heard.isEmpty ? (status ?? " ") : session.heard)
                .font(.footnote)
                .foregroundStyle(session.heard.isEmpty ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, 48)
                .frame(height: 18)
            ZStack {
                Button { session.deliver() } label: {
                    WiqoListeningOrb(level: session.level, working: working, flash: session.delivered)
                        .scaleEffect(prominent ? 1.45 : 1, anchor: .center)
                        .frame(height: prominent ? 138 : 92)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dinliyorum")
                .accessibilityHint("Göndermek için dokun")
                HStack {
                    Button { WiqoSpeaker.shared.muted.toggle(); WiqoSpeaker.shared.stop() } label: {
                        Image(systemName: speaker.muted ? "speaker.slash" : "speaker.wave.2")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                            .background(Color.primary.opacity(0.07), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(speaker.muted ? "Sesli yanıtı aç" : "Sesli yanıtı kapat")
                    .padding(.leading, 10)
                    Spacer()
                    Button { Task { await session.finish(send: false) } } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                            .background(Color.primary.opacity(0.07), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Vazgeç")
                }
                .padding(.trailing, 10)
            }
            if !queued.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(queued.prefix(3).enumerated()), id: \.offset) { index, sentence in
                        Button { WiqoHaptics.selection(); onRemoveQueued(index) } label: {
                            HStack(spacing: 5) {
                                Text(sentence).lineLimit(1).truncationMode(.tail)
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .frame(maxWidth: 150)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(WiqoMotion.ease(0.25), value: queued)
    }
}

// MARK: - Spoken replies

/// Reads Wiqo's reply aloud in the person's language, sentence by sentence as it is written, so a spoken conversation does not wait for the whole answer.
/// It speaks only while a voice session is open; the person speaking over it (barge-in) or tapping the orb stops it at once.
@MainActor
final class WiqoSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = WiqoSpeaker()
    static let settingKey = "wiqo.voice.speak"

    @Published private(set) var isSpeaking = false
    /// The speaker button of the voice session: muted for this session only.
    @Published var muted = false

    private let synthesizer = AVSpeechSynthesizer()
    private var raw = ""            // every character of the reply fed so far
    private var pending = ""        // the part not yet cut into a sentence
    private var spoken = 0          // characters handed to the synthesizer for this reply
    private var queued = 0
    private var capped = false
    private var ownsSession = false
    /// What was said aloud most recently, and when it ended: a sentence that is only that coming back through the microphone is not the person.
    private var lastSpoken = ""
    private var lastEnded: Date?
    /// Set by the voice session: true while the person is in the middle of a sentence. Wiqo then yields instead of talking over them.
    var userIsSpeaking: () -> Bool = { false }
    /// A long answer (a whole document) is not read out: the first part, then a pointer to the screen.
    private static let characterLimit = 700

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    /// A new reply starts: whatever was still being read is dropped.
    func begin() {
        stop()
        raw = ""
        pending = ""
        spoken = 0
        capped = false
    }

    func feed(_ delta: String, listening: Bool) {
        guard listening, Self.isEnabled, !muted, !delta.isEmpty else { return }
        raw += delta
        pending += delta
        drain(final: false)
    }

    /// The reply is complete. What was already read stays; the rest is read, or all of it again if the final text is not an extension of what streamed.
    func finish(reply: String, listening: Bool) {
        guard listening, Self.isEnabled, !muted else { return }
        if reply.hasPrefix(raw) {
            pending += reply.dropFirst(raw.count)
        } else {
            stop()
            spoken = 0
            capped = false
            pending = reply
        }
        raw = reply
        drain(final: true)
    }

    /// The person spoke (or tapped the orb): quiet at once.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        pending = ""
        queued = 0
        isSpeaking = false
        releaseSession()
    }

    // MARK: Cutting and cleaning

    private func drain(final: Bool) {
        while let range = pending.range(of: #"[.!?…]+[\s)"”']*|\n+"#, options: .regularExpression) {
            let sentence = String(pending[..<range.upperBound])
            pending.removeSubrange(..<range.upperBound)
            enqueue(sentence)
        }
        if final, !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            enqueue(pending)
            pending = ""
        }
    }

    /// True for the sentence that is Wiqo's own voice: while it speaks, or just after, when what was "heard" is part of what was said.
    func isEcho(_ heard: String) -> Bool {
        if isSpeaking { return true }
        guard let lastEnded, Date().timeIntervalSince(lastEnded) < 1.4 else { return false }
        let words = WiqoVoiceIntent.folded(heard)
        return !words.isEmpty && WiqoVoiceIntent.folded(lastSpoken).contains(words)
    }

    private func enqueue(_ text: String) {
        if userIsSpeaking() {
            // The person started to speak between two sentences: they have the floor, the rest of the reply is not read.
            stop()
            capped = true
            return
        }
        guard !capped else { return }
        let clean = Self.speakable(text)
        guard !clean.isEmpty else { return }
        if spoken + clean.count > Self.characterLimit {
            capped = true
            say(String(localized: "Devamı ekranda."))
            return
        }
        spoken += clean.count
        say(clean)
    }

    private func say(_ text: String) {
        lastSpoken = String((lastSpoken + " " + text).suffix(800))
        prepareSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.05
        queued += 1
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Markdown, links, code and emoji are not read: what is left is what a person would say.
    nonisolated static func speakable(_ text: String) -> String {
        var value = text
        let rules: [(String, String)] = [
            (#"```[\s\S]*?```"#, " "),                       // code blocks
            (#"`([^`]*)`"#, "$1"),                              // inline code
            (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),              // links and images keep their text
            (#"https?://\S+"#, " "),                           // bare addresses
            (#"(?m)^\s{0,3}#{1,6}\s*"#, ""),                   // headings
            (#"(?m)^\s*[-•*]\s+"#, ""),                        // bullets (before the emphasis marks are removed)
            (#"[*_~>|]+"#, " "),                                // emphasis, quotes, table bars
            (#"\s+"#, " ")
        ]
        for (pattern, replacement) in rules {
            value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        value = value.unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)) }
            .map(String.init).joined()
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The voice of the person's language (best quality installed), Turkish when there is none.
    private static func voice() -> AVSpeechSynthesisVoice? {
        let code = WiqoSpeechRecorder.recognitionLocale().language.languageCode?.identifier ?? "tr"
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(code) }
        return candidates.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "tr-TR")
    }

    // MARK: Audio session

    /// While the microphone is open the recorder's session (play and record, echo-cancelled) is used as it is; otherwise a playback session.
    private func prepareSession() {
        guard !ownsSession, !WiqoSpeechRecorder.hasOpenMicrophone else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        ownsSession = true
    }

    private func releaseSession() {
        guard ownsSession else { return }
        ownsSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    private func utteranceEnded() {
        queued = max(0, queued - 1)
        if queued == 0 {
            isSpeaking = false
            lastEnded = Date()
            releaseSession()
        }
    }
}

/// Which result cards the voice conversation screen shows: what Wiqo presents, not the machinery of the task.
enum WiqoVoiceStage {
    static func shows(_ kind: RovaBackendClient.CopilotResultWidget.Kind) -> Bool {
        switch kind {
        case .task_plan, .task_result, .approval, .unknown: return false
        default: return true
        }
    }
}

// MARK: - Composer glass

extension View {
    /// The composer's surfaces (the field and the round buttons beside it): Liquid Glass on iOS 26, tinted a little with the app's accent
    /// (a touch more while the field is in use); a thin material with an accent hairline before that.
    @ViewBuilder
    func wiqoComposerGlass<S: InsettableShape>(_ shape: S, active: Bool = false, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            let glass = Glass.regular.tint(Color.accentColor.opacity(active ? 0.16 : 0.07))
            self.glassEffect(interactive ? glass.interactive() : glass, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.accentColor.opacity(active ? 0.35 : 0.16), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        }
    }
}
