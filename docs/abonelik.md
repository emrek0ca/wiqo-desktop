# Wiqo Abonelik Sistemi

Bu doküman Wiqo'nun abonelik/faturalama sisteminin **tamamını** anlatır: plan limitleri, App Store Connect ayarları, backend mimarisi, PayTR entegrasyonu ve hâlâ yapılması gerekenler. Yeni bir konuşmada veya yeni bir geliştiricide hiçbir detayın kaybolmaması için buradaki bilgiler eksiksiz tutulmalı.

Son güncelleme: 2026-09-15.

---

## 1. Plan limitleri (tek doğru kaynak: `rova-backend/src/billing/tiers.ts`)

| Plan | Günlük mesaj | Günlük görsel | PC bağlantısı | Fiyat | Satış kanalı |
|---|---|---|---|---|---|
| **Free** | 10 | 1 | ❌ Yok | Ücretsiz | — |
| **Pro** | 100 | 10 | ✅ Var | **$10/ay** (App Store fiyat noktası: **$9.99**) | Uygulama içi, **StoreKit 2** |
| **Business** | 200 | 20 | ✅ Var | **$20/ay** | Sadece **web sitesi**, **PayTR** |

Önemli kural: Business planı App Store'da IAP ürünü olarak **hiç oluşturulmadı**. Uygulama içinde "Business" planına dokunan kullanıcı web sitesine yönlendirilir (bkz. bölüm 6). Bu, Apple'ın "uygulama içi satılan dijital hizmet uygulama içinden satılmalı" kuralına takılmamak için bilinçli bir tercih.

Limitler backend'de `TIER_LIMITS` sabitinde tanımlı; iOS tarafı bu sayıları backend'den (`GET /billing/subscription`) okuyup göstermeli, **asla client'ta hardcode edilmemeli**.

---

## 2. Modelin hızını/kalitesini etkilemeyen tasarım ilkesi

Kota kontrolü her zaman **Groq'a hiçbir istek gitmeden önce**, ucuz bir SQLite okuma/yazma ile yapılır:

- `rova-backend/src/routes/copilot.ts`: `/copilot/chat` isteğinde, işlem gerçekten yeni başlıyorsa (`claimCopilotRequest` başarılıysa) `consumeMessageQuota(userId)` çağrılır. Kota dolmuşsa `converse()` (yani Groq çağrısı) **hiç tetiklenmez**, direkt `QUOTA_EXCEEDED` hatası SSE ile döner.
- Görsel araçları (`generate_image`, `edit_image` — `rova-backend/src/tools/creativeTools.ts`) kendi içinde `consumeImageQuota(userId)` çağırır; kota dolmuşsa Gemini'ye hiç istek gitmez.
- PC/cihaz araçları tamamen ayrı bir mekanizmayla kapatılır (bölüm 4).

Sonuç: Free, Pro, Business kullanıcıları **aynı modeli, aynı hızda** kullanır; fark sadece günlük hak sayısıdır.

---

## 3. Veritabanı şeması (`rova-backend/src/db.ts`)

### `users` tablosuna eklenen kolonlar
- `subscription_tier TEXT NOT NULL DEFAULT 'free'` — `free | pro | business`
- `subscription_source TEXT NOT NULL DEFAULT 'none'` — `none | storekit | paytr`
- `subscription_expires_at TEXT` — ISO 8601, null ise abonelik yok
- `apple_original_transaction_id TEXT` — Apple'ın `originalTransactionId`'si; `idx_users_apple_txn` unique index ile **bir Apple aboneliği yalnızca bir Wiqo hesabına** bağlanabilir (replay/paylaşım engeli)

### Yeni tablolar
```sql
CREATE TABLE usage_daily (
  user_id INTEGER NOT NULL REFERENCES users(id),
  day TEXT NOT NULL,               -- 'YYYY-MM-DD', gün UTC'de kesilir
  message_count INTEGER NOT NULL DEFAULT 0,
  image_count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, day)
);

CREATE TABLE paytr_orders (
  merchant_oid TEXT PRIMARY KEY,   -- 'wiqobiz{userId}{12 hex karakter}'
  user_id INTEGER NOT NULL REFERENCES users(id),
  amount_kurus INTEGER NOT NULL,   -- 2000 TL = 200000 kuruş (örnek, gerçek TL karşılığı PayTR'de ayarlanır)
  status TEXT NOT NULL DEFAULT 'pending',  -- pending | paid | failed
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  resolved_at TEXT
);
```

