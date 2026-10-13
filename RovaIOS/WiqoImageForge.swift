import MetalKit
import SwiftUI
import simd

// MARK: - What the placeholder knows about the picture

/// The picture in the making, as far as the server has said so: which real step is running and the shape it will have. Written from the
/// activity stream, read by the placeholders (the one in the timeline and the one that waits for the file).
@MainActor
final class WiqoForgeBrief: ObservableObject {
    static let shared = WiqoForgeBrief()

    /// A picture is being made in this turn.
    @Published private(set) var active = false
    /// The step that is running, in the server's words ("Çiziyorum…").
    @Published private(set) var caption: String?
    /// Width over height of the picture to come, when the server knows it.
    @Published private(set) var aspect: CGFloat?

    func note(_ update: RovaBackendClient.ActivityUpdate) {
        guard let hint = update.hint, hint.kind == "image" else { return }
        active = true
        caption = update.label
        if let raw = hint.aspect {
            let parts = raw.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2, parts[0] > 0, parts[1] > 0 { aspect = CGFloat(parts[0] / parts[1]) }
        }
    }

    /// The turn is over: the placeholder in the timeline goes, the one that waits for the file keeps the shape.
    func endTurn() { active = false }

    /// The picture arrived.
    func finish() {
        active = false
        caption = nil
        aspect = nil
    }
}

// MARK: - The placeholder shown while a picture is being made

/// What the conversation shows while an image is generated or edited: a field of very small dots with a slow gradient of size and colour moving
/// through it, drawn straight onto the conversation (no card, no frame) with soft edges. A finger swells the dots under it, pushes them aside and
/// sends a ring out. A line under it says which real step of the work is running. The colours are the theme colour the person chose in the settings, the shape
/// is the picture's. Light on purpose: one cheap pass per pixel, no loops over geometry, 30 frames a second. Rendered by a Metal fragment shader
/// compiled from source at run time (no resource file); without Metal only the line stays.
struct WiqoImageForge: View {
    var editing = false
    /// The file is already made and is only coming down to the phone.
    var arriving = false
    var persona: String?
    @StateObject private var brief = WiqoForgeBrief.shared
    @State private var started = WiqoForgeClock.begin()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var caption: String {
        if arriving { return String(localized: "Görsel geliyor…") }
        if let text = brief.caption, !text.isEmpty { return text }
        return editing ? String(localized: "Görseli düzenliyorum…") : String(localized: "Çiziyorum…")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if WiqoForgeRenderer.shared != nil {
                    WiqoForgeMetalView(reduceMotion: reduceMotion, started: started)
                } else {
                    Color.clear
                }
            }
            .aspectRatio(brief.aspect ?? 4.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: 340)
            HStack(spacing: 8) {
                if let persona { WiqoAgentMascot(persona, size: 20, isWorking: true) }
                Text(caption)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.35), value: caption)
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(editing ? String(localized: "Görsel düzenleniyor") : String(localized: "Görsel oluşturuluyor"))
    }
}

/// The placeholder in the timeline and the one that waits for the file to come down are the same picture: they share one start, so the field
/// does not begin again when the turn ends. A start older than two minutes belongs to an earlier picture.
@MainActor
enum WiqoForgeClock {
    private static var start: Date?

    static func begin() -> Date {
        if let start, Date().timeIntervalSince(start) < 120 { return start }
        let now = Date()
        start = now
        return now
    }

    /// The picture arrived: the next one starts fresh.
    static func finish() {
        start = nil
        WiqoForgeBrief.shared.finish()
    }
}

// MARK: - Metal view

private final class WiqoForgeMTKView: MTKView {
    var onTouch: ((CGPoint, CGSize, Bool) -> Void)?
    private var lastHaptic: CFTimeInterval = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = CACurrentMediaTime()
        if now - lastHaptic > 0.4 {
            lastHaptic = now
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.35)
        }
        for touch in touches { onTouch?(touch.location(in: self), bounds.size, true) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { onTouch?(touch.location(in: self), bounds.size, false) }
    }
}

