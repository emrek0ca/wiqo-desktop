import Foundation

/// Product identifiers Wiqo sells through StoreKit. See docs/abonelik.md for the plan/billing design.
enum WiqoProduct {
    static let proMonthly = "com.wiqo.ios.pro.monthly"
    static let all: Set<String> = [proMonthly]
}

/// Mirrors the backend's `GET /billing/subscription` response exactly - the single source of
/// truth for plan limits and today's usage. Never compute limits locally; the backend is also
/// what actually enforces them.
/// One plan as the backend lists it (limits come from the same table that enforces them).
struct WiqoPlan: Decodable, Equatable, Identifiable {
    let id: String
    let label: String
    let messagesPerDay: Int
    let imagesPerDay: Int
    let pcAllowed: Bool
    let purchasableInApp: Bool
    /// Act (code project) jobs per day; absent from an older backend.
    let actJobsPerDay: Int?
}

struct SubscriptionInfo: Codable, Equatable {
    struct UsageCounter: Codable, Equatable {
        let used: Int
        let limit: Int
    }
    struct Usage: Codable, Equatable {
        let messages: UsageCounter
        let images: UsageCounter
        /// Act jobs today; absent from an older backend or snapshot.
        var act: UsageCounter? = nil
    }

    let tier: String
    let label: String
    let source: String
    let expiresAt: String?
    let pcAllowed: Bool
    let usage: Usage
    /// When today's usage counters reset (the next local midnight). Absent in snapshots saved
    /// before the server sent it.
    let resetsAt: String?

    /// Used before the first successful fetch - deliberately the Free plan's real shape (not an
    /// optimistic guess), since a brand-new account genuinely starts on Free.
    static let placeholder = SubscriptionInfo(
        tier: "free",
        label: "Free",
        source: "none",
        expiresAt: nil,
        pcAllowed: true,
        usage: Usage(messages: UsageCounter(used: 0, limit: 10), images: UsageCounter(used: 0, limit: 1)),
        resetsAt: nil
    )

    func withMessageUsage(used: Int, limit: Int) -> SubscriptionInfo {
        SubscriptionInfo(
            tier: tier, label: label, source: source, expiresAt: expiresAt, pcAllowed: pcAllowed,
            usage: Usage(messages: UsageCounter(used: used, limit: limit), images: usage.images, act: usage.act),
            resetsAt: resetsAt
        )
    }

    /// A new day has begun: nothing has been used yet. The limits stay; the next server snapshot
    /// restores the real reset time.
    func withUsageReset() -> SubscriptionInfo {
        SubscriptionInfo(
            tier: tier, label: label, source: source, expiresAt: expiresAt, pcAllowed: pcAllowed,
            usage: Usage(messages: UsageCounter(used: 0, limit: usage.messages.limit), images: UsageCounter(used: 0, limit: usage.images.limit), act: usage.act.map { UsageCounter(used: 0, limit: $0.limit) }),
            resetsAt: nil
        )
    }

    /// The server writes JavaScript ISO dates ("2026-09-20T21:00:00.000Z").
    private static func date(from text: String?) -> Date? {
        guard let text else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    var resetDate: Date? { Self.date(from: resetsAt) }

    /// A paid plan whose end date has passed: the server decides whether it renewed.
    var isPastExpiry: Bool {
        guard tier != "free", let end = Self.date(from: expiresAt) else { return false }
        return end <= Date()
    }
}
