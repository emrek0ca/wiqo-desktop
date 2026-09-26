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
                .font(.custom("InterVariable", size: 17, relativeTo: .body))
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

    private static func instant(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func perform() async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        // Without permission nothing would show; the backend keeps ownership (no lease).
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        guard let plan = try? await RovaBackendClient.fetchLocalNotifications() else { return }
        let items = plan.notifications
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
                content.categoryIdentifier = WiqoNotificationActions.reminderCategory
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
        for item in plan.once ?? [] {
            guard requestCount < Self.maxRequests, let at = Self.instant(item.at) else { continue }
            let interval = at.timeIntervalSinceNow
            guard interval > 5 else { continue }
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            content.threadIdentifier = "rova-reminders"
            content.categoryIdentifier = WiqoNotificationActions.reminderCategory
            content.userInfo = ["automationId": item.automationId]
            let request = UNNotificationRequest(
                identifier: "\(Self.identifierPrefix)\(item.automationId).once",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            )
            if (try? await center.add(request)) != nil {
                requestCount += 1
                scheduled.append(item.automationId)
            }
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
        WiqoNotificationActions.register()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        RovaPushCoordinator.shared.handleDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Notification delivery is optional; local pairing and manual Mac control remain usable.
    }

}

/// Buttons on Wiqo's notifications: a reminder can be snoozed or stopped from the lock screen,
/// a failed automation retried or stopped - without opening the app.
enum WiqoNotificationActions {
    static let reminderCategory = "WIQO_REMINDER"
    static let failedCategory = "WIQO_AUTOMATION_FAILED"
    static let approvalCategory = "WIQO_APPROVAL"
    static let snooze = "WIQO_SNOOZE"
    static let stop = "WIQO_STOP"
    static let retry = "WIQO_RETRY"
    private static let snoozePrefix = "wiqo.snooze."

    static func register() {
        let snoozeAction = UNNotificationAction(identifier: snooze, title: "10 dk ertele", options: [])
        let stopAction = UNNotificationAction(identifier: stop, title: "Durdur", options: [.destructive, .authenticationRequired])
        let retryAction = UNNotificationAction(identifier: retry, title: "Tekrar dene", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: reminderCategory, actions: [snoozeAction, stopAction], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: failedCategory, actions: [retryAction, stopAction], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: approvalCategory, actions: [], intentIdentifiers: [], options: [])
        ])
    }

    static func automationID(in userInfo: [AnyHashable: Any]) -> Int? {
        if let id = userInfo["automationId"] as? Int { return id }
        return (userInfo["rova"] as? [String: Any])?["automationId"] as? Int
    }

    /// Snoozing happens on the phone alone: the same notification again in ten minutes.
    static func scheduleSnooze(of content: UNNotificationContent) async {
        let copy = UNMutableNotificationContent()
        copy.title = content.title
        copy.body = content.body
        copy.sound = .default
        copy.threadIdentifier = content.threadIdentifier
        copy.categoryIdentifier = reminderCategory
        copy.userInfo = content.userInfo
        let request = UNNotificationRequest(
            identifier: snoozePrefix + UUID().uuidString,
            content: copy,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false)
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}

final class RovaNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let automationID = WiqoNotificationActions.automationID(in: content.userInfo)
        switch response.actionIdentifier {
        case WiqoNotificationActions.snooze:
            await WiqoNotificationActions.scheduleSnooze(of: content)
        case WiqoNotificationActions.stop:
            if let automationID { _ = try? await RovaBackendClient.pauseAutomation(id: automationID) }
        case WiqoNotificationActions.retry:
            if let automationID { _ = try? await RovaBackendClient.runAutomationNow(id: automationID) }
        case UNNotificationDefaultActionIdentifier:
            let rova = content.userInfo["rova"] as? [String: Any] ?? [:]
            if let id = rova["confirmationId"] as? String, UUID(uuidString: id) != nil {
                RovaApprovalNotificationRoute.open(id: id)
            } else if let conversationID = rova["conversationId"] as? String, !conversationID.isEmpty {
                NotificationCenter.default.post(name: .wiqoOpenConversation, object: conversationID)
            } else if let automationID = WiqoNotificationActions.automationID(in: content.userInfo),
                      let runID = rova["runId"] as? Int {
                if let conversationID = try? await RovaBackendClient.conversationFromRun(automationID: automationID, runID: runID) {
                    NotificationCenter.default.post(name: .wiqoOpenConversation, object: conversationID)
                } else {
                    RovaApprovalNotificationRoute.openActivity()
                }
            } else if rova["agentTaskId"] != nil || WiqoNotificationActions.automationID(in: content.userInfo) != nil {
                RovaApprovalNotificationRoute.openActivity()
            }
        default:
            break
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}

/// Persists the tapped approval long enough for the authenticated chat root to mount after a cold
/// launch. The notification itself never carries the requested command or other private text.
enum RovaApprovalNotificationRoute {
    static let notificationName = Notification.Name("wiqo.open-approval")
    private static let storageKey = "rova.pending-approval-route"
    private static let activityStorageKey = "rova.pending-activity-route"
    static let activityNotificationName = Notification.Name("wiqo.open-activity")

    static func open(id: String) {
        UserDefaults.standard.set(id, forKey: storageKey)
        NotificationCenter.default.post(name: notificationName, object: id)
    }

    static func consume() -> UUID? {
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        guard let value = UserDefaults.standard.string(forKey: storageKey) else { return nil }
        return UUID(uuidString: value)
    }

    static func openActivity() {
        UserDefaults.standard.set(true, forKey: activityStorageKey)
        NotificationCenter.default.post(name: activityNotificationName, object: nil)
    }

    static func consumeActivity() -> Bool {
        defer { UserDefaults.standard.removeObject(forKey: activityStorageKey) }
        return UserDefaults.standard.bool(forKey: activityStorageKey)
    }
}
