import CoreLocation
import MapKit
import SwiftUI

/// The phone's position, asked for once when a map needs it. Nothing here leaves the phone.
@MainActor
final class WiqoLocation: NSObject, CLLocationManagerDelegate {
    static let shared = WiqoLocation()

    enum Failure: Error { case denied, unavailable }

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation, Error>] = []
    private var last: CLLocation?

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isDenied: Bool { manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted }

    /// A position from the last two minutes, or a fresh one (the system asks for permission the first time).
    func current() async throws -> CLLocation {
        if let last, abs(last.timestamp.timeIntervalSinceNow) < 120 { return last }
        if isDenied || !CLLocationManager.locationServicesEnabled() { throw Failure.denied }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() } else { manager.requestLocation() }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedAlways, .authorizedWhenInUse: if !self.waiting.isEmpty { self.manager.requestLocation() }
            case .denied, .restricted: self.finish(.failure(Failure.denied))
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.last = location
            self.finish(.success(location))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(.failure(Failure.unavailable)) }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        let pending = waiting
        waiting = []
        for continuation in pending { continuation.resume(with: result) }
    }
}

/// Everything a map card shows, worked out on the phone with Apple Maps: places are looked up, the route and its
/// travel time (with today's traffic) are calculated, nearby places are searched. The backend only sent the words.
@MainActor
final class WiqoMapModel: ObservableObject {
    enum Phase: Equatable { case loading, ready, needsLocation, failed(String) }

    @Published var phase: Phase = .loading
    @Published var title = ""
    @Published var routes: [MKRoute] = []
    @Published var selectedRoute = 0
    @Published var results: [MKMapItem] = []
    @Published var selectedResult: Int?
    @Published var place: MKMapItem?
    @Published var origin: MKMapItem?
    @Published var destination: MKMapItem?
    @Published var position: MapCameraPosition = .automatic
    @Published var transport = "driving"
    @Published var showsTraffic = false
    @Published var userLocation: CLLocation?

    private var widget: RovaBackendClient.CopilotResultWidget?
    private var loadedAt: Date?

    func load(_ widget: RovaBackendClient.CopilotResultWidget, force: Bool = false) async {
        if !force, self.widget == widget, let loadedAt, Date().timeIntervalSince(loadedAt) < 300, phase == .ready { return }
        self.widget = widget
        if self.widget?.transport != nil || !force { transport = widget.transport ?? "driving" }
        showsTraffic = widget.traffic ?? false
        title = widget.title ?? ""
        phase = .loading
        do {
            switch widget.mode ?? "place" {
            case "route": try await loadRoute(origin: widget.origin, destination: widget.destination ?? widget.query ?? "")
            case "search": try await loadSearch(widget.query ?? "", near: widget.near)
            case "traffic": widget.destination != nil ? try await loadRoute(origin: widget.origin, destination: widget.destination ?? "") : try await loadArea(widget.near)
            default: try await loadPlace(widget.query ?? widget.destination ?? "")
            }
            loadedAt = Date()
            phase = .ready
        } catch WiqoLocation.Failure.denied {
            phase = .needsLocation
        } catch let error as MapError {
            phase = .failed(error.message)
        } catch {
            phase = .failed(String(localized: "Harita şu an hesaplanamadı. İnternet bağlantını kontrol edip tekrar dene."))
        }
    }

    func reroute(transport newTransport: String) async {
        guard let widget, destination != nil else { return }
        transport = newTransport
        do { try await loadRoute(origin: widget.origin, destination: widget.destination ?? widget.query ?? "", keepDestination: true); phase = .ready } catch { phase = .failed(String(localized: "Bu ulaşım türüyle rota bulunamadı.")) }
    }

    /// "Yol tarifi" on a nearby result: the same card turns into a route to it.
    func routeToSelected(_ item: MKMapItem) async {
        guard let here = try? await WiqoLocation.shared.current() else { phase = .needsLocation; return }
        userLocation = here
        origin = MKMapItem.forCurrentLocation()
        destination = item
        results = []
        selectedResult = nil
        place = nil
        do { try await calculate(); phase = .ready } catch { phase = .failed(String(localized: "Rota hesaplanamadı.")) }
    }

