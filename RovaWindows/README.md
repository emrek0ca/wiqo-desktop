# Wiqo Windows

Wiqo'nun Windows yardımcısı. Bildirim alanında çalışır; telefondan gelen imzalı istekleri bu bilgisayarda uygular. Mac yardımcısıyla aynı protokolü, aynı operasyon kataloğunu ve aynı güvenlik kurallarını kullanır.

## Yapı

| Klasör | Ne |
|---|---|
| `Core/` | Tel biçimi (tam saniyeli ISO tarih), paylaşılan katalog (`operations.json` gömülü), doğrulama, yetenek ayarları, sonuç defteri, bağlantı güvenliği |
| `Operations/` | Uygulamalar, sistem (güç, ses, medya, pano, ekran görüntüsü), dosyalar ve arama |
| `Native/` | Win32 ve Core Audio çağrıları |
| `Terminal/` | Terminal oturumu v1 ve v2: `run_plan`, `read_file`, `write_file`, `edit_file`, `search`, yama, arka plan işleri, profil |
| `ProtocolV2Client.cs` | Backend bağlantısı: kayıt, imzalı komutlar, yeniden bağlanma, makbuzlar, otomasyon adımları |
| `App/` | WPF tepsi uygulaması (`Wiqo.exe`): eşleme QR'ı, ayarlar, açılışta başlatma, günlükler |
| `Tests/` | Sözleşme vektörleri, Mac paritesi, doğrulama, terminal (PowerShell testleri yalnız Windows'ta) |

## Mac ile parite

`contracts/companion/check.sh` iki tarafı birlikte kontrol eder:
- aynı imza ve kanonik JSON vektörleri;
- Windows manifestosunun, `RovaShared/OperationManifest.swift`'teki Windows listesiyle birebir aynı olması.

Şu an 47 operasyonun 31'i Windows'ta var. Yalnız Mac'te kalanlar Apple'a özgü: Takvim, Anımsatıcılar, Notlar, Mail, Mesajlar, Kısayollar. Bunlara ek olarak şunlar da henüz Windows'ta yok:
- parlaklık;
- pano geçmişi;
- belge motoru;
- arayüz tıklaması.

Windows'a özgü davranışlar:
- **Silme:** Dosyalar Geri Dönüşüm Kutusu'na gider, kalıcı silinmez.
- **OneDrive:** Buluttaki dosyalar (reparse point) normal dosya sayılır. Yalnız sembolik link ve junction reddedilir.
- **Terminal:** Varsa PowerShell 7, yoksa Windows PowerShell 5.1 kullanılır. Çıktı UTF-8'dir. PATH her komutta registry'den taze okunur ve adı gizli bilgiye benzeyen ortam değişkenleri çıkarılır.
- **Düzenleme:** `edit_file` CRLF dosyalarda LF ile yazılmış metni de bulur. `write_file` dosyanın satır sonlarını ve BOM'unu korur.

## Derleme ve test

macOS'ta da çalışır (`EnableWindowsTargeting`):

```bash
dotnet test RovaWindows/Tests/RovaWindows.Tests.csproj -p:EnableWindowsTargeting=true
```

```bash
RovaWindows/scripts/publish.sh
```

Çıktılar `RovaWindows/dist/win-x64/Wiqo.exe` ve `RovaWindows/dist/win-arm64/Wiqo.exe` dosyalarıdır. Tek dosyalıktır ve .NET kurulumu gerektirmez. CI (`.github/workflows/rova-windows.yml`) Windows'ta tüm testleri çalıştırır ve iki paketi indirilebilir olarak yükler.

## Sanal makinede elle test

1. `Wiqo.exe`'yi aç. Eşleme penceresi açılır. Telefondan QR'ı okut; pencere "Bağlandı" deyip kapanır. Tepsi simgesinde yeşil nokta görünür.
2. Telefondan şunları sırayla dene:
   - "Hesap makinesini aç";
   - "sesi %30 yap";
   - "masaüstündeki dosyaları listele";
   - "ekran görüntüsü al";
   - "masaüstünde deneme klasöründe notlar.txt oluştur, merhaba yaz, selam yap, göster".
   Son istek terminal onay kartını açar.
3. Ayarlar'dan bir grubu kapat ve aynı isteği tekrarla; reddedilmeli.
4. Wi-Fi'ı kapatıp aç, ya da bilgisayarı uyutup uyandır. Birkaç saniye içinde yeniden bağlanmalı.
5. Günlükler: `%LOCALAPPDATA%\Wiqo\logs`. Token, dosya yolu ya da içerik yazılmaz.

## Durum

Uygulama henüz kod imzalı değil; kurulumda SmartScreen uyarısı çıkar. Geniş dağıtım için bir kod imzalama sertifikası gerekir.
