# Interface languages

The app's interface strings live in `RovaIOS/Localizable.xcstrings` (source language: Turkish; the Turkish text is the key) and the permission
prompts in `RovaIOS/InfoPlist.xcstrings`. Languages: en, de, es, fr, ar, ru, tr. Other device languages fall back to English; replies, cards and
notifications written by the backend follow the phone's language whatever it is (the app sends `locale` with every chat request).

- `translations.json` — `{ language: { key: translation } }`, the source of truth; `keys.json` — every key the app uses.
- `node contracts/i18n/build.mjs` rebuilds `Localizable.xcstrings` from them.
- `info-plist.json` — the permission texts and their translations (InfoPlist.xcstrings is generated from it the same way).

Adding or changing a screen text:
1. Write it in Turkish in the code. `Text("…")`, `Button("…")`, `Label("…")` and friends localize themselves; for a `String` use `String(localized: "…")`
   (never for wire values, enum raw values, comparisons or App Shortcut phrases).
2. Build with `SWIFT_EMIT_LOC_STRINGS=YES`, then `node contracts/i18n/extract.mjs <…/RovaIOS.build>` adds the new keys to `keys.json`.
3. In the backend repo: `npm run i18n:catalog -- <keys.json> <translations.json>` translates what is missing (it checks the format specifiers), then run `build.mjs`.

`guard.mjs` (CI) also fails on a Turkish sentence in `RovaIOS/*.swift` that is not a catalog key; text that must stay as written (wire text the backend matches, regexes, comparisons) is listed in `verbatim.json`.
4. `node contracts/i18n/guard.mjs` (CI) fails on a Turkish sentence in `RovaIOS/*.swift` that is not a catalog key; text that must stay as written (wire text the backend matches, regexes, comparisons) is listed in `verbatim.json`.
