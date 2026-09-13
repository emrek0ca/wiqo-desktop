import AppKit
import CoreImage
import SwiftUI

struct MacMenuView: View {
    @ObservedObject var runtime: MacRuntime
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rova").font(.headline)
            Label(connectionStatusText, systemImage: connectionStatusIcon)
            Divider()
            Text("This Mac").font(.subheadline.weight(.semibold))
            Text(Host.current().localizedName ?? "Mac")
            Text(runtime.localIPAddress).font(.caption).foregroundStyle(.secondary)
            Text("Service: \(runtime.serviceState.rawValue.capitalized)").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Pairing").font(.subheadline.weight(.semibold))
            Text("Kod: \(runtime.pairingCode)").monospacedDigit()
            Button {
                openWindow(id: RovaWindowID.pairingQR)
                bringPairingWindowToFront()
            } label: {
                Label("Show Pairing QR", systemImage: "qrcode")
            }
            if let name = runtime.pairedDeviceName {
                Divider()
                Text("Paired Device").font(.subheadline.weight(.semibold))
                Text(name)
                Text(runtime.connectedDeviceID == nil ? "Not connected" : "Connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Revoke Device", role: .destructive) { runtime.revokeCurrentDevice() }
            }
            Divider()
            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }
            Button("Quit Rova") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 240)
    }

    private func bringPairingWindowToFront() {
        // SwiftUI creates a Window scene on the next run-loop turn. Retry briefly
        // so a menu-bar-only app cannot leave the QR window behind another app.
        for delay in [0.0, 0.1, 0.3, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApp.activate(ignoringOtherApps: true)
                guard let window = NSApp.windows.first(where: { $0.title == "Pairing QR" }) else { return }
                window.level = .floating
                window.orderFrontRegardless()
                window.makeKey()
            }
        }
    }

    private var connectionStatusText: String {
        if runtime.connectedDeviceID != nil { return "Connected" }
        if runtime.serviceState == .running { return "Service Running" }
        if runtime.serviceState == .starting { return "Starting Service…" }
        return "Service unavailable"
    }

    private var connectionStatusIcon: String {
        if runtime.connectedDeviceID != nil || runtime.serviceState == .running {
            return "checkmark.circle.fill"
        }
        return "exclamationmark.triangle"
    }
}

struct PairingQRView: View {
    @ObservedObject var runtime: MacRuntime

    var body: some View {
        VStack(spacing: 14) {
            Text("Pair this iPhone").font(.title3.weight(.semibold))
            if let payload = runtime.pairingPayload, let value = try? RovaQRCodec.encode(payload), let image = makeQRCode(value) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 260, height: 260)
                Text("Kod: \(payload.pairingCode)").font(.title2.monospacedDigit())
                Text("Bu kod 5 dakika geçerli.").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView("TLS identity hazırlanıyor…")
            }
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
                guard let window = NSApp.windows.first(where: { $0.title == "Pairing QR" }) else { return }
                window.level = .floating
                window.orderFrontRegardless()
                window.makeKey()
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

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { runtime.launchAtLogin },
                    set: { value in runtime.setLaunchAtLogin(value) }
                ))
            }
            Section("Devices") {
                if let name = runtime.pairedDeviceName {
                    LabeledContent("Paired", value: name)
                    Button("Revoke Device", role: .destructive) { runtime.revokeCurrentDevice() }
                } else {
                    Text("No paired devices")
                }
            }
            Section("Network") {
                LabeledContent("Service", value: runtime.serviceState.rawValue.capitalized)
                LabeledContent("Connection", value: runtime.connectedDeviceID == nil ? "Not connected" : "Connected")
                LabeledContent("Port", value: String(runtime.port))
                LabeledContent("Local IP", value: runtime.localIPAddress)
                if let error = runtime.serviceError { Text(error).foregroundStyle(.red) }
            }
            Section("Security") {
                Button("Regenerate Pairing") { runtime.regeneratePairing() }
                Button("Revoke All Devices", role: .destructive) { runtime.revokeAllDevices() }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 440)
    }
}
