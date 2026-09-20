import Foundation
import StoreKit

/// Product identifiers Wiqo sells through StoreKit. See docs/abonelik.md for the plan/billing design.
enum WiqoProduct {
    static let proMonthly = "com.rova.ios.pro.monthly"
    static let all: Set<String> = [proMonthly]
}

/// Wiqo's own web addresses. The app never links to a page that sells anything.
enum WiqoWebsite {
    static let downloadURL = URL(string: "https://wiqoai.com")!
    /// Wiqo's own legal/support pages. Required to be reachable from both the paywall
    /// (Guideline 3.1.2) and Settings, and referenced as-is in App Store Connect's Privacy
    /// Policy/Support URL fields.
    static let privacyPolicyURL = URL(string: "https://wiqoai.com/privacy")!
    static let termsOfServiceURL = URL(string: "https://wiqoai.com/terms")!
    static let supportURL = URL(string: "https://wiqoai.com/support")!
}

/// Mirrors the backend's `GET /billing/subscription` response exactly - the single source of
/// truth for plan limits and today's usage. Never compute limits locally; the backend is also
/// what actually enforces them.
struct SubscriptionInfo: Codable, Equatable {
    struct UsageCounter: Codable, Equatable {
        let used: Int
        let limit: Int
    }
    struct Usage: Codable, Equatable {
        let messages: UsageCounter
        let images: UsageCounter
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
        pcAllowed: false,
        usage: Usage(messages: UsageCounter(used: 0, limit: 10), images: UsageCounter(used: 0, limit: 1)),
        resetsAt: nil
    )

    func withMessageUsage(used: Int, limit: Int) -> SubscriptionInfo {
        SubscriptionInfo(
            tier: tier, label: label, source: source, expiresAt: expiresAt, pcAllowed: pcAllowed,
            usage: Usage(messages: UsageCounter(used: used, limit: limit), images: usage.images),
            resetsAt: resetsAt
        )
    }