    struct MapError: Error { let message: String }

    // MARK: Loading

    private func resolve(_ text: String, around: CLLocation?, span: Double = 60_000) async -> MKMapItem? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        if let around { request.region = MKCoordinateRegion(center: around.coordinate, latitudinalMeters: span, longitudinalMeters: span) }
        return try? await MKLocalSearch(request: request).start().mapItems.first
    }

    private func hereIfAllowed() async -> CLLocation? {
        if let userLocation { return userLocation }
        let location = try? await WiqoLocation.shared.current()
        userLocation = location
        return location
    }

    private func loadPlace(_ query: String) async throws {
        let item = await resolve(query, around: await hereIfAllowed())
        guard let item else { throw MapError(message: String(localized: "“\(query)” için haritada bir sonuç bulamadım.")) }
        place = item
        routes = []; results = []; origin = nil; destination = nil
        title = item.name ?? title
        position = .region(MKCoordinateRegion(center: item.placemark.coordinate, latitudinalMeters: 1_200, longitudinalMeters: 1_200))
    }

    private func loadRoute(origin originText: String?, destination destinationText: String, keepDestination: Bool = false) async throws {
        let here = await hereIfAllowed()
        if !keepDestination || destination == nil {
            if let originText, !originText.isEmpty {
                guard let start = await resolve(originText, around: here) else { throw MapError(message: String(localized: "Başlangıç yerini (“\(originText)”) bulamadım.")) }
                origin = start
            } else {
                guard here != nil else { throw WiqoLocation.Failure.denied }
                origin = MKMapItem.forCurrentLocation()
            }
            guard let end = await resolve(destinationText, around: here ?? origin?.placemark.location) else { throw MapError(message: String(localized: "Varış yerini (“\(destinationText)”) bulamadım.")) }
            destination = end
        }
        place = nil; results = []
        try await calculate()
    }

    private func calculate() async throws {
        guard let origin, let destination else { return }
        let request = MKDirections.Request()
        request.source = origin
        request.destination = destination
        request.transportType = transport == "walking" ? .walking : transport == "transit" ? .transit : .automobile
        request.requestsAlternateRoutes = transport == "driving"
        let response = try await MKDirections(request: request).calculate()
        guard !response.routes.isEmpty else { throw MapError(message: String(localized: "Bu iki yer arasında rota bulunamadı.")) }
        routes = Array(response.routes.prefix(3))
        selectedRoute = 0
        showsTraffic = transport == "driving"
        fit(routes[0])
    }

    private func loadSearch(_ query: String, near: String?) async throws {
        var center: CLLocation?
        if let near, !near.isEmpty {
            guard let area = await resolve(near, around: await hereIfAllowed()) else { throw MapError(message: String(localized: "“\(near)” bölgesini bulamadım.")) }
            center = area.placemark.location
        } else {
            guard let here = await hereIfAllowed() else { throw WiqoLocation.Failure.denied }
            center = here
        }
        guard let center else { throw WiqoLocation.Failure.denied }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: center.coordinate, latitudinalMeters: 4_000, longitudinalMeters: 4_000)
        request.resultTypes = [.pointOfInterest, .address]
        let found = try await MKLocalSearch(request: request).start().mapItems
        let sorted = found.sorted { ($0.placemark.location?.distance(from: center) ?? .greatestFiniteMagnitude) < ($1.placemark.location?.distance(from: center) ?? .greatestFiniteMagnitude) }
        guard !sorted.isEmpty else { throw MapError(message: String(localized: "Yakında “\(query)” bulamadım.")) }
        results = Array(sorted.prefix(10))
        userLocation = userLocation ?? (near == nil ? center : nil)
        routes = []; place = nil; origin = nil; destination = nil
        selectedResult = nil
        var rect = MKMapRect.null
        for item in results.prefix(6) { rect = rect.union(MKMapRect(origin: MKMapPoint(item.placemark.coordinate), size: MKMapSize(width: 1, height: 1))) }
        rect = rect.union(MKMapRect(origin: MKMapPoint(center.coordinate), size: MKMapSize(width: 1, height: 1)))
        position = .rect(rect.insetBy(dx: -rect.size.width * 0.25 - 400, dy: -rect.size.height * 0.25 - 400))
    }

    private func loadArea(_ near: String?) async throws {
        var center: CLLocation?
        if let near, !near.isEmpty {
            center = await resolve(near, around: await hereIfAllowed())?.placemark.location
            if center == nil { throw MapError(message: "“\(near)” bölgesini bulamadım.") }
        } else {
            center = await hereIfAllowed()
        }
        guard let center else { throw WiqoLocation.Failure.denied }
        routes = []; results = []; place = nil; origin = nil; destination = nil
        showsTraffic = true
        position = .region(MKCoordinateRegion(center: center.coordinate, latitudinalMeters: 6_000, longitudinalMeters: 6_000))
    }

    private func fit(_ route: MKRoute) {
        let rect = route.polyline.boundingMapRect
        position = .rect(rect.insetBy(dx: -rect.size.width * 0.18 - 300, dy: -rect.size.height * 0.18 - 300))
    }

    func select(route index: Int) {
        guard routes.indices.contains(index) else { return }
        selectedRoute = index
        fit(routes[index])
    }

    func select(result index: Int?) {
        selectedResult = index
        if let index, results.indices.contains(index) {
            position = .region(MKCoordinateRegion(center: results[index].placemark.coordinate, latitudinalMeters: 1_000, longitudinalMeters: 1_000))
        }
    }

    // MARK: Words

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) dk" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) sa" : "\(hours) sa \(rest) dk"
    }

    static func distance(_ meters: CLLocationDistance) -> String {
        meters < 1_000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", meters / 1_000).replacingOccurrences(of: ".", with: ",")
    }
}

