import AVFoundation
import Contacts
import SwiftUI
import UserNotifications

/// Small state a card keeps on this phone (checked items, a running timer), keyed by the card's identity.
private enum WiqoCardStore {
    static func ints(_ key: String) -> Set<Int> { Set((UserDefaults.standard.array(forKey: "wiqo.card.\(key)") as? [Int]) ?? []) }
    static func save(_ value: Set<Int>, _ key: String) { UserDefaults.standard.set(Array(value), forKey: "wiqo.card.\(key)") }
    static func date(_ key: String) -> Date? { UserDefaults.standard.object(forKey: "wiqo.card.\(key)") as? Date }
    static func save(_ value: Date?, _ key: String) { UserDefaults.standard.set(value, forKey: "wiqo.card.\(key)") }
}

/// A countdown that survives leaving the screen: the end time is stored and a local notification rings at zero.
private enum WiqoTimerEngine {
    static func start(key: String, seconds: TimeInterval, title: String) async -> Date {
        let end = Date().addingTimeInterval(seconds)
        WiqoCardStore.save(end, key)
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(localized: "Süre doldu.")
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        try? await center.add(UNNotificationRequest(identifier: "wiqo.timer.\(key)", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)))
        return end
    }

    static func cancel(key: String) {
        WiqoCardStore.save(nil, key)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["wiqo.timer.\(key)"])
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// The small cards Wiqo answers with: timer, quotes, scores, translation, calculation, recipe, trip, music, checklist, contact.
struct WiqoCardView: View {
    let widget: RovaBackendClient.CopilotResultWidget

    var body: some View {
        switch widget.kind ?? "" {
        case "timer": WiqoTimerCard(widget: widget)
        case "quotes": WiqoQuotesCard(widget: widget)
        case "score": WiqoScoreCard(widget: widget)
        case "translation": WiqoTranslationCard(widget: widget)
        case "calc": WiqoCalcCard(widget: widget)
        case "recipe": WiqoRecipeCard(widget: widget)
        case "trip": WiqoTripCard(widget: widget)
        case "media": WiqoMediaCard(widget: widget)
        case "checklist": WiqoChecklistCard(widget: widget)
        case "contact": WiqoContactCard(widget: widget)
        default: EmptyView()
        }
    }
}

/// The frame every card shares: an icon, a title and a quiet line, then the content.
private struct CardFrame<Content: View>: View {
    let icon: String
    let title: String
    var subtitle: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WiqoTheme.ink)
                    .frame(width: 32, height: 32)
                    .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WiqoTheme.card, in: RoundedRectangle(cornerRadius: WiqoTheme.cardCorner, style: .continuous))
    }
}

// MARK: Timer

private struct WiqoTimerCard: View {
    let widget: RovaBackendClient.CopilotResultWidget
    @State private var end: Date?

    private var total: TimeInterval { widget.seconds ?? 60 }

