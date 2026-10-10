# Changelog (iPhone and Mac apps)

## 2026-10-10

- **Every displayed sentence is translated.** ~120 Turkish status and error texts that were returned as plain strings (plan and task states, automation timelines, Act errors, file and connection messages) now go through the catalog: 1,408 strings in 6 languages. `contracts/i18n/guard.mjs` fails CI on a Turkish sentence outside the catalog (`verbatim.json` lists the ones that must stay as written); `extract.mjs` adds a build's new keys.
- **Act has a side dock** on the right edge (projects: new, search, import, privacy; a project: preview, code, history, device / full screen / reload, project menu); the bars above and below the content are gone. The writer notice is asked once per kind of project, not with every request. The approval sheet is small (what will happen, İptal / Onayla, longer-lasting choices behind one menu) and the keyboard closes when it opens. The Chat/Act switch has no icons.
- **Voice commands in Act:** the microphone is a command, not dictation. A glossy listening orb in the accent colour (breathes with the voice, soft shadow and glow) replaces the composer; the sentence is applied the moment the person stops speaking (tap the orb to send now, × to cancel). The Chat/Act switch is Liquid Glass on iOS 26.
- **Act progress is one line:** while the writer works, a single strip above the composer shows the step (Yazılıyor / Telefonda deneniyor / Kaydediliyor, 1/3), three short segments and Durdur; tapping it opens the writer's message. The card that covered the preview is gone; the last-change line is one calm line with Geri al.
- **Chat / Act switch:** slimmer two-way switch with one soft thumb and icons; swipe left/right in the top or bottom band to change side; tapping the current side focuses the composer (Chat) or returns to the project list (Act); a working mark on Act while a job runs and a dot on Chat when a reply finished meanwhile; the app opens on the side it was left on; the sides slide slightly as they cross-fade.
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
