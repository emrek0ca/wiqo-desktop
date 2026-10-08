import StoreKit
import SwiftUI

/// Plan comparison + purchase flow. Pro is bought right here through StoreKit, and the price shown
/// is always the one the App Store returns for the user's storefront - never a number typed into
/// the app. Business is not sold in the app; it only appears for accounts that already have it.
struct PaywallView: View {
    @ObservedObject var subscriptionStore: SubscriptionStore
    @ObservedObject private var storeKit: StoreKitManager
    @Environment(\.dismiss) private var dismiss

    @State private var isRestoring = false
    @State private var errorMessage: String?
    @State private var plans: [WiqoPlan] = []
    /// First launch of a new account: the plans are offered once, with a clear way to carry on for free.
    private let introMode: Bool
    /// Inside the Abonelik page: just the plan cards, restore and terms, with no sheet chrome and no dismissing after a purchase.
    private let embedded: Bool

    init(subscriptionStore: SubscriptionStore, introMode: Bool = false, embedded: Bool = false) {
        self.introMode = introMode
        self.embedded = embedded
        self.subscriptionStore = subscriptionStore
        _storeKit = ObservedObject(wrappedValue: subscriptionStore.storeKit)
    }

    private var currentTier: String { subscriptionStore.info.tier }

    var body: some View {
        if embedded {
            planContent
                .task { await loadAll() }
                .alert("İşlem tamamlanamadı", isPresented: errorBinding) {
                    Button("Tamam", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
        } else {
            sheetBody
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func loadAll() async {
        async let catalog = try? RovaBackendClient.fetchPlans()
        await storeKit.loadProductsForPaywall()
        await subscriptionStore.refreshIfStale(maxAge: 60)
        if let fetched = await catalog, !fetched.isEmpty { plans = fetched }
    }

    private var planContent: some View {
        VStack(spacing: RovaDesign.cardSpacing) {
            if !embedded { header }
            planCard(
                title: "Free",
                price: String(localized: "Ücretsiz"),
                features: features(for: "free", fallback: (10, 1)),
                isCurrent: currentTier == "free"
            )
            proCard
            if currentTier == "business" {
                planCard(
                    title: "Business",
                    price: nil,
                    features: features(for: "business", fallback: (200, 20)),
                    isCurrent: true
                )
            }
            restoreButton
            if introMode {
                WiqoActionButton(title: String(localized: "Ücretsiz devam et"), kind: .secondary) { dismiss() }
            }
            legalFooter
        }
    }

    private var sheetBody: some View {
        NavigationStack {
            ScrollView {
                planContent
                    .padding(RovaDesign.screenPadding)
            }
            .background(RovaDesign.canvas)
            .navigationTitle("Planlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(introMode ? "Şimdi değil" : "Kapat") { dismiss() }
                }
            }
            .task { await loadAll() }
            .wiqoToastHost(level: 2)
            .alert("İşlem tamamlanamadı", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("Tamam", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(introMode ? "Wiqo'ya hoş geldin" : "Wiqo'yu yükselt")
                .font(.title2.weight(.bold))
            Text(introMode ? "Ücretsiz plan hazır. Daha fazla mesaj ve görsel istersen Pro'ya şimdi geçebilirsin." : "Daha fazla mesaj ve görsel için bir plan seç.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .wiqoRiseIn()
    }

    /// The lines of a plan card: the numbers the backend enforces (the built-in ones only until they have loaded).
    private func features(for id: String, fallback: (messages: Int, images: Int)) -> [String] {
        let plan = plans.first { $0.id == id }
        return [
            String(localized: "Günde \(plan?.messagesPerDay ?? fallback.messages) mesaj"),
            String(localized: "Günde \(plan?.imagesPerDay ?? fallback.images) görsel")
        ] + (plan?.actJobsPerDay.map { [String(localized: "Günde \($0) Act işi")] } ?? [])
          + ((plan?.pcAllowed ?? true) ? [String(localized: "PC bağlantısı")] : [])
    }

    private var proCard: some View {
        planCard(
            title: "Pro",
            price: storeKit.proProduct?.displayPrice,
            priceSuffix: "/ay",
            features: features(for: "pro", fallback: (100, 10)),
            isCurrent: currentTier == "pro"
        ) {
            switch storeKit.productLoadState {
            case .idle, .loading:
                if currentTier != "pro" {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("App Store fiyatı yükleniyor…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            case .available:
                if currentTier != "pro" {
                    WiqoActionButton(title: String(localized: "Pro'ya geç"), isLoading: storeKit.isPurchasing) {
                        Task { await purchasePro() }
                    }
                    .disabled(storeKit.isPurchasing)
                    .padding(.top, 4)
                }
            case .unavailable:
                VStack(alignment: .leading, spacing: 8) {
                    Text(storeKit.productLoadMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    WiqoActionButton(title: String(localized: "Tekrar dene"), kind: .secondary) {
                        Task { await storeKit.retryLoadingProducts() }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var restoreButton: some View {
        Button {
            Task { await restore() }
        } label: {
            ZStack {
                if isRestoring {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Satın alımları geri yükle")
                }
            }
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .disabled(isRestoring)
    }

    /// Required by App Store Review Guideline 3.1.2: auto-renewal terms spelled out in the
    /// purchase flow itself, plus working links to the Privacy Policy and Terms of Use right next
    /// to the purchase buttons - not just somewhere else in the app.
    private var legalFooter: some View {
        let priceClause = storeKit.proProduct.map { String(localized: "aylık \($0.displayPrice) karşılığında") } ?? String(localized: "aylık ücret karşılığında")
        return VStack(spacing: 10) {
            Text("Pro, \(priceClause) otomatik yenilenen bir abonelik ürünüdür. Ödeme, satın alma onayıyla Apple ID hesabınızdan tahsil edilir; mevcut dönemin bitiminden en az 24 saat önce iptal etmediğiniz sürece abonelik aynı ücretle otomatik olarak yenilenir. Aboneliğinizi Ayarlar > [Adınız] > Abonelikler yolundan istediğiniz zaman yönetebilirsiniz.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Link("Gizlilik Politikası", destination: WiqoWebsite.privacyPolicyURL)
                Link("Kullanım Şartları", destination: WiqoWebsite.termsOfServiceURL)
            }
            .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    @ViewBuilder
    private func planCard<Action: View>(
        title: String,
        price: String?,
        priceSuffix: String = "",
        features: [String],
        isCurrent: Bool,
        @ViewBuilder action: () -> Action = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                if isCurrent {
                    Text("Mevcut plan")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(WiqoTheme.ink, in: Capsule())
                        .foregroundStyle(Color(uiColor: .systemBackground))
                }
                Spacer()
                if let price {
                    Text(price + priceSuffix)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .transition(.wiqoBlur)
                } else if title == "Pro" {
                    switch storeKit.productLoadState {
                    case .idle, .loading:
                        WiqoSkeleton(width: 64, height: 14)
                    case .available:
                        Text("Fiyat bilgisi yok")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    case .unavailable:
                        Text("Fiyat yüklenemedi")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(WiqoTheme.orange)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(features, id: \.self) { feature in
                    Label {
                        Text(feature)
                    } icon: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(WiqoTheme.ink)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            action()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiqoCard(radius: RovaDesign.cardRadius)
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: RovaDesign.cardRadius, style: .continuous)
                    .strokeBorder(WiqoTheme.ink.opacity(0.6), lineWidth: 1.5)
            }
        }
        .wiqoAnimation(WiqoMotion.ease(0.3), value: price)
    }

    private func purchasePro() async {
        do {
            let outcome = try await storeKit.purchasePro()
            switch outcome {
            case .purchased:
                if !embedded { dismiss() }
                WiqoToastCenter.shared.show(String(localized: "Pro aktif. Hoş geldin!"), kind: .success)
            case .pending:
                errorMessage = String(localized: "Satın alma onay bekliyor (Ask to Buy). Onaylanınca otomatik aktif olacak.")
            case .cancelled:
                break
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await storeKit.restore()
            if !embedded { dismiss() }
            WiqoToastCenter.shared.show(String(localized: "Satın alımların geri yüklendi"), kind: .success)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
