import SwiftUI
import UIKit

/// The input of the Act tab, shaped like the chat's: one rounded bar, a menu on the left, the text, then the
/// microphone (dictation: the words land in the field, nothing is sent) or the send arrow.
struct ActComposerBar<Leading: View>: View {
    @Binding var text: String
    let placeholder: String
    let busy: Bool
    let canSend: Bool
    var focus: FocusState<Bool>.Binding
    let onSend: () -> Void
    /// When set, the microphone is a voice command: a listening orb takes the bar's place, and the sentence is handed over the moment the person stops speaking.
    var onVoiceCommand: ((String) -> Void)? = nil
    @ViewBuilder let leading: () -> Leading

    @StateObject private var recorder = WiqoSpeechRecorder()
    @State private var voiceActive = false
    @State private var voiceWatch: Task<Void, Never>?
    @State private var starting = false
    @State private var spokenFrom = ""
    @State private var micMessage: String?
    @State private var micDenied = false

    var body: some View {
        Group {
            if voiceActive {
                listening
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                bar
                    .transition(.opacity)
            }
        }
        .animation(WiqoMotion.ease(0.3), value: voiceActive)
        .onChange(of: recorder.transcript) { _, transcript in
            guard voiceActive, !transcript.isEmpty else { return }
            armSilenceTimer(after: 1.4)
        }
        .onChange(of: recorder.isRecording) { _, recording in
            // The recognizer stopped by itself: hand over what was heard, or just close.
            if !recording, voiceActive { Task { await finishVoice(send: true) } }
        }
        .alert("Sesli giriş izni gerekli", isPresented: $micDenied) {
            Button("Ayarları Aç") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            Button("Vazgeç", role: .cancel) {}
        } message: { Text("Konuşarak yazmak için Ayarlar'dan mikrofon ve konuşma tanıma iznini aç.") }
        .alert("Ses", isPresented: Binding(get: { micMessage != nil }, set: { if !$0 { micMessage = nil } })) {
            Button("Tamam", role: .cancel) {}
        } message: { Text(micMessage ?? "") }
    }

