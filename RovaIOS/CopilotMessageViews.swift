import SwiftUI
import UIKit

/// What a user attached shows as small thumbnails sitting above their own message bubble, exactly
/// where the user placed them before sending - not just held ephemerally in the composer and lost
/// the moment the message goes out. Read-only (no remove button, unlike the composer's own
/// attachmentStrip); tapping one opens it large enough to actually look at.
struct AttachmentThumbnailStrip: View {
    let thumbnails: [Data]
    @State private var fullscreenImage: UIImage?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, data in
                if let uiImage = UIImage(data: data) {
                    Button {
                        fullscreenImage = uiImage
                    } label: {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .fullScreenCover(item: $fullscreenImage) { image in
            AttachmentFullScreenView(image: image)
        }
    }
}

extension UIImage: @retroactive Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

struct AttachmentFullScreenView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") { dismiss() }
                        .tint(.white)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.black, for: .navigationBar)
        }
    }
}

struct CopyReplyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            WiqoHaptics.selection()
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Kopyalandı" : "Yanıtı kopyala")
    }
}
