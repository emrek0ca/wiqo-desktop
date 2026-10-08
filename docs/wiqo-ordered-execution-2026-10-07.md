# Wiqo — genel görev anlama ve güvenilir yürütme

Bu değişiklikler yereldir; bu düzeltme turunda commit, push veya deploy yapılmadı. Windows ve Act kapsam dışıdır. Önceden var olan çalışma ve wiqo-story değişiklikleri korundu.

## Düzeltilen ortak akış

- Görev kimliği iOS → backend → devam/sonuç → onay boyunca taşınır. Gecikmiş veya kimliksiz sonuç yeni görevi sürdüremez; eski onay yan etki çalıştıramaz. Aynı metindeki iki istek de ayrılır.
- Yerel devam sonuçları aynı assistant mesajını günceller. Sentetik “Yerel PC sonuçları hazır” turları geçmişe tekrar eklenmez; dosya ve widget kartları korunur.
- PC ajanının planlayıcısı gerçek araç açıklamalarını ve işlemlerini görür. Kullanıcı kararı eksikse soru sorar; araçla öğrenilebilecek bilgi için keşif planlayabilir. Komuta özel ifade eşleştirme eklenmedi.
- Yürütücü yalnız sıradaki adımın aracını ve plan kontrol araçlarını görür. Hata/belirsiz yan etki bağımlı adımları durdurur. Başarılı işlemin aynısı tekrar yürütülmez; değişiklik sonrası doğrulama okumaları yeniden yapılabilir.
- Plan bitince gerçek sonuçlar hedefle karşılaştırılır. Eksik kalan iş için en fazla bir plan onarım turu vardır; doğrulanamayan sonuç başarı sayılmaz.
- Sağlayıcının reddettiği araç çağrıları mevcut ortak şema doğrulamalı kurtarmadan geçer. Düzelmezse yalnız bir ek model çağrısı yapılır; tamamlanan işlemler yeniden başlatılmaz.
- PC ajanının dosya kartları son yanıta taşınır. Mac gönderimde dosya türünü, boyutunu ve sunucunun döndürdüğü SHA-256/byteCount değerlerini kontrol eder.
- Onay açılırken klavye kapatılır. Kullanıcı isterse yalnız o görev boyunca hassas olmayan dosya okumalarına izin verir; yazma/silme/gönderim izni bu seçeneğe dahil değildir.

## Dosyalar

Uygulama: RovaIOS/CopilotView.swift, CopilotExecutionViews.swift, RovaBackendClient.swift, DeviceOutcomeNarrator.swift; RovaMac/MacSystem+Files.swift, MacCommandEngine.swift, MacSystem+Applications.swift; RovaShared/Protocol.swift.

Backend: src/agent/pcAgent.ts; src/db/conversations.ts; src/routes/copilot.ts; src/groq/client.ts, prompts.ts, taskLedger.ts, completionCheck.ts, salvage.ts, intents.ts, replies.ts; src/tools/semanticDeviceTools.ts, deviceTools.ts, deviceRecovery.ts; src/scripts/eval-pc-agent.ts, pc-task-sim.ts. İlgili regresyon dosyaları: agent/pcAgent.test.ts, db/conversations.test.ts, groq/client.test.ts, taskLedger.test.ts, completionCheck.test.ts.

## Doğrulama ve sınırlar

- iOS Wiqo ve Mac RovaMac: imzasız Debug xcodebuild başarılı. Gerçek cihazda kurulum/çalıştırma yapılmadı.
- Backend TypeScript derlemesi başarılı. Tam regresyon koşusunda 466/466 geçti; son küçük değişikliklerde odaklı kontroller ayrıca çalıştırıldı.
- Gerçek model + simüle Mac: tam yolla aktarım, dosyayı tarif edip telefona getirme, başka ifadeyle sohbete dosya ekleme son odaklı denemelerinde çalıştı. Belirsiz sunum isteği sıfır Mac işlemiyle soru sordu.
- Ara koşularda gereksiz sorular, yanlış araç argümanları ve sağlayıcı tool_use_failed hataları görüldü. Küçük senaryo seti genel başarı oranını veya her karmaşık görevin çalışacağını kanıtlamaz. Değerlendirici artık API hatasını açıklama sorusu olarak başarılı saymaz; dosya teslim edilip görev sonucu doğrulanamazsa da başarısız sayar.
- PC ajanında anlama/yürütme için varsayılan deep_reasoning kullanılıyor; planlamaya daha fazla düşünme payı verildi. Diğer sohbet yollarının modeli değiştirilmedi. Gerçek iş başına maliyet için kontrollü önce/sonra ölçümü yapılmadı; maliyet düşüşü iddiası yok.
- Bu sürümün backend ve iOS birlikte güncellenmesi gerekir. Eski istemcinin kimliksiz devam isteği güvenli biçimde durur. Yeniden başlatma/TTL sonrası kaybolan görev bağlamı otomatik yeniden yürütülmez.
- Başarılı süreç çıkışı tek başına tüm hedefin kanıtı değildir; eski araçların kanıt kapsamı ve gerçek cihaz davranışı ayrıca doğrulanmalıdır.

## Emre'nin deneyeceği beş senaryo

1. Bir dosyayı özellikleriyle tarif ederek telefona getir; dosya kartı açılsın, yalnız bir sonuç mesajı olsun.
2. İlk işten sonra farklı bir iş ver; eski işin adımı veya onayı yeni işe taşınmasın.
3. Belirsiz bir düzenleme iste; dosya değişmeden önce neyin değişeceğini sorsun.
4. Görev boyunca okuma izni ver; sonraki okumalarda tekrar sormasın. Yazma/ret ekranında klavye kapansın ve ret bağımlı işi durdursun.
5. Dosyayı oku, düzenle, tekrar doğrula ve telefona gönder; kaydetme ile teslim sonucu ayrı kanıtlarla doğru gösterilsin.
