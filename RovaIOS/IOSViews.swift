import SwiftUI

struct RootView: View {
    @ObservedObject var model: IOSConnectionModel
    @ObservedObject var authSession: AuthSessionStore

    var body: some View {
        Group {
            if !authSession.isAuthenticated {
                AuthView { authSession.refresh() }
            } else if model.isPaired {
                TabView {
                    CopilotView(model: model, authSession: authSession)
                        .tabItem { Label("Rova", systemImage: "sparkles") }
                    HomeView(model: model, authSession: authSession)
                        .tabItem { Label("Mac", systemImage: "laptopcomputer") }
                }
            } else {
                PairingView(model: model)
            }
        }
        .onChange(of: authSession.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated { model.sendBackendTokenIfAvailable() }
        }
    }
}

struct PairingView: View {
    @ObservedObject var model: IOSConnectionModel
    @State private var showingScanner = false
    @State private var scanError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.tint)
                Text("Connect to your Mac")
                    .font(.title2.weight(.semibold))
                Text("Rova Mac’te gösterilen QR kodu tarayarak güvenli bağlantı kur.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button {
                    showingScanner = true
                } label: {
                    Label("Scan Pairing QR", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if model.isPairing { ProgressView("Pairing…") }
                if let error = scanError ?? model.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding(28)
            .navigationTitle("Rova")
            .sheet(isPresented: $showingScanner) {
                QRScannerView { value in
                    showingScanner = false
                    do {
                        model.pair(using: try RovaQRCodec.decode(value))
                        scanError = nil
                    } catch {
                        scanError = "Geçersiz Rova QR kodu."
                    }
                } onCancel: {
                    showingScanner = false
                }
                .ignoresSafeArea()
            }
        }
    }
}

struct HomeView: View {
    @ObservedObject var model: IOSConnectionModel
    @ObservedObject var authSession: AuthSessionStore
    @State private var showingLockConfirmation = false
    @State private var showingSleepConfirmation = false
    @State private var showingDisplaySleepConfirmation = false
    @State private var volume: Double = 50
    @State private var brightness: Double = 80
    @State private var urlText = "https://www.apple.com"
    @State private var clipboardText = ""
    @State private var tasks: [RovaBackendClient.RovaTask] = []
    @State private var automations: [RovaBackendClient.RovaAutomation] = []
    @Environment(\.scenePhase) private var scenePhase

