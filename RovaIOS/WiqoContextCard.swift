import SwiftUI

/// What Wiqo read to answer: a short excerpt with the file it came from. Opening the card shows
/// more of the text; the source chip always says where it was taken from.
struct WiqoContextChunk: Identifiable, Equatable {
    let id: String
    let title: String
    let text: String
    let source: String

    var characterCount: Int { text.count }

    /// A short uppercase label for the file type, e.g. "PDF", "CSV", "TXT".
    var badge: String {
        let ext = (source as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "DOSYA" : String(ext.prefix(4))
    }

    var tone: Color {
        switch (source as NSString).pathExtension.lowercased() {
        case "pdf": return WiqoTheme.red
        case "csv", "xls", "xlsx", "numbers": return WiqoTheme.green
        case "doc", "docx", "pages", "rtf": return .blue
        case "md", "txt": return .gray
        default: return .indigo
        }
    }
}

struct WiqoContextCard: View {
    let chunk: WiqoContextChunk

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let collapsedLineLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(chunk.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(chunk.characterCount.formatted()) karakter")
                    .font(.caption)
                    .foregroundStyle(WiqoTheme.ink3)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 40)

            Rectangle().fill(WiqoTheme.line).frame(height: 0.5)

            Button {
                withAnimation(reduceMotion ? nil : WiqoMotion.slide()) { isExpanded.toggle() }
            } label: {
                Text(chunk.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Kısalt" : "Tamamını göster")

            sourceChip
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .wiqoCard()
        .transition(reduceMotion ? .identity : .wiqoFadeUp)
    }

    private var sourceChip: some View {
        HStack(spacing: 6) {
            Text(chunk.badge)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .frame(minWidth: 16, minHeight: 14)
                .background(chunk.tone, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(chunk.source)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(WiqoTheme.inset, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Kaynak: \(chunk.source)")
    }
}
