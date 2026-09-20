# Wiqo iOS - App Store gönderim rehberi

Sürüm: 1.0.0 (1) · Bundle ID: `com.wiqo.ios` · Minimum iOS 17 · Sadece iPhone

## 1. Gönderimden önce (sırayla)

1. Apple Developer'da `com.wiqo.ios` App ID'si kayıtlı (Push ve In-App Purchase açık).
2. App Store Connect'te **yeni uygulama** kaydı: bundle `com.wiqo.ios`, SKU `wiqoios001`, birincil dil Türkçe. (Eski `Wiqo`/`com.rova.ios` kaydı kullanılmaz; bundle kimliği kayıtta değiştirilemez.) Ad, mevcut "Wiqo" ile çakışırsa örn. "Wiqo: PC'ni Konuşarak Yönet"; ana ekrandaki ad `CFBundleDisplayName` ile yine "Wiqo" kalır.
3. Yeni kaydın Apple Kimliği ile abonelik ürününü kur (`docs/abonelik.md` bölüm 5.1), sunucu `.env`'ye `APPLE_APP_ID=<yeni kimlik>` yaz, `APPLE_BUNDLE_ID=com.wiqo.ios` ve `APNS_BUNDLE_ID=com.wiqo.ios` olmalı.
4. Xcode: Signing & Capabilities → Team seç, Push Notifications ve Sign-in yeteneklerinin yeni App ID ile eşleştiğini doğrula.
5. TestFlight: kendi iPhone'unda ve 3-5 tanıdık kişide şu akışı dene: kayıt → onboarding → QR eşleştirme → "Sesi kıs" → onay kartı → Pro satın alma (sandbox) → satın alımı geri yükle → hesabı sil.
6. Product → Archive → Distribute → App Store Connect.

## 2. Mağaza metinleri (Türkçe)

**Ad:** Wiqo
**Alt başlık (30):** Bilgisayarını telefondan yönet
**Kategori:** Üretkenlik (ikincil: Yardımcı Programlar)
**Anahtar kelimeler (100):** uzaktan,bilgisayar,mac,kontrol,asistan,otomasyon,ses,dosya,pc,komut,görev,canvas

**Tanıtım metni:**

> Bilgisayarını telefonundan, konuşarak yönet.
>
> "Sesi kıs." "Chrome'u kapat." "Masaüstündeki son belgeyi bul." Wiqo, Mac'inde çalışan uygulama sayesinde ne istediğini anlar ve yapar. Riskli işlerde önce sana sorar, sen onaylamadan hiçbir şey yapmaz.
>
> • Telefondan Mac'ini yönet: ses, parlaklık, uygulamalar, dosyalar, pano, ekran
> • Onay kartlarıyla güvenli: silme, gönderme, kilitleme gibi işlemler senin onayınla çalışır
> • PC kapalıyken de: Google Takvim, Gmail, Drive, Docs, Sheets, Notion ve belge/tablo/grafik hazırlama
> • Canvas: Wiqo'ya bir arayüz yazdır, telefonda ve PC görünümünde canlı gör; Python'u kütüphaneleriyle çalıştır
> • Tekrarlayan işleri otomasyona çevir
>
> PC özelliklerini kullanmak için Mac uygulamasını wiqoai.com adresinden indirip aç, sonra telefondan QR kodu tara. Mac uygulaması olmadan sohbet, canvas ve bulut araçları çalışır.
>
> Free plan sınırlıdır. Wiqo Pro aylık abonelikle daha fazla mesaj, görsel ve PC bağlantısı sunar. Abonelik Apple ID hesabından tahsil edilir ve dönem bitiminden en az 24 saat önce iptal edilmezse otomatik yenilenir; Ayarlar > Apple ID > Abonelikler'den yönetilir.

**Destek URL'si:** https://wiqoai.com/support
**Gizlilik Politikası URL'si:** https://wiqoai.com/privacy
**Kullanım Şartları:** https://wiqoai.com/terms
(Üç sayfa da siteye eklenmeden gönderim yapılmamalı; uygulama bu adreslere bağlanıyor: `RovaIOS/Billing.swift` → `WiqoWebsite`.)

## 3. Gizlilik ("App Privacy") yanıtları

`RovaIOS/PrivacyInfo.xcprivacy` ile birebir aynı olmalı. Hepsi: **kullanıcıya bağlı, takip için kullanılmıyor, amaç: uygulama işlevselliği.**

| Veri türü | Neden |
|---|---|
| E-posta adresi | Hesap |
| Diğer kullanıcı içeriği | Sohbet mesajları |
| Ses verisi | Sesli mesaj |
| Fotoğraf veya video | Sohbete eklenen görseller |
| E-postalar veya metin mesajları | Kullanıcı Gmail'i bağlarsa okunan içerik |
| Kişiler | Kullanıcı Google'ı bağlarsa kişi arama |
| Cihaz kimliği | Push bildirim jetonu |
| Satın alma geçmişi | Abonelik durumu |

Takip (tracking): **Hayır.** Mesaj, ses ve görseller yanıt üretmek için yapay zeka hizmet sağlayıcılarıyla işlenir. Bu, kayıt ekranındaki açık onayda ve gizlilik politikasında "yapay zeka hizmet sağlayıcıları" olarak yazmalıdır (App Store 5.1.2). Politikada verinin **sadece Wiqo'da kaldığı** yazılmamalı; doğru değil ve hem Apple hem kullanıcı için yanıltıcı olur. Sağlayıcı adını yazmak zorunlu değil, türünü yazmak zorunlu.

Şifreleme (export compliance): `ITSAppUsesNonExemptEncryption = NO` (yalnızca TLS ve HMAC-SHA256 imza).

## 4. Yaş derecelendirmesi

Üretken yapay zeka ve kullanıcı içeriği soruları dürüst yanıtlanmalı; beklenen sonuç 12+ civarı. Tarayıcı/web erişimi soruları için "hayır".

## 5. İnceleme notları (App Review Information)

> Wiqo, bir Mac'te çalışan yardımcı uygulama ile iPhone'dan bilgisayarı yönetir. İnceleme için:
> 1. Uygulama Mac olmadan da açılır: sohbet, Canvas ve bulut araçları çalışır.
> 2. PC özellikleri için Mac uygulaması (https://wiqoai.com) gerekir; eşleştirme QR ile yapılır. Kısa bir demo videosu: [VİDEO BAĞLANTISI].
> 3. Test hesabı: [E-POSTA] / [ŞİFRE] (Pro planı tanımlı).
> 4. Abonelik yalnızca uygulama içi satın alma ile satılır; uygulama içinde harici ödeme bağlantısı yoktur.
> 5. Yapay zeka hizmet sağlayıcılarıyla veri işleme, kayıt sırasında açıkça onaylatılır. (İnceleyici sağlayıcıyı sorarsa Groq olarak yanıtlanır.)

Doldurulacak: demo videosu, test hesabı.

## 6. Ekran görüntüleri (6,9" ve 6,5")

1. Onboarding: "Bilgisayarını telefonundan, konuşarak yönet."
2. Sohbet: "Sesi kıs" + sonuç satırı
3. Onay kartı (ör. Gmail gönderme) ve "Yaptım" hapı
4. Canvas: telefon çerçevesinde canlı uygulama önizlemesi
5. Ayarlar: PC durumu, plan kullanımı
6. Planlar ekranı

## 7. Bu sürümde bilerek olmayanlar

- Windows istemcisi (yalnızca Mac). Uygulamada ve mağaza metninde Windows vaat edilmez.
- Business planı uygulama içinde satılmaz; yalnızca mevcut Business hesaplarında görünür.