private struct WiqoForgeMetalView: UIViewRepresentable {
    var reduceMotion: Bool
    var started: Date
    /// The theme colour the person picked in Ayarlar > Görünüm (the app's tint): the placeholder is made of it and nothing else.
    @Environment(\.self) private var environment

    @MainActor func makeUIView(context: Context) -> MTKView {
        let view = WiqoForgeMTKView(frame: .zero, device: WiqoForgeRenderer.shared?.device)
        // Nothing behind the dots: they are drawn on the conversation itself.
        view.isOpaque = false
        view.backgroundColor = .clear
        view.layer.isOpaque = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isMultipleTouchEnabled = true
        // The dots are tiny: 2x keeps them round, 3x only costs battery.
        view.contentScaleFactor = min(view.contentScaleFactor, 2)
        // A slow gradient does not need more; Low Power Mode asks for less still.
        view.preferredFramesPerSecond = ProcessInfo.processInfo.isLowPowerModeEnabled ? 20 : 30
        view.delegate = context.coordinator
        view.onTouch = { [weak coordinator = context.coordinator] point, size, began in
            coordinator?.touch(at: point, in: size, began: began)
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let accent = UIColor(cgColor: Color.accentColor.resolve(in: environment).cgColor)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        accent.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let coordinator = context.coordinator
        let base = SIMD3<Float>(Float(red), Float(green), Float(blue))
        // The theme colour in three depths: a shade of it, itself, and a light tint of it. Nothing else is mixed in, so it always reads as the theme.
        coordinator.palette = [base * 0.68, base, simd_mix(base, SIMD3<Float>(repeating: 1), SIMD3<Float>(repeating: 0.5))]
        coordinator.animated = !reduceMotion
        coordinator.isDark = view.traitCollection.userInterfaceStyle == .dark ? 1 : 0
        coordinator.started = started
        view.isPaused = reduceMotion
        view.enableSetNeedsDisplay = reduceMotion
        if reduceMotion { view.setNeedsDisplay() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MTKViewDelegate {
        var animated = true
        var palette: [SIMD3<Float>] = [SIMD3<Float>(0.2, 0.3, 0.5), SIMD3<Float>(0.3, 0.5, 0.9), SIMD3<Float>(0.7, 0.8, 1.0)]
        var isDark: Float = 1
        var started = Date()
        private static let slotCount = 4
        /// The last touches, newest last: centred position (height 1), when it began, how strong.
        private var touches: [(position: SIMD2<Float>, born: CFTimeInterval, strength: Float)] = []

        func touch(at point: CGPoint, in size: CGSize, began: Bool) {
            guard size.width > 1, size.height > 1 else { return }
            let aspect = Float(size.width / size.height)
            let position = SIMD2<Float>((Float(point.x / size.width) - 0.5) * aspect, Float(point.y / size.height) - 0.5)
            let now = CACurrentMediaTime()
            if let last = touches.last, !began {
                // A drag leaves a trail, but not a ring per event.
                if simd_distance(last.position, position) < 0.05 && now - last.born < 0.12 { return }
            }
            touches.append((position, now, began ? 1.0 : 0.7))
            if touches.count > Self.slotCount { touches.removeFirst(touches.count - Self.slotCount) }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let renderer = WiqoForgeRenderer.shared,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let buffer = renderer.queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            let now = CACurrentMediaTime()
            touches.removeAll { now - $0.born > 3.0 }
            var slots = [SIMD4<Float>](repeating: .zero, count: Self.slotCount)
            for (index, item) in touches.suffix(Self.slotCount).enumerated() {
                slots[index] = SIMD4<Float>(item.position.x, item.position.y, Float(now - item.born), item.strength)
            }
            var uniforms = WiqoForgeRenderer.Uniforms(
                c0: SIMD4<Float>(palette[0], 1),
                c1: SIMD4<Float>(palette[1], 1),
                c2: SIMD4<Float>(palette[2], 1),
                size: SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                time: animated ? Float(max(0, Date().timeIntervalSince(started))) : 4.0,
                dark: isDark,
                count: animated ? Float(min(touches.count, Self.slotCount)) : 0
            )
            encoder.setRenderPipelineState(renderer.pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WiqoForgeRenderer.Uniforms>.stride, index: 0)
            slots.withUnsafeBytes { raw in
                if let base = raw.baseAddress { encoder.setFragmentBytes(base, length: raw.count, index: 1) }
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }
    }
}

// MARK: - Renderer

/// The Metal device, queue and compiled pipeline of the placeholder, made once on the main actor.
@MainActor
final class WiqoForgeRenderer {
    static let shared = WiqoForgeRenderer()

    struct Uniforms {
        var c0: SIMD4<Float>
        var c1: SIMD4<Float>
        var c2: SIMD4<Float>
        var size: SIMD2<Float>
        var time: Float
        var dark: Float
        var count: Float
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let vertex = library.makeFunction(name: "forge_vertex"),
              let fragment = library.makeFunction(name: "forge_fragment") else { return nil }
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
    struct Uniforms { float4 c0; float4 c1; float4 c2; float2 size; float time; float dark; float count; };

    vertex VOut forge_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    fragment float4 forge_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]], constant float4* touches [[buffer(1)]]) {
        float aspect = u.size.x / max(u.size.y, 1.0);
        float2 p = (in.uv - 0.5) * float2(aspect, 1.0);
        float t = u.time;

        // A lattice of very small dots, every other row shifted by half a cell.
        const float cells = 54.0;
        float2 g = p * cells;
        float row = floor(g.y);
        float stagger = 0.5 * fmod(abs(row), 2.0);
        g.x += stagger;
        float2 id = floor(g);
        float2 f = fract(g) - 0.5;
        float2 centre = float2(id.x + 0.5 - stagger, id.y + 0.5) / cells;

        // A finger: the dots under it swell and are pushed aside, and a ring runs out from where it touched.
        float swell = 0.0;
        float2 push = float2(0.0);
        for (int i = 0; i < 4; i++) {
            if (float(i) >= u.count) break;
            float4 tc = touches[i];
            float2 d = centre - tc.xy;
            float r = length(d) + 1e-4;
            float env = exp(-tc.z * 1.5) * tc.w;
            float ring = exp(-pow((r - tc.z * 0.55) * 11.0, 2.0)) * env;
            float lens = exp(-r * r * 22.0) * env;
            swell += 1.0 * lens + 0.85 * ring;
            push += (d / r) * (0.0042 * lens + 0.0030 * ring);
        }
        swell = min(swell, 1.2);

        // The gradient the dots follow: two slow waves crossing. It decides each dot's size and where it sits between the three colours.
        float2 q = centre + push;
        float wave = sin(q.x * 3.1 + t * 0.55 + 1.3 * sin(q.y * 2.5 - t * 0.35));
        float wave2 = sin(q.y * 4.2 - t * 0.45 + q.x * 1.6);
        float gr = clamp(0.5 + 0.30 * wave + 0.22 * wave2, 0.0, 1.0);

        // Never wider than its own cell, so a swollen dot stays round instead of being cut square.
        float radius = min(0.10 + 0.24 * gr + 0.30 * swell, 0.46);
        float aa = cells / max(u.size.y, 1.0);
        float cover = smoothstep(radius + aa, radius - aa, length(f - push * cells));

        float3 colour = mix(mix(u.c0.rgb, u.c1.rgb, smoothstep(0.0, 0.55, gr)), u.c2.rgb, smoothstep(0.55, 1.0, gr));
        colour = mix(colour, float3(1.0), 0.42 * min(swell, 1.0));

        // Soft edges, so the field is a cloud of dots on the conversation and not a rectangle.
        float2 e = abs(in.uv - 0.5) * 2.0;
        float m = pow(pow(e.x, 4.0) + pow(e.y, 4.0), 0.25);
        float edge = 1.0 - smoothstep(0.72, 1.0, m);

        float alpha = cover * edge * min(mix(0.50, 1.0, gr) + 0.5 * swell, 1.0);
        return float4(colour * alpha, alpha);
    }
    """
}
