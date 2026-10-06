import AppKit
import SwiftUI

@main
struct RovaMacApp: App {
    @StateObject private var runtime: MacRuntime
    @StateObject private var launchCoordinator: MacLaunchCoordinator
    @ObservedObject private var agentAccess = AgentAccessStore.shared

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
        MenuBarExtra {
            MacMenuView(runtime: runtime)
        } label: {
            Image(systemName: agentAccess.isActive ? "bolt.circle.fill" : "arrow.triangle.2.circlepath")
        }
        Window("Wiqo telefonu bağla", id: RovaWindowID.pairingQR) {
            PairingQRView(runtime: runtime)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 380)
        Window("Wiqo Projeleri", id: RovaWindowID.projects) {
            MacProjectsView()
        }
        .defaultSize(width: 900, height: 600)
        Settings {
            MacSettingsView(runtime: runtime)
        }
    }
}

enum RovaWindowID {
    static let pairingQR = "pairing-qr"
    static let projects = "projects"
}

/// Presents the first-run window without changing the existing menu-bar and QR scenes. A small
/// AppKit coordinator is used because this target supports macOS 14, where SwiftUI's explicit
/// default scene launch behavior is not available yet.
@MainActor
final class MacLaunchCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    private let runtime: MacRuntime
    private var welcomeWindow: NSWindow?

    init(runtime: MacRuntime) {
        self.runtime = runtime
        super.init()
    }

    func presentWelcomeIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: MacStorage.welcomeCompletedKey),
              !runtime.isPaired,
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
        UserDefaults.standard.set(true, forKey: MacStorage.welcomeCompletedKey)
        welcomeWindow?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === welcomeWindow else { return }
        welcomeWindow = nil
    }
}