/// The map card in the chat: Apple Maps drawn right in the answer, with live traffic and the time it takes now.
struct WiqoMapCard: View {
    let widget: RovaBackendClient.CopilotResultWidget

    @Environment(\.openURL) private var openURL
    @StateObject private var model = WiqoMapModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            map
            VStack(alignment: .leading, spacing: 10) {
                header
                details
                actions
            }
            .padding(14)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(.separator).opacity(0.35), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: widget.stableID) { await model.load(widget) }
        .fullScreenCover(isPresented: $showingFullScreen) { fullScreenMap }
    }

    // MARK: Map

    @State private var showingFullScreen = false

    /// In the chat the map is a picture (a map that pans would swallow the swipes that scroll the conversation);
    /// tapping it opens the same map full screen, where it moves, zooms and shows its controls.
    private func mapView(interactive: Bool) -> some View {
        Map(position: $model.position, interactionModes: interactive ? [.pan, .zoom, .rotate] : []) {
            UserAnnotation()
            ForEach(Array(model.routes.enumerated()), id: \.offset) { index, route in
                MapPolyline(route.polyline)
                    .stroke(index == model.selectedRoute ? Color.blue : Color.gray.opacity(0.55), lineWidth: index == model.selectedRoute ? 6 : 4)
            }
            if let origin = model.origin, !origin.isCurrentLocation {
                Marker(origin.name ?? String(localized: "Başlangıç"), systemImage: "circle.fill", coordinate: origin.placemark.coordinate).tint(.green)
            }
            if let destination = model.destination {
                Marker(destination.name ?? String(localized: "Varış"), systemImage: "flag.fill", coordinate: destination.placemark.coordinate).tint(.red)
            }
            if let place = model.place {
                Marker(place.name ?? String(localized: "Yer"), coordinate: place.placemark.coordinate).tint(.red)
            }
            ForEach(Array(model.results.enumerated()), id: \.offset) { index, item in
                if index < 6 {
                    Marker(item.name ?? String(localized: "Yer"), monogram: Text("\(index + 1)"), coordinate: item.placemark.coordinate)
                        .tint(model.selectedResult == index ? .orange : .red)
                } else {
                    Marker(item.name ?? String(localized: "Yer"), systemImage: "mappin", coordinate: item.placemark.coordinate).tint(.red)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .including([.restaurant, .cafe, .pharmacy, .hospital, .gasStation, .parking, .publicTransport, .atm, .bank, .hotel, .museum, .park]), showsTraffic: model.showsTraffic))
        .mapControls { if interactive { MapUserLocationButton(); MapCompass(); MapScaleView() } }
    }

    private var failedPhase: Bool { if case .failed = model.phase { return true }; return false }

    private var map: some View {
        mapView(interactive: false)
            .frame(height: 250)
            .allowsHitTesting(false)
            .overlay {
                if model.phase == .loading {
                    ZStack { Color(.secondarySystemBackground).opacity(0.7); ProgressView() }
                } else if model.phase == .needsLocation || failedPhase {
                    Color(.secondarySystemBackground).opacity(0.85)
                }
            }
            .overlay(alignment: .topLeading) {
                if model.phase == .ready, model.showsTraffic || widget.mode == "traffic" {
                    Label("Canlı trafik", systemImage: "car.fill")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if model.phase == .ready {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(.regularMaterial, in: Circle())
                        .padding(8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if model.phase == .ready { showingFullScreen = true } }
            .accessibilityLabel("Haritayı tam ekran aç")
            .accessibilityAddTraits(.isButton)
    }

    private var fullScreenMap: some View {
        ZStack(alignment: .topTrailing) {
            mapView(interactive: true).ignoresSafeArea()
            Button { showingFullScreen = false } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.primary)
                    .frame(width: 36, height: 36).background(.regularMaterial, in: Circle())
            }
            .padding(12)
            .accessibilityLabel("Kapat")
            if model.routes.indices.contains(model.selectedRoute) {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                        Text(WiqoMapModel.duration(model.routes[model.selectedRoute].expectedTravelTime)).font(.headline)
                        Text(WiqoMapModel.distance(model.routes[model.selectedRoute].distance)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 28)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Text under the map

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
            Text(model.title.isEmpty ? (widget.title ?? String(localized: "Harita")) : model.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var icon: String {
        switch widget.mode {
        case "route": return model.transport == "walking" ? "figure.walk" : model.transport == "transit" ? "bus.fill" : "car.fill"
        case "search": return "magnifyingglass"
        case "traffic": return "car.2.fill"
        default: return "mappin.and.ellipse"
        }
    }

    @ViewBuilder private var details: some View {
        switch model.phase {
        case .loading:
            Text("Harita hazırlanıyor…").font(.footnote).foregroundStyle(.secondary)
        case .needsLocation:
            VStack(alignment: .leading, spacing: 8) {
                Text("Konumun gerekiyor. Konum izni verirsen rotayı ve yakındaki yerleri burada gösterebilirim; konum yalnızca telefonda kalır.").font(.footnote).foregroundStyle(.secondary)
                Button("Konum iznini aç") {
                    if WiqoLocation.shared.isDenied, let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } else { Task { await model.load(widget, force: true) } }
                }
                .buttonStyle(.wiqoPill(.accent))
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                Button("Tekrar dene") { Task { await model.load(widget, force: true) } }.buttonStyle(.wiqoPill(.secondary))
            }
        case .ready:
            readyDetails
        }
    }

    @ViewBuilder private var readyDetails: some View {
        if model.routes.indices.contains(model.selectedRoute) {
            let route = model.routes[model.selectedRoute]
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(WiqoMapModel.duration(route.expectedTravelTime)).font(.title3.weight(.bold))
                    Text(WiqoMapModel.distance(route.distance)).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if model.transport == "driving" {
                        Text("şu anki trafikle").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let notice = route.advisoryNotices.first {
                    Label(notice, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                transportPicker
                if model.routes.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(Array(model.routes.enumerated()), id: \.offset) { index, alternative in
                            Button { model.select(route: index) } label: {
                                VStack(spacing: 1) {
                                    Text(index == 0 ? "En hızlı" : "Alternatif \(index)").font(.caption2).foregroundStyle(.secondary)
                                    Text(WiqoMapModel.duration(alternative.expectedTravelTime)).font(.footnote.weight(.semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(index == model.selectedRoute ? WiqoTheme.ink.opacity(0.12) : WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                routeSteps(route)
            }
        } else if let place = model.place {
            VStack(alignment: .leading, spacing: 6) {
                if let address = place.placemark.title { Text(address).font(.footnote).foregroundStyle(.secondary) }
                if let phone = place.phoneNumber, let url = URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) {
                    Button { openURL(url) } label: { Label(phone, systemImage: "phone.fill").font(.footnote.weight(.medium)) }.buttonStyle(.plain).foregroundStyle(WiqoTheme.ink)
                }
            }
        } else if !model.results.isEmpty {
            nearbyList
        } else if widget.mode == "traffic" {
            Text("Kırmızı ve turuncu çizgiler yoğun trafiği gösterir. Haritaya dokunup tam ekranda kaydırabilir, yakınlaştırabilirsin.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var transportPicker: some View {
        HStack(spacing: 6) {
            ForEach([("driving", "car.fill", String(localized: "Araç")), ("walking", "figure.walk", String(localized: "Yürüyüş")), ("transit", "bus.fill", String(localized: "Toplu"))], id: \.0) { item in
                Button { Task { await model.reroute(transport: item.0) } } label: {
                    Label(item.2, systemImage: item.1)
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(model.transport == item.0 ? WiqoTheme.ink : WiqoTheme.inset, in: Capsule())
                        .foregroundStyle(model.transport == item.0 ? Color(.systemBackground) : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @State private var showingSteps = false

    @ViewBuilder private func routeSteps(_ route: MKRoute) -> some View {
        let steps = route.steps.filter { !$0.instructions.isEmpty }
        if !steps.isEmpty {
            DisclosureGroup(isExpanded: $showingSteps) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(steps.prefix(12).enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text(WiqoMapModel.distance(step.distance)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                            Text(step.instructions).font(.footnote)
                        }
                    }
                    if steps.count > 12 { Text("…ve \(steps.count - 12) adım daha (Haritalar'da).").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.top, 6)
            } label: {
                Text("Adımlar").font(.footnote.weight(.medium))
            }
            .tint(.primary)
        }
    }

    private var nearbyList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.results.prefix(6).enumerated()), id: \.offset) { index, item in
                Button { model.select(result: model.selectedResult == index ? nil : index) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(model.selectedResult == index ? Color.orange : Color.red, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? String(localized: "Yer")).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            Text(subtitle(for: item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if model.selectedResult == index {
                            Button("Yol tarifi") { Task { await model.routeToSelected(item) } }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.plain)
                                .foregroundStyle(WiqoTheme.ink)
                        }
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < min(model.results.count, 6) - 1 { Divider() }
            }
        }
    }

    private func subtitle(for item: MKMapItem) -> String {
        var parts: [String] = []
        if let here = model.userLocation, let location = item.placemark.location { parts.append(WiqoMapModel.distance(location.distance(from: here))) }
        if let address = item.placemark.thoroughfare ?? item.placemark.title { parts.append(address) }
        return parts.joined(separator: " · ")
    }

    // MARK: Buttons

    @ViewBuilder private var actions: some View {
        if model.phase == .ready {
            HStack(spacing: 10) {
                Button { openInMaps() } label: { Label("Haritalar'da aç", systemImage: "map").font(.footnote.weight(.semibold)).frame(maxWidth: .infinity) }
                    .buttonStyle(.wiqoPill(.accent))
                if let link = widget.url, let url = URL(string: link) {
                    Button { openURL(url) } label: { Image(systemName: "safari").font(.system(size: 15, weight: .medium)).frame(width: 40, height: 36) }
                        .buttonStyle(.wiqoPill(.secondary))
                        .accessibilityLabel("Google Haritalar'da aç")
                }
            }
        }
    }

    private func openInMaps() {
        let mode: String = model.transport == "walking" ? MKLaunchOptionsDirectionsModeWalking : model.transport == "transit" ? MKLaunchOptionsDirectionsModeTransit : MKLaunchOptionsDirectionsModeDriving
        if let origin = model.origin, let destination = model.destination {
            MKMapItem.openMaps(with: [origin, destination], launchOptions: [MKLaunchOptionsDirectionsModeKey: mode])
        } else if let place = model.place {
            place.openInMaps()
        } else if model.selectedResult != nil, let index = model.selectedResult, model.results.indices.contains(index) {
            model.results[index].openInMaps()
        } else if !model.results.isEmpty {
            MKMapItem.openMaps(with: Array(model.results.prefix(8)), launchOptions: nil)
        } else if let link = widget.url, let url = URL(string: link) {
            openURL(url)
        }
    }
}
