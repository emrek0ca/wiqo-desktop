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
        title: String(localized: "Sabah brifingi"),
        detail: String(localized: "Her sabah hava durumu ve gündemi özetler"),
        icon: "sun.max.fill",
        prompt: String(localized: "Her sabah 08:00'de bana hava durumunu ve takvimimdeki bugünkü etkinlikleri özetleyen bir otomasyon oluştur.")
    ),
    AutomationTemplate(
        title: String(localized: "Pil uyarısı"),
        detail: String(localized: "PC pili azalınca haber verir"),
        icon: "battery.25",
        prompt: String(localized: "PC'min pili %20'nin altına düştüğünde bana haber veren bir otomasyon oluştur.")
    ),
    AutomationTemplate(
        title: String(localized: "Hafta sonu hatırlatıcı özeti"),
        detail: String(localized: "Cuma akşamı bekleyen hatırlatıcıları listeler"),
        icon: "checklist",
        prompt: String(localized: "Her Cuma 18:00'de tamamlanmamış hatırlatıcılarımı özetleyen bir otomasyon oluştur.")
    ),
    AutomationTemplate(
        title: String(localized: "Odak modu"),
        detail: String(localized: "Belirlediğin saatte Rahatsız Etmeyi açar"),
        icon: "moon.stars.fill",
        prompt: String(localized: "Her gün 09:00'da Rahatsız Etme'yi açan, 18:00'de kapatan bir otomasyon oluştur.")
    ),
    AutomationTemplate(
        title: String(localized: "Haftalık takvim özeti"),
        detail: String(localized: "Pazartesi sabahı haftanın programını çıkarır"),
        icon: "calendar",
        prompt: String(localized: "Her Pazartesi 08:30'da o haftaki takvim etkinliklerimi özetleyen bir otomasyon oluştur.")
    ),
    AutomationTemplate(
        title: String(localized: "İndirilenler temizliği"),
        detail: String(localized: "Her hafta eski dosyaları ayıklar"),
        icon: "trash",
        prompt: String(localized: "Her Pazar 20:00'de İndirilenler klasöründeki 30 günden eski dosyaları listeleyip benden onay isteyen bir otomasyon oluştur.")
    ),
    AutomationTemplate(
        title: String(localized: "Gece kilidi"),
        detail: String(localized: "Belirlediğin saatte PC'yi otomatik kilitler"),
        icon: "lock.fill",
        prompt: String(localized: "Her gece 00:30'da PC'mi otomatik kilitleyen bir otomasyon oluştur.")
    ),
    AutomationTemplate(
        title: String(localized: "Akşam özet e-postası"),
        detail: String(localized: "Günün özetini akşam bana gönderir"),
        icon: "envelope.fill",
        prompt: String(localized: "Her gün 19:00'da o günkü yaptıklarımın kısa bir özetini bana ileten bir otomasyon oluştur.")
    ),
    AutomationTemplate(
        title: String(localized: "Pano temizliği"),
        detail: String(localized: "Panoyu belirli aralıklarla temizler"),
        icon: "doc.on.clipboard",
        prompt: String(localized: "Her gün 22:00'de PC'min panosunu (clipboard) temizleyen bir otomasyon oluştur.")
    ),
    AutomationTemplate(
        title: String(localized: "Ayın başı hatırlatıcı"),
        detail: String(localized: "Her ayın ilk günü bir hatırlatma gönderir"),
        icon: "calendar.badge.clock",
        prompt: String(localized: "Her ayın 1'inde saat 09:00'da o ay için bütçe/faturalarımı gözden geçirmemi hatırlatan bir otomasyon oluştur.")
    ),
    AutomationTemplate(
        title: String(localized: "Uygulama açılışı"),
        detail: String(localized: "Gün başında sık kullandığın uygulamaları açar"),
        icon: "app.badge",
        prompt: String(localized: "Her hafta içi 09:00'da mail ve takvim uygulamalarımı PC'de otomatik açan bir otomasyon oluştur.")
    )
]

struct AutomationTemplatesView: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var skills: [RovaBackendClient.UserSkill] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !skills.isEmpty {
                        WiqoSettingsGroup(title: String(localized: "Becerilerim")) {
                            ForEach(skills) { skill in
                                Button {
                                    onSelect(skill.prompt)
                                } label: {
                                    WiqoRow(
                                        systemImage: "sparkles",
                                        title: skill.name,
                                        subtitle: skill.prompt,
                                        showsDivider: skill.id != skills.last?.id
                                    )
                                }
                                .buttonStyle(WiqoRowButtonStyle())
                                .contextMenu {
                                    Button("Sil", role: .destructive) {
                                        Task {
                                            try? await RovaBackendClient.deleteSkill(id: skill.id)
                                            skills.removeAll { $0.id == skill.id }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    WiqoSettingsGroup {
                        ForEach(automationTemplates) { template in
                            Button {
                                onSelect(template.prompt)
                            } label: {
                                WiqoRow(
                                    systemImage: template.icon,
                                    title: template.title,
                                    subtitle: template.detail,
                                    showsDivider: template.id != automationTemplates.last?.id
                                )
                            }
                            .buttonStyle(WiqoRowButtonStyle())
                        }
                    }
                    Text("Bir şablon seçince Wiqo'yla yeni bir sohbet açılır ve istek yazı kutusuna doldurulur - göndermeden önce saat, hedef PC vb. ayrıntıları dilediğin gibi değiştirebilirsin.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
                .padding(RovaDesign.screenPadding)
            }
            .background(RovaDesign.canvas)
            .task { skills = (try? await RovaBackendClient.fetchSkills()) ?? [] }
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
