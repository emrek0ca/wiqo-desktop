# Wiqo Android (React Native)

This is the Android-only React Native client migration. It keeps the Play Console application ID `wiqo.android.com` and targets Android 9 (API 28) or newer. Google Play currently requires new submissions and updates to target API 36 or newer; this project uses Expo SDK 57's API 36 toolchain.

## Current migration stage

The first stage implements the iOS-matched sign-in, registration, consent/legal links, and 6-digit password reset flow. Existing Kotlin/Compose Android sources remain in `../RovaAndroid` while the remaining screens and device integrations are ported and verified; they are not used by this Expo app. Do not publish this stage as a feature-complete replacement yet.

## Run on Android

```sh
npm install
npx expo start --android
```

For a standalone native development build, generate Android files with Expo prebuild and run the Gradle build. Do not hand-edit generated `android/` files; configure native behavior through `app.json` and config plugins.

## Verify

```sh
npm run typecheck
npm run lint
npx expo-doctor
```

## Auth contract

- API base: `https://api.wiqoai.com`
- Auth routes: `POST /auth/login`, `/auth/register`, `/auth/forgot-password`, `/auth/reset-password`
- Account tokens are stored with Android Keystore-backed Expo SecureStore.
- Legal URLs match iOS: `https://wiqoai.com/privacy` and `https://wiqoai.com/terms`.

Backend, iOS, and desktop repositories are read-only references during this migration.

## Chat mascots and voice session

- The four chat agent mascot PNGs are the original iOS asset exports; React Native animates them with native-driver transforms while work is active.
- `expo-speech-recognition` provides Android speech input and input-level updates for the orb. `expo-speech` provides system text-to-speech for replies, controlled by the existing speak-replies preference. Recognized text uses the existing chat endpoint; no voice-specific backend endpoint is introduced.
- The voice orb is drawn with the already-installed `expo-linear-gradient` and native animated views, so it has no WebView or GPU runtime dependency.
