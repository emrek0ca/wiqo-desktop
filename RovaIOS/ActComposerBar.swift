import MetalKit
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
    /// What the task is doing right now ("Yazılıyor · 1 sırada"), shown in the orb's place of words while the session goes on.
    var voiceStatus: String? = nil
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
            armSilenceTimer(after: 1.1)
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
            Text(recorder.transcript.isEmpty ? (voiceStatus ?? " ") : recorder.transcript)
                .font(.footnote)
                .foregroundStyle(recorder.transcript.isEmpty ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, 48)
                .frame(height: 18)
            ZStack {
                Button { deliverVoice() } label: {
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
        if starting || (busy && onVoiceCommand == nil) {
            ProgressView().controlSize(.small)
        } else if canSend && !recorder.isRecording && !busy {
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
            if recorder.transcript.isEmpty {
                // Nobody spoke for a long while: the session closes by itself.
                await finishVoice(send: false)
            } else {
                deliverVoice()
            }
        }
    }

    private func startVoice() {
        guard !starting else { return }
        starting = true
        focus.wrappedValue = false
        Task { @MainActor in
            defer { starting = false }
            switch await recorder.start() {
            case .started, .startedWithNetworkFallback:
                WiqoHaptics.selection()
                voiceActive = true
                armSilenceTimer(after: 12)
            case .permissionDenied: micDenied = true
            case .speechUnavailable: micMessage = String(localized: "Konuşma tanıma şu an kullanılamıyor. Siri ve Dikte'nin açık olduğundan emin ol; bu arada yazabilirsin.")
            case .setupFailed: micMessage = String(localized: "Mikrofon başlatılamadı; başka bir uygulama kullanıyor olabilir.")
            }
        }
    }

    /// The sentence heard so far goes to the task now, and the session keeps listening for the next one on the same microphone:
    /// speaking while the first command is being carried out is how it is meant to be used.
    private func deliverVoice() {
        guard voiceActive else { return }
        let heard = recorder.rollover()
        guard !heard.isEmpty else { return }
        WiqoHaptics.success()
        onVoiceCommand?(heard)
        // Listening goes on; with nothing more said for a while, the session ends.
        armSilenceTimer(after: 30)
    }

    /// Ends the session. `send` hands over a sentence that was still being spoken.
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

/// The listening orb: a real 3D sphere rendered with Metal (see `WiqoMetalOrb`); on a device without Metal, the drawn version below.
struct WiqoListeningOrb: View {
    var level: CGFloat

    var body: some View {
        if WiqoMetalOrb.isAvailable {
            WiqoMetalOrb(level: level)
                // The view is larger than the space the orb takes, so its glow and shadow are never cut at an edge.
                .frame(width: 220, height: 136)
                .frame(width: 132, height: 92)
                .accessibilityHidden(true)
        } else {
            WiqoCanvasOrb(level: level)
        }
    }
}

/// The fallback orb, drawn in layers: a glossy sphere in the app's accent colour with a soft ground shadow, a gradient
/// that slowly turns inside it, a specular highlight and a rim of light. Its outline breathes with the voice (`level`, 0...1).
private struct WiqoCanvasOrb: View {
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

// MARK: - Metal orb

/// A sphere ray-marched in a fragment shader: its surface is displaced by animated noise that grows with the voice, and it is lit like a
/// real object (key light, soft box reflection, fresnel rim, bounce light, specular) in the app's accent colour, with a glow and a ground shadow.
/// The shader is compiled from source at run time, so it needs no resource file; if that fails the drawn orb is used.
struct WiqoMetalOrb: UIViewRepresentable {
    var level: CGFloat
    @Environment(\.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor static var isAvailable: Bool { WiqoOrbRenderer.shared != nil }

    @MainActor func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: WiqoOrbRenderer.shared?.device)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let accent = UIColor(cgColor: Color.accentColor.resolve(in: environment).cgColor)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        accent.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let coordinator = context.coordinator
        coordinator.targetLevel = Float(min(max(level, 0), 1))
        coordinator.accent = SIMD4<Float>(Float(red), Float(green), Float(blue), 1)
        coordinator.isDark = view.traitCollection.userInterfaceStyle == .dark ? 1 : 0
        coordinator.animated = !reduceMotion
        view.isPaused = reduceMotion
        view.enableSetNeedsDisplay = reduceMotion
        if reduceMotion { view.setNeedsDisplay() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MTKViewDelegate {
        var targetLevel: Float = 0
        var accent = SIMD4<Float>(0.2, 0.4, 0.9, 1)
        var isDark: Float = 0
        var animated = true
        private var shownLevel: Float = 0
        private var lastTarget: Float = 0
        private var lastFrame = CACurrentMediaTime()
        private var pulse: Float = 0
        private var squash: Float = 0
        private var squashVelocity: Float = 0
        private let start = CACurrentMediaTime()

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let renderer = WiqoOrbRenderer.shared,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let buffer = renderer.queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            let now = CACurrentMediaTime()
            let dt = Float(min(max(now - lastFrame, 1.0 / 240.0), 1.0 / 30.0))
            lastFrame = now
            // The surface follows the voice closely: up fast, down a little slower.
            let follow: Float = targetLevel > shownLevel ? 0.55 : 0.18
            shownLevel += (targetLevel - shownLevel) * follow
            // The start of a word is an impulse: it kicks the spring (the body squashes and springs back, like a drop that was struck)
            // and sends a ring over the surface.
            let onset = max(0, targetLevel - lastTarget)
            lastTarget = targetLevel
            if animated {
                pulse = min(pulse * exp(-dt * 3.0) + onset * 2.6, 1.4)
                let drive = 2.0 * onset + 0.5 * (shownLevel - 0.25)
                squashVelocity += (-85 * squash - 7.5 * squashVelocity + drive * 40) * dt
                squash = min(max(squash + squashVelocity * dt, -0.9), 0.9)
            }
            let time = animated ? Float(now - start) : 0.0
            var uniforms = WiqoOrbRenderer.Uniforms(
                accent: accent,
                size: SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                time: time,
                level: animated ? shownLevel : 0.15,
                dark: isDark,
                pulse: animated ? pulse : 0,
                squash: animated ? squash : 0,
                drift: animated ? sin(time * 1.6) * shownLevel : 0
            )
            encoder.setRenderPipelineState(renderer.pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WiqoOrbRenderer.Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }
    }
}

/// The Metal device, queue and compiled pipeline, made once. Used from the main actor only (the view and its draw callbacks run there).
@MainActor
final class WiqoOrbRenderer {
    static let shared = WiqoOrbRenderer()

    struct Uniforms {
        var accent: SIMD4<Float>
        var size: SIMD2<Float>
        var time: Float
        var level: Float
        var dark: Float
        /// A ring that runs over the surface when a word starts.
        var pulse: Float
        /// Squash and stretch of the whole body, from a damped spring (positive = taller and narrower).
        var squash: Float
        /// Sideways drift while speaking.
        var drift: Float
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let vertex = library.makeFunction(name: "orb_vertex"),
              let fragment = library.makeFunction(name: "orb_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; float2 uv; };
    struct Uniforms { float4 accent; float2 size; float time; float level; float dark; float pulse; float squash; float drift; };

    vertex VOut orb_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    // Signed distance to the orb: a sphere of liquid. It squashes and stretches (a damped spring in the app), its surface flows
    // faster the louder the voice is, and a ring runs over it when a word begins.
    static float field(float3 p, float t, float lv, float pulse, float squash) {
        float3 q = p;
        q.y *= 1.0 - 0.14 * squash;
        q.x *= 1.0 + 0.07 * squash;
        q.z *= 1.0 + 0.07 * squash;
        float speed = 1.0 + 2.6 * lv;
        float amp = 0.016 + 0.075 * lv;
        float n = sin(q.x * 3.1 + t * 1.30 * speed + sin(q.y * 2.0 + t * 0.8 * speed)) * sin(q.y * 2.7 - t * 1.10 * speed) * sin(q.z * 3.3 + t * 0.90 * speed)
                + 0.55 * sin(q.x * 5.3 - t * 1.70 * speed + q.y * 2.1) * sin(q.z * 4.1 + t * 1.20 * speed);
        float r = length(q.xz);
        float ring = sin(r * 6.5 - t * 9.0) * exp(-r * 0.85) * smoothstep(-0.3, 1.0, q.y) * pulse * 0.07;
        return length(q) - (1.0 + 0.06 * lv) - amp * n - ring;
    }

    static float3 normalAt(float3 p, float t, float lv, float pulse, float squash) {
        const float e = 0.004;
        const float2 k = float2(1.0, -1.0);
        return normalize(k.xyy * field(p + k.xyy * e, t, lv, pulse, squash) + k.yyx * field(p + k.yyx * e, t, lv, pulse, squash) +
                         k.yxy * field(p + k.yxy * e, t, lv, pulse, squash) + k.xxx * field(p + k.xxx * e, t, lv, pulse, squash));
    }

    fragment float4 orb_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float aspect = u.size.x / max(u.size.y, 1.0);
        float2 p2 = (in.uv * 2.0 - 1.0) * float2(aspect, 1.0) * 2.05;
        p2.y = -p2.y;
        p2.y += 0.05;                                    // the orb sits a little above the middle; its shadow below
        p2.x -= u.drift * 0.10;                          // it sways with the voice
        p2.y -= u.squash * 0.10;                         // and rises a little as it stretches

        float lv = clamp(u.level, 0.0, 1.0);
        float3 ro = float3(p2, 3.0);
        float3 rd = float3(0.0, 0.0, -1.0);

        float t = 0.0;
        float dmin = 1e9;
        bool hit = false;
        float3 pos = ro;
        for (int i = 0; i < 56; i++) {
            pos = ro + rd * t;
            float d = field(pos, u.time, lv, u.pulse, u.squash);
            dmin = min(dmin, d);
            if (d < 0.0015) { hit = true; break; }
            t += d * 0.7;
            if (t > 6.0) break;
        }

        float3 accent = u.accent.rgb;
        float3 color = float3(0.0);
        float orbAlpha = 0.0;

        if (hit) {
            float3 n = normalAt(pos, u.time, lv, u.pulse, u.squash);
            float3 v = float3(0.0, 0.0, 1.0);
            float3 key = normalize(float3(-0.55, 0.70, 0.55));

            float ndv = clamp(dot(n, v), 0.0, 1.0);
            float diffuse = clamp(dot(n, key), 0.0, 1.0);
            float wrap = diffuse * 0.78 + 0.22;

            // Body: deep shade of the accent into a lit, slightly lighter accent.
            // Liquid inside: slow swirls of lighter and deeper accent, quicker and stronger while the voice is.
            float speed = 1.0 + 2.6 * lv;
            float swirl = 0.5 + 0.5 * sin(pos.x * 3.6 + u.time * 1.3 * speed + sin(pos.y * 2.8 - u.time * 0.9 * speed) * 1.6)
                              * cos(pos.z * 3.1 - u.time * 1.0 * speed + pos.y * 2.2);
            float3 shade = accent * 0.20;
            float3 lit = mix(accent * 0.92, accent * 1.18 + 0.05, swirl * (0.30 + 0.60 * lv)) + 0.03;
            color = mix(shade, lit, wrap);
            // Bright streaks where the liquid folds over, only when it is moving.
            float streak = pow(clamp(swirl, 0.0, 1.0), 6.0) * 0.30 * lv;
            color += mix(accent, float3(1.0), 0.5) * streak;

            // Light that travels through the body: the rim glows with the accent, brighter when the voice is.
            float rim = pow(1.0 - ndv, 2.2);
            color += accent * rim * (0.12 + 0.16 * lv);

            // Fresnel sheen.
            float fresnel = pow(1.0 - ndv, 4.0);
            color += float3(1.0) * fresnel * (0.12 + 0.08 * u.dark);

            // A soft box reflected in the surface, upper left.
            float3 r = reflect(-v, n);
            float2 q = (r.xy - float2(-0.42, 0.52)) / float2(0.34, 0.20);
            float box = exp(-dot(q, q) * 0.9);
            color += float3(1.0) * box * 0.55;

            // Sharp specular highlight.
            float3 h = normalize(key + v);
            float spec = pow(clamp(dot(n, h), 0.0, 1.0), 110.0);
            color += float3(1.0) * spec * 0.95;

            // Light bounced back from the surface below.
            float bounce = smoothstep(0.1, 1.0, -n.y) * 0.22;
            color += mix(accent, float3(1.0), 0.35) * bounce;

            color = clamp(color, 0.0, 1.0);

            // Anti-aliased silhouette.
            orbAlpha = 1.0;
        } else {
            float px = 2.05 * 2.0 / max(u.size.y, 1.0);
            orbAlpha = 1.0 - smoothstep(0.0, px * 1.4, dmin);
            color = accent * 0.5;
        }

        // Glow around the orb, stronger with the voice.
        float glow = exp(-max(dmin, 0.0) * 2.3) * (0.20 + 0.38 * lv) * (1.0 - u.dark * 0.15);
        glow = hit ? 0.0 : glow;

        // Ground shadow, flattened, a little tighter when the orb swells.
        float2 sp = float2(p2.x / (1.05 - 0.12 * lv), (p2.y + 1.62) / 0.22);
        float shadow = exp(-dot(sp, sp) * 1.5) * (0.26 - 0.06 * lv) * (1.0 - u.dark * 0.35);

        // Compose premultiplied: orb over glow over shadow.
        float a = orbAlpha;
        float glowA = glow * (1.0 - a);
        float shadowA = shadow * (1.0 - a) * (1.0 - glowA);
        float3 rgb = color * a + accent * glowA;
        float alpha = a + glowA + shadowA;
        return float4(rgb, alpha);
    }
    """
}
