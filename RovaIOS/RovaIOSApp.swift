import SwiftUI
import UIKit
import UserNotifications

@main
struct RovaIOSApp: App {
    @UIApplicationDelegateAdaptor(RovaAppDelegate.self) private var appDelegate
    @StateObject private var model = IOSConnectionModel()
    @StateObject private var authSession = AuthSessionStore()

    var body: some Scene {
        WindowGroup {
            RootView(model: model, authSession: authSession)
        }
    }
}

/// Keeps the APNs token only in memory, registers it for the currently authenticated account,
/// and never makes notification delivery a prerequisite for the local Mac-control path.
@MainActor
final class RovaPushCoordinator {
    static let shared = RovaPushCoordinator()

    private var currentToken: String?
    private var registrationTask: Task<Void, Never>?

    private init() {}

    func requestRegistrationIfAuthenticated() {
        guard RovaBackendClient.isAuthenticated else { return }
        registrationTask?.cancel()
        if let currentToken {
            registrationTask = Task { @MainActor in
                try? await RovaBackendClient.registerAPNsToken(currentToken)
            }
            return
        }

        registrationTask = Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true
            guard granted, RovaBackendClient.isAuthenticated else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func handleDeviceToken(_ data: Data) {
        currentToken = data.map { String(format: "%02x", $0) }.joined()
        requestRegistrationIfAuthenticated()
    }

    func revokeCurrentToken() {
        let token = currentToken
        currentToken = nil
        registrationTask?.cancel()
        registrationTask = Task { @MainActor in
            try? await RovaBackendClient.revokeAPNsToken(token)
        }
    }
}

@MainActor
final class RovaAppDelegate: NSObject, UIApplicationDelegate {
    private let notificationDelegate = RovaNotificationDelegate()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        RovaPushCoordinator.shared.handleDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Notification delivery is optional; local pairing and manual Mac control remain usable.
    }

}

final class RovaNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
