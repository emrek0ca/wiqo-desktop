import SwiftUI
import UIKit

/// The code editor of the Act workspace: a plain-text view set up for code (monospace, no autocorrect, no smart
/// quotes), with the symbols a phone keyboard hides in a bar above the keyboard and the indent kept on a new line.
struct ActCodeEditor: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = UIFont(name: "JetBrainsMono-Regular", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardType = .asciiCapable
        view.backgroundColor = .secondarySystemBackground
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.keyboardDismissMode = .interactive
        view.delegate = context.coordinator
        view.text = text
        view.inputAccessoryView = Self.symbolBar(for: view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        // The app's appearance reaches the editor: text size (Ayarlar > Uygulama görünümü) and the accent colour (cursor, selection).
        let size = 13 * Self.scale(for: context.environment.dynamicTypeSize)
        if abs((view.font?.pointSize ?? 0) - size) > 0.1 {
            view.font = UIFont(name: "JetBrainsMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        view.textColor = .label
        view.tintColor = UIColor(cgColor: Color.accentColor.resolve(in: context.environment).cgColor)
    }

    private static func scale(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: return 0.85
        case .small: return 0.92
        case .medium: return 0.97
        case .large: return 1
        case .xLarge: return 1.08
        case .xxLarge: return 1.16
        case .xxxLarge: return 1.25
        default: return 1.35
        }
    }

    private static let symbols = ["⇥", "{", "}", "(", ")", "[", "]", "<", ">", "\"", "'", "`", ";", ":", "=", "/", "#", "$", "&", "|", "!", "-", "_", "."]

    private static func symbolBar(for view: UITextView) -> UIView {
        let bar = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.autoresizingMask = .flexibleWidth
        bar.backgroundColor = .secondarySystemBackground
        bar.showsHorizontalScrollIndicator = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: bar.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 32)
        ])
        for symbol in symbols {
            var config = UIButton.Configuration.gray()
            config.title = symbol
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
            config.baseForegroundColor = .label
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak view] _ in
                view?.insertText(symbol == "⇥" ? "  " : symbol)
            })
            stack.addArrangedSubview(button)
        }
        return bar
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ActCodeEditor
        init(_ parent: ActCodeEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }

        /// A new line starts at the indent of the line above (one level deeper after an opening bracket or a colon).
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            guard replacement == "\n" else { return true }
            let text = textView.text as NSString
            let lineStart = text.lineRange(for: NSRange(location: range.location, length: 0)).location
            let line = text.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let opens = line.trimmingCharacters(in: .whitespaces).last.map { "{([:>".contains($0) } ?? false
            let extra = opens ? "  " : ""
            guard !(indent + extra).isEmpty else { return true }
            textView.insertText("\n" + indent + extra)
            return false
        }
    }
}