Hesap silinirken (`deleteUserAccount`) bu iki tablo da temizlenir — kullanıcı verisi hiçbir yerde artık kalmaz.

Kota tüketimi **atomik** bir transaction ile yapılır (`tryConsumeDailyQuota`): aynı anda gelen iki istek asla limiti aşamaz.

---

## 4. PC bağlantısı gating mimarisi

Bu kısım en kırılgan yerdi, dikkatlice tasarlandı çünkü üç farklı bağlantı yolu var:

1. **Doğrudan bağlantı** (iPhone ↔ Mac, aynı ağda NWConnection ile P2P) — backend'i hiç görmez, **backend'den asla engellenemez**.
2. **Backend relay** (`POST /devices/:id/command`) — backend üzerinden geçer, kontrol edilebilir.
3. **AI tool-calling yolu** (`/copilot/chat` üzerinden modelin PC araçlarını çağırması) — backend üzerinden geçer, kontrol edilebilir.

Free planın "PC bağlantısı yok" kuralı şu şekilde uygulanıyor:

- **`rova-backend/src/billing/subscriptions.ts`**: `pcAllowed(userId)` fonksiyonu, kullanıcının etkin planına göre `TIER_LIMITS[tier].pcAllowed` döner.
- **`rova-backend/src/tools/registry.ts`**: `ToolRegistry.forRequest(...)` yeni bir `pcAllowed: boolean = true` parametresi aldı. `false` ise `buildSemanticDeviceTools(...)` hiç çağrılmıyor, cihaz araçları listesi direkt `[]` oluyor — client'ın gönderdiği `availableCapabilities`/`applicationTargets`/`authorities` ne olursa olsun.
  - ⚠️ Bilinçli bir tuzaktan kaçınıldı: `buildDeviceTools` içinde boş `availableCapabilities` dizisi "hiç filtreleme yapma, her şeye izin ver" anlamına geliyor (eski client uyumluluğu için). Bu yüzden PC'yi kapatmak için o diziyi boşaltmak **tam tersi etkiye** yol açardı. Onun yerine yepyeni, açık bir `pcAllowed` parametresi eklendi.
- **`rova-backend/src/groq/client.ts`**: `toolRegistry.forRequest(...)` çağrısına `pcAllowed(userId)` son parametre olarak eklendi.

Sonuç: Free kullanıcının sohbet isteğinde modele PC araçları **hiç sunulmuyor**, yani model onları çağırmayı deneyemiyor bile.

### İstemci tarafı (henüz yapılmadı — bkz. bölüm 8)
Doğrudan bağlantı backend'den görülemediği için, iOS tarafında da:
- Ayarlar ekranındaki cihaz eşleştirme/PC bağlan butonları Free kullanıcıya kapalı/kilitli gösterilmeli.
- Bu sadece UX içindir; sunucu tarafı zaten AI yolunu tamamen kapatıyor. Kullanıcı kendi client'ını değiştirip doğrudan bağlantıyı zorlarsa bile sadece **kendi zaten sahip olduğu** Mac'ini kontrol edebilir — kabul edilen, düşük riskli bir senaryo.

---

## 5. Apple StoreKit 2 entegrasyonu

### 5.1 App Store Connect durumu

Uygulama kaydı bundle kimliğiyle kalıcı bağlıdır ve sonradan değiştirilemez. Eski kayıt (`Wiqo`,
`com.rova.ios`) bu yüzden kullanılmıyor; her şey `com.wiqo.ios` bundle kimliğiyle **yeni bir kayıtta**
kurulur.

