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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private var availableApps: [ApplicationInfo] {
        model.deviceInfo?.availableApplications ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if subscriptionStore.info.pcAllowed {
                        if model.isPaired {
                            header
                            controlGroup
                            powerGroup
                            openGroup
                            deviceGroup
                            if let error = model.lastError { errorFootnote(error) }
                        } else {
                            pairingPromptCard
                        }
                    } else {
                        pcUpsellCard
                    }
                }
                .padding(.horizontal, RovaDesign.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(RovaDesign.canvas)
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

    // MARK: - Sections

    /// Who this is and whether it is reachable: a name, one quiet line, and a way back only when it is not connected.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(model.state == .connected ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 9, height: 9)
                Text(model.deviceInfo?.displayName ?? "PC")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                if model.state == .connecting { ProgressView().controlSize(.small) }
            }
            Text(statusSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if model.state != .connected {
                HStack(spacing: 10) {
                    Text(model.isReconnecting ? String(localized: "Bağlantıyı yeniden kuruyorum…") : model.userFacingConnectionError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if !model.isReconnecting {
                        Button("Tekrar dene") { model.retry() }
                            .buttonStyle(.wiqoPill(.secondary))
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 6)
    }

    private var statusSubtitle: String {
        var parts = [statusText]
        if let status = model.systemStatus {
            if let battery = status.batteryPercentage {
                parts.append(status.isCharging == true ? String(localized: "%\(battery) şarjda") : "%\(battery)")
            }
        }
        return parts.joined(separator: " · ")
    }

    private var controlGroup: some View {
        WiqoSettingsGroup(title: String(localized: "Kontrol")) {
            sliderRow(systemImage: "speaker.wave.2.fill", title: String(localized: "Ses"), value: $volume) { level in
                _ = await model.setVolume(level)
            }
            sliderRow(systemImage: "sun.max.fill", title: String(localized: "Parlaklık"), value: $brightness) { level in
                _ = await model.setBrightness(level)
            }
            HStack(spacing: 0) {
                Text("Medya").font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                mediaButton("backward.fill", label: String(localized: "Önceki parça")) { _ = await model.mediaControl(.previousTrack) }
                mediaButton("playpause.fill", label: String(localized: "Oynat veya duraklat")) { _ = await model.mediaControl(.playPause) }
                mediaButton("forward.fill", label: String(localized: "Sonraki parça")) { _ = await model.mediaControl(.nextTrack) }
                mediaButton("speaker.slash.fill", label: String(localized: "Sessize al")) { _ = await model.toggleMute() }
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(minHeight: 52)
            .disabled(model.state != .connected)
        }
    }

    private var powerGroup: some View {
        WiqoSettingsGroup(title: String(localized: "Güç")) {
            Button { showingLockConfirmation = true } label: {
                WiqoRow(systemImage: "lock.fill", title: String(localized: "PC'yi kilitle"))
            }
            .buttonStyle(WiqoRowButtonStyle())
            Button { showingSleepConfirmation = true } label: {
                WiqoRow(systemImage: "moon.fill", title: String(localized: "Uyku moduna al"))
            }
            .buttonStyle(WiqoRowButtonStyle())
            Button { showingDisplaySleepConfirmation = true } label: {
                WiqoRow(systemImage: "display", title: String(localized: "Ekranı uyut"), showsDivider: false)
            }
            .buttonStyle(WiqoRowButtonStyle())
        }
        .disabled(model.state != .connected)
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

    /// Apps, an address and the clipboard: the three things one sends to the PC by hand, one row each.
    private var openGroup: some View {
        WiqoSettingsGroup(title: String(localized: "PC'ye gönder")) {
            Menu {
                ForEach(availableApps) { app in
                    Button {
                        hapticImpact()
                        Task { _ = await model.send(.openApplication, payload: .application(app.id)) }
                    } label: {
                        Label(app.name, systemImage: icon(for: app.id))
                    }
                }
                if !availableApps.isEmpty {
                    Divider()
                    Menu(String(localized: "Kapat")) {
                        ForEach(availableApps) { app in
                            Button(app.name, role: .destructive) {
                                Task { _ = await model.quitApplication(app.id) }
                            }
                        }
                    }
                }
            } label: {
                WiqoRow(systemImage: "square.grid.2x2", title: String(localized: "Uygulama aç"))
            }
            .disabled(availableApps.isEmpty || model.state != .connected)

            fieldRow(systemImage: "link", placeholder: String(localized: "Adres aç (youtube.com)"), text: $urlText, sendSymbol: "arrow.up.right",
                     canSend: normalizedURL(from: urlText) != nil, keyboard: .URL, action: openTypedURL)

            fieldRow(systemImage: "doc.on.clipboard", placeholder: String(localized: "Panoya yaz"), text: $clipboardText, sendSymbol: "arrow.up",
                     canSend: !clipboardText.isEmpty, keyboard: .default, showsDivider: false) {
                guard !clipboardText.isEmpty else { return }
                hapticImpact()
                Task {
                    _ = await model.setClipboardText(clipboardText)
                    clipboardText = ""
                    hapticNotification(.success)
                }
            }
        }
    }

    /// What this PC can do and how it is known: capabilities, what was allowed ahead of time, recent activity, the devices, and forgetting it.
    private var deviceGroup: some View {
        WiqoSettingsGroup(title: String(localized: "Cihaz")) {
            NavigationLink {
                DeviceCapabilitiesView(authorities: model.deviceInfo?.authorities ?? [])
            } label: {
                WiqoRow(systemImage: "checklist", title: String(localized: "Yetenekler"), subtitle: String(localized: "PC'nde nelerin hazır olduğunu gör"))
            }
            .buttonStyle(WiqoRowButtonStyle())

            if !trustGrants.isEmpty {
                NavigationLink {
                    PCTrustGrantsPage(grants: $trustGrants)
                } label: {
                    WiqoRow(systemImage: "checkmark.shield", title: String(localized: "Onaylı eylemler"), subtitle: String(localized: "\(trustGrants.count) eylem sormadan yapılıyor"))
                }
                .buttonStyle(WiqoRowButtonStyle())
            }

            if !model.activities.isEmpty {
                NavigationLink {
                    PCActivityPage(activities: model.activities)
                } label: {
                    WiqoRow(systemImage: "clock.arrow.circlepath", title: String(localized: "Son etkinlik"))
                }
                .buttonStyle(WiqoRowButtonStyle())
            }

            ForEach(backendDevices) { device in
                Button {
                    renameText = device.displayName
                    renamingDeviceID = device.id
                } label: {
                    WiqoRow(systemImage: "laptopcomputer", title: device.displayName,
                            subtitle: device.online ? String(localized: "Bağlı") : String(localized: "Çevrimdışı")) {
                        Image(systemName: "pencil").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(WiqoRowButtonStyle())
                .contextMenu {
                    Button(role: .destructive) { deletingDeviceID = device.id } label: { Label("Sil", systemImage: "trash") }
                }
            }

            Button(role: .destructive) {
                showingForgetMacConfirmation = true
            } label: {
                WiqoRow(systemImage: "laptopcomputer.slash", title: "PC'yi unut", isDestructive: true, showsDivider: false)
            }
            .buttonStyle(WiqoRowButtonStyle())
        }
        .wiqoConfirmation(String(localized: "PC'yi unutmak istediğine emin misin?"), isPresented: $showingForgetMacConfirmation) {
            Button("PC'yi unut", role: .destructive) { model.forgetPairing(); dismiss() }
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

    private func errorFootnote(_ error: String) -> some View {
        DisclosureGroup("Ayrıntı") {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 3)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }

    // MARK: - Row pieces

    private func sliderRow(systemImage: String, title: String, value: Binding<Double>, commit: @escaping (Int) async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.footnote).foregroundStyle(.secondary).frame(width: 20)
                Text(title).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text("%\(Int(value.wrappedValue))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...100, step: 5) { editing in
                if !editing {
                    hapticImpact()
                    Task { await commit(Int(value.wrappedValue)) }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .disabled(model.state != .connected)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WiqoTheme.line).frame(height: 0.5).padding(.leading, 14)
        }
    }

    private func mediaButton(_ symbol: String, label: String, action: @escaping () async -> Void) -> some View {
        Button {
            hapticImpact(.light)
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func fieldRow(systemImage: String, placeholder: String, text: Binding<String>, sendSymbol: String, canSend: Bool,
                          keyboard: UIKeyboardType, showsDivider: Bool = true, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(WiqoTheme.ink)
                .frame(width: 28, height: 28)
                .background(WiqoTheme.tint(WiqoTheme.ink), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            TextField(placeholder, text: text)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .submitLabel(.go)
                .onSubmit { if canSend && model.state == .connected { action() } }
            Button(action: action) {
                Image(systemName: sendSymbol)
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(canSend && model.state == .connected ? Color.accentColor : WiqoTheme.inset, in: Circle())
                    .foregroundStyle(canSend && model.state == .connected ? Color.white : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend || model.state != .connected)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) {
            if showsDivider { Rectangle().fill(WiqoTheme.line).frame(height: 0.5).padding(.leading, 54) }
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

    private func hapticImpact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private func hapticNotification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}

// MARK: - Sub-pages

/// What Wiqo may do without asking, each with a way to take that back.
private struct PCTrustGrantsPage: View {
    @Binding var grants: [RovaBackendClient.TrustGrant]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Wiqo bunları daha önce onayladığın için artık sormadan yapıyor.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                WiqoSettingsGroup {
                    ForEach(Array(grants.enumerated()), id: \.element.id) { index, grant in
                        WiqoRow(systemImage: "checkmark.shield", title: grant.label, subtitle: grant.grantedAt, showsDivider: index < grants.count - 1) {
                            Button {
                                let id = grant.id
                                Task {
                                    try? await RovaBackendClient.revokeTrustGrant(id: id)
                                    grants.removeAll { $0.id == id }
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
            .padding(RovaDesign.screenPadding)
        }
        .background(RovaDesign.canvas)
        .navigationTitle("Onaylı eylemler")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The last commands sent to the PC.
private struct PCActivityPage: View {
    let activities: [IOSActivity]

    var body: some View {
        ScrollView {
            WiqoSettingsGroup {
                ForEach(Array(activities.prefix(30).enumerated()), id: \.element.id) { index, activity in
                    WiqoRow(systemImage: "terminal", title: activity.title, subtitle: activity.detail, showsDivider: index < min(activities.count, 30) - 1) {
                        EmptyView()
                    }
                }
            }
            .padding(RovaDesign.screenPadding)
        }
        .background(RovaDesign.canvas)
        .navigationTitle("Son etkinlik")
        .navigationBarTitleDisplayMode(.inline)
    }
}
