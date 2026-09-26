import SwiftUI

/// "Neler yapabilirim" keşif ekranı - kullanıcı Wiqo'nun tüm yeteneklerini bir sohbet turu
/// yapmadan görebilsin diye örnek istekleri kategorilere ayırıp listeler. Bir örneğe dokunmak
/// onu composer'a yazar ve sayfayı kapatır; gönderme kararı yine kullanıcıya kalır.
private struct DiscoveryExample: Identifiable {
    let id = UUID()
    let prompt: String
    let requiresDevice: Bool
}

private struct DiscoveryCategory: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let examples: [DiscoveryExample]
}

private let discoveryCategories: [DiscoveryCategory] = [
    DiscoveryCategory(title: "Belgeler ve tablolar", icon: "doc.richtext.fill", examples: [
        DiscoveryExample(prompt: "Bu ayki bütçemi kalemlere ayırıp bir tabloya dök", requiresDevice: false),
        DiscoveryExample(prompt: "Toplantı notlarımı düzenli, başlıklı bir belgeye dönüştür", requiresDevice: false),
        DiscoveryExample(prompt: "Geçen ayki satışları özetleyen bir grafik çiz", requiresDevice: false)
    ]),
    DiscoveryCategory(title: "Kod ve hesap makinesi", icon: "function", examples: [
        DiscoveryExample(prompt: "Basit bir hesap makinesi yap", requiresDevice: false),
        DiscoveryExample(prompt: "Sayı tahmin oyunu yaz, tarayıcıda oynayabileyim", requiresDevice: false),
        DiscoveryExample(prompt: "Bu verinin ortalamasını ve standart sapmasını hesapla: 12, 18, 9, 25, 14", requiresDevice: false)
    ]),
    DiscoveryCategory(title: "Matematik", icon: "x.squareroot", examples: [
        DiscoveryExample(prompt: "x^2 + 3x - 4 = 0 denklemini adım adım çöz", requiresDevice: false)
    ]),
    DiscoveryCategory(title: "Görsel üretimi", icon: "photo.fill", examples: [
        DiscoveryExample(prompt: "Minimalist bir uygulama ikonu taslağı çiz", requiresDevice: false)
    ]),
    DiscoveryCategory(title: "Güncel araştırma", icon: "magnifyingglass", examples: [
        DiscoveryExample(prompt: "Bugün dolar kuru ne kadar, kaynağıyla söyle", requiresDevice: false)
    ]),
    DiscoveryCategory(title: "Otomasyon", icon: "clock.badge.checkmark.fill", examples: [
        DiscoveryExample(prompt: "Her sabah 9'da bana günün özetini çıkar", requiresDevice: false)
    ]),
    DiscoveryCategory(title: "PC kontrolü", icon: "laptopcomputer", examples: [
        DiscoveryExample(prompt: "PC'mi kilitle", requiresDevice: true),
        DiscoveryExample(prompt: "Sesi kıs", requiresDevice: true),
        DiscoveryExample(prompt: "Müziği duraklat", requiresDevice: true)
    ])
]

struct DiscoveryView: View {
    let deviceReady: Bool
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !deviceReady {
                        Text("PC gerektiren örnekler, bir PC eşleştirip bağlandığında burada görünür.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                    }
                    ForEach(discoveryCategories.filter { category in
                        category.examples.contains { deviceReady || !$0.requiresDevice }
                    }) { category in
                        let examples = category.examples.filter { deviceReady || !$0.requiresDevice }
                        WiqoSettingsGroup(title: category.title) {
                            ForEach(examples) { example in
                                Button {
                                    onSelect(example.prompt)
                                    dismiss()
                                } label: {
                                    WiqoRow(
                                        systemImage: category.icon,
                                        title: example.prompt,
                                        showsDivider: example.id != examples.last?.id
                                    ) {
                                        Image(systemName: "arrow.up.left")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(WiqoTheme.ink3)
                                    }
                                }
                                .buttonStyle(WiqoRowButtonStyle())
                            }
                        }
                    }
                }
                .padding(RovaDesign.screenPadding)
            }
            .background(RovaDesign.canvas)
            .navigationTitle("Neler yapabilirim?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
    }
}