| Alan | Değer |
|---|---|
| Bundle ID | `com.wiqo.ios` (Developer hesabında kayıtlı; Push ve In-App Purchase açık) |
| App Apple ID | yeni kaydın Apple Kimliği (sunucuda `APPLE_APP_ID`) |
| Product ID | `com.wiqo.ios.pro.monthly` |
| Abonelik grubu | "Wiqo Abonelikler" |
| Süre / fiyat | 1 ay / $9.99 (ABD + TR) |

Yeni kayıt oluşturulduktan sonra abonelik grubunu ve ürünü kurmak için (`asc` API anahtarıyla
çalışır, Apple web oturumu gerekmez):

```bash
ASC=/opt/homebrew/Cellar/asc/5.3.1/bin/asc
$ASC subscriptions setup \
  --app <YENİ_APPLE_KİMLİĞİ> \
  --group-display-name "Wiqo Abonelikler" \
  --group-locale "tr" \
  --reference-name "Wiqo Pro Aylık" \
  --product-id "com.wiqo.ios.pro.monthly" \
  --subscription-period ONE_MONTH \
  --price "9.99" \
  --price-territory "United States" \
  --territories "US,TR" \
  --available-in-new-territories true \
  --locale "tr" \
  --display-name "Wiqo Pro" \
  --description "Günde 100 mesaj, 10 görsel ve PC bağlantısı." \
  --no-verify \
  --output json --pretty
```

App Store Connect'te bir kez ayarlanacak: **App Bilgileri → App Store Sunucu Bildirimleri**,
hem Production hem Sandbox için URL: `https://api.wiqoai.com/billing/storekit/notifications` (V2).

Ürün review'a, uygulama içi satın alma sandbox hesabıyla uçtan uca denenmeden gönderilmez.

### 5.2 Sunucu tarafı doğrulama (`rova-backend/src/billing/subscriptions.ts`)

- Paket: `@apple/app-store-server-library` (v3.1.0).
- Apple'ın herkese açık **"Apple Root CA - G3"** sertifikası base64 olarak koda gömülü (`APPLE_ROOT_CA_G3_BASE64`) — ayrı bir dosya olarak tutulmadı çünkü `tsc` build'i `src/`'deki `.ts` olmayan dosyaları `dist/`'e kopyalamıyor, gömmek bu adımı tamamen gereksiz kıldı.
- İki doğrulayıcı var: `productionVerifier` ve `sandboxVerifier`. TestFlight build'leri "Production" App Store kaydına sahip bir uygulamada bile Sandbox JWS payload'ı üretebildiği için, önce Production denenir, `INVALID_ENVIRONMENT` hatası alınırsa Sandbox'a düşülür (hem `verifyTransaction` hem `verifyNotification` için).
- `enableOnlineChecks: false` — OCSP ağ bağımlılığı olmadan, basitlik için.
- Ayrı bir "In-App Purchase API key" **gerekmiyor** — bu sadece Apple'ın Server API'sini aktif sorgulamak isteseydik gerekirdi (bu tasarım onu kullanmıyor, sadece imza doğruluyor).

### 5.3 Akış

1. iOS: StoreKit 2 ile satın alma tamamlanır → `Transaction.jwsRepresentation` alınır.
2. iOS: `POST /billing/storekit/verify` ile `{ signedTransaction }` gönderilir.
3. Backend: `applyVerifiedTransaction(userId, signedTransaction)`:
   - imza doğrulanır (Production → Sandbox fallback)
   - `productId === "com.wiqo.ios.pro.monthly"` kontrolü
   - süresi dolmamış mı kontrolü
   - `apple_original_transaction_id` başka bir hesaba bağlı mı kontrolü (`ALREADY_CLAIMED`)
   - `setSubscription(userId, "pro", "storekit", expiresAt, originalTransactionId)`
