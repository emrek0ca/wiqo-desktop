# Companion sözleşmesi (Mac ↔ Windows)

Mac (`RovaShared`, Swift) ve Windows (`RovaWindows`, C#) aynı sözleşmeye uyar. Bir taraf ayrışırsa kontrol kırmızı yanar.

| Dosya | Ne |
|---|---|
| `operations.json` | Hangi operasyon hangi platformda: `RovaShared/OperationManifest.swift`'ten dışa aktarılır, elle düzenlenmez. |
| `vectors.json` | Kanonik JSON (RFC 8785), terminal grant imzası ve komut imzası v2 örnekleri. `generate-vectors.mjs` üretir. Referans JavaScript'tir, çünkü RFC 8785 sayı ve dizgi biçimini ECMAScript ile tanımlar. |
| `swift/main.swift` | RovaShared'ı vektörlere karşı doğrular ve `operations.json`'un güncel olduğunu kontrol eder. |
| `RovaWindows/Tests` | Aynı vektörler ve parite: Windows manifestosu tam olarak `operations.json`'daki Windows listesi olmalı. |
| `parity-report.mjs` | Henüz yalnız Mac'te olan operasyonları listeler. |

Hepsini tek komutla çalıştır:

```bash
contracts/companion/check.sh
```

Manifesto ya da vektör değişince dosyaları yeniden üret:

```bash
contracts/companion/check.sh --write
```

Windows'a yeni bir operasyon eklemek üç adımdır:

1. `RovaWindows`'ta operasyonu uygula.
2. `WindowsCapabilityManifest.cs`'e ekle.
3. `OperationManifest.swift`'teki `windowsSupported` listesine ekle, sonra `check.sh --write` çalıştır.

Bu üç adımdan biri eksik kalırsa kontrol kırmızı yanar.
