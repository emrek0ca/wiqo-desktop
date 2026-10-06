# Wiqo decoupling — 7 Ekim 2026

Durum: yerel doğrulamalar tamamlandı; Emre commit ve backend deploy onayını verdi. Yayın sonucu sohbet tesliminde kaydedilir. Windows ve Act kapsam dışı.

## Tamamlanan düzeltmeler
- Mac metin/dosya yazımında diskten içerik karşılaştırması; artifact boyut/hash kontrolünün ardından disk kanıtı. Belge çıktısı hedef dosyayla byte düzeyinde karşılaştırılır. Başarısız doğrulama başarı sayılmaz ve otomatik tekrarlanmaz.
- Dosya yolu ve boyutu iOS sonuç kartına doğrudan eklenir, ek model çağrısı yapılmaz. Kuyruk kartında sonuç özeti gösterilir; bu, ayrı dosya listesi widget'ı değildir.
- Belge/artifact overwrite öncesi mevcut yedek mekanizması kullanılır. Her kaynak yolunun SHA256 grubu ve UUID'li yedeği vardır; aynı adlı dosyalar birbirinin 10 sürümlük saklama grubunu tüketmez. Yedek başarısızsa overwrite durur.
- Artifact indirmede eski Keychain tokenı yerine mevcut yenilemeli dosya aktarım oturumu kullanılır.
- Bekleyen kart, kuyruk/ulaşılamıyor/çalışıyor durumlarını ayırır; bildirim izni bilinmeden kesin bildirim sözü vermez.
- HTTP üzerinden aktif Mac yazma işlemi tamamlanınca genel içerikli APNS bildirimi gönderilir; dosya adı/içerik kilit ekranına konmaz. Aynı terminal sonucun tekrar gelişi tekrar bildirim oluşturmaz.
- Arama şeması boş query kabul ederken adaptörün reddetmesi düzeltildi. Tarih filtresiyle arama artık gereksiz model tekrarına düşmez.
- 'silme' ve bağlamsız 'dosyayı gönder' router kuralları düzeltildi; karma olumlu/olumsuz emirler için regresyon kontrolü eklendi.
- Kullanıcı onayıyla Free Mac erişimi açıldı; günlük 10 mesaj ve mevcut izin/onay sınırları korundu. iOS plan metinleri güncellendi.
- Mevcut token günlüğü korunarak usage:report -- --by-request ile istek bazlı çağrı/token/tahmini USD dökümü eklendi. Fiyatlar repo varsayımıdır, fatura değildir; bilinmeyen modeller ayrıca sayılır.

## Ölçüm
Ayrı /tmp veritabanları, sentetik istekler; gerçek kullanıcı veritabanı ve canlıya dokunulmadı. Gerçek sağlayıcı çağrıları kullanıldı; Mac araçları model eval'inde taklit edildi.

| Ölçüm | Önce | Sonra |
|---|---:|---:|
| Aynı 11 dosya senaryosu | 10/11 | 11/11 |
| Model çağrısı | 16 | 15 |
| Toplam provider token | 137149 | 130135 |
| İş başına ortalama token | 12468 | 11830 |
| 8 router senaryosu | 6/8 | 8/8 |
| Router model çağrısı | 4 | 2 |

Dosya token toplamında %5,1 düşüş; tek koşu, istatistiksel kapasite veya kalıcı tasarruf kanıtı değildir. USD önce/sonra ölçülmedi; token maliyet göstergesidir. Prompt metni ve model seçimi değiştirilmedi. Ek çevrimdışı/olumsuz/belirsiz 3 senaryo 3/3 geçti (3 çağrı, 21252 token).

## Doğrulama
- Backend TypeScript derlemesi başarılı.
- iPhone ve Mac xcodebuild başarılı, imzalama kapalı.
- 25 odaklı backend kontrolü başarılı (router, araç sözleşmesi, kota, workflow, APNS teslim kaydı).
- 2 Mac testi başarılı: eksik/yanlış boyut/yanlış içerik başarı dönmez; belge uzantısı kanıtla eşleşir.
- Güvenlik ve mimari diff incelemesi yapıldı; yedek çakışması, karma olumsuz emir ve yazma dışı bildirim bulguları düzeltildi.

