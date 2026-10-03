# Wiqo 60 saniyelik tanıtım filmi

Bu Remotion 4 bileşimi mevcut `wiqo-story` projesine eklenmiştir. Eski `WiqoComputerUseLaunch` bileşeninin kaynak klasörü korunmuştur. Ana film 1080×1920, 30 FPS ve 1800 karedir. Kare, yatay, 15 saniyelik ve 6 saniyelik çıktılar aynı sahne bileşenlerinden üretilir.

## Önizleme ve render

```sh
npx remotion studio src/index.ts
npx remotion render src/index.ts WiqoLaunch60 out/wiqo-launch-60.mp4 --codec=h264 --crf=16 --pixel-format=yuv420p
npm run render:all
```

`npm run render:all`, dikey 60 saniye, kare 60 saniye, yatay 60 saniye, 15 saniyelik kısa kurgu ve 6 saniyelik bumper videolarını `out/` altına render eder. 15 saniyelik versiyon kanca, marka vaadi ve PDF iş akışından; bumper ise kanca ve marka vaadinden kesilir. Render concurrency ayarı komutlarda `4` olarak belirlenmiştir; bellek baskısı yaşanırsa komutlardaki `--concurrency=4` değerini `2` veya `1` yapın.

`WiqoLaunch60` şu props değerlerini alır:

- `hookVariant`: `0`–`4` arasındaki ilk üç saniye kancası
- `aspect`: `portrait`, `square` veya `landscape`
- `showCaptions`: kare zamanlı altyazıları gösterir veya gizler
- `musicVolume`: varsa müziğin temel ses düzeyi

Örnek alternatif kanca:

```sh
npx remotion render src/index.ts WiqoLaunch60 out/wiqo-hook-b.mp4 --props='{"hookVariant":1}' --codec=h264 --crf=16 --pixel-format=yuv420p
```

Fontlar `@remotion/google-fonts` üzerinden yüklenir; render, Inter ve Manrope yükleme denemesi tamamlanana kadar bekler. Başlıkta Manrope 700/800, gövdede Inter 500 kullanılır. Google Fonts erişilemezse CSS sans-serif yedeği devreye girer.

## Sizden beklenen kayıt ve ses dosyaları

Kayıtlar gerçek uygulama görüntüsü olarak doğrudan cihaz çerçevelerinde oynatılır. Dosya eksikse ilgili slotta dosya adını içeren `FOOTAGE:` yer tutucusu görünür; yerine çizilmiş bir uygulama arayüzü üretilmez. Kayıtları şu yollarla ekleyin:

```text
public/footage/phone-cv-to-pdf.mp4
public/footage/mac-working.mp4
public/footage/phone-screenshot.mp4
public/footage/phone-approval.mp4
```

Kırpma kareleri, oynatma hızı ve odak noktaları `config.ts` içindeki `FOOTAGE` bölümündedir. Mac çalışma kaydı 3× hızda oynar. Telefon ve Mac kayıtlarının sesleri kapalıdır; film müziği ve SFX ayrı katmanlardır.

Ses dosyaları isteğe bağlıdır. Bulunmadıklarında video sessizce render edilir:

```text
public/audio/music.mp3
public/audio/sfx/click.mp3
public/audio/sfx/whoosh.mp3
public/audio/sfx/tick.mp3
public/audio/sfx/notification.mp3
```

Altyazı aralığında ve geçiş/SFX çevresinde müzik yaklaşık 6 dB kısılır. App Store rozeti isteğe bağlıdır; `public/brand/appstore-badge.svg` eklenmezse kapanışta metin CTA kullanılır.

## Bilinen eksikler

- Dört gerçek ekran kaydı henüz `public/footage/` altında yok; yer tutucular görünür.
- `music.mp3` ve dört SFX dosyası yok; animasyonlar sessiz çalışır.
- App Store rozet dosyası yok; metin CTA kullanılır.
- İlk kanca varyantı varsayılan seçilidir. Diğer dört seçenek render props ile değiştirilebilir.

Resmî `w_logo.png`, mavi/yeşil/turuncu/mor maskotlar ve imleç PNG'leri mevcut `public/` dosyalarından aynen kullanılır; yeniden çizilmez ve esnetilmez.
