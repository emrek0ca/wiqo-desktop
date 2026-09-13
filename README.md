# Rova V0

Rova is a native, local-only iPhone-to-Mac command bridge. It has no cloud, account, database, AI, LLM, analytics, or arbitrary shell execution.

## Targets

- `RovaMac`: macOS 14+ menu bar app, TLS listener on TCP `47831`, Bonjour service `_rova._tcp`.
- `RovaIOS`: iOS 17+ SwiftUI client with QR pairing, certificate pinning and reconnect.
- `RovaShared`: Codable wire protocol, validation, framing, Keychain and QR helpers.

## Run

1. Open `Rova.xcodeproj` in Xcode 26 or newer.
2. Select an Apple Development Team for both app targets under Signing & Capabilities.
3. Run the `RovaMac` scheme on the Mac. Rova appears in the menu bar and starts the listener asynchronously.
4. Run the `RovaIOS` scheme on a physical iPhone (iOS 17+). The iPhone and Mac must be on the same local network.

## Pair

1. Open the Rova menu bar item and choose **Show Pairing QR**.
2. In the iPhone app choose **Scan Pairing QR** and allow camera/local-network access.
3. The QR contains the Mac endpoint, pinned TLS certificate fingerprint, six-digit code and five-minute expiry. Pairing writes the token and fingerprint only to Keychain.
4. After pairing, the iPhone reconnects with the token. Use **Retry** after a temporary network interruption.

The Mac accepts only paired tokens and the fixed capabilities: system status, allow-listed application launch, `http`/`https` URL opening, lock and ping. The command ledger is persisted under Application Support and keeps the last 128 command IDs.

## macOS permissions

`lockMac` uses a fixed System Events AppleScript shortcut. macOS may ask for Automation/Accessibility permission; if denied, the command returns a safe error and does not execute an alternative command.

The Debug build is intentionally unsigned (`CODE_SIGNING_ALLOWED=NO` in local verification). A physical iPhone install requires the normal Apple Development signing/profile configured in Xcode.