## Sınırlar ve kalan riskler
- Fiziksel iPhone–Mac E2E, uyku/uyanma, APNS teslimi, Face ID/onay ve Duo görünümü bu ortamda doğrulanmadı.
- Kapalı/uyuyan Mac uyandırılmaz. Önceden yetkili güvenli işler kalıcı kuyrukta bekler; 24 saat sonra sona erer. Kullanıcı varlığı/onay isteyen yazma işlemleri bu sınırı aşarak otomatik çalıştırılmaz.
- Teslim edilmiş ancak sonucu belirsiz iş güvenlik için otomatik tekrarlanmaz. Bu, her koşulda tam bir kez çalıştırma garantisi değildir.
- Yeni online dosya APNS bildirimi best-effort: aktif HTTP komutuyla sınırlı; geç reconnect sonucu, LAN yolu ve backend restart sonrası kalıcı push retry bu eklemede yok. Mevcut otomasyon bildiriminin kalıcı retry yolu korunuyor. Bildirim garantisi yok.
- Her platform aracının bütün yan etkisi doğrulanmış sayılmaz: bu değişiklik dosya yazma/belge/artifact çıktısına odaklanır; keyfi terminal komutunun exit=0 sonucu işin anlamsal başarısını tek başına kanıtlamaz.
- Dış S3 yedek, ROVA_DATA_KEY geçişi ve gerçek geri yükleme önceki runbook düzeyinde; hesap/anahtar sağlanmadan etkin değil. Yük testi yapılmadı.
- Yerel yedeği geri almak için önce hedefi kapat; kullanıcı home dizinindeki Library/Application Support/Wiqo/Backups altında standart tam yolun SHA256 grubunu bul, zaman damgalı uygun sürümü ayrı bir dosyaya kopyalayıp doğrula; ardından açık onayla hedefe geri koy. Legacy yedekler silinmedi.

## Emre'nin deneyeceği 5 senaryo
1. Free hesapla eşleş; uygulamaları kapat/aç; Mac erişimi açık, 10 mesaj sınırı korunuyor mu?
2. Mac kapalıyken Belgeler klasörünü listelet; kuyruk mesajı, açılınca tek yürütme ve terminal sonucu kontrol et.
3. Metin/belge oluştur ve güncelle; iOS kartındaki yol/boyut ile diski karşılaştır; eski sürüm yedeğini kontrol et.
4. Onayı reddet, izni kaldır ve bağlantıyı iş sırasında kes; yanlış başarı veya otomatik yinelenen yazma olmamalı.
5. Telefon arka plandayken Mac dosya işini tamamlat; bildirimi ve yeniden açınca kartı kontrol et; yatay/Duo görünümünü dene.

## Değişen dosyalar

rova:
- `RovaIOS/Billing.swift`
- `RovaIOS/CopilotMessageViews.swift`
- `RovaIOS/CopilotView.swift`
- `RovaIOS/DeviceOutcomeNarrator.swift`
- `RovaIOS/PaywallView.swift`
- `RovaMac/DocumentEngine.swift`
- `RovaMac/MacCommandEngine.swift`
- `RovaMac/MacSystem+Files.swift`
- `Tests/RovaMacTests/MacCommandEngineTests.swift`

rova-backend:
- `src/billing/tiers.ts`
- `src/billing/usage.test.ts`
- `src/groq/deviceWidgets.ts`
- `src/groq/intentRoute.test.ts`
- `src/groq/intentRoute.ts`
- `src/groq/prompts.ts`
- `src/notifications/apns.ts`
- `src/scripts/eval-file-tasks.ts`
- `src/scripts/eval-routing.ts`
- `src/scripts/usage-report.ts`
- `src/tools/deviceTools.ts`
- `src/tools/fileTools.test.ts`
- `src/ws/deviceHub.ts`
- `docs/wiqo-decoupling-2026-10-07.md` (bu rapor, uygulama deposu)