    var body: some View {
        CardFrame(icon: "timer", title: widget.title ?? String(localized: "Zamanlayıcı"), subtitle: String(localized: "\(WiqoTimerEngine.clock(total)) süreli")) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let remaining = end.map { $0.timeIntervalSince(context.date) } ?? total
                let finished = end != nil && remaining <= 0
                HStack(spacing: 18) {
                    ZStack {
                        Circle().stroke(WiqoTheme.inset, lineWidth: 8)
                        Circle().trim(from: 0, to: end == nil ? 1 : max(0, min(1, remaining / total)))
                            .stroke(finished ? Color.green : WiqoTheme.ink, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 78, height: 78)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(finished ? String(localized: "Süre doldu") : WiqoTimerEngine.clock(remaining))
                            .font(.system(size: finished ? 22 : 34, weight: .bold, design: .rounded).monospacedDigit())
                        if end == nil {
                            Button("Başlat") { Task { end = await WiqoTimerEngine.start(key: widget.stableID, seconds: total, title: widget.title ?? String(localized: "Zamanlayıcı")) } }
                                .buttonStyle(.wiqoPill(.accent))
                        } else {
                            Button(finished ? "Sıfırla" : "İptal") { WiqoTimerEngine.cancel(key: widget.stableID); end = nil }
                                .buttonStyle(.wiqoPill(.secondary))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear { end = WiqoCardStore.date(widget.stableID) }
    }
}

// MARK: Quotes

private struct Sparkline: View {
    let points: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            if let low = points.min(), let high = points.max(), points.count > 1 {
                let span = max(high - low, 0.0000001)
                Path { path in
                    for (index, value) in points.enumerated() {
                        let x = geo.size.width * CGFloat(index) / CGFloat(points.count - 1)
                        let y = geo.size.height * (1 - CGFloat((value - low) / span))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

private struct WiqoQuotesCard: View {
    let widget: RovaBackendClient.CopilotResultWidget

    var body: some View {
        CardFrame(icon: "chart.line.uptrend.xyaxis", title: widget.title ?? String(localized: "Piyasalar"), subtitle: widget.subtitle) {
            VStack(spacing: 0) {
                ForEach(Array((widget.quotes ?? []).enumerated()), id: \.offset) { index, quote in
                    let up = (quote.changePercent ?? 0) >= 0
                    let tint: Color = quote.changePercent == nil ? .secondary : up ? .green : .red
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(quote.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(quote.symbol).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        if let series = quote.series { Sparkline(points: series, color: tint).frame(width: 64, height: 26) }
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Self.price(quote.price))\(quote.unit.map { " \($0)" } ?? "")").font(.subheadline.weight(.semibold).monospacedDigit())
                            if let change = quote.changePercent {
                                Text("\(up ? "▲" : "▼") %\(String(format: "%.2f", abs(change)).replacingOccurrences(of: ".", with: ","))").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
                            }
                        }
                    }
                    .padding(.vertical, 9)
                    if index < (widget.quotes?.count ?? 0) - 1 { Divider() }
                }
            }
        }
    }

    private static func price(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value >= 1000 ? 0 : value >= 100 ? 2 : 4
        formatter.minimumFractionDigits = value >= 1000 ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

// MARK: Score

private struct WiqoScoreCard: View {
    let widget: RovaBackendClient.CopilotResultWidget

    var body: some View {
        CardFrame(icon: "sportscourt", title: widget.title ?? String(localized: "Maçlar"), subtitle: widget.subtitle) {
            VStack(spacing: 0) {
                ForEach(Array((widget.matches ?? []).enumerated()), id: \.offset) { index, match in
                    VStack(spacing: 4) {
                        HStack(spacing: 8) {
                            Text(match.home).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .trailing).lineLimit(1)
                            Text(match.homeScore != nil && match.awayScore != nil ? "\(match.homeScore!) – \(match.awayScore!)" : "vs")
                                .font(.headline.monospacedDigit())
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(WiqoTheme.inset, in: Capsule())
                            Text(match.away).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        }
                        Text([match.status, match.when, match.league].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 9)
                    if index < (widget.matches?.count ?? 0) - 1 { Divider() }
                }
            }
        }
    }
}

// MARK: Translation

private struct WiqoTranslationCard: View {
    let widget: RovaBackendClient.CopilotResultWidget
    @State private var copied = false
    private static let synthesizer = AVSpeechSynthesizer()

    private static func name(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "" }
        return Locale(identifier: "tr_TR").localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    var body: some View {
        CardFrame(icon: "character.bubble", title: "\(Self.name(widget.sourceLang)) → \(Self.name(widget.targetLang))") {
            VStack(alignment: .leading, spacing: 10) {
                if let original = widget.original, !original.isEmpty { Text(original).font(.subheadline).foregroundStyle(.secondary) }
                Text(widget.translated ?? "").font(.title3.weight(.semibold)).textSelection(.enabled)
                HStack(spacing: 18) {
                    Button { speak() } label: { Label("Dinle", systemImage: "speaker.wave.2") }
                    Button { UIPasteboard.general.string = widget.translated; copied = true } label: { Label(copied ? "Kopyalandı" : "Kopyala", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    Spacer(minLength: 0)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
    }

    private func speak() {
        let utterance = AVSpeechUtterance(string: widget.translated ?? "")
        if let code = widget.targetLang, let voice = AVSpeechSynthesisVoice(language: code) { utterance.voice = voice }
        Self.synthesizer.stopSpeaking(at: .immediate)
        Self.synthesizer.speak(utterance)
    }
}

// MARK: Calculation / conversion

private struct WiqoCalcCard: View {
    let widget: RovaBackendClient.CopilotResultWidget
    @State private var copied = false

    var body: some View {
        CardFrame(icon: "equal.circle", title: widget.title ?? String(localized: "Sonuç"), subtitle: widget.subtitle?.capitalized) {
            VStack(alignment: .leading, spacing: 6) {
                if let expression = widget.expression { Text(expression).font(.subheadline).foregroundStyle(.secondary) }
                HStack(alignment: .firstTextBaseline) {
                    Text("= \(widget.result ?? "")").font(.system(size: 30, weight: .bold, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { UIPasteboard.general.string = widget.result; copied = true } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.footnote) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Recipe

private struct WiqoRecipeCard: View {
    let widget: RovaBackendClient.CopilotResultWidget
    @State private var checked = Set<Int>()
    @State private var running: [Int: Date] = [:]

    var body: some View {
        CardFrame(icon: "fork.knife", title: widget.title ?? String(localized: "Tarif"), subtitle: [widget.servings.map { String(localized: "\(Int($0)) kişilik") }, widget.minutes.map { "\(Int($0)) dk" }].compactMap { $0 }.joined(separator: " · ")) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Malzemeler").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array((widget.ingredients ?? []).enumerated()), id: \.offset) { index, item in
                        Button {
                            if checked.contains(index) { checked.remove(index) } else { checked.insert(index) }
                            WiqoCardStore.save(checked, widget.stableID + ".ing")
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: checked.contains(index) ? "checkmark.circle.fill" : "circle").foregroundStyle(checked.contains(index) ? Color.green : Color.secondary)
                                Text(item).font(.subheadline).strikethrough(checked.contains(index)).foregroundStyle(checked.contains(index) ? .secondary : .primary).multilineTextAlignment(.leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Yapılışı").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array((widget.directions ?? []).enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)").font(.caption.weight(.bold)).frame(width: 22, height: 22).background(WiqoTheme.inset, in: Circle())
                            VStack(alignment: .leading, spacing: 6) {
                                Text(step.text).font(.subheadline)
                                if let seconds = step.seconds { stepTimer(index: index, seconds: seconds) }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { checked = WiqoCardStore.ints(widget.stableID + ".ing") }
    }

    @ViewBuilder private func stepTimer(index: Int, seconds: Double) -> some View {
        let key = "\(widget.stableID).step\(index)"
        if let end = running[index] {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let remaining = end.timeIntervalSince(context.date)
                HStack(spacing: 8) {
                    Image(systemName: "timer")
                    Text(remaining > 0 ? WiqoTimerEngine.clock(remaining) : String(localized: "Süre doldu")).font(.footnote.weight(.semibold).monospacedDigit())
                    Button("İptal") { WiqoTimerEngine.cancel(key: key); running[index] = nil }.font(.footnote).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        } else {
            Button {
                Task { running[index] = await WiqoTimerEngine.start(key: key, seconds: seconds, title: String(localized: "\(widget.title ?? "Tarif"): \(index + 1). adım")) }
            } label: { Label("\(max(1, Int((seconds / 60).rounded()))) dk zamanlayıcı", systemImage: "timer").font(.footnote.weight(.medium)) }
            .buttonStyle(.plain)
            .foregroundStyle(WiqoTheme.ink)
        }
    }
}

// MARK: Trip

private struct WiqoTripCard: View {
    let widget: RovaBackendClient.CopilotResultWidget
    @State private var open: Set<Int> = [0]

    var body: some View {
        CardFrame(icon: "suitcase", title: widget.title ?? String(localized: "Gezi planı"), subtitle: widget.subtitle) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array((widget.tripDays ?? []).enumerated()), id: \.offset) { index, day in
                    Button {
                        if open.contains(index) { open.remove(index) } else { open.insert(index) }
                    } label: {
                        HStack {
                            Text(day.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: open.contains(index) ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if open.contains(index) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(day.items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(item.time ?? "•").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 42, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).font(.subheadline.weight(.medium))
                                        if let note = item.note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                                        if let place = item.place, !place.isEmpty {
                                            Button {
                                                if let url = URL(string: "https://maps.apple.com/?q=\(place.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? place)") { UIApplication.shared.open(url) }
                                            } label: { Label(place, systemImage: "mappin.and.ellipse").font(.caption.weight(.medium)) }
                                            .buttonStyle(.plain).foregroundStyle(WiqoTheme.ink)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 10)
                    }
                    if index < (widget.tripDays?.count ?? 0) - 1 { Divider() }
                }
            }
        }
    }
}

// MARK: Music

private struct WiqoMediaCard: View {
    let widget: RovaBackendClient.CopilotResultWidget
    @Environment(\.openURL) private var openURL

    private var query: String { widget.query ?? widget.title ?? "" }
    private var encoded: String { query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query }

    private var services: [(id: String, name: String, icon: String, url: URL?)] {
        [("apple_music", String(localized: "Apple Music"), "music.note", URL(string: "https://music.apple.com/tr/search?term=\(encoded)")),
         ("spotify", "Spotify", "waveform", URL(string: "https://open.spotify.com/search/\(encoded)")),
         ("youtube", "YouTube", "play.rectangle.fill", URL(string: "https://www.youtube.com/results?search_query=\(encoded)"))]
    }

    var body: some View {
        let preferred = widget.service ?? "apple_music"
        CardFrame(icon: "music.note", title: query, subtitle: String(localized: "Dinlemek için bir uygulama seç")) {
            VStack(spacing: 8) {
                ForEach(services.sorted { $0.id == preferred && $1.id != preferred }, id: \.id) { service in
                    Button { if let url = service.url { openURL(url) } } label: {
                        Label(service.name, systemImage: service.icon).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.wiqoPill(service.id == preferred ? .accent : .secondary))
                }
            }
        }
    }
}

// MARK: Checklist

private struct WiqoChecklistCard: View {
    let widget: RovaBackendClient.CopilotResultWidget
    @State private var checked = Set<Int>()

    var body: some View {
        let items = widget.checklist ?? []
        CardFrame(icon: "checklist", title: widget.title ?? String(localized: "Liste"), subtitle: String(localized: "\(checked.count)/\(items.count) tamamlandı")) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Button {
                        if checked.contains(index) { checked.remove(index) } else { checked.insert(index) }
                        WiqoCardStore.save(checked, widget.stableID)
                        WiqoHaptics.selection()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: checked.contains(index) ? "checkmark.circle.fill" : "circle").font(.system(size: 20)).foregroundStyle(checked.contains(index) ? Color.green : Color.secondary)
                            Text(item).font(.subheadline).strikethrough(checked.contains(index)).foregroundStyle(checked.contains(index) ? .secondary : .primary).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < items.count - 1 { Divider() }
                }
            }
        }
        .onAppear { checked = WiqoCardStore.ints(widget.stableID) }
    }
}

// MARK: Contact

private struct WiqoContactCard: View {
    let widget: RovaBackendClient.CopilotResultWidget
    @Environment(\.openURL) private var openURL

    private struct Person: Identifiable {
        let id: String
        let name: String
        let numbers: [String]
    }

    private enum Phase { case loading, denied, none, ready([Person]) }
    @State private var phase: Phase = .loading

    var body: some View {
        CardFrame(icon: "person.crop.circle", title: widget.contactQuery ?? widget.title ?? String(localized: "Kişi"), subtitle: String(localized: "Rehberinden")) {
            switch phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .denied:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rehber izni gerekiyor. İzin verirsen kişiyi burada bulup arayabilirsin; rehber telefonda kalır.").font(.footnote).foregroundStyle(.secondary)
                    Button("Ayarları aç") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }.buttonStyle(.wiqoPill(.accent))
                }
            case .none:
                Text("Rehberinde “\(widget.contactQuery ?? "")” adında biri bulunamadı.").font(.footnote).foregroundStyle(.secondary)
            case .ready(let people):
                VStack(spacing: 0) {
                    ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(person.name).font(.subheadline.weight(.semibold))
                            ForEach(person.numbers.prefix(2), id: \.self) { number in
                                HStack(spacing: 10) {
                                    Text(number).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                    Button { call(number) } label: { Label("Ara", systemImage: "phone.fill").font(.footnote.weight(.semibold)) }.buttonStyle(.wiqoPill(.accent))
                                    Button { message(number) } label: { Label("Mesaj", systemImage: "message.fill").font(.footnote.weight(.semibold)) }.buttonStyle(.wiqoPill(.secondary))
                                }
                            }
                        }
                        .padding(.vertical, 10)
                        if index < people.count - 1 { Divider() }
                    }
                }
            }
        }
        .task(id: widget.stableID) { await lookUp() }
    }

    private func digits(_ number: String) -> String { number.filter { $0.isNumber || $0 == "+" } }
    private func call(_ number: String) { if let url = URL(string: "tel:\(digits(number))") { openURL(url) } }
    private func message(_ number: String) { if let url = URL(string: "sms:\(digits(number))") { openURL(url) } }

    private func lookUp() async {
        let store = CNContactStore()
        do {
            let granted = try await store.requestAccess(for: .contacts)
            guard granted else { phase = .denied; return }
        } catch { phase = .denied; return }
        let query = widget.contactQuery ?? ""
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactPhoneNumbersKey as CNKeyDescriptor]
        let found = await Task.detached { () -> [Person] in
            guard let contacts = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys) else { return [] }
            return contacts.prefix(3).compactMap { contact in
                let numbers = contact.phoneNumbers.map { $0.value.stringValue }
                guard !numbers.isEmpty else { return nil }
                return Person(id: contact.identifier, name: CNContactFormatter.string(from: contact, style: .fullName) ?? query, numbers: numbers)
            }
        }.value
        phase = found.isEmpty ? .none : .ready(found)
    }
}
