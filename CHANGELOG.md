# Changelog (iPhone and Mac apps)

## 2026-10-10

- **Every displayed sentence is translated.** ~120 Turkish status and error texts that were returned as plain strings (plan and task states, automation timelines, Act errors, file and connection messages) now go through the catalog: 1,408 strings in 6 languages. `contracts/i18n/guard.mjs` fails CI on a Turkish sentence outside the catalog (`verbatim.json` lists the ones that must stay as written); `extract.mjs` adds a build's new keys.
- **Uygulama görünümü** (Ayarlar): theme (system / light / dark), accent colour (6) and text size (small / standard / large). One modifier at the app root (`WiqoAppearanceModifier`), so Chat, Act, the sidebar and every sheet follow; `RovaDesign.ink` is now the app tint.
- **Chat is calmer:** one flat card surface, finished turns hide the plan, task row and duplicate file list under the reply, plan card is one line until opened, copy on long press, empty-chat line and a "do it again" chip for the last PC task, entry motion and a completion haptic.

## 2026-10-08 / 09

- **Languages:** the interface in English, German, Spanish, French, Arabic, Russian and Turkish (String Catalog, permission prompts included); replies follow the phone's language.
- **Abonelik** page in Settings (plan, renewal, usage incl. Act, plan cards with purchase, restore, manage); plans from the backend's real limits; the plans offered once on first launch; the paywall opens when the day's messages run out.
- **Görevler** is one page (running tasks with Durdur, to-dos, scheduled automations, review, agents, one switch for working on its own); Hedefler and Etkinlik simplified; Hafıza leaves Settings.
- **Deleting the app signs the account out** (the Keychain survives an uninstall; items older than the installation are removed at launch).
- **Mac:** files/system utility capabilities declared in the capability settings.
- **Fixes:** wire strings (HTTP headers, the continuation message) are never localized — `contracts/i18n/guard.mjs` in CI.
- **Housekeeping:** RovaBackendClient and IOSViews split by domain/screen; CI for the Apple apps (`.github/workflows/apple.yml`); API samples decoded in tests.
