# Wiqo · Mac / iOS / backend teslimi

## Tamamlanan değişiklikler

- Backend cihaz JWT'si artık sunucudaki oturum kimliğine bağlı. HTTP, WebSocket mesajı ve komut yönlendirmesinde iptal kontrol edilir; cihaz silme tüm ilgili soketleri kapatır. Eski cihaz JWT'si refresh ile yeni biçime geçer.
- Mac'te refresh çağrıları birleştirildi, taze token 10 dakika kullanılır. İptal edilmiş oturum yeniden bağlanma döngüsünde tutulmaz. Yeniden eşleşmede eski refresh sonucu yeni oturumu değiştiremez.
- Çevrimdışı görev claim'i ve workflow kaydı aynı transaction'da. iOS özgün görev kartı sunucudan tamamlandı/iptal/hata/belirsiz sonucunu okur; görünüm kapanınca veya uygulama arka plana geçince sorgulama iptal edilir.
- Act senkronunda eksik tarama silme sayılmaz; geçersiz yollar, symlink ve aşırı dosya boyutu reddedilir. Ağ hatalarında bekleme vardır. HTTP sırasında değişen yerel dosyalar korunur. Çakışma kopyaları birbirini ezmez. Python proje yürütme mevcut sınırlı process adaptörünü kullanır.
- Araç kurtarması doğrudan araçların `action` alanını korur. Zorunlu araç şeması bütçe filtresinde korunur. Hata nedeni özel içerik olmadan sınıflandırılır. Eski `%27` oranının düştüğü iddia edilmiyor; yayın sonrası ölçülmeli.
- S3 uyumlu hedefe Restic ile şifreli yedek hazırlığı ve anahtar/dönüşüm/geri yükleme yönergesi backend'de eklendi. Şifreleme/yükleme hatasında başarı veya retention yapılmaz.

## Commit'ler ve dosyalar

Uygulama `feature/android-app`:

- `70aa557`: `RovaMac/MacBackendChannel.swift`, `RovaWindows/ProtocolV2Client.cs` — oturum iptal/refresh düzeltmesi.
- `611f9c6`: Windows Act hazırlığı; Emre'nin talebiyle durduruldu, tamamlanmış Windows sürümü değildir. Dosyalar: `RovaWindows/App/App.xaml.cs`, `CompanionHost.cs`, `TrayIcon.cs`, `ProjectsWindow.xaml`, `ProjectsWindow.xaml.cs`; `RovaWindows/WindowsSecretStore.cs`; `RovaWindows/Projects/ActVault.cs`, `WindowsProjectSync.cs`.
- `e7e071b`: `RovaMac/MacBackendChannel.swift`, `RovaMac/MacProjectSync.swift`, `RovaShared/ActSync.swift`.
- `94c7937`: `RovaIOS/CopilotMessageViews.swift`, `RovaIOS/RovaBackendClient.swift`.

Backend `refactor/foundation`:

- `cb19025`: `src/auth.ts`, `src/routes/deviceSessions.ts`, `src/ws/deviceHub.ts`.
- `a400036`: `src/automation/deferred.ts`, `src/routes/devices.ts`, `src/codeprojects/pcTasks.ts`.
- `c37e934`: `src/groq/client.ts`, `src/groq/model-router.ts`, `src/groq/salvage.ts`.
- `88b6e82`: `scripts/backup.sh`, `docs/production-data-readiness.md`.

## Doğrulama ve sınırlar

Mac: `xcodebuild -project Rova.xcodeproj -scheme RovaMac -configuration Debug -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build` başarılı.

iOS: `xcodebuild -project Rova.xcodeproj -scheme Wiqo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/wiqo-ios-build CODE_SIGNING_ALLOWED=NO build` başarılı.

Backend: `npm run build`, `bash -n scripts/backup.sh` ve diff boşluk kontrolü başarılı. Test/eval, telefon/simülatör çalıştırma, canlı migration, push veya deploy yapılmadı. Backend'deki önceden bulunan iki eval JSON dosyası korunmuştur.

Windows durdurulmadan önce çapraz derleme geçti; çalışma/paket/parite tamamlanmış sayılmaz. Mac/iOS dağıtım imzalama, kurulum/güncelleme akışı ve tüm araçların gerçek cihaz paritesi bu teslimde doğrulanmadı. Mevcut kart türleri ve inline app korunmuştur; gerçek cihaz başarısı ölçülmedi. Binlerce kullanıcı kapasitesi ölçülmedi. Dış yedek hedefi/anahtarı sağlanmadığından yedek etkinleştirilmedi. Canlı backend eski sürümdedir; yeni görev durum endpoint'i ancak yetkili yayın sonrası kullanılabilir.

## Emre'nin deneyeceği 5 senaryo

1. iPhone ile Mac'i eşleştir; Wi-Fi değiştir, Mac'i uyutup uyandır. Yeniden bağlanınca tek görev gönder.
2. Mac kapalıyken güvenli bir uygulama açma işi iste; Mac açıldığında yalnız bir kez yürüsün, aynı telefon kartı tamamlandıya dönsün.
3. Dosya yazma/terminal isteğinde onayla, başka isteği reddet; kuyrukta işi iptal et. Cihaz erişimini kaldırınca yeni komut çalışmasın; tekrar eşleştirme çalışsın.
4. Act projesini iPhone ve Mac'te değiştir; aynı dosya çakışmasında iki sürüm korunsun. Büyük/okunamayan dosya silinmesin. Python görevi zaman aşımında arayüzü kilitlemesin.
5. Harita, kur, skor, çeviri, zamanlayıcı, tarif, gezi, kişi, müzik, kontrol listesi ve inline app'i aç; sıfırla/tam ekranı ve yatay/Duo düzenini dene.
