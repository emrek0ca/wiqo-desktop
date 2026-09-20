import SwiftUI

/// One thing Wiqo did (or is doing) on the user's behalf.
struct WiqoToolRow: Identifiable, Equatable {
    let id: String
    var icon: String
    var label: String
    /// The object of the action - an app, a file - shown as a small chip next to the label.
    var chip: String? = nil
    var tone: WiqoToolChipTone = .neutral
    /// One short sentence about how the step is going ("Şimdi yapıyorum…").
    var status: String? = nil
    /// What the tool actually did; revealed when the row is opened.
    var detail: [String] = []

    var isExpandable: Bool { !detail.isEmpty }
}

/// An agent run as compact rows: the collapsed header summarises the run, every row expands to
/// show what the tool really did. A single step is shown as one row without the header.
struct WiqoToolChips: View {
    let rows: [WiqoToolRow]
    var summary: String? = nil

    @State private var isOpen = true
    @State private var expanded: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsHeader: Bool { rows.count > 1 && summary != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsHeader, let summary {
                header(summary)
            }
            if isOpen || !showsHeader {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                            .transition(reduceMotion ? .identity : .wiqoFadeUp)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiqoAnimation(WiqoMotion.ease(0.3), value: rows)
    }

    private func header(_ summary: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : WiqoMotion.ease(0.3)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 0 : -90))
                Text(summary)
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOpen ? "Açık" : "Kapalı")
    }

    private func rowView(_ row: WiqoToolRow) -> some View {
        let isExpanded = expanded.contains(row.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                guard row.isExpandable else { return }
                withAnimation(reduceMotion ? nil : WiqoMotion.ease(0.3)) {
                    if isExpanded { expanded.remove(row.id) } else { expanded.insert(row.id) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: row.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(row.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let chip = row.chip, !chip.isEmpty {
                        chipView(chip)
                    }
                    Spacer(minLength: 4)
                    trailing(row, isExpanded: isExpanded)
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)

            if let status = row.status, !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(row.tone == .neutral || row.tone == .active ? Color.secondary : row.tone.tint)
                    .padding(.leading, 26)
                    .padding(.bottom, 2)
                    .transition(.opacity)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(row.detail.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 12)
                .padding(.vertical, 2)
                .overlay(alignment: .leading) {
                    Rectangle().fill(WiqoTheme.line).frame(width: 1)
                }
                .padding(.leading, 9)
                .padding(.top, 2)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func chipView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(WiqoTheme.line, lineWidth: 0.5)
            }
    }

    @ViewBuilder
    private func trailing(_ row: WiqoToolRow, isExpanded: Bool) -> some View {
        HStack(spacing: 6) {
            if row.tone == .active {
                ProgressView().controlSize(.mini)
            } else if row.tone != .neutral {
                Image(systemName: row.tone.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(row.tone.tint)
            }
            if row.isExpandable {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WiqoTheme.ink3)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
        }
    }
}