4. Apple, App Store Server Notifications V2 ile yenileme/iptal/iade olaylarını **webhook** olarak gönderir → `POST /billing/storekit/notifications` (kimlik doğrulaması yok, güven sınırı tamamen JWS imzasında):
   - `DID_RENEW` / `SUBSCRIBED` / `OFFER_REDEEMED` → `handleRenewalNotification` → sadece `subscription_expires_at`'i günceller (hesap zaten adım 3'te bağlanmış olmalı; bağlı değilse no-op)
   - `EXPIRED` / `GRACE_PERIOD_EXPIRED` / `REFUND` / `REVOKE` → `handleTerminationNotification` → `revokeByOriginalTransactionId` ile hesabı Free'ye düşürür
   - Apple 2xx dönmeyen her yanıtı **tekrar dener**, bu yüzden doğrulama hatası da 500 döner (yanlışlıkla olay kaybetmemek için)

### 5.4 ⚠️ Manuel adım — App Store Connect'te elle yapılmalı

**App Store Server Notifications URL'si CLI/API ile ayarlanamıyor.** App Store Connect web arayüzünde:

> App Information → App Store Server Notifications

Hem **Production URL** hem **Sandbox URL** alanına şu adres girilmeli:

```
https://84-247-172-213.sslip.io/billing/storekit/notifications
```

Bu yapılmadan yenileme/iptal olayları backend'e hiç ulaşmaz (sadece ilk satın alma anındaki `/storekit/verify` çağrısı çalışır, sonrası senkron kalmaz).

---

## 6. Business planı — PayTR (sadece web sitesi) — ŞU AN DURAKLATILDI

**Durum (2026-09-15):** Odak şu an çalışan ürünü (Free + Pro) çıkarmak. Business'ın PayTR/website entegrasyonu bilinçli olarak ertelendi — uygulamada Business kartı "Yakında" olarak görünüyor, hiçbir yere yönlendirmiyor (bkz. `RovaIOS/PaywallView.swift`'teki `businessCard`). Aşağıdaki akış ve API sözleşmesi tasarlandı ve backend'de zaten hazır (`/billing/paytr/*` route'ları çalışıyor); sadece web sitesi tarafı ve PayTR kimlik bilgileri eksik.

**PayTR hesabı kararı:** Kullanıcının zaten `witlydesign.com` için aktif bir PayTR mağazası var (Mağaza No: 743366, Bildirim URL şu an `https://payments.witlydesign.com/api/paytr/callback`'e gidiyor — bu, `/opt/witly-payment-gateway` altında `witlypay` kullanıcısıyla pm2'de çalışan, 127.0.0.1:3035'te dinleyen ayrı bir Node servisi). PayTR'de **mağaza başına tek Bildirim URL** olduğu için bu hesabı Wiqo için de kullanmanın seçilen yöntemi:

- Bildirim URL'yi **değiştirmiyoruz** (witlydesign'ın kendi akışı bozulmasın diye).
- `payments.witlydesign.com/api/paytr/callback`'in koduna (o proje `/opt/witly-payment-gateway`, ayrı bir proje — bu oturumda dokunulmadı) küçük bir yönlendirme kuralı eklenecek: gelen `merchant_oid` `"wiqobiz"` ile başlıyorsa isteği aynen Wiqo'nun backend'ine (`https://84-247-172-213.sslip.io/billing/paytr/webhook`) ilet; başlamıyorsa witlydesign kendi işine devam etsin.
- Bu değişiklik henüz yapılmadı — Business'a geri dönüldüğünde ilk adım bu.

Akış (Business açıldığında):

1. Uygulama içinde kullanıcı "Business" planına dokunur → **`https://elyan.dev/business`** adresine yönlendirilir (bkz. `RovaIOS/Billing.swift`'teki `WiqoWebsite.businessCheckoutURL` — tek sabit, ihtiyaç halinde tek satırda değişir).
2. Web sitesi, giriş yapmış Wiqo kullanıcısının oturumuyla `POST /billing/create-order`... → gerçek route adı: **`POST /billing/paytr/create-order`** (auth gerekli, Wiqo session token ile) çağrılır. Backend `merchant_oid` üretir ve `paytr_orders` tablosuna `pending` durumda kaydeder.
3. Web sitesi bu `merchant_oid`'i kullanarak **PayTR'nin kendi API'sinden doğrudan** bir iframe token'ı ister (bu adım backend'i hiç kullanmaz, PayTR'nin standart entegrasyon şekli budur).
4. Kullanıcı ödemeyi PayTR iframe'inde tamamlar.
5. PayTR, merchant panelinde tanımlı **"Bildirim URL"**'ye (webhook) server-to-server bir POST atar → **`POST /billing/paytr/webhook`** (form-urlencoded, kimlik doğrulaması yok — güven sınırı HMAC hash'te).
6. Backend `verifyPaytrHash` ile hash'i doğrular, `applyPaytrNotification(merchant_oid, status)` çağırır:
   - `status === "success"` ise `setSubscription(userId, "business", "paytr", now+31gün)`
   - `resolvePaytrOrder` sadece `pending` durumundaki siparişi günceller → PayTR'nin tekrar tekrar aynı webhook'u göndermesi (retry) asla çift abonelik/çift işlem yaratmaz