    /// A new day has begun: nothing has been used yet. The limits stay; the next server snapshot
    /// restores the real reset time.
    func withUsageReset() -> SubscriptionInfo {
        SubscriptionInfo(
            tier: tier, label: label, source: source, expiresAt: expiresAt, pcAllowed: pcAllowed,
            usage: Usage(messages: UsageCounter(used: 0, limit: usage.messages.limit), images: UsageCounter(used: 0, limit: usage.images.limit)),
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

/// Owns the current account's plan and usage. The last snapshot is kept on disk (namespaced by
/// account id, like ProfileStore), so plan-gated UI and usage numbers read instantly on launch and
/// never leak across accounts on a shared device. The server is asked again only when that
/// snapshot is older than `freshnessWindow`, after a purchase (whose response already carries the
/// new plan), or when a new day starts. The message count is kept current without asking: the
/// server announces it at the start of every chat request.
@MainActor
final class SubscriptionStore: ObservableObject {
    @Published private(set) var info: SubscriptionInfo

    /// The StoreKit side lives exactly as long as this store, so App Store events (renewals, Ask to
    /// Buy approvals, a purchase on another device) are heard for the whole session.
    let storeKit: StoreKitManager

    /// How long a snapshot is trusted before a screen may ask the server again.
    static let freshnessWindow: TimeInterval = 300

    private struct CachedSubscription: Codable {
        let info: SubscriptionInfo
        let fetchedAt: Date?
    }

    private let cacheURL: URL?
    private var fetchedAt: Date?
    private var isRefreshing = false

    init() {
        let userID = RovaBackendClient.currentUserID
        cacheURL = Self.cacheURL(forUserID: userID)
        let cached = cacheURL.flatMap(Self.readCache)
        info = cached?.info ?? SubscriptionInfo.placeholder
        fetchedAt = cached?.fetchedAt
        storeKit = StoreKitManager()
        storeKit.attach(to: self)
        rollOverIfNeeded()
    }

    /// Everything the app needs at launch: the App Store product, a fresh-enough plan, and a check
    /// that a subscription bought outside this session is known to the server.
    func start() async {
        async let products: Void = storeKit.loadProducts()
        await refreshIfStale()
        await products
        await storeKit.reconcileEntitlements()
    }

    /// Asks the server only when the snapshot is older than `maxAge` (or a new day has begun).
    func refreshIfStale(maxAge: TimeInterval = SubscriptionStore.freshnessWindow) async {
        rollOverIfNeeded()
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < maxAge { return }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let fresh = try? await RovaBackendClient.fetchSubscription() else { return }
        apply(fresh)
    }

    /// Adopts a snapshot the server just sent, from a refresh or from a purchase response.
    func apply(_ snapshot: SubscriptionInfo) {
        info = snapshot
        fetchedAt = Date()
        persist()
    }

    /// The server counts a message when a chat request starts and reports the running total.
    func applyMessageUsage(used: Int, limit: Int) {
        guard info.usage.messages.used != used || info.usage.messages.limit != limit else { return }
        info = info.withMessageUsage(used: used, limit: limit)
        persist()
    }

    /// A day boundary or a paid plan's end date has passed since the snapshot was taken: show a
    /// fresh day right away and make the snapshot count as stale so the server confirms it.
    private func rollOverIfNeeded() {
        var changed = false
        if let reset = info.resetDate, reset <= Date() {
            info = info.withUsageReset()
            changed = true
        }
        if changed || info.isPastExpiry {
            fetchedAt = nil
            if changed { persist() }
        }
    }

    private func persist() {
        guard let cacheURL else { return }
        let entry = CachedSubscription(info: info, fetchedAt: fetchedAt)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: [.atomic, .completeFileProtection])
    }

    private static func readCache(at url: URL) -> CachedSubscription? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let entry = try? JSONDecoder().decode(CachedSubscription.self, from: data) { return entry }
        // A snapshot saved before fetch times were recorded: still good to show, counts as stale.
        return (try? JSONDecoder().decode(SubscriptionInfo.self, from: data)).map { CachedSubscription(info: $0, fetchedAt: nil) }
    }

    private static func cacheURL(forUserID userID: String?) -> URL? {
        userID.flatMap { id in
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("wiqo-subscription-\(id).json")
        }
    }

    /// Called on account deletion, alongside ProfileStore.clearCache() - keeps a shared device
    /// from ever showing a deleted account's last-known plan to whoever signs in next.
    static func clearCacheForCurrentUser() {
        guard let url = cacheURL(forUserID: RovaBackendClient.currentUserID) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

enum PurchaseOutcome {
    case purchased
    case pending
    case cancelled
}

enum PurchaseError: Error, LocalizedError {
    case productUnavailable
    case verificationFailed
    case backendRejected(String)

    var errorDescription: String? {
        switch self {
        case .productUnavailable: return "Wiqo Pro şu anda App Store'dan alınamıyor. Az sonra tekrar dene."
        case .verificationFailed: return "Satın alma Apple tarafından doğrulanamadı."
        case .backendRejected(let message): return message
        }
    }
}

/// Wraps StoreKit 2 for Wiqo Pro: product lookup, purchase and restore, plus a listener for
/// transactions that arrive outside a purchase flow (renewals, Ask to Buy approvals, a purchase
/// made on another device). Every verified transaction is forwarded to the backend
/// (`POST /billing/storekit/verify`) - that endpoint, not this class, is the only place a purchase
/// unlocks a tier - and its response, which already carries the new plan, updates the store at
/// once. The App Store Server Notifications webhook (see docs/abonelik.md) keeps the account
/// correct while the app is closed.
@MainActor
final class StoreKitManager: ObservableObject {
    @Published private(set) var proProduct: Product?
    @Published private(set) var isPurchasing = false

    private weak var subscriptionStore: SubscriptionStore?
    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func attach(to store: SubscriptionStore) {
        subscriptionStore = store
    }

    func loadProducts() async {
        guard proProduct == nil else { return }
        proProduct = try? await Product.products(for: [WiqoProduct.proMonthly]).first
    }

    @discardableResult
    func purchasePro() async throws -> PurchaseOutcome {
        await loadProducts()
        guard let product = proProduct else { throw PurchaseError.productUnavailable }
        isPurchasing = true
        defer { isPurchasing = false }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            try await apply(verification)
            return .purchased
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        @unknown default:
            return .pending
        }
    }

    /// Re-checks the account's current entitlements with StoreKit and re-verifies with the
    /// backend - covers "Satın alımları geri yükle" and a purchase whose earlier backend verify
    /// call failed (the transaction stays unfinished until verify succeeds).
    func restore() async throws {
        try await AppStore.sync()
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement, WiqoProduct.all.contains(transaction.productID) else { continue }
            try await apply(entitlement)
            return
        }
        throw PurchaseError.backendRejected("Geri yüklenecek aktif bir Wiqo Pro aboneliği bulunamadı.")
    }

    /// What StoreKit says this Apple ID is entitled to, checked at launch. An active Pro
    /// subscription the server does not know about (bought on another device, or a listener event
    /// that was missed) is handed to the server, so the plan is right without the user doing
    /// anything.
    func reconcileEntitlements() async {
        guard subscriptionStore?.info.tier == "free" else { return }
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement,
                  WiqoProduct.all.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            try? await apply(entitlement)
            return
        }
    }

    private func handle(_ update: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = update, WiqoProduct.all.contains(transaction.productID) else { return }
        // A revoked or ended subscription is the server's to settle (its notification webhook has
        // the final word); the app only needs to look again.
        if transaction.revocationDate != nil {
            await transaction.finish()
            await subscriptionStore?.refresh()
            return
        }
        let before = subscriptionStore?.info.tier
        try? await apply(update)
        if before != "pro", subscriptionStore?.info.tier == "pro" {
            WiqoToastCenter.shared.show("Pro aktif. Hoş geldin!", kind: .success)
        }
    }

    /// The single place a verified transaction is forwarded to the backend and, only once that
    /// succeeds, finished with StoreKit - a failed backend verify leaves it unfinished so it
    /// reappears (via `Transaction.updates` or `restore()`) instead of being silently lost.
    private func apply(_ verification: VerificationResult<Transaction>) async throws {
        guard case .verified(let transaction) = verification else { throw PurchaseError.verificationFailed }
        let snapshot: SubscriptionInfo?
        do {
            snapshot = try await RovaBackendClient.verifyStoreKitTransaction(verification.jwsRepresentation)
        } catch RovaBackendError.declined(let message) {
            throw PurchaseError.backendRejected(message)
        }
        await transaction.finish()
        if let snapshot {
            subscriptionStore?.apply(snapshot)
        } else {
            await subscriptionStore?.refresh()
        }
    }
}
