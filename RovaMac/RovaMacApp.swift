import AppKit
import SwiftUI

@main
struct RovaMacApp: App {
    @StateObject private var runtime: MacRuntime
    @StateObject private var launchCoordinator: MacLaunchCoordinator

    init() {
        let runtime = MacRuntime()
        let launchCoordinator = MacLaunchCoordinator(runtime: runtime)
        _runtime = StateObject(wrappedValue: runtime)
        _launchCoordinator = StateObject(wrappedValue: launchCoordinator)
        DispatchQueue.main.async {
            runtime.start()
            launchCoordinator.presentWelcomeIfNeeded()
        }
    }

    var body: some Scene {
        MenuBarExtra("Wiqo", systemImage: "arrow.triangle.2.circlepath") {
            MacMenuView(runtime: runtime)
        }
        Window("Wiqo telefonu bağla", id: RovaWindowID.pairingQR) {
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

/// Presents the first-run window without changing the existing menu-bar and QR scenes. A small
/// AppKit coordinator is used because this target supports macOS 14, where SwiftUI's explicit
/// default scene launch behavior is not available yet.
@MainActor
final class MacLaunchCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    private static let welcomeCompletedKey = "rova.mac.welcome.completed"

    private let runtime: MacRuntime
    private var welcomeWindow: NSWindow?

    init(runtime: MacRuntime) {
        self.runtime = runtime
        super.init()
    }

    func presentWelcomeIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.welcomeCompletedKey),
              runtime.pairedDeviceID == nil,
              welcomeWindow == nil else { return }

        let view = MacWelcomeView(
            onComplete: { [weak self] in
                self?.completeWelcome()
            },
            runtime: runtime
        )
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 450),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wiqo'ya hoş geldin"
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.delegate = self
        window.center()
        welcomeWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func completeWelcome() {
        UserDefaults.standard.set(true, forKey: Self.welcomeCompletedKey)
        welcomeWindow?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === welcomeWindow else { return }
        welcomeWindow = nil
    }
}