7. Backend, PayTR protokolüne göre **düz metin `"OK"`** döner (aksi halde PayTR yeniden dener).

### Gerekli ortam değişkenleri (kullanıcı PayTR panelinden alacak, henüz `.env`'e eklenmedi)
```
PAYTR_MERCHANT_ID=...
PAYTR_MERCHANT_KEY=...
PAYTR_MERCHANT_SALT=...
```
`isPaytrConfigured()` bunlardan biri eksikse `false` döner; `/billing/paytr/create-order` bu durumda `503` döner (sessizce yanlış davranmaz).

### ⚠️ Test edilmedi
`verifyPaytrHash`'teki HMAC-SHA256 formülü (`merchant_oid + merchant_salt + status + total_amount`, base64, `merchant_key` ile imzalanmış) PayTR'nin **genel dokümantasyonundaki** standart formata göre yazıldı ama **gerçek bir PayTR sandbox/merchant hesabıyla hiç test edilmedi** (bu oturumda merchant bilgileri mevcut değildi). Gerçek panel bilgileri eklenince ilk canlı testte bu fonksiyon dikkatle doğrulanmalı.

---

## 7. Backend API özeti (`rova-backend/src/routes/billing.ts`)

| Endpoint | Auth | Açıklama |
|---|---|---|
| `GET /billing/subscription` | Wiqo oturumu | `{ tier, label, source, expiresAt, pcAllowed, usage: { messages: {used,limit}, images: {used,limit} } }` — Ayarlar ekranı bunu kullanmalı |
| `POST /billing/storekit/verify` | Wiqo oturumu | `{ signedTransaction }` → satın alma sonrası anlık doğrulama |
| `POST /billing/storekit/notifications` | Yok (Apple imzası) | Apple'ın webhook'u — bkz. bölüm 5.4 |
| `POST /billing/paytr/create-order` | Wiqo oturumu | Web sitesi çağırır, `{ merchantOid, amountKurus }` döner |
| `POST /billing/paytr/webhook` | Yok (HMAC imzası) | PayTR'nin webhook'u — bkz. bölüm 6 |

Tüm route'lar `rova-backend/src/index.ts`'te `/billing` altında kayıtlı.

---

## 8. Yapılacaklar (henüz TAMAMLANMADI)

### Şimdi öncelikli (Free + Pro'yu çıkarmak için)
- [ ] **App Store Connect'te Server Notifications URL'sinin elle girilmesi** (bkz. bölüm 5.4 — CLI/API ile yapılamıyor).
- [ ] **Pro aboneliğinin App Store review'a gönderilmesi** — iOS satın alma kodu artık hazır (bkz. bölüm 9), sıradaki adım bu (`6812481170`, şu an `READY_TO_SUBMIT`).
- [ ] **Gerçek cihazda/TestFlight'ta uçtan uca satın alma testi** — Sandbox test hesabıyla gerçek bir Pro satın alması denenip backend'in doğru şekilde `pro`'ya geçirdiği doğrulanmalı (bu oturumda sadece derleme doğrulandı, gerçek bir satın alma denemesi yapılmadı).

