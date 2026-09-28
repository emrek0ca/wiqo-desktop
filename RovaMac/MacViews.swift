import AppKit
import CoreImage
import SwiftUI

struct MacMenuView: View {
    @ObservedObject var runtime: MacRuntime
    @ObservedObject private var agentAccess = AgentAccessStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(runtime.isPhoneConnected ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text("Wiqo").font(.headline)
            }
            Label(connectionStatusText, systemImage: connectionStatusIcon)
                .font(.subheadline)
            if runtime.serviceState == .failed {
                failureActions
            } else if let detail = runtime.startupDetail, runtime.serviceState != .starting {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if agentAccess.isEnabled {
                Divider()
                Label(agentAccess.currentStep.map { "Ajan çalışıyor: \($0)" } ?? "Tam yetki açık", systemImage: "bolt.shield.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                Button {
                    agentAccess.setEnabled(false)
                } label: {
                    Label("Durdur ve tam yetkiyi kapat", systemImage: "stop.circle")
                }
            }
            Divider()
            Button {
                openWindow(id: RovaWindowID.pairingQR)
                bringPairingWindowToFront()
            } label: {
                Label("Telefonu bağla", systemImage: "qrcode")
            }
            if let name = runtime.pairedDeviceName {
                Label(name, systemImage: "iphone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsLink {
                Label("Ayarları Aç", systemImage: "gearshape")
            }
            Divider()
            Button("Wiqo'yu kapat") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 250)
    }

    private func bringPairingWindowToFront() {
        // SwiftUI creates a Window scene on the next run-loop turn. Retry briefly
        // so a menu-bar-only app cannot leave the QR window behind another app.
        for delay in [0.0, 0.1, 0.3, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApp.activate(ignoringOtherApps: true)
                guard let window = NSApp.windows.first(where: { $0.title == "Wiqo telefonu bağla" }) else { return }
                window.level = .floating
                window.orderFrontRegardless()
                window.makeKey()
            }
        }
    }

    private var connectionStatusText: String {
        if runtime.connectedDeviceID != nil { return "iPhone bağlı" }
        if runtime.backendSessionActive { return "İnternet üzerinden hazır" }
        if runtime.isPaired { return "iPhone bağlı değil" }
        switch runtime.serviceState {
        case .running: return "Telefonunu bağlamaya hazır"
        case .starting: return runtime.startupDetail ?? "Wiqo açılıyor…"
        case .failed: return "Wiqo başlatılamadı"
        case .stopped: return "PC’ye ulaşılamıyor"
        }
    }

    private var connectionStatusIcon: String {
        runtime.isPhoneConnected ? "checkmark.circle.fill" : "exclamationmark.triangle"
    }

    @ViewBuilder
    private var failureActions: some View {
        if let error = runtime.serviceError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Button("Yeniden dene") { runtime.restart() }
        Button("Sertifikayı yenile") { runtime.resetCertificateAndRestart() }
            .help("Yeni bir yerel sertifika oluşturur. Yerel ağ üzerinden eşleşmiş telefonlar yeniden eşleşmelidir.")
    }
}

struct MacWelcomeView: View {
    let onComplete: () -> Void
    @ObservedObject var runtime: MacRuntime

    init(onComplete: @escaping () -> Void, runtime: MacRuntime) {
        self.onComplete = onComplete
        self.runtime = runtime
    }

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("Wiqo'ya hoş geldin")
                    .font(.title2.weight(.bold))

                Text("Bilgisayarını telefonundan, konuşarak yönet.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    instructionRow(number: "1", text: "iPhone'da Wiqo'yu aç.")
                    instructionRow(number: "2", text: "Sağdaki kodu Wiqo'da tara.")
                    instructionRow(number: "3", text: "Bağlanınca ilk komutunu ver.")
                }
                .padding(.top, 4)

                Text("Kurulum tamamlandığında bu pencereyi kapatabilirsin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Anladım") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(width: 310, alignment: .leading)

            Divider()

