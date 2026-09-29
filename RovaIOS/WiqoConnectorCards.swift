import SwiftUI

/// Result cards for the connected services: mail, agenda, files, pages and people share one list
/// card that takes its icon and tint from the service; spreadsheet rows get a table card. The
/// backend sends typed rows (never text to parse), so the card is a pure rendering of them.

private var connectorCardBackground: some View {
    RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color(uiColor: .secondarySystemGroupedBackground))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
}

struct ConnectorListCard: View {
    let widget: RovaBackendClient.CopilotResultWidget
    @State private var showsAll = false

    private enum Domain: String {
        case mail, calendar, drive, notion, contacts

        var symbol: String {
            switch self {
            case .mail: return "envelope.fill"
            case .calendar: return "calendar"
            case .drive: return "folder.fill"
            case .notion: return "doc.text.fill"
            case .contacts: return "person.2.fill"
            }
        }

        var tint: Color {
            switch self {
            case .mail: return .red
            case .calendar: return .blue
            case .drive: return .green
            case .notion: return .primary
            case .contacts: return .orange
            }
        }

        var noun: String {
            switch self {
            case .mail: return "e-posta"
            case .calendar: return "etkinlik"
            case .drive: return "dosya"
            case .notion: return "sayfa"
            case .contacts: return "kişi"
            }
        }
    }

    private static let collapsedCount = 4

    private var domain: Domain { Domain(rawValue: widget.domain ?? "") ?? .drive }
    private var items: [RovaBackendClient.CopilotResultWidget.ListItem] { widget.items ?? [] }
    private var visible: [RovaBackendClient.CopilotResultWidget.ListItem] {
        showsAll ? items : Array(items.prefix(Self.collapsedCount))
    }
    private var total: Int { max(widget.total ?? items.count, items.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 12)
            content
            footer
        }
        .background(connectorCardBackground)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: domain.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(domain.tint)
                .frame(width: 38, height: 38)
                .background(domain.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(widget.title ?? domain.noun.capitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(total) \(domain.noun)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if domain == .calendar {
            agenda
        } else {
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.offset) { index, item in
                    row(item)
                    if index < visible.count - 1 { Divider().padding(.leading, 12) }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: Agenda

    private var agenda: some View {
        let groups = dayGroups(visible)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
                Text(group.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, groupIndex == 0 ? 10 : 14)
                    .padding(.bottom, 4)
                ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                    agendaRow(item)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func agendaRow(_ item: RovaBackendClient.CopilotResultWidget.ListItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(domain.tint)
                .frame(width: 3, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Label(subtitle, systemImage: "mappin.and.ellipse")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let meta = item.meta, !meta.isEmpty {
                Text(meta)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private struct DayGroup {
        let label: String
        var items: [RovaBackendClient.CopilotResultWidget.ListItem]
    }

    private func dayGroups(_ items: [RovaBackendClient.CopilotResultWidget.ListItem]) -> [DayGroup] {
        var groups: [DayGroup] = []
        for item in items {
            let label = Self.dayLabel(for: item.start)
            if let index = groups.firstIndex(where: { $0.label == label }) {
                groups[index].items.append(item)
            } else {
                groups.append(DayGroup(label: label, items: [item]))
            }
        }
        return groups
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlainFormatter = ISO8601DateFormatter()
    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.setLocalizedDateFormatFromTemplate("dMMMMEEEE")
        return formatter
    }()

    private static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        return isoFormatter.date(from: value) ?? isoPlainFormatter.date(from: value) ?? dateOnlyFormatter.date(from: value)
    }

    private static func dayLabel(for start: String?) -> String {
        guard let date = date(from: start) else { return "Tarihsiz" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Bugün" }
        if calendar.isDateInTomorrow(date) { return "Yarın" }
        return dayFormatter.string(from: date)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ item: RovaBackendClient.CopilotResultWidget.ListItem) -> some View {
        if let raw = item.url, let url = safeURL(raw) {
            Link(destination: url) { rowBody(item, opensLink: true) }
                .buttonStyle(.plain)
                .accessibilityHint("Kendi uygulamasında açar")
        } else {
            rowBody(item, opensLink: false)
        }
    }

    private func rowBody(_ item: RovaBackendClient.CopilotResultWidget.ListItem, opensLink: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if domain == .contacts {
                Text(initials(item.title))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(domain.tint)
                    .frame(width: 32, height: 32)
                    .background(domain.tint.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.subheadline.weight(domain == .mail ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(domain == .mail ? 1 : 2)
                    Spacer(minLength: 4)
                    if let meta = item.meta, !meta.isEmpty {
                        Text(meta)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            if opensLink {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        let hidden = items.count - visible.count
        let unlisted = total - items.count
        return VStack(spacing: 0) {
            if hidden > 0 {
                Divider().padding(.horizontal, 12)
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { showsAll = true }
                } label: {
                    Text("\(hidden) \(domain.noun) daha göster")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            } else if showsAll && items.count > Self.collapsedCount {
                Divider().padding(.horizontal, 12)
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { showsAll = false }
                } label: {
                    Text("Daha az göster")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            if unlisted > 0 {
                Text("Toplam \(total) \(domain.noun); ilk \(items.count) tanesi gösteriliyor.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .padding(.top, hidden > 0 ? 0 : 8)
            }
        }
    }

    private func safeURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

struct ConnectorTableCard: View {
    let widget: RovaBackendClient.CopilotResultWidget

    private var columns: [String] { widget.columns ?? [] }
    private var rows: [[String]] { widget.rows ?? [] }
    private var totalRows: Int { max(widget.totalRows ?? rows.count, rows.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "tablecells.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 38, height: 38)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(widget.title ?? "Tablo")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(totalRows) satır")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            Divider().padding(.horizontal, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if !columns.isEmpty {
                        HStack(spacing: 0) {
                            ForEach(Array(columns.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(2)
                                    .frame(width: 112, alignment: .leading)
                                    .padding(8)
                                    .background(Color.primary.opacity(0.04))
                            }
                        }
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell.isEmpty ? "—" : cell)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .frame(width: 112, alignment: .leading)
                                    .padding(8)
                            }
                        }
                        Divider()
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 4)
            if totalRows > rows.count {
                Text("\(totalRows - rows.count) satır daha")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(12)
            }
        }
        .background(connectorCardBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tablo, \(totalRows) satır")
    }
}
