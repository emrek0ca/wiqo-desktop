import SwiftUI

struct RootView: View {
    @ObservedObject var model: IOSConnectionModel

    var body: some View {
        Group {
            if model.isPaired { HomeView(model: model) } else { PairingView(model: model) }
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
    @State private var showingLockConfirmation = false
    @State private var showingSleepConfirmation = false
    @State private var showingDisplaySleepConfirmation = false
    @State private var volume: Double = 50
    @State private var brightness: Double = 80
    @State private var urlText = "https://www.apple.com"
    @State private var clipboardText = ""
    @State private var showingCopilot = false
    @Environment(\.scenePhase) private var scenePhase

    private var availableApps: [ApplicationInfo] {
        model.deviceInfo?.availableApplications ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
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
                }
                if let status = model.systemStatus {
                    Section("System Status") {
                        LabeledContent("macOS", value: status.macOSVersion)
                        if let battery = status.batteryPercentage {
                            let chargingSuffix = (status.isCharging == true) ? " (Charging)" : ""
                            LabeledContent("Battery", value: "\(battery)%\(chargingSuffix)")
                        }
                        LabeledContent("Uptime", value: formatUptime(status.uptimeSeconds))
                    }
                }
                Section("Media & Audio") {
                    HStack(spacing: 20) {
                        Button {
                            hapticImpact()
                            Task { _ = await model.mediaControl(.previousTrack) }
                        } label: {
                            Image(systemName: "backward.fill").font(.title3)
                        }
                        .buttonStyle(.borderless)

                        Button {
                            hapticImpact()
                            Task { _ = await model.mediaControl(.playPause) }
                        } label: {
                            Image(systemName: "playpause.fill").font(.title2)
                        }
                        .buttonStyle(.borderless)

                        Button {
                            hapticImpact()
                            Task { _ = await model.mediaControl(.nextTrack) }
                        } label: {
                            Image(systemName: "forward.fill").font(.title3)
                        }
                        .buttonStyle(.borderless)

                        Spacer()

                        Button {
                            hapticImpact()
                            Task { _ = await model.toggleMute() }
                        } label: {
                            Image(systemName: "speaker.slash.fill").font(.title3)
                        }
                        .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .disabled(model.state != .connected)

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
                Section("Display & Screen") {
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

                    Button {
                        showingDisplaySleepConfirmation = true
                    } label: {
                        Label("Display Sleep", systemImage: "display")
                    }
                    .disabled(model.state != .connected)
                    .confirmationDialog("Mac ekranı uyutulacak. Devam et?", isPresented: $showingDisplaySleepConfirmation, titleVisibility: .visible) {
                        Button("Display Sleep", role: .destructive) {
                            hapticImpact()
                            Task { _ = await model.displaySleep() }
                        }
                        Button("Cancel", role: .cancel) { }
                    }
                }
                Section("Quick Actions & Apps") {
                    ForEach(availableApps) { app in
                        HStack {
                            Button {
                                hapticImpact()
                                Task { _ = await model.send(.openApplication, payload: .application(app.id)) }
                            } label: {
                                Label("Open \(app.name)", systemImage: icon(for: app.id))
                            }
                            Spacer()
                            Button(role: .destructive) {
                                hapticImpact()
                                Task { _ = await model.quitApplication(app.id) }
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Quit \(app.name)")
                        }
                        .disabled(model.state != .connected)
                    }
                    Button {
                        showingLockConfirmation = true
                    } label: {
                        Label("Lock Mac", systemImage: "lock.fill")
                    }
                    .disabled(model.state != .connected)
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

                    Button {
                        showingSleepConfirmation = true
                    } label: {
                        Label("Sleep Mac", systemImage: "moon.fill")
                    }
                    .disabled(model.state != .connected)
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
                }
                Section("Mac Clipboard") {
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
                Section("Open URL") {
                    TextField("https://…", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Open in Browser") {
                        hapticImpact()
                        Task { _ = await model.send(.openURL, payload: .url(urlText)) }
                    }
                    .disabled(model.state != .connected)
                }
                Section("Activity") {
                    if model.activities.isEmpty {
                        Text("No recent commands").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.activities) { activity in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(activity.title).font(.subheadline.weight(.medium))
                                Text(activity.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let error = model.lastError {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Rova")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingCopilot = true } label: { Image(systemName: "sparkles") }
                        .accessibilityLabel("Rova AI")
                }
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
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showingCopilot) {
                CopilotView(model: model)
            }
        }
        .task { model.connect() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.connect() }
        }
        .onChange(of: model.systemStatus) { _, status in
            if let level = status?.volumePercentage { volume = Double(level) }
            if let level = status?.brightnessPercentage { brightness = Double(level) }
        }
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