            PairingQRView(runtime: runtime)
        }
        .padding(24)
        .frame(width: 740, height: 450)
    }

    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())

            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PairingQRView: View {
    @ObservedObject var runtime: MacRuntime

    var body: some View {
        VStack(spacing: 14) {
            Text("Telefonunu bağla").font(.title3.weight(.semibold))
            content
        }
        .padding(24)
        .frame(width: 320, height: 380)
        .onAppear {
            // Always show a fresh 5-minute code: a code generated at app launch (or the last
            // time this window was opened) could otherwise already be expired or seconds from
            // expiring, which used to surface as a confusing generic "invalid QR" on the phone.
            runtime.regeneratePairing()
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                guard let window = NSApp.windows.first(where: { $0.title == "Wiqo telefonu bağla" }) else { return }
                window.level = .floating
                window.orderFrontRegardless()
                window.makeKey()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch runtime.relayPairing {
        case .paired:
            if runtime.backendSessionActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("Telefon bağlandı").font(.headline)
                Text("Wiqo'yu telefonundan kullanmaya başlayabilirsin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView("Bağlantı yeniden kuruluyor…")
                Text("Mac'in açık ve internete bağlı olduğundan emin ol.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .waiting(let payload):
            if let value = try? RovaQRCodec.encode(payload) {
                qrCode(value)
                Text("İnternet üzerinden güvenli bağlantı").font(.subheadline.weight(.semibold))
                Text("Bu kodu Wiqo uygulamasında tara. Kod 10 dakika geçerli.").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView("Güvenli bağlantı kuruluyor…")
            }
        case .preparing:
            ProgressView("Güvenli bağlantı kuruluyor…")
        case .unavailable:
            localNetworkContent
        }
    }

    /// The internet code needs the backend; without it the phone can still pair over the same Wi-Fi.
    @ViewBuilder
    private var localNetworkContent: some View {
        if runtime.serviceState == .failed {
            Text(runtime.serviceError ?? "Wiqo başlatılamadı.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else if runtime.serviceState == .running,
                  runtime.localIPAddress != MacNetwork.unavailableAddress,
                  let payload = runtime.pairingPayload,
                  let value = try? RovaQRCodec.encode(payload) {
            qrCode(value)
            Text("Kod: \(payload.pairingCode)").font(.title2.monospacedDigit())
            Text("İnternete ulaşılamıyor. Yalnızca aynı Wi-Fi ağında bağlanır.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            ProgressView("Ağ bağlantısı bekleniyor…")
        }
    }

    private func qrCode(_ value: String) -> some View {
        Group {
            if let image = makeQRCode(value) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 260, height: 260)
            }
        }
    }

    private func makeQRCode(_ value: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

struct MacSettingsView: View {
    @ObservedObject var runtime: MacRuntime
    @Environment(\.scenePhase) private var scenePhase
    /// Privacy permission states, computed off the main thread on appear/refresh - never in `body`.
    @State private var privacyPermissions: [MacPermission] = []

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("Genel", systemImage: "slider.horizontal.3") }
            devicesTab
                .tabItem { Label("Cihazlar", systemImage: "iphone.and.arrow.forward") }
            automationsTab
                .tabItem { Label("Otomasyonlar", systemImage: "clock.arrow.circlepath") }
            permissionsTab
                .tabItem { Label("İzinler", systemImage: "lock.shield") }
            CapabilitiesSettingsView()
                .tabItem { Label("Yetenekler", systemImage: "switch.2") }
            advancedTab
                .tabItem { Label("Gelişmiş", systemImage: "gearshape.2") }
        }
        .padding(20)
        // A fixed size: the Settings window sizes itself to its content, and grouped Forms (scroll
        // views) have no single ideal size - with only a minimum the two renegotiated forever
        // (a SwiftUI layout loop at 100% CPU that froze the app when Settings opened).
        .frame(width: 660, height: 500)
    }

    private var generalTab: some View {
        Form {
            Section("Wiqo") {
                Toggle("Girişte aç", isOn: Binding(
                    get: { runtime.launchAtLogin },
                    set: { value in runtime.setLaunchAtLogin(value) }
                ))
                LabeledContent("Hesap", value: runtime.backendSessionActive ? "Bağlı" : "iPhone bekleniyor")
            }
            if let error = runtime.serviceError {
                Section("Durum") { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }

    private var devicesTab: some View {
        Form {
            Section("Bağlı telefon") {
                if let name = runtime.pairedDeviceName {
                    LabeledContent("iPhone", value: name)
                    LabeledContent("Bağlantı", value: runtime.connectedDeviceID == nil ? "Bağlı değil" : "Bağlı")
                    Button("Cihaz yetkisini kaldır", role: .destructive) { runtime.revokeCurrentDevice() }
                } else {
                    Text("Bağlı telefon yok").foregroundStyle(.secondary)
                }
            }
            Section("Bağlantı") {
                Button("Yeni bağlantı kodu oluştur") { runtime.regeneratePairing() }
                Button("Tüm cihazların yetkisini kaldır", role: .destructive) { runtime.revokeAllDevices() }
            }
        }
        .formStyle(.grouped)
    }

    private var permissionsTab: some View {
        Form {
            Section("Gizlilik izinleri") {
                if privacyPermissions.isEmpty {
                    ProgressView().controlSize(.small)
                }
                ForEach(privacyPermissions) { permission in
                    HStack(spacing: 10) {
                        Image(systemName: permission.granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(permission.granted ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(permission.title).font(.body.weight(.medium))
                            Text(permission.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Aç") { openSettings(permission.url) }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
            }
            Section("Uygulama izinleri") {
                if runtime.automationPermissions.isEmpty && runtime.isRefreshingPermissions {
                    ProgressView("İzin durumu okunuyor…")
                } else {
                    ForEach(runtime.automationPermissions) { permission in
                        HStack(spacing: 10) {
                            Image(systemName: automationPermissionIcon(permission.status))
                                .foregroundStyle(automationPermissionColor(permission.status))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(permission.title).font(.body.weight(.medium))
                                Text(permission.message ?? permission.bundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Aç") { openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") }
                                .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 3)
                    }
                }
                Button {
                    Task { await runtime.warmUpAutomationPermissions() }
                } label: {
                    if runtime.isWarmingAutomationPermissions {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Tüm İzinleri Şimdi İste")
                }
                .disabled(runtime.isWarmingAutomationPermissions)
                if let message = runtime.permissionActionMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Wiqo Shortcuts") {
                Button("Shortcuts'ı Kur") { runtime.installWiqoShortcuts() }
                ForEach(WiqoShortcut.allCases, id: \.self) { shortcut in
                    LabeledContent(shortcut.displayName, value: runtime.installedWiqoShortcuts.contains(shortcut) ? "Kurulu" : "Eksik")
                        .foregroundStyle(runtime.installedWiqoShortcuts.contains(shortcut) ? .green : .secondary)
                }
                if let message = runtime.shortcutInstallMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Durumu yenile") {
                    runtime.refreshPermissions()
                    refreshPrivacyPermissions()
                }
                .disabled(runtime.isRefreshingPermissions)
            }
        }
        .formStyle(.grouped)
        // No `.id(counter)` here: bumping a counter in onAppear that is also the view's identity
        // recreated the view, which ran onAppear again - an endless rebuild at 100% CPU that froze
        // the app the moment Settings opened. Results live in state; refreshing only updates them.
        .onAppear {
            runtime.refreshPermissions()
            refreshPrivacyPermissions()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            runtime.refreshPermissions()
            refreshPrivacyPermissions()
        }
    }

    private var automationsTab: some View {
        Form {
            Section("Otomasyonlar") {
                if runtime.isLoadingAutomations {
                    ProgressView("Yükleniyor…")
                } else if let error = runtime.automationsError {
                    Text(error).foregroundStyle(.red)
                    Button("Tekrar dene") {
                        Task { await runtime.refreshAutomations() }
                    }
                } else if runtime.automations.isEmpty {
                    Text("Kayıtlı otomasyon yok").foregroundStyle(.secondary)
                } else {
                    ForEach(runtime.automations) { automation in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(automation.prompt)
                                .font(.body.weight(.medium))
                                .lineLimit(2)
                            HStack {
                                Label(automation.cron == "@trigger" ? "Koşul" : automation.cron, systemImage: "clock")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(automation.isActive ? "Aktif" : "Kapalı")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(automation.isActive ? .green : .secondary)
                                Button("İptal", role: .destructive) {
                                    Task { await runtime.cancelAutomation(automation) }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await runtime.refreshAutomations() }
    }

    private var advancedTab: some View {
        Form {
            Section("Servis") {
                LabeledContent("Durum", value: serviceStateText)
                LabeledContent("Port", value: String(runtime.port))
                LabeledContent("Yerel adres", value: runtime.localIPAddress)
                LabeledContent("iPhone bağlantısı", value: runtime.connectedDeviceID == nil ? "Bağlı değil" : "Bağlı")
            }
        }
        .formStyle(.grouped)
    }

    private var serviceStateText: String {
        switch runtime.serviceState {
        case .running: return "Çalışıyor"
        case .starting: return "Başlıyor"
        case .stopped: return "Durduruldu"
        case .failed: return "Hatalı"
        }
    }

    private func automationPermissionIcon(_ status: MacAutomationPermissionStatus) -> String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied, .unavailable: return "xmark.circle.fill"
        case .notChecked: return "questionmark.circle.fill"
        }
    }

    private func automationPermissionColor(_ status: MacAutomationPermissionStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied, .unavailable: return .red
        case .notChecked: return .orange
        }
    }

    /// Checks the four privacy permissions off the main thread (the disk check touches the file
    /// system) and publishes them once; `body` only reads the stored result.
    private func refreshPrivacyPermissions() {
        Task { @MainActor in
            let rows = await Task.detached(priority: .userInitiated) {
                [
                    MacPermission(id: "accessibility", title: "Erişilebilirlik", detail: "Arayüz kontrolü ve ekran tıklaması için", granted: MacSystem.hasAccessibilityAccess(), url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
                    MacPermission(id: "full-disk", title: "Tam Disk Erişimi", detail: "Belgeleri okuyup kaydetmek için", granted: MacSystem.hasFullDiskAccess(), url: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
                    MacPermission(id: "screen-recording", title: "Ekran Kaydı", detail: "Ekran gözlemi için", granted: MacSystem.hasScreenRecordingAccess(), url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
                    MacPermission(id: "calendar", title: "Takvim", detail: "Takvim adımları için", granted: MacSystem.hasCalendarAccess(), url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
                ]
            }.value
            privacyPermissions = rows
        }
    }

    private func openSettings(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct MacPermission: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let granted: Bool
    let url: String
}
