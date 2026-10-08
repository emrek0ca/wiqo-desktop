import Foundation
import UserNotifications

/// Notification-only automations the phone schedules itself.
extension RovaBackendClient {
    // MARK: - On-device reminders

    /// A notification-only automation the phone schedules itself (backend: automation/localDelivery.ts).
    struct LocalNotification: Decodable, Sendable {
        let automationId: Int
        let specHash: String?
        let title: String
        let body: String
        let hour: Int
        let minute: Int
        /// 0 = Sunday ... 6 = Saturday, like cron; nil = every day.
        let weekdays: [Int]?
        let timezone: String
    }

    /// A single-moment reminder ("yarın 9'da", "10 dakika sonra").
    struct LocalOnceNotification: Decodable, Sendable {
        let automationId: Int
        let title: String
        let body: String
        /// ISO 8601 instant.
        let at: String
    }

    struct LocalNotificationPlan: Decodable, Sendable {
        let notifications: [LocalNotification]
        let once: [LocalOnceNotification]?
    }

    static func fetchLocalNotifications() async throws -> LocalNotificationPlan {
        try await authorizedGet("automations/local-notifications", as: LocalNotificationPlan.self)
    }

    static func leaseLocalDelivery(_ automationIDs: [Int]) async throws -> [Int] {
        struct Response: Decodable { let leased: [Int] }
        return try await authorizedPost("automations/local-delivery", body: ["automationIds": automationIDs], as: Response.self).leased
    }

    /// Automations can change from chat approvals or the detail screen; the phone's own schedule follows.
    static func reconcileLocalReminders() {
        Task { @MainActor in WiqoLocalReminders.shared.reconcile() }
    }
}
