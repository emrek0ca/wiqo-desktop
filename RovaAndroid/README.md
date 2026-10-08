# Wiqo Android

Android istemcisi `com.wiqo.android` kimliğiyle ayrı Gradle projesidir. iOS’taki backend sözleşmesini korur; PC üzerindeki işlemler eşlenmiş macOS/Windows eşlikçi uygulamasında yürütülür.

## Kaynak eşlemesi

| iOS kaynağı | Android karşılığı |
| --- | --- |
| `RovaIOS/RovaBackendClient.swift` | `app/.../data/network/WiqoApi.kt` |
| `RovaShared/Protocol.swift`, `Validation.swift`, `Framing.swift`, `QRPairing.swift` | QR pairing transport in `app/.../data/network/WiqoApi.kt`; full cross-platform byte-contract coverage is still pending |
| `RovaIOS/DesignSystem.swift`, `WiqoTheme.swift` | `app/.../ui/theme/` |
| `RovaIOS/AuthView.swift`, `OnboardingView.swift` | `app/.../ui/AuthScreen.kt`, `PairingScreen` |
| `RovaIOS/CopilotView.swift`, `CopilotConversationStore.swift` | `app/.../ui/ChatScreen.kt`, `ChatViewModel.kt`, Room and remote history |
| `RovaIOS/IOSViews.swift` | Compose navigation, PC, activity, history, and settings destinations |
| `RovaIOS/ProfileViews.swift`, `ConnectedAccountsView.swift` | account and connected-account destinations |
| `RovaIOS/AutomationDetailView.swift`, `AutomationTemplatesView.swift` | automation destinations |
| `RovaIOS/WiqoWorkHub.swift` | `ui/WorkHubScreen.kt` aggregates work, automation review, agents and autonomy controls |
| `RovaIOS/ActView.swift`, `ActModel.swift`, `ActProjectStore.swift` | `ui/ActScreen.kt`, `data/act/` for device projects, writer jobs, preview, encrypted sync and export |
| `RovaIOS/WiqoInlineApp.swift`, `WiqoCards.swift` | `ui/widgets/WiqoWidgetCard.kt`, bundled `assets/inline/` helpers |
| `RovaIOS/RovaIOSApp.swift` local reminders | `data/automation/LocalReminderCoordinator.kt` and Android alarms |
| `RovaIOS/PaywallView.swift`, `Billing.swift` | `data/billing/PlayBillingRepository.kt`, `SubscriptionScreen.kt`, backend verification route |
| APNs registration in `RovaIOS/RovaBackendClient.swift` | FCM registration/revoke routes |

## Android platform support

- `minSdk = 33`, `compileSdk = 37`, `targetSdk = 37` (Android 13–17).
- Compose UI, Navigation 3, lifecycle ViewModels, StateFlow and coroutines.
- Room keeps conversation data scoped by account ID. Preferences use DataStore. Session and pairing credentials are AES-GCM encrypted with a non-exportable Android Keystore key.
- Inter and JetBrains Mono are bundled under their upstream OFL licenses.
- OkHttp is the single HTTP/SSE transport. It is used behind `WiqoApi`; UI code does not perform direct network calls.
- ML Kit Document Scanner delegates capture and PDF creation to Google Play services; Android's system speech recognizer supplies voice input. The QR scanner uses Google Code Scanner so the app does not need camera access just to scan pairing codes.
- Chat accepts at most four image attachments (18 MB total encoded) and five documents. Documents are parsed on the phone using Android PDF rendering and ZIP/XML readers; bundled ML Kit Text Recognition v2 reads scanned pages and images without waiting for a model download. The existing document picker grants read access only to the selected files. Only extracted text (up to the backend's 6 MB request limit) is sent; raw document bytes are never sent or written to Room. OCR may be less accurate than a native PDF text layer for selectable PDFs.
- Play purchase state stays free until `/billing/google-play/verify` validates the purchase with Google. Pending purchases stay pending; restore uses the Play-owned purchase list and repeats backend verification.
- FCM registration refreshes on sign-in/token rotation and is revoked on sign-out. Notification bodies stay generic; notification IDs route to the matching Wiqo area.
- Notification-only automations are reconciled from `/automations/local-notifications`. Android installs exact local alarms and calls `/automations/local-delivery` only when notification and exact-alarm permissions allow scheduling. Alarms are restored after reboot, time changes, and app updates. If permissions are missing, backend delivery remains responsible.
- Inline apps load the backend HTML into a networkless, fileless WebView. The same bundled core/chart/confetti/template helpers used by iOS are shipped as Android assets; per-card state is scoped to the signed-in account.

## Build

Install Android SDK Platform 37 and Build Tools 37, then run:

```sh
./gradlew :app:assembleDebug
./gradlew :app:testDebugUnitTest
./gradlew :app:connectedDebugAndroidTest
```

The app uses the production API origin `https://api.wiqoai.com` to match iOS. Android Studio or a local emulator is needed for screenshot and device-flow verification.

## External service setup

FCM delivery and Google Play purchase verification remain unavailable until Firebase, Play Console, and backend service accounts are configured. For local FCM builds, place the Firebase-generated `google-services.json` at `app/google-services.json`; the Google Services Gradle plugin is applied only when this file exists. Do not commit this file, service-account JSON, or signing keys.

The backend deployment needs `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` for Android Publisher purchase lookup/acknowledgement, `GOOGLE_PLAY_RTDN_AUDIENCE` and `GOOGLE_PLAY_PUBSUB_SERVICE_ACCOUNT_EMAIL` for Pub/Sub OIDC verification, and `FCM_PROJECT_ID` for FCM. It can use the Play service account for FCM when it has access to the Firebase project, or a separate `FCM_SERVICE_ACCOUNT_JSON`. Setup details are in `../../rova-backend/docs/android-store-and-push-setup.md`.

The Play Console product ID is `wiqo_pro_monthly`. Live store and push verification requires a Play internal-testing release and the external service setup above.
