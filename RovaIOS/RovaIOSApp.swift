import SwiftUI
import UIKit
import UserNotifications

@main
struct RovaIOSApp: App {
    @UIApplicationDelegateAdaptor(RovaAppDelegate.self) private var appDelegate
    @StateObject private var model = IOSConnectionModel()
    @StateObject private var authSession = AuthSessionStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model, authSession: authSession)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { WiqoLocalReminders.shared.reconcile() }
                }
        }
    }
}

/// Edge delivery for notification-only automations ("her gün 9'da bana merhaba de"): the phone
/// schedules them as repeating local notifications, so they arrive on time with no model call, no
/// PC and no network. After scheduling, the phone renews a lease on the backend, which then stops
/// pushing those automations; if this phone stops reconciling, the lease lapses and APNs resumes.
@MainActor
final class WiqoLocalReminders {
    static let shared = WiqoLocalReminders()

    private static let identifierPrefix = "wiqo.automation."
    /// iOS keeps at most 64 pending requests per app; leave room for anything else.
    private static let maxRequests = 56

    private var task: Task<Void, Never>?
    private var needsAnotherPass = false

    private init() {}

    func reconcile() {
        guard RovaBackendClient.isAuthenticated else { return }
        if task != nil {
            needsAnotherPass = true
            return
        }
        task = Task { @MainActor in
            repeat {
                needsAnotherPass = false
                await perform()
            } while needsAnotherPass
            task = nil
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)
        }
    }

    private func perform() async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        // Without permission nothing would show; the backend keeps ownership (no lease).
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        guard let items = try? await RovaBackendClient.fetchLocalNotifications() else { return }
        let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        var scheduled: [Int] = []
        var requestCount = 0
        for item in items {
            let weekdays: [Int?] = item.weekdays.map { $0.map { Optional($0) } } ?? [nil]
            guard requestCount + weekdays.count <= Self.maxRequests else { continue }
            var added = true
            var identifiers: [String] = []
            for weekday in weekdays {
                var components = DateComponents()
                components.hour = item.hour
                components.minute = item.minute
                if let weekday { components.weekday = weekday + 1 }
                components.timeZone = TimeZone(identifier: item.timezone)
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.body
                content.sound = .default
                content.threadIdentifier = "rova-reminders"
                content.userInfo = ["automationId": item.automationId]
                let identifier = "\(Self.identifierPrefix)\(item.automationId).\(weekday.map(String.init) ?? "daily")"
                identifiers.append(identifier)
                let request = UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                )
                do {
                    try await center.add(request)
                    requestCount += 1
                } catch {
                    added = false
                }
            }
            if added {
                scheduled.append(item.automationId)
            } else {
                // Half a schedule plus the backend's push would double up; the backend keeps it.
                center.removePendingNotificationRequests(withIdentifiers: identifiers)
            }
        }
        if !scheduled.isEmpty { _ = try? await RovaBackendClient.leaseLocalDelivery(scheduled) }
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
        WiqoLocalReminders.shared.clear()
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