    /// Only the listening orb, in the composer's place: the words as they are heard in one quiet line, tap to send now, a small close.
    private var listening: some View {
        VStack(spacing: 0) {
            Text(recorder.transcript.isEmpty ? " " : recorder.transcript)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, 48)
                .frame(height: 18)
            ZStack {
                Button { Task { await finishVoice(send: true) } } label: {
                    WiqoListeningOrb(level: CGFloat(recorder.level))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dinliyorum")
                .accessibilityHint("Göndermek için dokun")
                HStack {
                    Spacer()
                    Button { Task { await finishVoice(send: false) } } label: {
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
        }
        .frame(maxWidth: .infinity)
    }

    private var bar: some View {
        HStack(alignment: .bottom, spacing: 4) {
            leading()
                .frame(width: 34, height: 34)
            TextField(recorder.isRecording ? String(localized: "Dinliyorum…") : placeholder, text: $text, axis: .vertical)
                .lineLimit(1...5)
                .focused(focus)
                .disabled(busy || recorder.isRecording)
                .padding(.vertical, 8)
            trailing
                .frame(width: 34, height: 34)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(focus.wrappedValue ? RovaDesign.ink.opacity(0.45) : Color(.separator).opacity(0.4), lineWidth: focus.wrappedValue ? 1.2 : 0.75)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .animation(.easeOut(duration: 0.15), value: canSend)
        .onChange(of: recorder.transcript) { _, transcript in
            guard recorder.isRecording, !voiceActive, !transcript.isEmpty else { return }
            text = spokenFrom.isEmpty ? transcript : spokenFrom + " " + transcript
        }
    }

    @ViewBuilder private var trailing: some View {
        if busy || starting {
            ProgressView().controlSize(.small)
        } else if canSend && !recorder.isRecording {
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(width: 30, height: 30)
                    .background(Color.primary, in: Circle())
            }
            .accessibilityLabel("Gönder")
        } else {
            Button(action: toggleMic) {
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(recorder.isRecording ? Color.white : Color.primary)
                    .frame(width: 30, height: 30)
                    .background(recorder.isRecording ? Color.red : Color(.tertiarySystemFill), in: Circle())
            }
            .accessibilityLabel(recorder.isRecording ? "Ses kaydını bitir" : "Konuşarak yaz")
        }
    }

    // MARK: Voice command

    /// Quiet for a moment after the last word: that is the end of the sentence.
    private func armSilenceTimer(after seconds: Double) {
        voiceWatch?.cancel()
        voiceWatch = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, voiceActive else { return }
            await finishVoice(send: true)
        }
    }

    private func startVoice() {
        guard !starting, !busy else { return }
        starting = true
        focus.wrappedValue = false
        Task { @MainActor in
            defer { starting = false }
            switch await recorder.start() {
            case .started, .startedWithNetworkFallback:
                WiqoHaptics.selection()
                voiceActive = true
                // Nobody spoke: close by itself instead of listening for ever.
                armSilenceTimer(after: 9)
            case .permissionDenied: micDenied = true
            case .speechUnavailable: micMessage = String(localized: "Konuşma tanıma şu an kullanılamıyor. Siri ve Dikte'nin açık olduğundan emin ol; bu arada yazabilirsin.")
            case .setupFailed: micMessage = String(localized: "Mikrofon başlatılamadı; başka bir uygulama kullanıyor olabilir.")
            }
        }
    }

    private func finishVoice(send: Bool) async {
        guard voiceActive else { return }
        voiceWatch?.cancel()
        voiceActive = false
        let heard = await recorder.stop()
        guard send, !heard.isEmpty else { return }
        WiqoHaptics.success()
        onVoiceCommand?(heard)
    }

    private func toggleMic() {
        if onVoiceCommand != nil { startVoice(); return }
        guard !starting else { return }
        starting = true
        Task { @MainActor in
            defer { starting = false }
            if recorder.isRecording {
                let heard = await recorder.stop()
                if !heard.isEmpty { text = spokenFrom.isEmpty ? heard : spokenFrom + " " + heard }
                return
            }
            spokenFrom = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch await recorder.start() {
            case .started, .startedWithNetworkFallback: break
            case .permissionDenied: micDenied = true
            case .speechUnavailable: micMessage = String(localized: "Konuşma tanıma şu an kullanılamıyor. Siri ve Dikte'nin açık olduğundan emin ol; bu arada yazabilirsin.")
            case .setupFailed: micMessage = String(localized: "Mikrofon başlatılamadı; başka bir uygulama kullanıyor olabilir.")
            }
        }
    }
}

/// A listening orb that looks like an object: a glossy sphere in the app's accent colour with a soft ground shadow, a gradient
/// that slowly turns inside it, a specular highlight and a rim of light. Its outline breathes with the voice (`level`, 0...1).
struct WiqoListeningOrb: View {
    var level: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                draw(&context, size: size, time: time, level: reduceMotion ? 0.15 : min(max(level, 0), 1))
            }
        }
        // The canvas is larger than the space the orb takes, so its glow and shadow are never cut at an edge.
        .frame(width: 220, height: 170)
        .frame(width: 132, height: 92)
        .accessibilityHidden(true)
    }

    private func blob(center: CGPoint, radius: CGFloat, time: Double, level: CGFloat) -> Path {
        let a1 = 0.016 + 0.050 * level, a2 = 0.012 + 0.038 * level, a3 = 0.006 + 0.024 * level
        var path = Path()
        let steps = 90
        for step in 0...steps {
            let angle = Double(step) / Double(steps) * 2 * .pi
            let wobble = 1
                + a1 * sin(2 * angle + 1.4 * time)
                + a2 * sin(3 * angle - 1.1 * time)
                + a3 * sin(5 * angle + 0.8 * time)
            let r = radius * CGFloat(wobble)
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: Double, level: CGFloat) {
        let accent = Color.accentColor
        let radius = 27 * (1 + 0.10 * level)
        let center = CGPoint(x: size.width / 2, y: size.height * 0.46)

        // Ground shadow: the orb sits on something.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 7))
            let width = radius * (1.5 - 0.2 * level), height = radius * 0.26
            layer.fill(Path(ellipseIn: CGRect(x: center.x - width / 2, y: center.y + radius * 1.18, width: width, height: height)),
                       with: .color(.black.opacity(0.20)))
        }
        // Ambient light the orb gives off.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 16))
            let glow = radius * (1.30 + 0.35 * level)
            layer.fill(Path(ellipseIn: CGRect(x: center.x - glow, y: center.y - glow, width: glow * 2, height: glow * 2)),
                       with: .color(accent.opacity(0.22 + 0.25 * level)))
        }

        let body = blob(center: center, radius: radius, time: time, level: level)
        context.fill(body, with: .color(accent))

        // Everything that models the surface stays inside the body.
        context.drawLayer { layer in
            layer.clip(to: body)
            // Liquid turning slowly inside.
            layer.drawLayer { inner in
                inner.addFilter(.blur(radius: 7))
                inner.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .conicGradient(
                        Gradient(colors: [.white.opacity(0.0), .white.opacity(0.30), .white.opacity(0.0), .black.opacity(0.22), .white.opacity(0.0)]),
                        center: CGPoint(x: center.x + radius * 0.12, y: center.y + radius * 0.08),
                        angle: .radians(time * 0.55)
                    )
                )
            }
            // Diffuse key light from the upper left.
            layer.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.50), .white.opacity(0.0)]),
                    center: CGPoint(x: center.x - radius * 0.38, y: center.y - radius * 0.42),
                    startRadius: 0, endRadius: radius * 1.45
                )
            )
            // Core shadow toward the edge: the roundness.
            layer.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .radialGradient(
                    Gradient(colors: [.black.opacity(0.0), .black.opacity(0.46)]),
                    center: CGPoint(x: center.x - radius * 0.12, y: center.y - radius * 0.14),
                    startRadius: radius * 0.50, endRadius: radius * 1.12
                )
            )
            // Light bounced back from below.
            layer.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.24), .white.opacity(0.0)]),
                    center: CGPoint(x: center.x + radius * 0.34, y: center.y + radius * 0.72),
                    startRadius: 0, endRadius: radius * 0.75
                )
            )
        }

        // Specular highlight and its small hot spot.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 2.2))
            layer.translateBy(x: center.x - radius * 0.40, y: center.y - radius * 0.55)
            layer.rotate(by: .degrees(-28))
            layer.fill(Path(ellipseIn: CGRect(x: -radius * 0.26, y: -radius * 0.13, width: radius * 0.52, height: radius * 0.26)),
                       with: .color(.white.opacity(0.80)))
        }
        // A thin rim of light along the upper edge.
        context.stroke(
            body,
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0.45), .white.opacity(0.0), .white.opacity(0.10)]),
                startPoint: CGPoint(x: center.x - radius, y: center.y - radius),
                endPoint: CGPoint(x: center.x + radius, y: center.y + radius)
            ),
            lineWidth: 0.9
        )
    }
}
