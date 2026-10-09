# Changelog (iPhone and Mac apps)

## 2026-10-08 / 09

- **Languages:** the interface in English, German, Spanish, French, Arabic, Russian and Turkish (String Catalog, permission prompts included); replies follow the phone's language.
- **Abonelik** page in Settings (plan, renewal, usage incl. Act, plan cards with purchase, restore, manage); plans from the backend's real limits; the plans offered once on first launch; the paywall opens when the day's messages run out.
- **Görevler** is one page (running tasks with Durdur, to-dos, scheduled automations, review, agents, one switch for working on its own); Hedefler and Etkinlik simplified; Hafıza leaves Settings.
- **Deleting the app signs the account out** (the Keychain survives an uninstall; items older than the installation are removed at launch).
- **Mac:** files/system utility capabilities declared in the capability settings.
- **Fixes:** wire strings (HTTP headers, the continuation message) are never localized — `contracts/i18n/guard.mjs` in CI.
- **Housekeeping:** RovaBackendClient and IOSViews split by domain/screen; CI for the Apple apps (`.github/workflows/apple.yml`); API samples decoded in tests.
