import SwiftUI

/// Everything about the paired Mac: pairing, live status, quick actions, media/display, apps,
/// clipboard/URL, trust grants, and connection activity. Reached either from the chat toolbar's
/// connection icon or from the "PC ayarları" row in general Settings - kept as its own screen so
/// PC control reads as one dedicated surface instead of being buried in a long general list, and
/// so PC connection state/polling never has to be set up just to open general Settings.
struct PCSettingsView: View {
    @ObservedObject var model: IOSConnectionModel
    @ObservedObject var subscriptionStore: SubscriptionStore
    @State private var showingLockConfirmation = false
    @State private var showingSleepConfirmation = false
    @State private var showingDisplaySleepConfirmation = false
    @State private var showingForgetMacConfirmation = false
    @State private var showingPairing = false
    @State private var showingPaywall = false
    @State private var volume: Double = 50
    @State private var brightness: Double = 80
    @State private var urlText = ""
    @State private var clipboardText = ""
    @State private var backendDevices: [RovaBackendClient.DeviceStatus] = []
    @State private var deletingDeviceID: String?
    @State private var renamingDeviceID: String?
    @State private var renameText = ""
    @State private var trustGrants: [RovaBackendClient.TrustGrant] = []
    /// Remote control and PC settings are two different jobs: one tab each, instead of one long page with a "Gelişmiş" fold.
    @State private var pcTab: PCTab = .control
    private enum PCTab: Hashable { case control, settings }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private var availableApps: [ApplicationInfo] {
        model.deviceInfo?.availableApplications ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: RovaDesign.cardSpacing) {
                    if subscriptionStore.info.pcAllowed {
                        if model.isPaired {
                            statusCard
                            Picker("Bölüm", selection: $pcTab) {
                                Text("Kontrol").tag(PCTab.control)
                                Text("Ayarlar").tag(PCTab.settings)
                            }
                            .pickerStyle(.segmented)
                            if pcTab == .control {
                                quickActionsCard
                                mediaCard
                                displayCard
                                appsCard
                                clipboardCard
                                urlCard
                            } else {
                                if !backendDevices.isEmpty { devicesCard }
                                capabilitiesCard
                                connectionActionsCard
                                if !trustGrants.isEmpty { trustGrantsCard }
                                activityCard
                            }
                            if let error = model.lastError { errorCard(error) }
                        } else {
                            pairingPromptCard
                        }
                    } else {
                        pcUpsellCard
                    }
                }
                .padding(RovaDesign.screenPadding)
            }
            .background(WiqoSettingsStyle.canvas)
            .navigationTitle("PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Text("Kapat").font(.body.weight(.medium)) }
                }
            }
            .sheet(isPresented: $showingPairing) {
                PairingView(model: model)
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(subscriptionStore: subscriptionStore)
            }
        }
        .task {
            model.connect()
            await loadDevicesAndTrust()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.connect()
                Task { await loadDevicesAndTrust() }
            }
        }
        .onChange(of: model.systemStatus) { _, status in
            if let level = status?.volumePercentage { volume = Double(level) }
            if let level = status?.brightnessPercentage { brightness = Double(level) }
        }
    }

    /// Shown instead of every other card when the current plan doesn't include PC access (Free) -
    /// the backend already refuses to hand the model any PC tools for these accounts (see
    /// rova-backend's ToolRegistry.forRequest), so this is purely about not showing controls that
    /// would just fail or mislead.
    private var pcUpsellCard: some View {
        RovaCard {
            HStack(spacing: 14) {
                Image(systemName: "lock.laptopcomputer")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PC bağlantısı").font(.subheadline.weight(.semibold))
                    Text("PC'ni kontrol edebilmek için Pro veya Business'a geç.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Yükselt") { showingPaywall = true }
                    .buttonStyle(.wiqoPill(.accent))
            }
        }
    }

    private var connectionActionsCard: some View {
        RovaCard {
            Text("Bağlantı").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Button {
                Task { _ = await model.send(.ping) }
            } label: {
                settingsRow(title: String(localized: "Bağlantıyı ölç"), systemImage: "waveform.path.ecg")
            }
            Button {
                Task { _ = await model.send(.getSystemStatus) }
            } label: {
                settingsRow(title: String(localized: "Durumu yenile"), systemImage: "arrow.clockwise")
            }
            Divider()
            Button(role: .destructive) {
                showingForgetMacConfirmation = true
            } label: {
                settingsRow(title: "PC'yi unut", systemImage: "laptopcomputer.slash", isDestructive: true)
            }
        }
        .wiqoConfirmation(String(localized: "PC'yi unutmak istediğine emin misin?"), isPresented: $showingForgetMacConfirmation) {
            Button("PC'yi unut", role: .destructive) { model.forgetPairing(); dismiss() }
        }
    }

    // MARK: - Cards

    private var devicesCard: some View {
        RovaCard {
            Label("Bağlı cihazlar", systemImage: "rectangle.3.group")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(backendDevices) { device in
                Button {
                    renameText = device.displayName
                    renamingDeviceID = device.id
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: device.online ? "circle.fill" : "circle")
                            .foregroundStyle(device.online ? .green : .secondary)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.displayName).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            Text("\(displayPlatformName(device.platform)) • \(device.capabilities.count) yetenek")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(device.online ? "Bağlı" : "Çevrimdışı")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(device.online ? .green : .secondary)
                        Image(systemName: "pencil")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        deletingDeviceID = device.id
                    } label: {
                        Label("Sil", systemImage: "trash")
                    }
                }
            }
            if backendDevices.count > 1 {
                Text("Birden fazla PC'n varsa isim vererek ayırt edebilirsin (\"Ofis PC\" gibi).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .alert("PC'yi yeniden adlandır", isPresented: Binding(
            get: { renamingDeviceID != nil },
            set: { if !$0 { renamingDeviceID = nil } }
        )) {
            TextField("Örn. Ofis PC", text: $renameText)
            Button("Kaydet") {
                guard let id = renamingDeviceID else { return }
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    if let updated = try? await RovaBackendClient.renameDevice(id: id, name: name.isEmpty ? nil : name) {
                        if let index = backendDevices.firstIndex(where: { $0.id == id }) { backendDevices[index] = updated }
                    }
                }
            }
            Button("Vazgeç", role: .cancel) {}
        }
        .wiqoConfirmation(item: $deletingDeviceID, title: { _ in String(localized: "Bu cihazı listeden kaldırmak istediğine emin misin?") }) { id in
            Button("Cihazı sil", role: .destructive) {
                backendDevices.removeAll { $0.id == id }
                Task { try? await RovaBackendClient.deleteDevice(id: id) }
            }
        } message: { _ in EmptyView() }
    }

    /// A live status view of what Wiqo can actually do on this Mac right now - answers "neden
    /// çalışmıyor" without needing to guess or wait for a failed attempt first.
    private var capabilitiesCard: some View {
        NavigationLink {
            DeviceCapabilitiesView(authorities: model.deviceInfo?.authorities ?? [])
        } label: {
            RovaCard {
                HStack(spacing: 14) {
                    Image(systemName: "checklist")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PC Yetenekleri").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text("PC'nde nelerin hazır olduğunu gör").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var pairingPromptCard: some View {
        RovaCard {
            HStack(spacing: 14) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PC ekle").font(.subheadline.weight(.semibold))
                    Text("PC'ni QR kodu okutarak bağla.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Bağla") { showingPairing = true }
                    .buttonStyle(.wiqoPill(.accent))
            }
        }
    }

    private var statusCard: some View {
        RovaCard {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.deviceInfo?.displayName ?? "PC").font(.headline)
                    HStack(spacing: 6) {
                        Text(statusText).font(.subheadline).foregroundStyle(statusColor)
                    }
                }
                Spacer()
                if model.state == .connecting { ProgressView() }
            }
            if model.state != .connected {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.isReconnecting ? String(localized: "Bağlantıyı yeniden kuruyorum…") : model.userFacingConnectionError)
                            .font(.caption.weight(.medium))
                    }
                    Spacer(minLength: 8)
                    if !model.isReconnecting {
                        Button("Tekrar dene") {
                            model.retry()
                        }
                        .buttonStyle(.wiqoPill(.secondary))
                    }
                }
            }
            if let status = model.systemStatus {
                Divider()
                HStack {
                    Label("PC · \(status.macOSVersion)", systemImage: "desktopcomputer")
                    Spacer()
                    if let battery = status.batteryPercentage {
                        Label("\(battery)%\(status.isCharging == true ? " ⚡︎" : "")", systemImage: "battery.100")
                    }
                    Spacer()
                    Label(formatUptime(status.uptimeSeconds), systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var quickActionsCard: some View {
        RovaCard {
            Text("Hızlı Eylemler").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    RovaActionTile(title: String(localized: "Kilitle"), systemImage: "lock.fill", isDestructive: true) {
                        showingLockConfirmation = true
                    }
                    RovaActionTile(title: String(localized: "Uyku"), systemImage: "moon.fill", isDestructive: true) {
                        showingSleepConfirmation = true
                    }
                    RovaActionTile(title: String(localized: "Ekran Uyut"), systemImage: "display", isDestructive: true) {
                        showingDisplaySleepConfirmation = true
                    }
                    RovaActionTile(title: String(localized: "Geri"), systemImage: "backward.fill") {
                        hapticImpact(); Task { _ = await model.mediaControl(.previousTrack) }
                    }
                    RovaActionTile(title: "Oynat/Duraklat", systemImage: "playpause.fill") {
                        hapticImpact(); Task { _ = await model.mediaControl(.playPause) }
                    }
                    RovaActionTile(title: String(localized: "İleri"), systemImage: "forward.fill") {
                        hapticImpact(); Task { _ = await model.mediaControl(.nextTrack) }
                    }
                    RovaActionTile(title: String(localized: "Sessiz"), systemImage: "speaker.slash.fill") {
                        hapticImpact(); Task { _ = await model.toggleMute() }
                    }
                }
            }
            .disabled(model.state != .connected)
        }
        .wiqoConfirmation("PC kilitlenecek. Devam et?", isPresented: $showingLockConfirmation) {
            Button("PC'yi kilitle", role: .destructive) {
                hapticImpact()
                Task {
                    let ok = await model.authenticateBiometrics(reason: String(localized: "PC'yi kilitlemek için kimliğinizi doğrulayın"))
                    if ok { _ = await model.send(.lockMac) }
                }
            }
        }
        .wiqoConfirmation(String(localized: "PC uyku moduna alınacak. Devam et?"), isPresented: $showingSleepConfirmation) {
            Button("PC'yi uyut", role: .destructive) {
                hapticImpact()
                Task {
                    let ok = await model.authenticateBiometrics(reason: String(localized: "PC'yi uykuya almak için kimliğinizi doğrulayın"))
                    if ok { _ = await model.sleepMac() }
                }
            }
        }
        .wiqoConfirmation(String(localized: "PC ekranı uyutulacak. Devam et?"), isPresented: $showingDisplaySleepConfirmation) {
            Button("Ekranı uyut", role: .destructive) {
                hapticImpact()
                Task { _ = await model.displaySleep() }
            }
        }
    }

    private var mediaCard: some View {
        RovaCard {
            Text("Ses").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.1.fill").foregroundStyle(.secondary)
                Slider(value: $volume, in: 0...100, step: 5) { editing in
                    if !editing {
                        hapticImpact()
                        Task { _ = await model.setVolume(Int(volume)) }
                    }
                }
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            .disabled(model.state != .connected)
        }
    }

    private var displayCard: some View {
        RovaCard {
            Text("Parlaklık").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: "sun.min.fill").foregroundStyle(.secondary)
                Slider(value: $brightness, in: 0...100, step: 5) { editing in
                    if !editing {
                        hapticImpact()
                        Task { _ = await model.setBrightness(Int(brightness)) }
                    }
                }
                Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
            }
            .disabled(model.state != .connected)
        }
    }

    private var appsCard: some View {
        RovaCard {
            Text("Uygulamalar").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(availableApps) { app in
                        RovaActionTile(title: app.name, systemImage: icon(for: app.id)) {
                            hapticImpact()
                            Task { _ = await model.send(.openApplication, payload: .application(app.id)) }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { _ = await model.quitApplication(app.id) }
                            } label: {
                                Label("Kapat", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
            }
            .disabled(model.state != .connected)
            if !availableApps.isEmpty {
                Text("Kapatmak için basılı tut").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var clipboardCard: some View {
        RovaCard {
            Text("Pano").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                TextField("Metin yapıştır veya yaz…", text: $clipboardText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    guard !clipboardText.isEmpty else { return }
                    hapticImpact()
                    Task {
                        _ = await model.setClipboardText(clipboardText)
                        clipboardText = ""
                        hapticNotification(.success)
                    }
                } label: {
                    Image(systemName: "arrow.up.doc.fill")
                }
                .buttonStyle(.wiqoPill(.accent))
                .disabled(clipboardText.isEmpty || model.state != .connected)
            }
        }
    }

    private var urlCard: some View {
        RovaCard {
            Text("URL Aç").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            TextField("youtube.com", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit(openTypedURL)
            if let resolved = normalizedURL(from: urlText), resolved.absoluteString != urlText {
                Text(resolved.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Aç", action: openTypedURL)
                .disabled(model.state != .connected || normalizedURL(from: urlText) == nil)
        }
    }

    /// Turns free-form input ("youtube", "youtube.com", "https://youtube.com/watch?v=…") into a
    /// URL the Mac will actually accept - RovaValidation.isAllowedURL (the same check the Mac
    /// re-applies on its side) requires an explicit http/https scheme and a real host, so a bare
    /// word gets ".com" appended and a missing scheme gets "https://" prepended, the way a
    /// browser's own address bar completes a typed site name. Returns nil for anything that still
    /// can't resolve to a valid URL, which is what disables the "Aç" button.
    private func normalizedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var candidate = trimmed
        if !candidate.lowercased().hasPrefix("http://"), !candidate.lowercased().hasPrefix("https://") {
            candidate = "https://" + candidate
        }
        guard var components = URLComponents(string: candidate), let host = components.host, !host.isEmpty else { return nil }
        if !host.contains(".") {
            components.host = host + ".com"
        }
        guard let url = components.url, RovaValidation.isAllowedURL(url.absoluteString) else { return nil }
        return url
    }

    private func openTypedURL() {
        guard let resolved = normalizedURL(from: urlText) else { return }
        hapticImpact()
        Task { _ = await model.send(.openURL, payload: .url(resolved.absoluteString)) }
    }

    private var trustGrantsCard: some View {
        RovaCard {
            Text("Onaylı Eylemler").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text("Wiqo bunları daha önce onayladığın için artık sormadan yapıyor.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(trustGrants) { grant in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(grant.label).font(.subheadline)
                        Text(grant.grantedAt).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button {
                        Task {
                            try? await RovaBackendClient.revokeTrustGrant(id: grant.id)
                            trustGrants.removeAll { $0.id == grant.id }
                        }
                    } label: {
                        Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(grant.label) için onayı geri al")
                }
            }
        }
    }

    private var activityCard: some View {
        RovaCard {
            Text("Etkinlik").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if model.activities.isEmpty {
                Text("Henüz komut yok").foregroundStyle(.secondary).font(.subheadline)
            } else {
                ForEach(model.activities.prefix(8)) { activity in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity.title).font(.subheadline.weight(.medium))
                        Text(activity.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func errorCard(_ error: String) -> some View {
        RovaCard {
            DisclosureGroup("Ayrıntı") {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 3)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func loadDevicesAndTrust() async {
        async let fetchedDevices = try? RovaBackendClient.fetchDevices()
        async let fetchedTrustGrants = try? RovaBackendClient.fetchTrustGrants()
        backendDevices = (await fetchedDevices) ?? []
        trustGrants = (await fetchedTrustGrants) ?? []
    }

    private func displayPlatformName(_ platform: String) -> String {
        let normalized = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isDesktopPlatform = normalized.contains("mac")
            || normalized.contains("windows")
            || normalized == "win32"
            || normalized.contains("linux")
            || normalized == "desktop"
        return isDesktopPlatform ? "PC" : platform
    }

    private var statusText: String {
        model.userFacingConnectionLabel
    }

    private var statusColor: Color {
        model.state == .connected ? .green : .secondary
    }

    private func icon(for id: ApplicationID) -> String {
        switch id {
        case .safari: return "safari"
        case .xcode: return "hammer"
        case .terminal: return "terminal"
        case .finder: return "face.smiling"
        case .visualStudioCode: return "chevron.left.forwardslash.chevron.right"
        case .mail: return "envelope.fill"
        case .music: return "music.note"
        case .messages: return "message.fill"
        case .notes: return "note.text"
        case .systemSettings: return "gearshape.fill"
        }
    }

    private func formatUptime(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let hours = totalMinutes / 60
        let days = hours / 24
        if days > 0 {
            return "\(days)d \(hours % 24)h"
        } else if hours > 0 {
            return "\(hours)h \(totalMinutes % 60)m"
        } else {
            return "\(max(1, totalMinutes))m"
        }
    }

    private func hapticImpact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private func hapticNotification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}

/// Shared plain-row style for a tappable settings-style action (used by both the general and
/// PC-specific settings screens).
private func settingsRow(title: String, systemImage: String, isDestructive: Bool = false) -> some View {
    HStack(spacing: 10) {
        Image(systemName: systemImage).frame(width: 22)
        Text(title).font(.subheadline.weight(.medium))
        Spacer()
    }
    .foregroundStyle(isDestructive ? Color.red : Color.primary)
    .contentShape(Rectangle())
}
