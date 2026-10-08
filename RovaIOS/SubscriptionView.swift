import StoreKit
import SwiftUI

/// Ayarlar > Abonelik: what the account has, what it has used today, when it renews, and how to change it - the plan cards and the purchase
/// itself are the same ones the paywall shows. Everything here is the account's real state: the plan and the numbers come from the backend,
/// the renewal date and the "will renew" flag from StoreKit.
struct SubscriptionView: View {
    @ObservedObject var subscriptionStore: SubscriptionStore
    @State private var renewal: Renewal?
    @State private var showingManage = false

    /// What StoreKit says about the Apple subscription on this Apple ID.
    struct Renewal: Equatable {
        let willRenew: Bool
        let date: Date?
        let inGracePeriod: Bool
        let inBillingRetry: Bool
    }

    private var info: SubscriptionInfo { subscriptionStore.info }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                planHeader
                usageCard
                PaywallView(subscriptionStore: subscriptionStore, embedded: true)
                if info.tier == "pro", info.source == "storekit" || renewal != nil {
                    manageCard
                }
            }
            .padding(.horizontal, RovaDesign.screenPadding)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .background(WiqoSettingsStyle.canvas)
        .navigationTitle("Abonelik")
        .navigationBarTitleDisplayMode(.inline)
        .manageSubscriptionsSheet(isPresented: $showingManage)
        .task {
            await subscriptionStore.refresh()
            renewal = await Self.loadRenewal(subscriptionStore.storeKit)
        }
        .refreshable {
            await subscriptionStore.refresh()
            renewal = await Self.loadRenewal(subscriptionStore.storeKit)
        }
        .wiqoToastHost(level: 2)
    }

    // MARK: Plan

    private var planHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(info.label)
                    .font(.title.weight(.bold))
                Spacer()
                statusChip
            }
            Text(planSentence)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if info.tier == "free", info.usage.messages.limit > 0, Double(info.usage.messages.used) / Double(info.usage.messages.limit) >= 0.8 {
                Label(info.usage.messages.used >= info.usage.messages.limit
                      ? String(localized: "Bugünkü hakkın doldu. Pro ile devam edebilirsin.")
                      : String(localized: "Bugünkü hakkının büyük kısmını kullandın."), systemImage: "bolt.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(WiqoTheme.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiqoGlass()
    }

    @ViewBuilder
    private var statusChip: some View {
        if let renewal, renewal.inBillingRetry || renewal.inGracePeriod {
            chip(String(localized: "Ödeme bekleniyor"), tint: WiqoTheme.orange)
        } else if info.tier == "free" {
            chip(String(localized: "Ücretsiz"), tint: .secondary)
        } else if let renewal, !renewal.willRenew {
            chip(String(localized: "Sona eriyor"), tint: WiqoTheme.orange)
        } else {
            chip(String(localized: "Aktif"), tint: WiqoTheme.green)
        }
    }

    private func chip(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(WiqoTheme.tint(tint), in: Capsule())
    }

    private var planSentence: String {
        let end = renewal?.date ?? Self.date(from: info.expiresAt)
        let day = end.map { $0.formatted(date: .long, time: .omitted) }
        switch info.tier {
        case "free":
            return String(localized: "Günde \(info.usage.messages.limit) mesaj ve \(info.usage.images.limit) görsel. Daha fazlası için Pro'ya geçebilirsin.")
        case "business":
            return day.map { String(localized: "Business planı \($0) tarihine kadar geçerli. Yönetimi Wiqo hesabını açtığın yerden yapılır.") }
                ?? String(localized: "Business planı aktif. Yönetimi Wiqo hesabını açtığın yerden yapılır.")
        default:
            if let renewal, renewal.inBillingRetry || renewal.inGracePeriod {
                return String(localized: "Apple son ödemeyi alamadı. Ödeme yöntemini güncelle; o zamana kadar Pro açık kalır.")
            }
            guard let day else { return String(localized: "Pro planın aktif.") }
            if let renewal, !renewal.willRenew { return String(localized: "Pro \(day) tarihinde sona erecek; yenilenmeyecek.") }
            return String(localized: "Pro her ay otomatik yenilenir. Sonraki yenileme: \(day).")
        }
    }

    // MARK: Usage

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bugünkü kullanım")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            WiqoUsageBar(title: String(localized: "Mesaj"), used: info.usage.messages.used, limit: info.usage.messages.limit)
            WiqoUsageBar(title: String(localized: "Görsel"), used: info.usage.images.used, limit: info.usage.images.limit)
            if let act = info.usage.act {
                WiqoUsageBar(title: String(localized: "Act"), used: act.used, limit: act.limit)
            }
            if let reset = info.resetDate {
                Text("Sayaçlar \(reset.formatted(date: .omitted, time: .shortened)) saatinde sıfırlanır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiqoGlass()
    }

    // MARK: Manage

    private var manageCard: some View {
        WiqoSettingsGroup {
            Button { showingManage = true } label: {
                WiqoRow(systemImage: "creditcard", title: String(localized: "Aboneliği yönet"), subtitle: String(localized: "Apple hesabında iptal et, planı değiştir"), showsDivider: false) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WiqoTheme.ink3)
                }
            }
            .buttonStyle(WiqoRowButtonStyle())
        }
    }

    // MARK: StoreKit

    private static func loadRenewal(_ storeKit: StoreKitManager) async -> Renewal? {
        guard let subscription = storeKit.proProduct?.subscription,
              let statuses = try? await subscription.status else { return nil }
        for status in statuses {
            guard case .verified(let renewalInfo) = status.renewalInfo,
                  case .verified(let transaction) = status.transaction else { continue }
            return Renewal(
                willRenew: renewalInfo.willAutoRenew,
                date: transaction.expirationDate,
                inGracePeriod: status.state == .inGracePeriod,
                inBillingRetry: status.state == .inBillingRetryPeriod
            )
        }
        return nil
    }

    private static func date(from text: String?) -> Date? {
        guard let text else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}