### Ertelendi (Business — bkz. bölüm 6)
- [ ] `payments.witlydesign.com/api/paytr/callback`'e `wiqobiz` önekli siparişleri Wiqo'ya yönlendiren forward kuralının eklenmesi.
- [ ] `.env`'e PayTR bilgilerinin eklenmesi (`PAYTR_MERCHANT_ID`, `PAYTR_MERCHANT_KEY`, `PAYTR_MERCHANT_SALT` — witlydesign'ın mevcut mağaza 743366 bilgileri, PayTR panelinde Entegrasyon Bilgileri sekmesinden).
- [ ] PayTR webhook hash doğrulamasının gerçek sandbox ile test edilmesi.
- [ ] Web sitesinin (`elyan.dev/business`) PayTR checkout akışıyla inşa edilmesi (bölüm 6'daki API sözleşmesine göre).
- [ ] `RovaIOS/PaywallView.swift`'teki Business kartının "Yakında"dan gerçek "Web sitesinde satın al" butonuna çevrilmesi (yukarıdakiler bitince tek satırlık değişiklik).

## 9. Tamamlanan işler (özet)

### Backend
- ✅ `rova-backend/src/billing/tiers.ts` — plan limitleri tek yerde tanımlı
- ✅ `rova-backend/src/billing/subscriptions.ts` — StoreKit doğrulama, plan uygulama, webhook işleme
- ✅ `rova-backend/src/billing/paytr.ts` — PayTR sipariş oluşturma, hash doğrulama, webhook işleme
- ✅ `rova-backend/src/routes/billing.ts` — tüm endpoint'ler
- ✅ `rova-backend/src/db.ts` — şema migrasyonları, kota/abonelik fonksiyonları
- ✅ `rova-backend/src/routes/copilot.ts` — mesaj kotası, Groq çağrısından önce kontrol ediliyor
- ✅ `rova-backend/src/tools/creativeTools.ts` — görsel üretme/düzenleme araçlarında görsel kotası
- ✅ `rova-backend/src/tools/registry.ts` + `rova-backend/src/groq/client.ts` — PC araçlarının plan bazlı tamamen gizlenmesi
- ✅ App Store Connect'te Pro abonelik grubu/ürünü oluşturuldu (`asc` CLI ile)
- ✅ Backend VPS'e deploy edildi, `npx tsc --noEmit` ve `npm test` (20/20) yeşil

### iOS
- ✅ `RovaIOS/Billing.swift` — `SubscriptionInfo`/`SubscriptionStore` (`/billing/subscription`'ı hesap bazlı önbellekleyen, ProfileStore ile aynı desende bir store) ve `StoreKitManager` (ürün getirme, satın alma, `Transaction.updates` dinleyicisi, `restore()`)
- ✅ `RovaIOS/PaywallView.swift` — Free/Pro/Business karşılaştırma ekranı; Pro'da StoreKit satın alma butonu, Business'ta `elyan.dev/business`'a yönlendiren buton, "Satın alımları geri yükle"
- ✅ `RovaIOS/RovaBackendClient.swift` — `fetchSubscription()`, `verifyStoreKitTransaction(_:)` (`POST /billing/storekit/verify`)
- ✅ `RovaIOS/IOSViews.swift` (`SettingsView`) — plan/kullanım kartı (Ayarlar'ın en üstünde), plan `pcAllowed` ise mevcut PC kartları, değilse tek bir "Yükselt" kartı gösteriliyor (backend zaten AI yolunu tamamen kapatıyor, bu sadece kullanıcıya doğru arayüzü göstermek için)
- ✅ `RovaIOS/ProfileViews.swift` — hesap silinirken abonelik önbelleği de temizleniyor (`SubscriptionStore.clearCacheForCurrentUser()`)
- ✅ `Rova.xcodeproj/project.pbxproj` — iki yeni dosya projeye eklendi
- ✅ Hem `RovaIOS` hem `RovaMac` şeması `xcodebuild` ile temiz derleniyor (simülatör açılmadan, sadece derleme doğrulaması)

**Not:** In-App Purchase için Xcode'da ayrı bir "capability" eklemeye gerek yoktu — StoreKit 2 satın alımları, Push Notifications'ın aksine, entitlements dosyasında bir anahtar gerektirmiyor; App Store Connect'teki ürün/abonelik kaydı zaten yeterli.
