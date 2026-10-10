import AVFoundation
import PhotosUI
import QuickLook
import Speech
import SwiftUI
import UIKit

extension JSONEncoder {
    static var rovaISO8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

enum CopilotWidgetDestination: Identifiable {
    case agents
    case automation(RovaBackendClient.RovaAutomation)

    var id: String {
        switch self {
        case .agents: return "agents"
        case .automation(let automation): return "automation-\(automation.id)"
        }
    }
}

struct CopilotResultWidgetView: View {
    let widget: RovaBackendClient.CopilotResultWidget
    let artifact: RovaBackendClient.ArtifactDescriptor?
    let isOpeningArtifact: Bool
    let onTap: () -> Void
    @State private var isExpanded = false
    @State private var showsConnections = false
    @Environment(\.wiqoFollowUp) private var followUp

    @ViewBuilder
    var body: some View {
        switch widget.type {
        case .created_resource:
            createdResourceCard
        case .code_change:
            CodeChangeCard(widget: widget)
        case .weather:
            weatherCard
        case .sources:
            sourcesCard
        case .artifact:
            artifactResultCard
        case .task_plan:
            TaskPlanMiniCard(widget: widget)
        case .task_result:
            taskResultCard
        case .error:
            errorResultCard
        case .list:
            ConnectorListCard(widget: widget)
        case .table:
            ConnectorTableCard(widget: widget)
        case .map:
            WiqoMapCard(widget: widget)
        case .card:
            WiqoCardView(widget: widget)
        case .inline_app:
            WiqoInlineAppCard(widget: widget)
        case .act_handoff:
            WiqoActHandoffCard(widget: widget)
        case .clarification:
            WiqoClarificationCard(widget: widget)
        case .approval:
            // Pending confirmations are rendered by the existing execution card, which owns
            // the live confirmation ID and approve/reject actions. Rendering this projection
            // separately would create a second, misleading approval surface.
            EmptyView()
        case .unknown:
            EmptyView()
        }
    }