    private var availableApps: [ApplicationInfo] {
        model.deviceInfo?.availableApplications ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: RovaDesign.cardSpacing) {
                    statusCard
                    quickActionsCard
                    mediaCard
                    displayCard
                    appsCard
                    clipboardCard
                    urlCard
                    if !pendingTasks.isEmpty || !activeAutomations.isEmpty { tasksAutomationsCard }
                    activityCard
                    if let error = model.lastError { errorCard(error) }
                }
                .padding(RovaDesign.screenPadding)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Mac")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.retry() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Retry connection")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Ping") { Task { _ = await model.send(.ping) } }
                        Button("Refresh Status") { Task { _ = await model.send(.getSystemStatus) } }
                        Divider()
                        Button("Forget Mac", role: .destructive) { model.forgetPairing() }
                        Button("Rova Hesabından Çıkış Yap", role: .destructive) { authSession.signOut() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .task {
            model.connect()
            await loadTasksAndAutomations()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.connect() }
        }
        .onChange(of: model.systemStatus) { _, status in
            if let level = status?.volumePercentage { volume = Double(level) }
            if let level = status?.brightnessPercentage { brightness = Double(level) }
        }
    }

    // MARK: - Cards

    private var statusCard: some View {
        RovaCard {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.deviceInfo?.displayName ?? "My Mac").font(.headline)
                    HStack(spacing: 6) {
                        Text(statusText).font(.subheadline).foregroundStyle(statusColor)
                        if model.state == .connected {
                            Image(systemName: model.connectionQuality.symbolName)
                                .font(.caption2)
                                .foregroundStyle(qualityColor)
                            if let latency = model.lastPingLatencyMs {
                                Text("\(model.connectionQuality.label) • \(latency) ms")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer()
                if model.state == .connecting { ProgressView() }
            }
            if let status = model.systemStatus {
                Divider()
                HStack {
                    Label(status.macOSVersion, systemImage: "apple.logo")
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
                    RovaActionTile(title: "Kilitle", systemImage: "lock.fill", isDestructive: true) {
                        showingLockConfirmation = true
                    }
                    RovaActionTile(title: "Uyku", systemImage: "moon.fill", isDestructive: true) {
                        showingSleepConfirmation = true
                    }
                    RovaActionTile(title: "Ekran Uyut", systemImage: "display", isDestructive: true) {
                        showingDisplaySleepConfirmation = true
                    }
                    RovaActionTile(title: "Geri", systemImage: "backward.fill") {
                        hapticImpact(); Task { _ = await model.mediaControl(.previousTrack) }
                    }
                    RovaActionTile(title: "Oynat/Duraklat", systemImage: "playpause.fill") {
                        hapticImpact(); Task { _ = await model.mediaControl(.playPause) }
                    }
                    RovaActionTile(title: "İleri", systemImage: "forward.fill") {
                        hapticImpact(); Task { _ = await model.mediaControl(.nextTrack) }
                    }
                    RovaActionTile(title: "Sessiz", systemImage: "speaker.slash.fill") {
                        hapticImpact(); Task { _ = await model.toggleMute() }
                    }
                }
            }
            .disabled(model.state != .connected)
        }
        .confirmationDialog("Mac kilitlenecek. Devam et?", isPresented: $showingLockConfirmation, titleVisibility: .visible) {
            Button("Lock Mac", role: .destructive) {
                hapticImpact()
                Task {
                    let ok = await model.authenticateBiometrics(reason: "Mac'i kilitlemek için kimliğinizi doğrulayın")
                    if ok { _ = await model.send(.lockMac) }
                }
            }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Mac uyku moduna alınacak. Devam et?", isPresented: $showingSleepConfirmation, titleVisibility: .visible) {
            Button("Sleep Mac", role: .destructive) {
                hapticImpact()
                Task {
                    let ok = await model.authenticateBiometrics(reason: "Mac'i uykuya almak için kimliğinizi doğrulayın")
                    if ok { _ = await model.sleepMac() }
                }
            }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Mac ekranı uyutulacak. Devam et?", isPresented: $showingDisplaySleepConfirmation, titleVisibility: .visible) {
            Button("Display Sleep", role: .destructive) {
                hapticImpact()
                Task { _ = await model.displaySleep() }
            }
            Button("Cancel", role: .cancel) { }
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
                .buttonStyle(.borderedProminent)
                .disabled(clipboardText.isEmpty || model.state != .connected)
            }
        }
    }

    private var urlCard: some View {
        RovaCard {
            Text("URL Aç").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            TextField("https://…", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Open in Browser") {
                hapticImpact()
                Task { _ = await model.send(.openURL, payload: .url(urlText)) }
            }
            .disabled(model.state != .connected)
        }
    }

    private var pendingTasks: [RovaBackendClient.RovaTask] {
        tasks.filter { $0.status == "pending" }
    }

    private var activeAutomations: [RovaBackendClient.RovaAutomation] {
        automations.filter(\.isActive)
    }

    private var tasksAutomationsCard: some View {
        RovaCard {
            if !pendingTasks.isEmpty {
                Text("Görevler").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(pendingTasks) { task in
                    HStack {
                        Image(systemName: "circle").foregroundStyle(.secondary)
                        Text(task.title).font(.subheadline)
                        Spacer()
                    }
                }
            }
            if !activeAutomations.isEmpty {
                if !pendingTasks.isEmpty { Divider() }
                Text("Otomasyonlar").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(activeAutomations) { automation in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(automation.prompt).font(.subheadline)
                            Text(automation.cron).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task {
                                try? await RovaBackendClient.cancelAutomation(id: automation.id)
                                await loadTasksAndAutomations()
                            }
                        } label: {
                            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
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
            Text(error).foregroundStyle(.red).font(.subheadline)
        }
    }

    private func loadTasksAndAutomations() async {
        async let fetchedTasks = try? RovaBackendClient.fetchTasks()
        async let fetchedAutomations = try? RovaBackendClient.fetchAutomations()
        tasks = (await fetchedTasks) ?? []
        automations = (await fetchedAutomations) ?? []
    }

    private var statusText: String {
        switch model.state {
        case .connected: return "Online"
        case .connecting: return "Connecting…"
        case .failed: return "Connection failed"
        case .disconnected: return "Mac Offline"
        }
    }

    private var qualityColor: Color {
        switch model.connectionQuality {
        case .unknown: return .secondary
        case .weak: return .red
        case .good: return .orange
        case .excellent: return .green
        }
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
