import StoreKit
import SwiftUI

/// Plan comparison + purchase flow. Pro purchases right here through StoreKit. Business is sold
/// on the website via PayTR (see WiqoWebsite in Billing.swift) but that integration isn't wired
/// up yet, so its card shows "Yakında" instead of a live link - see docs/abonelik.md section 8.
struct PaywallView: View {
    @ObservedObject var subscriptionStore: SubscriptionStore
    @StateObject private var storeKit = StoreKitManager()
    @Environment(\.dismiss) private var dismiss

    @State private var isRestoring = false
    @State private var errorMessage: String?

    private var currentTier: String { subscriptionStore.info.tier }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: RovaDesign.cardSpacing) {
                    header
                    freeCard
                    proCard
                    businessCard
                    restoreButton
                }
                .padding(RovaDesign.screenPadding)
            }
            .background(RovaDesign.canvas)
            .navigationTitle("Planlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") { dismiss() }
                }
            }
            .task { await storeKit.loadProducts() }
            .alert("Hata", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("Tamam", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("Wiqo'yu yükselt").font(.title2.weight(.bold))
            Text("Daha fazla mesaj, görsel ve PC bağlantısı için bir plan seç.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var freeCard: some View {
        planCard(
            title: "Free",
            price: "Ücretsiz",
            features: ["Günde 10 mesaj", "Günde 1 görsel", "PC bağlantısı yok"],
            isCurrent: currentTier == "free"
        )
    }

    private var proCard: some View {
        planCard(
            title: "Pro",
            price: storeKit.proProduct?.displayPrice ?? "$9,99/ay",
            features: ["Günde 100 mesaj", "Günde 10 görsel", "PC bağlantısı"],
            isCurrent: currentTier == "pro"
        ) {
            if currentTier != "pro" {
                Button {
                    Task { await purchasePro() }
                } label: {
                    if storeKit.isPurchasing {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Pro'ya geç").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(storeKit.isPurchasing || storeKit.proProduct == nil)
                .padding(.top, 4)
            }
        }
    }

    private var businessCard: some View {
        planCard(
            title: "Business",
            price: "$20,00/ay",
            features: ["Günde 200 mesaj", "Günde 20 görsel", "PC bağlantısı"],
            isCurrent: currentTier == "business"
        ) {
            if currentTier != "business" {
                // Business satışı web sitesi + PayTR üzerinden yürüyecek, ama o entegrasyon henüz
                // bağlanmadı (bkz. docs/abonelik.md bölüm 8) - bağlanana kadar yönlendirme yerine
                // net bir "yakında" durumu gösteriliyor.
                VStack(alignment: .leading, spacing: 6) {
                    Button {} label: {
                        Text("Yakında").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(true)
                    Text("Business planı yakında Wiqo'nun web sitesi üzerinden satışa açılacak.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var restoreButton: some View {
        Button {
            Task { await restore() }
        } label: {
            if isRestoring {
                ProgressView()
            } else {
                Text("Satın alımları geri yükle")
            }
        }
        .font(.footnote.weight(.medium))
        .disabled(isRestoring)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func planCard<Action: View>(
        title: String,
        price: String,
        features: [String],
        isCurrent: Bool,
        @ViewBuilder action: () -> Action = { EmptyView() }
    ) -> some View {
        RovaCard {
            HStack {
                Text(title).font(.headline)
                if isCurrent {
                    Text("Mevcut plan")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RovaDesign.signal.opacity(0.18), in: Capsule())
                        .foregroundStyle(RovaDesign.signal)
                }
                Spacer()
                Text(price).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(features, id: \.self) { feature in
                Label(feature, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            action()
        }
    }

    private func purchasePro() async {
        do {
            let outcome = try await storeKit.purchasePro(subscriptionStore: subscriptionStore)
            switch outcome {
            case .purchased:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            case .pending:
                errorMessage = "Satın alma onay bekliyor (Ask to Buy). Onaylanınca otomatik aktif olacak."
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
            try await storeKit.restore(subscriptionStore: subscriptionStore)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
