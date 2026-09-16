import Foundation
import StoreKit

/// Product identifiers Wiqo sells through StoreKit. Business is web/PayTR-only and never appears
/// here - see WiqoWebsite below and docs/abonelik.md for the full plan/billing design.
enum WiqoProduct {
    static let proMonthly = "com.rova.ios.pro.monthly"
    static let all: Set<String> = [proMonthly]
}

/// Where "Business" in the paywall sends the user - Business is sold on Wiqo's own website via
/// PayTR, never through StoreKit (App Store rules aside, the user explicitly wants it this way).
enum WiqoWebsite {
    static let businessCheckoutURL = URL(string: "https://elyan.dev/business")!
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

    /// Used before the first successful fetch - deliberately the Free plan's real shape (not an
    /// optimistic guess), since a brand-new account genuinely starts on Free.
    static let placeholder = SubscriptionInfo(
        tier: "free",
        label: "Free",
        source: "none",
        expiresAt: nil,
        pcAllowed: false,
        usage: Usage(messages: UsageCounter(used: 0, limit: 10), images: UsageCounter(used: 0, limit: 1))
    )
}

/// Owns the current account's plan/usage. Cached exactly like ProfileStore, namespaced by account
/// id, so plan-gated UI (PC access, usage numbers) reads instantly on launch and never leaks
/// across accounts on a shared device.
@MainActor
final class SubscriptionStore: ObservableObject {
    @Published private(set) var info: SubscriptionInfo

    private let cacheURL: URL?

    init() {
        let userID = RovaBackendClient.currentUserID
        cacheURL = Self.cacheURL(forUserID: userID)
        var cached = SubscriptionInfo.placeholder
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode(SubscriptionInfo.self, from: data) {
            cached = decoded
        }
        info = cached
    }

    func refresh() async {
        guard let fresh = try? await RovaBackendClient.fetchSubscription() else { return }
        info = fresh
        guard let cacheURL, let data = try? JSONEncoder().encode(fresh) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: [.atomic, .completeFileProtection])
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

/// Wraps StoreKit 2 for Wiqo Pro: product lookup, purchase, and restore, plus a background
/// listener for transactions that land while this isn't the active purchase flow (renewals,
/// Ask to Buy approvals, a purchase made on another device). Every verified transaction is
/// forwarded to the backend (`POST /billing/storekit/verify`) - that endpoint, not this class, is
/// the only place a purchase actually unlocks a tier. The App Store Server Notifications webhook
/// (see docs/abonelik.md) is the durable path that keeps the account correct after this app isn't
/// even running; this listener is only a same-session convenience for instant feedback.
@MainActor
final class StoreKitManager: ObservableObject {
    @Published private(set) var proProduct: Product?
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isPurchasing = false

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

    func loadProducts() async {
        guard proProduct == nil else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        proProduct = try? await Product.products(for: [WiqoProduct.proMonthly]).first
    }

    @discardableResult
    func purchasePro(subscriptionStore: SubscriptionStore) async throws -> PurchaseOutcome {
        await loadProducts()
        guard let product = proProduct else { throw PurchaseError.productUnavailable }
        isPurchasing = true
        defer { isPurchasing = false }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            try await apply(verification, subscriptionStore: subscriptionStore)
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
    /// backend - covers both "Satın alımları geri yükle" and a purchase whose earlier backend
    /// verify call failed (the transaction stays unfinished until verify succeeds, so it keeps
    /// showing up here until it does).
    func restore(subscriptionStore: SubscriptionStore) async throws {
        try await AppStore.sync()
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement, WiqoProduct.all.contains(transaction.productID) else { continue }
            try await apply(entitlement, subscriptionStore: subscriptionStore)
            return
        }
        throw PurchaseError.backendRejected("Geri yüklenecek aktif bir Wiqo Pro aboneliği bulunamadı.")
    }

    private func handle(_ update: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = update, WiqoProduct.all.contains(transaction.productID) else { return }
        try? await apply(update, subscriptionStore: nil)
    }

    /// The single place a verified transaction is forwarded to the backend and, only once that
    /// succeeds, finished with StoreKit - a failed backend verify leaves it unfinished so it
    /// reappears (via `Transaction.updates` or `restore()`) instead of being silently lost.
    private func apply(_ verification: VerificationResult<Transaction>, subscriptionStore: SubscriptionStore?) async throws {
        guard case .verified(let transaction) = verification else { throw PurchaseError.verificationFailed }
        do {
            try await RovaBackendClient.verifyStoreKitTransaction(verification.jwsRepresentation)
        } catch RovaBackendError.declined(let message) {
            throw PurchaseError.backendRejected(message)
        }
        await transaction.finish()
        await subscriptionStore?.refresh()
    }
}
