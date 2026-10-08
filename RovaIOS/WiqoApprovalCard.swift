import SwiftUI

/// The one moment Wiqo stops and asks: what it is about to do, the details behind it, and two
/// clear answers. Everything before this (tool rows) is quiet; this card is the only surface in a
/// conversation that carries a solid action, so an approval is never mistaken for status.
struct WiqoApprovalCard: View {
    struct Field: Identifiable, Equatable {
        let id: String
        let label: String
        let value: String
    }

    let title: String
    let summary: String
    var fields: [Field] = []
    /// Position in a run that needs several approvals, shown as a rolling "1 / 3" counter.
    var step: Int = 1
    var stepCount: Int = 1
    var isDestructive = false
    var isProcessing = false
    var approveTitle = String(localized: "Onayla")
    var declineTitle = String(localized: "Reddet")
    let onApprove: () -> Void
    let onDecline: () -> Void

    @State private var showsFields = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isDestructive ? "exclamationmark.shield.fill" : "hand.raised.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(WiqoTheme.orange)
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(summary)
                            .font(.subheadline.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                if !fields.isEmpty {
                    fieldsSection
                }
            }
            .padding(14)

            Rectangle().fill(WiqoTheme.line).frame(height: 0.5)

            footer
        }
        .wiqoCard()
        .transition(reduceMotion ? .identity : .wiqoFadeUp)
        .accessibilityElement(children: .contain)
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : WiqoMotion.slide()) { showsFields.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showsFields ? 90 : 0))
                    Text("Ayrıntılar")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsFields {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(fields) { field in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.label)
                                .font(.caption2)
                                .foregroundStyle(WiqoTheme.ink3)
                            Text(field.value)
                                .font(.caption)
                                .lineLimit(6)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: WiqoTheme.controlRadius, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if stepCount > 1 {
                Text("\(step) / \(stepCount)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(WiqoTheme.ink3)
                    .contentTransition(.numericText())
                    .wiqoAnimation(WiqoMotion.ease(0.4), value: step)
                    .accessibilityLabel("Onay \(step), toplam \(stepCount)")
            }
            Spacer(minLength: 0)
            Button(declineTitle, action: onDecline)
                .buttonStyle(.wiqoPill(.ghost))
                .disabled(isProcessing)
            Button(action: onApprove) {
                if isProcessing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(Color(uiColor: .systemBackground))
                        Text("Yapıyorum…")
                    }
                } else {
                    Text(approveTitle)
                }
            }
            .buttonStyle(.wiqoPill(.accent))
            .disabled(isProcessing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// What remains of an approval once it has been answered: a single quiet pill instead of a card.
struct WiqoApprovalOutcome: View {
    enum Kind {
        case done
        case declined
        case failed

        var tint: Color {
            switch self {
            case .done: return WiqoTheme.green
            case .declined: return .secondary
            case .failed: return WiqoTheme.red
            }
        }

        var symbol: String {
            switch self {
            case .done: return "checkmark"
            case .declined: return "minus"
            case .failed: return "exclamationmark"
            }
        }
    }

    let kind: Kind
    let message: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(kind == .declined ? Color(uiColor: .systemBackground) : .white)
                .frame(width: 18, height: 18)
                .background(kind.tint, in: Circle())
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(kind == .declined ? Color.secondary : kind.tint)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .background(WiqoTheme.tint(kind.tint), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .transition(reduceMotion ? .identity : .wiqoPop)
        .onAppear {
            if kind == .done { WiqoHaptics.success() }
            if kind == .failed { WiqoHaptics.failure() }
        }
    }
}
