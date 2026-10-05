# Wiqo Act — 25 saniye

Türkçe, sessiz, beyaz fonda maskot ve tipografi filmi.
1080 × 1920, 30 FPS, tam 750 kare. Composition: `WiqoAct25`.

```sh
npm run studio
npm run lint
npm run render:act
```

Çıktı: `out/wiqo-act-25-tr.mp4` (H.264, CRF 16, yuv420p).
Render concurrency değeri 4; makineye göre scriptte değiştirilebilir.

Tüm sahne süreleri, metinler, PNG yolları ve maskot pozları `config.ts` içinde.
Logo her karede alt ortada sabittir. Orijinal PNG dosyaları değiştirilmez.
Maskotların hareketi tek bir sürekli zaman çizelgesinden hesaplanır; yeni yazı
geldiğinde giriş animasyonları yeniden başlamaz. Son saniye hareketsizdir.

CHAT → ACT: H kaybolur; C ve A kontrollü, karşıt kavislerle yer değiştirir.
T, yeni kelimenin sağ konumuna kayar. Mevcut imleç PNG'leri H harfinin
kaybolmasına eşlik eder. Ses bileşeni veya ses dosyası kullanılmaz.

Bu sürüm ürün anlatımıdır. Gerçek uygulama ekran kaydı sağlanmadığından
telefon/Mac arayüzü taklit edilmez ve demo kaydı varmış gibi gösterilmez.
İstek örneği, arayüzsüz bir metin olarak sunulur.
