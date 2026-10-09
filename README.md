# Wiqo

Wiqo is an AI assistant for iPhone and Mac: chat, documents and cloud tools from the phone, and control of the paired PC when the Mac app is running. The backend lives in a separate repository (`rova-backend`, served at `https://api.wiqoai.com`).

## Targets

- `RovaMac`: macOS 14+ menu bar app (product name Wiqo). Listens on TCP `47831` over TLS, advertises the Bonjour service `_rova._tcp`, and keeps a socket to the backend so the phone can reach it from anywhere.
- `RovaIOS`: iOS 17+ SwiftUI app (`com.wiqo.ios`).
- `RovaShared`: wire protocol, validation, framing, Keychain and QR helpers used by both.
- `RovaMacTests`, `RovaSharedTests`: unit tests.

The targets keep their original `Rova*` names. Renaming them would also rename persisted keychain items and preferences, which would unpair every installed Mac.

## Run

1. Open `Rova.xcodeproj` in Xcode and pick a Development Team for both app targets.
2. Run the `RovaMac` scheme. Wiqo appears in the menu bar; the menu shows what start-up is doing and offers **Yeniden dene** and **Sertifikayı yenile** if it fails.
3. Run the `RovaIOS` scheme on a physical iPhone.

For a terminal launch of the Mac app, use `bash scripts/run-mac.sh`. This builds
into `build/DerivedData-Mac`, separate from Xcode's default DerivedData, so an
iOS build in Xcode cannot lock the Mac build database. The script also refuses a
second simultaneous Mac build using that directory.

Xcode runs of the Mac app keep their own keychain items and paired-device records (`MacStorage`), so they never touch the installed app's.

## Pair

1. Menu bar → **Telefonu bağla**.
2. In the iPhone app scan the code. It is an internet code (valid 10 minutes, renewed automatically). When the backend cannot be reached the window shows a same-Wi-Fi code instead.
3. The window turns to **Telefon bağlandı** once the phone has claimed it.

## Docs

- `docs/abonelik.md`: subscription and quota design.
- `docs/app-store-gonderim.md`: App Store submission guide.
