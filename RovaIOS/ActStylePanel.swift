import SwiftUI

/// "Görünüm": the look of a project in a few taps (theme, accent colour, corners, buttons, text size, typeface).
/// It works on every project, whatever it is written in: the look is a layer over the page (or the program's output),
/// kept in `gorunum.json`; the project's own code is not rewritten. Every tap shows at once, nothing leaves the phone.
struct ActStylePanel: View {
    let projectID: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = ActModel.shared

    private static let swatches: [(name: String, hex: String)] = [
        ("Mavi", "#2563eb"), ("Yeşil", "#16a34a"), ("Kırmızı", "#e5322d"), ("Turuncu", "#f97316"), ("Mor", "#7c3aed"),
        ("Pembe", "#ec4899"), ("Turkuaz", "#0d9488"), ("Lacivert", "#1e3a8a"), ("Siyah", "#111827")
    ]

    private var project: ActLocalProject? { model.project(projectID) }
    private var look: ActLook { project?.look ?? ActLook() }
    private var isWeb: Bool { project?.isWeb ?? true }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    group("Tema") {
                        HStack(spacing: 10) {
                            choice("Sayfanın", systemImage: "circle.lefthalf.filled", selected: look.theme == nil) { change("Tema sıfırlandı") { $0.theme = nil } }
                            choice("Açık", systemImage: "sun.max", selected: look.theme == "light") { change("Açık tema") { $0.theme = "light" } }
                            choice("Koyu", systemImage: "moon", selected: look.theme == "dark") { change("Koyu tema") { $0.theme = "dark" } }
                        }
                    }
                    group("Ana renk") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                Button { change("Ana renk sıfırlandı") { $0.accent = nil } } label: {
                                    Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1).frame(width: 38, height: 38)
                                        .overlay { Image(systemName: look.accent == nil ? "checkmark" : "slash.circle").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary) }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Sayfanın kendi rengi")
                                ForEach(Self.swatches, id: \.hex) { swatch in
                                    Button { change("Ana renk: \(swatch.name.lowercased())") { $0.accent = swatch.hex } } label: {
                                        Circle().fill(Color(hex: swatch.hex)).frame(width: 38, height: 38)
                                            .overlay { if look.accent == swatch.hex { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white) } }
                                            .overlay { Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(swatch.name)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                    if isWeb {
                        group("Köşeler") {
                            HStack(spacing: 10) {
                                choice("Sayfanın", systemImage: "circle.lefthalf.filled", selected: look.corners == nil) { change("Köşeler sıfırlandı") { $0.corners = nil } }
                                choice("Keskin", systemImage: "square", selected: look.corners == "sharp") { change("Köşeler keskin") { $0.corners = "sharp" } }
                                choice("Yuvarlak", systemImage: "app", selected: look.corners == "round") { change("Köşeler yuvarlak") { $0.corners = "round" } }
                            }
                        }
                        group("Düğmeler") {
                            HStack(spacing: 10) {
                                choice("Sayfanın", systemImage: "circle.lefthalf.filled", selected: look.buttons == nil) { change("Düğmeler sıfırlandı") { $0.buttons = nil } }
                                choice("Köşeli", systemImage: "rectangle", selected: look.buttons == "square") { change("Düğmeler köşeli") { $0.buttons = "square" } }
                                choice("Hap", systemImage: "capsule", selected: look.buttons == "pill") { change("Düğmeler hap biçimli") { $0.buttons = "pill" } }
                            }
                        }
                    }
                    group("Yazı boyutu") {
                        HStack(spacing: 10) {
                            choice("Küçült", systemImage: "textformat.size.smaller", selected: false) { stepScale(-10) }
                            Text("%\(look.scale ?? 100)").font(.system(.subheadline, design: .monospaced).weight(.semibold)).frame(width: 64)
                            choice("Büyüt", systemImage: "textformat.size.larger", selected: false) { stepScale(10) }
                        }
                    }
                    group("Yazı tipi") {
                        HStack(spacing: 10) {
                            choice("Sayfanın", systemImage: "circle.lefthalf.filled", selected: look.font == nil) { change("Yazı tipi sıfırlandı") { $0.font = nil } }
                            choice("Serif", systemImage: "textformat", selected: look.font == "serif") { change("Yazı tipi serif") { $0.font = "serif" } }
                            choice("Yuvarlak", systemImage: "textformat.abc", selected: look.font == "rounded") { change("Yazı tipi yuvarlak") { $0.font = "rounded" } }
                            choice("Mono", systemImage: "chevron.left.forwardslash.chevron.right", selected: look.font == "mono") { change("Yazı tipi mono") { $0.font = "mono" } }
                        }
                    }
                    if !look.isDefault {
                        Button(role: .destructive) { change("Görünüm sıfırlandı") { $0 = ActLook() } } label: {
                            Label("Hepsini sıfırla", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    Text(isWeb
                         ? "Görünüm projenin kodunu değiştirmez, üstüne uygulanır; kod hangi dille yazılmış olursa olsun çalışır. Yazar model kodu yeniden yazsa da görünüm kalır."
                         : "Programın çıktısına uygulanır. Kod değişmez.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
            }
            .navigationTitle("Görünüm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Bitti") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func choice(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 15, weight: .medium))
                Text(title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(selected ? WiqoTheme.ink : WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(selected ? Color(.systemBackground) : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(model.job != nil)
    }

    private func stepScale(_ delta: Int) {
        let next = min(150, max(70, (look.scale ?? 100) + delta))
        change("Yazı boyutu %\(next)") { $0.scale = next == 100 ? nil : next }
    }

    private func change(_ summary: String, _ edit: (inout ActLook) -> Void) {
        var next = look
        edit(&next)
        model.setLook(projectID, next, summary: summary)
        WiqoHaptics.selection()
    }
}

private extension Color {
    init(hex: String) {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}
