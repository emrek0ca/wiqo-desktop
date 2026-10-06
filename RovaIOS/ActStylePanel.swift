import SwiftUI

/// "Görünüm": the look of a web project in a few taps (theme, accent colour, corners, text size). Every tap is a
/// quick edit of the project's design values: instant, no writer, nothing leaves the phone, one history entry each.
struct ActStylePanel: View {
    let projectID: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = ActModel.shared
    @State private var message: String?

    private static let swatches: [(word: String, hex: String)] = [
        ("mavi", "#2563eb"), ("yesil", "#16a34a"), ("kirmizi", "#e5322d"), ("turuncu", "#f97316"), ("mor", "#7c3aed"),
        ("pembe", "#ec4899"), ("turkuaz", "#0d9488"), ("lacivert", "#1e3a8a"), ("siyah", "#111827")
    ]

    private var files: [String: String] { model.project(projectID)?.files ?? [:] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    group("Tema") {
                        HStack(spacing: 10) {
                            choice("Açık", systemImage: "sun.max", selected: !isDark) { apply("açık tema yap") }
                            choice("Koyu", systemImage: "moon", selected: isDark) { apply("koyu tema yap") }
                        }
                    }
                    group("Ana renk") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Self.swatches, id: \.hex) { swatch in
                                    Button { apply("ana renk \(swatch.word)") } label: {
                                        Circle().fill(Color(hex: swatch.hex)).frame(width: 38, height: 38)
                                            .overlay { if accent == swatch.hex { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white) } }
                                            .overlay { Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(swatch.word)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                    group("Köşeler") {
                        HStack(spacing: 10) {
                            choice("Keskin", systemImage: "square", selected: false) { apply("köşeleri keskin yap") }
                            choice("Yuvarlak", systemImage: "app", selected: false) { apply("köşeleri yuvarlak yap") }
                        }
                        HStack(spacing: 10) {
                            choice("Köşeli düğme", systemImage: "rectangle", selected: false) { apply("düğmeleri keskin yap") }
                            choice("Hap düğme", systemImage: "capsule", selected: false) { apply("düğmeleri yuvarlak yap") }
                        }
                    }
                    group("Yazı boyutu") {
                        HStack(spacing: 10) {
                            choice("Küçült", systemImage: "textformat.size.smaller", selected: false) { apply("yazıyı küçült") }
                            choice("Büyüt", systemImage: "textformat.size.larger", selected: false) { apply("yazıyı büyüt") }
                        }
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(WiqoTheme.orange) }
                    Text("Anında değişir; yazar modele gitmez. Her değişiklik geçmişe yazılır, geri alınabilir.")
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
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func choice(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(selected ? WiqoTheme.ink : WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(selected ? Color(.systemBackground) : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(model.job != nil)
    }

    private func apply(_ request: String) {
        if model.quickEdit(projectID, request: request) {
            message = nil
            WiqoHaptics.selection()
        } else {
            message = "Bu projenin görünümü tek tek ayarlanamıyor; alttaki kutudan iste."
        }
    }

    // MARK: Current values (read from the project's design variables)

    private func cssVariable(_ name: String) -> String? {
        let pattern = "--\(name)\\s*:\\s*([^;}\\n]+)"
        for path in files.keys.sorted() where path.hasSuffix(".css") || path.hasSuffix(".html") {
            guard let text = files[path], let range = text.range(of: pattern, options: .regularExpression) else { continue }
            let match = String(text[range])
            if let colon = match.firstIndex(of: ":") { return match[match.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased() }
        }
        return nil
    }

    private var accent: String? { cssVariable("accent") }

    private var isDark: Bool {
        guard let hex = cssVariable("bg"), hex.hasPrefix("#"), hex.count == 7 else { return false }
        let value = Int(hex.dropFirst(), radix: 16) ?? 0xffffff
        let r = Double((value >> 16) & 0xff), g = Double((value >> 8) & 0xff), b = Double(value & 0xff)
        return (0.299 * r + 0.587 * g + 0.114 * b) < 110
    }
}

private extension Color {
    init(hex: String) {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}