    private var taskResultCard: some View {
        let completed = max(0, widget.completedSteps ?? 0)
        let total = max(completed, widget.totalSteps ?? completed)
        let status = widget.taskStatus ?? "completed"
        let label = status == "completed" ? String(localized: "Tamamlandı") : status == "partial" ? String(localized: "Kısmen tamamlandı") : String(localized: "Tamamlanamadı")
        let symbol = widget.capability == "browser" ? "safari"
            : widget.capability == "desktop" ? "macwindow"
            : widget.capability == "backend" ? "checkmark.seal" : "desktopcomputer"
        let tint: Color = status == "failed" ? .red : status == "partial" ? .orange : .green

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(widget.title ?? String(localized: "Görev sonucu"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(widget.summary ?? String(localized: "\(completed)/\(total) adım tamamlandı"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 4)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(tint.opacity(0.1), in: Capsule())
                    .fixedSize()
            }
            if status != "completed", total > 0 {
                ProgressView(value: Double(completed), total: Double(total))
                    .tint(tint)
                    .accessibilityLabel("\(completed) / \(total) adım tamamlandı")
            }
        }
        .padding(WiqoTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(widgetCardBackground)
        .accessibilityElement(children: .combine)
    }

    private var errorResultCard: some View {
        // The reason, not a code: the technical code stays out of sight (it is in the accessibility value and the server's task timeline), the card stays small.
        VStack(alignment: .leading, spacing: 3) {
            Label(widget.title ?? String(localized: "İşlem tamamlanamadı"), systemImage: "exclamationmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.red)
            if let message = widget.message, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if widget.code?.hasPrefix("CONNECTION_") == true && widget.code?.hasSuffix("_REQUIRED") == true {
                HStack(spacing: 12) {
                    Button("Bağlantıyı aç") { showsConnections = true }
                    Button("Devam et") { followUp?.send("devam et") }
                }
                .font(.footnote.weight(.semibold))
                .padding(.top, 6)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.red.opacity(0.12), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityValue(widget.code ?? "")
        .sheet(isPresented: $showsConnections) {
            NavigationStack { ConnectedAccountsView() }
        }
    }

    @ViewBuilder
    private var artifactResultCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    Image(systemName: artifactSymbol)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, height: 38)
                        .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text(widget.title ?? artifact?.filename ?? String(localized: "Dosya"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(artifactSubtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 4)
                    if isOpeningArtifact {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Dosyayı açar")

            if widget.variant == "table", let preview = widget.tablePreview,
               !preview.columns.isEmpty || !preview.rows.isEmpty {
                tablePreview(preview)
            } else if let artifact, hasInlineArtifactPreview(artifact.mimeType) {
                InlineArtifactPreview(artifact: artifact, onOpenFullscreen: onTap)
            }
        }
        .padding(WiqoTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(widgetCardBackground)
        .accessibilityElement(children: .contain)
    }

    private func tablePreview(_ preview: RovaBackendClient.CopilotResultWidget.TablePreview) -> some View {
        let columnCount = max(preview.columns.count, preview.rows.map(\.count).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 4) {
            FlexTable(columnCount: columnCount) {
                ForEach(0..<columnCount, id: \.self) { column in
                    FlexTableCell(isHeader: true, isFirstColumn: column == 0) {
                        Text(preview.columns[safe: column] ?? "").font(.caption.weight(.semibold))
                    }
                }
                ForEach(Array(preview.rows.enumerated()), id: \.offset) { _, row in
                    ForEach(0..<columnCount, id: \.self) { column in
                        let cell = row[safe: column] ?? ""
                        FlexTableCell(isFirstColumn: column == 0) {
                            Text(cell.isEmpty ? "—" : cell).font(.caption)
                        }
                    }
                }
            }
            if preview.totalRows > preview.rows.count {
                Text("\(preview.totalRows - preview.rows.count) satır daha")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Tablo önizlemesi, \(preview.totalRows) satır")
    }

    private var artifactSymbol: String {
        switch widget.variant {
        case "document", "pdf": return "doc.text"
        case "spreadsheet", "table": return "tablecells"
        case "chart": return "chart.bar"
        case "diagram": return "point.3.connected.trianglepath.dotted"
        case "image": return "photo"
        case "code": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    private func hasInlineArtifactPreview(_ mimeType: String) -> Bool {
        if case .none = ArtifactInlineKind(mimeType: mimeType) { return false }
        return true
    }

    private var artifactSubtitle: String {
        let labels: [String: String] = ["document": String(localized: "Belge"), "pdf": "PDF", "spreadsheet": String(localized: "Tablo dosyası"), "table": String(localized: "Tablo"), "chart": String(localized: "Grafik"), "diagram": String(localized: "Diyagram"), "image": String(localized: "Görsel"), "code": "Kod", "file": String(localized: "Dosya")]
        let kind = labels[widget.variant ?? "file"] ?? String(localized: "Dosya")
        let bytes = widget.byteCount ?? artifact?.byteCount
        return bytes.map { "\(kind) · \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" } ?? kind
    }

    private var sourcesCard: some View {
        let sources = Array((widget.sources ?? []).prefix(8))

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, height: 38)
                        .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Kaynaklar")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("\(sources.count) kaynak")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(WiqoTheme.cardPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Kaynaklar, \(sources.count) bağlantı")
            .accessibilityValue(isExpanded ? "Ayrıntılar açık" : "Ayrıntılar kapalı")
            .accessibilityHint("Kaynak bağlantılarını göstermek veya gizlemek için dokunun")

            if isExpanded {
                Divider().padding(.horizontal, 12)
                VStack(spacing: 0) {
                    ForEach(sources.indices, id: \.self) { index in
                        let source = sources[index]
                        if let url = safeSourceURL(source.url) {
                            Link(destination: url) {
                                sourceRow(source)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Kaynak bağlantısını açar")
                        } else {
                            sourceRow(source)
                        }
                        if index < sources.count - 1 {
                            Divider().padding(.leading, 54)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(widgetCardBackground)
        .accessibilityElement(children: .contain)
    }

    private func sourceRow(_ source: RovaBackendClient.CopilotResultWidget.Source) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "link")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 42, height: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(displaySourceText(source.title) ?? sourceHost(source.url) ?? String(localized: "Web kaynağı"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    if let host = sourceHost(source.url) {
                        Text(host)
                    }
                    if let published = displaySourceText(source.published) {
                        if sourceHost(source.url) != nil { Text("·") }
                        Text(published)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if safeSourceURL(source.url) != nil {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func safeSourceURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func sourceHost(_ value: String) -> String? {
        guard let host = safeSourceURL(value)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func displaySourceText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var createdResourceCard: some View {
        let isAgent = widget.resourceType == .agent
        let title = isAgent
            ? (widget.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Yeni ajan"))
            : String(localized: "Otomasyon")
        let summary = widget.summary.flatMap { $0.isEmpty ? nil : $0 }
            ?? widget.detail.flatMap { $0.isEmpty ? nil : $0 }
            ?? widget.scheduleLabel.flatMap { $0.isEmpty ? nil : $0 }
        let detailTitle = isAgent ? String(localized: "Görev") : String(localized: "İstek")

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    createdResourceMark(isAgent: isAgent)

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Text(isAgent ? "AJAN" : "OTOMASYON")
                                .font(.caption2.weight(.bold))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            statusBadge
                        }

                        Text(title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if let summary {
                            Text(summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .frame(width: 24, height: 44)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isAgent ? "Ajan" : "Otomasyon"): \(title)\(summary.map { ". \($0)" } ?? "")")
            .accessibilityValue(isExpanded ? "Ayrıntılar açık" : "Ayrıntılar kapalı")
            .accessibilityHint("Ayrıntıları göstermek veya gizlemek için dokunun")

            if isExpanded {
                Divider().padding(.horizontal, 14)
                VStack(alignment: .leading, spacing: 14) {
                    if let detail = widget.detail, !detail.isEmpty {
                        resourceDetailRow(detailTitle, value: detail)
                    }
                    if let schedule = widget.scheduleLabel, !schedule.isEmpty,
                       let nextRunAt = widget.nextRunAt, !nextRunAt.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            resourceInfoCard(String(localized: "Zamanlama"), value: schedule, symbol: "clock")
                            resourceInfoCard(
                                String(localized: "Sonraki çalışma"),
                                value: formattedDate(nextRunAt, timezone: widget.timezone),
                                symbol: "calendar"
                            )
                        }
                    } else if let schedule = widget.scheduleLabel, !schedule.isEmpty {
                        resourceInfoCard(String(localized: "Zamanlama"), value: schedule, symbol: "clock")
                    } else if let nextRunAt = widget.nextRunAt, !nextRunAt.isEmpty {
                        resourceInfoCard(
                            String(localized: "Sonraki çalışma"),
                            value: formattedDate(nextRunAt, timezone: widget.timezone),
                            symbol: "calendar"
                        )
                    }
                    Button(action: onTap) {
                        Label(isAgent ? "Ajanlarımda aç" : "Otomasyon ayrıntısını aç", systemImage: "arrow.up.right.square")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .contentShape(Rectangle())
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(widgetCardBackground)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func createdResourceMark(isAgent: Bool) -> some View {
        if isAgent {
            WiqoAgentMascot(widget.persona, size: 36)
                .accessibilityHidden(true)
                .frame(width: 48, height: 48)
        } else {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private func resourceInfoCard(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .padding(WiqoTheme.cardPadding)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var weatherCard: some View {
        let current = widget.current
        let days = Array((widget.days ?? []).prefix(3))
        let hours = Array((widget.hourly ?? []).prefix(24))

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(widget.location ?? String(localized: "Hava durumu"))
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(current?.condition ?? String(localized: "Güncel hava"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: weatherSymbol(current?.weatherCode))
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(temperature(current?.temperatureC))
                            .font(.system(.largeTitle, design: .rounded, weight: .medium))
                            .monospacedDigit()
                            .lineLimit(1)
                        Text("Hissedilen \(temperature(current?.feelsLikeC))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(widget.location ?? String(localized: "Hava durumu")), \(current?.condition ?? String(localized: "güncel hava")), \(temperature(current?.temperatureC))")
            .accessibilityValue(isExpanded ? "Ayrıntılar açık" : "Ayrıntılar kapalı")
            .accessibilityHint("Tahmini göstermek veya gizlemek için dokunun")

            if isExpanded {
                Divider().padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        weatherMetric(String(localized: "Nem"), value: percent(current?.humidityPercent), symbol: "humidity")
                        weatherMetric(String(localized: "Rüzgâr"), value: wind(current?.windKmh), symbol: "wind")
                    }

                    if !hours.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Saatlik · 24 saat")
                                .font(.subheadline.weight(.semibold))
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 8) {
                                    ForEach(Array(hours.enumerated()), id: \.offset) { _, hour in
                                        hourlyForecastCell(hour)
                                    }
                                }
                                .padding(.vertical, 1)
                            }
                            .accessibilityLabel("Önümüzdeki 24 saatin saatlik hava tahmini")
                        }
                    }

                    if !days.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("3 günlük tahmin")
                                .font(.subheadline.weight(.semibold))
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 8) {
                                    ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                                        dailyForecastCell(day)
                                        .frame(width: 96)
                                    }
                                }
                                .padding(.vertical, 1)
                            }
                            .accessibilityLabel("Üç günlük hava tahmini")
                        }
                    }

                    HStack(spacing: 6) {
                        Text(widget.source ?? String(localized: "Hava durumu verisi"))
                        if let observedAt = current?.observedAt, let localTime = localTime(observedAt) {
                            Text("·")
                            Text("Güncellendi \(localTime)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(widgetCardBackground)
        .accessibilityElement(children: .contain)
    }

    private func weatherMetric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func hourlyForecastCell(_ hour: RovaBackendClient.CopilotResultWidget.WeatherHour) -> some View {
        VStack(spacing: 7) {
            Text(localTime(hour.time) ?? "—")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Image(systemName: weatherSymbol(hour.weatherCode))
                .font(.body)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(temperature(hour.temperatureC))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
            if let rain = hour.rainChancePercent {
                Label("\(Int(rain.rounded()))%", systemImage: "drop.fill")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.blue)
                    .lineLimit(1)
            } else {
                Text(" ").font(.caption2)
            }
        }
        .frame(width: 62)
        .frame(minHeight: 92)
        .padding(.vertical, 8)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func dailyForecastCell(_ day: RovaBackendClient.CopilotResultWidget.WeatherDay) -> some View {
        VStack(spacing: 6) {
            Text(weekday(day.date, timezone: widget.timezone))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: weatherSymbol(day.weatherCode))
                .font(.body)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            HStack(spacing: 5) {
                Text(temperature(day.maxC)).foregroundStyle(.primary)
                Text(temperature(day.minC)).foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
            if let rain = day.rainChancePercent {
                Label("\(Int(rain.rounded()))%", systemImage: "drop.fill")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.blue)
                    .lineLimit(1)
            }
            if let rainMm = day.rainMm, rainMm > 0 {
                Text("\(rainAmount(rainMm)) mm")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .padding(8)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(weekday(day.date, timezone: widget.timezone)), \(day.condition), en yüksek \(temperature(day.maxC)), en düşük \(temperature(day.minC)), yağış olasılığı \(percent(day.rainChancePercent))")
    }

    private var statusBadge: some View {
        let isActive = widget.status == "active"
        return Text(isActive ? String(localized: "Etkin") : (widget.status ?? String(localized: "Durum bilinmiyor")))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isActive ? Color.green : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background((isActive ? Color.green : Color.secondary).opacity(0.1), in: Capsule())
            .fixedSize()
    }

    private var widgetCardBackground: some View {
        RoundedRectangle(cornerRadius: WiqoTheme.cardCorner, style: .continuous)
            .fill(WiqoTheme.card)
    }

    private func resourceDetailRow(_ title: String, value: String, symbol: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let symbol {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func temperature(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))°" } ?? "—"
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    private func wind(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded())) km/sa" } ?? "—"
    }

    private func rainAmount(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func weekday(_ value: String, timezone: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.timeZone = timezone.flatMap { TimeZone(identifier: $0) } ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: String(value.prefix(10))) else { return String(value.prefix(3)) }
        formatter.dateFormat = "EEE"
        return formatter.string(from: date).capitalized
    }

    private func localTime(_ value: String) -> String? {
        guard let separator = value.firstIndex(of: "T") else { return nil }
        let time = value[value.index(after: separator)...].prefix(5)
        return time.count == 5 ? String(time) : nil
    }

    private func formattedDate(_ value: String, timezone: String?) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = iso.date(from: value)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime]
            date = iso.date(from: value)
        }
        guard let date else { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.timeZone = timezone.flatMap { TimeZone(identifier: $0) } ?? .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func weatherSymbol(_ code: Int?) -> String {
        guard let code else { return "cloud.fill" }
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85...86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}

/// What a finished conversation turn shows under the reply. The reply already says what was done, so a completed plan, a "completed" task row and
/// a file list that repeats the file card are left out; whatever still needs the person (a step open, a failure, a question) stays.
enum WiqoChatDeclutter {
    static func visible(_ widgets: [RovaBackendClient.CopilotResultWidget], hasArtifact: Bool) -> [RovaBackendClient.CopilotResultWidget] {
        let hasArtifactCard = hasArtifact || widgets.contains { $0.type == .artifact }
        return widgets.filter { widget in
            switch widget.type {
            case .task_plan:
                let rows = widget.planSteps ?? []
                return rows.isEmpty || rows.contains { $0.status != "verified" }
            case .task_result:
                return (widget.taskStatus ?? "completed") != "completed"
            case .list:
                return !(hasArtifactCard && widget.domain == "files" && isFileEvidence(widget))
            default:
                return true
            }
        }
    }

    /// The "Doğrulanan dosya" list: proof of a save, which the file card above it already is.
    private static func isFileEvidence(_ widget: RovaBackendClient.CopilotResultWidget) -> Bool {
        widget.widgetId?.hasPrefix("file-evidence-") == true || widget.title == String(localized: "Doğrulanan dosya")
    }
}

// MARK: - Clarification

/// What the conversation tells a question card: which question may still be answered, and how to send an answer.
struct WiqoClarificationContext: @unchecked Sendable {
    var activeQuestionID: String?
    var sending: Bool = false
    var answer: (RovaBackendClient.CopilotResultWidget, String) -> Void = { _, _ in }
}

private struct WiqoClarificationKey: EnvironmentKey {
    static let defaultValue = WiqoClarificationContext()
}

extension EnvironmentValues {
    var wiqoClarification: WiqoClarificationContext {
        get { self[WiqoClarificationKey.self] }
        set { self[WiqoClarificationKey.self] = newValue }
    }
}

/// A question the running task is waiting on: the question, up to four ready answers, and a field for any other. Read-only once answered or replaced.
struct WiqoClarificationCard: View {
    let widget: RovaBackendClient.CopilotResultWidget
    @Environment(\.wiqoClarification) private var context
    @State private var text = ""
    @State private var submitted = false
    @FocusState private var focused: Bool

    private var isActive: Bool {
        !submitted && widget.questionId != nil && widget.questionId == context.activeQuestionID
    }

    private var canSend: Bool {
        isActive && !context.sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(widget.question ?? widget.summary ?? "")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isActive {
                if let options = widget.options, !options.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(options, id: \.self) { option in
                            Button { send(option) } label: {
                                Text(option)
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 42)
                                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(context.sending)
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Yanıtını yaz", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit { send(text) }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Button { send(text) } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .frame(width: 34, height: 34)
                            .background(canSend ? Color.primary : Color.primary.opacity(0.25), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel("Gönder")
                }
            } else {
                Text(submitted ? "Yanıtlandı" : "Bu soru artık beklenmiyor")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(WiqoTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WiqoTheme.card, in: RoundedRectangle(cornerRadius: WiqoTheme.cardCorner, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func send(_ answer: String) {
        guard isActive, !context.sending else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Locked here at once, so a second tap cannot send the same answer again; the conversation also refuses it.
        submitted = true
        focused = false
        context.answer(widget, trimmed)
    }
}
