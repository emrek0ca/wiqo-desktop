import SwiftUI

/// A ready-made prompt for a common automation. Automations are still created conversationally
/// (there's no separate "new automation" form/endpoint - see create_automation on the backend),
/// so a template is just a well-phrased request that lands in the composer as an editable draft -
/// never sent on the user's behalf - and Wiqo still confirms cron/target/etc. in the reply exactly
/// as it would if the user had typed it from scratch.
private struct AutomationTemplate: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let icon: String
    let prompt: String
}

private let automationTemplates: [AutomationTemplate] = [
    AutomationTemplate(
        title: "Sabah brifingi",
        detail: "Her sabah hava durumu ve gündemi özetler",
        icon: "sun.max.fill",
        prompt: "Her sabah 08:00'de bana hava durumunu ve takvimimdeki bugünkü etkinlikleri özetleyen bir otomasyon oluştur."
    ),
    AutomationTemplate(
        title: "Pil uyarısı",
        detail: "PC pili azalınca haber verir",
        icon: "battery.25",
        prompt: "PC'min pili %20'nin altına düştüğünde bana haber veren bir otomasyon oluştur."
    ),
    AutomationTemplate(
        title: "Hafta sonu hatırlatıcı özeti",
        detail: "Cuma akşamı bekleyen hatırlatıcıları listeler",
        icon: "checklist",
        prompt: "Her Cuma 18:00'de tamamlanmamış hatırlatıcılarımı özetleyen bir otomasyon oluştur."
    ),
    AutomationTemplate(
        title: "Odak modu",
        detail: "Belirlediğin saatte Rahatsız Etmeyi açar",
        icon: "moon.stars.fill",
        prompt: "Her gün 09:00'da Rahatsız Etme'yi açan, 18:00'de kapatan bir otomasyon oluştur."
    ),
    AutomationTemplate(
        title: "Haftalık takvim özeti",
        detail: "Pazartesi sabahı haftanın programını çıkarır",
        icon: "calendar",
        prompt: "Her Pazartesi 08:30'da o haftaki takvim etkinliklerimi özetleyen bir otomasyon oluştur."
    ),
    AutomationTemplate(
        title: "İndirilenler temizliği",
        detail: "Her hafta eski dosyaları ayıklar",
        icon: "trash",
        prompt: "Her Pazar 20:00'de İndirilenler klasöründeki 30 günden eski dosyaları listeleyip benden onay isteyen bir otomasyon oluştur."
    ),
    AutomationTemplate(
        title: "Gece kilidi",
        detail: "Belirlediğin saatte PC'yi otomatik kilitler",
        icon: "lock.fill",
        prompt: "Her gece 00:30'da PC'mi otomatik kilitleyen bir otomasyon oluştur."
    ),
    AutomationTemplate(
        title: "Akşam özet e-postası",
        detail: "Günün özetini akşam bana gönderir",
        icon: "envelope.fill",
        prompt: "Her gün 19:00'da o günkü yaptıklarımın kısa bir özetini bana ileten bir otomasyon oluştur."
    ),
    AutomationTemplate(
        title: "Pano temizliği",
        detail: "Panoyu belirli aralıklarla temizler",
        icon: "doc.on.clipboard",
        prompt: "Her gün 22:00'de PC'min panosunu (clipboard) temizleyen bir otomasyon oluştur."
    ),
    AutomationTemplate(
        title: "Ayın başı hatırlatıcı",
        detail: "Her ayın ilk günü bir hatırlatma gönderir",
        icon: "calendar.badge.clock",
        prompt: "Her ayın 1'inde saat 09:00'da o ay için bütçe/faturalarımı gözden geçirmemi hatırlatan bir otomasyon oluştur."
    ),
    AutomationTemplate(
        title: "Uygulama açılışı",
        detail: "Gün başında sık kullandığın uygulamaları açar",
        icon: "app.badge",
        prompt: "Her hafta içi 09:00'da mail ve takvim uygulamalarımı PC'de otomatik açan bir otomasyon oluştur."
    )
]

struct AutomationTemplatesView: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(automationTemplates) { template in
                        Button {
                            onSelect(template.prompt)
                        } label: {
                            RovaCard {
                                HStack(spacing: 14) {
                                    Image(systemName: template.icon)
                                        .font(.title3)
                                        .foregroundStyle(RovaDesign.ink)
                                        .frame(width: 36, height: 36)
                                        .background(RovaDesign.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(template.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                        Text(template.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Bir şablon seçince Wiqo'yla yeni bir sohbet açılır ve istek yazı kutusuna doldurulur - göndermeden önce saat, hedef PC vb. ayrıntıları dilediğin gibi değiştirebilirsin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(RovaDesign.screenPadding)
            }
            .background(RovaDesign.canvas)
            .navigationTitle("Otomasyon Şablonları")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
    }
}
