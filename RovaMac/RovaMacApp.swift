import SwiftUI

@main
struct RovaMacApp: App {
    @StateObject private var runtime: MacRuntime

    init() {
        let runtime = MacRuntime()
        _runtime = StateObject(wrappedValue: runtime)
        DispatchQueue.main.async { runtime.start() }
    }

    var body: some Scene {
        MenuBarExtra("Rova", systemImage: "arrow.triangle.2.circlepath") {
            MacMenuView(runtime: runtime)
        }
        Window("Pairing QR", id: RovaWindowID.pairingQR) {
            PairingQRView(runtime: runtime)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 380)
        Settings {
            MacSettingsView(runtime: runtime)
        }
    }
}

enum RovaWindowID {
    static let pairingQR = "pairing-qr"
}
