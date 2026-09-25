# Wiqo Windows companion çekirdeği

`RovaWindows.sln`, .NET 8 tabanlı bir protokol/işlem kütüphanesidir. Bu depoda Windows
UI/tray host'u yoktur. Host, `WindowsRuntime`, `DeviceSessionClient` ve `ProtocolV2Client`
sınıflarını kullanır; henüz uygulanmamış bir yeteneği kayıt mesajında ilan etmez.

## Eşleme ve yeniden bağlanma

1. Host bir `WindowsRuntime` oluşturur; `runtime.DeviceId` kalıcı cihaz kimliğidir.
2. `DeviceSessionClient.CreateRelayPairingQrAsync(runtime.DeviceId, runtime.DisplayName)`
   çağrılır. Dönen `Value` QR olarak gösterilir. Eşleme süresi dolarsa yeni QR üretilir.
3. iPhone QR'ı tarayıp PC eşlemesini onaylar. Host,
   `PollRelayPairingAsync(session)` sonucunu makul aralıklarla ve iptal token'ıyla sorar;
   `null` henüz eşleşmediğini veya sunucunun hız sınırı koyduğunu gösterir. Sonsuz/sık polling
   yapılmaz.
4. Dönen `DeviceSessionCredentials`, aynı kullanıcı oturumunun DPAPI korumalı alanına
   kaydedilir. Host `ProtocolV2Client(runtime, sessions: sessionClient)` ile
   `RunWithRefreshAsync(credentials, cancellationToken)` başlatır. Yeniden başlatmada
   `LoadStoredCredentials()` kullanılır; geçersiz kimlik bilgisinde yeniden eşleme gösterilir.
5. Eşleme token'ı da DPAPI ile kullanıcı profili altında saklanır. Bu token loga, UI hata
   metnine veya telemetriye yazılmaz. Farklı Windows kullanıcısı için yeniden eşleme gerekir.

`features: ["terminal-session-v1"]` yalnız eşleme token'ı mevcutsa gönderilir. Genel cihaz
manifestosu sadece gerçekten uygulanan sistem durumu, URL açma, açık uygulama listesi ve host
tarafından kullanıcı onayı sağlandığında dosya arama/okuma işlemlerini içerir. İzole kod sandbox'ı
olmadığı için `device.code.execute` ilan edilmez. Terminal oturumu ayrı, telefondan imzalı ve
zaman sınırlı bir protokoldür.

## Terminal ve imza sınırı

Windows, `terminalCommand` mesajındaki telefon imzalı grant'i her çalıştırma, yama, izleme ve
iptalde yeniden doğrular. Grant; tek cihazın eşleme token'ına, klasöre, `read/full` moduna ve
son kullanma zamanına bağlıdır. Çalışma klasörü ve yama dosyası grant kökü içinde çözülür;
reparse point/symlink geçişleri reddedilir. `read` modu yalnız izinli salt okuma komutlarını,
`full` modu ise tehlikeli komutlar dışındaki PowerShell/cmd komutlarını çalıştırır. `run`,
`start_job`, `get_job`, `cancel_job`, `apply_patch` desteklenir; arka plan işi bellekte izlenir,
grant süresini aşmadan en çok 30 dakika çalışır,
companion yeniden başlarsa sonuç `unknown` sayılır ve otomatik tekrar oynatılmaz. Çıktı
gönderilmeden önce bilinen gizli bilgi biçimleri maskelenir.

Normal `interactiveCommand` için `CommandRequest` v2 zorunludur. İmza, istek kimliği/türü,
epoch milisaniye zamanı, nonce ve RFC 8785 JSON payload SHA-256 özetini kapsar. Eski imza
sürümü çalıştırılmadan reddedilir. Güncel iPhone ve backend sürümleri birlikte kullanılmalıdır.

Grant klasörü, shell için çalışma kökünü ve yama hedefini sınırlar; PowerShell/cmd için işletim
sistemi düzeyinde dosya sandbox'ı sağlamaz. Bu nedenle `full` izni yalnız güvenilen komutlara ve
dar kapsamlı klasöre verilmeli, uygulama host'u izin kapsamını kullanıcıya açıkça göstermelidir.

## Windows'ta doğrulama

Windows 10 22H2+/Windows 11, .NET 8 SDK bulunan makinede:

```powershell
dotnet build RovaWindows/RovaWindows.sln -c Release
```

Elle kontrol: QR eşleme ve yeniden bağlanma; v1 veya payload'ı değiştirilmiş v2 komutun reddi;
`read` modunda yazmanın, grant dışı çalışma klasörünün, symlink/reparse point yolunun ve yasaklı
komutların reddi; `full` modunda tek dosya yaması/diff; uzun işte izleme, iptal ve yeniden başlatma
sonrası `unknown`; manifestoda uygulanmamış kod sandbox yeteneğinin yokluğu. Bu macOS ortamında
Windows derlemesi yapılmadı.
