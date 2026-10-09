# Wiqo iPhone design system (what to reuse)

One look across screens. Reach for these before writing a new style.

- **Background:** `RovaDesign.canvas` on every screen (Settings, sheets, paywall, Act). No per-screen grey.
- **Spacing and shape:** `RovaDesign.screenPadding` (16), `cardSpacing` (12), `WiqoTheme.cardRadius`.
- **Grouped lists (Settings-style pages):** `WiqoSettingsGroup(title:)` holding `WiqoRow` rows; destructive or toggling controls sit on the trailing edge. Cards are Liquid Glass (`wiqoGlass`) on iOS 26, a quiet grouped fill before.
- **Content cards inside chat:** `wiqoCard` (fill, hairline, soft lift) — chat only.
- **Buttons:** `WiqoActionButton` for the main action of a screen, `wiqoPill(.accent/.secondary)` in card footers; destructive actions ask with `wiqoConfirmation`.
- **Feedback:** `WiqoToastCenter` for a finished action, an inline banner for an error that stays.
- **Empty states:** a short title, one sentence, no buttons unless there is a single obvious next step.
- **Pages, not sub-pages:** a screen shows what the person acts on; details open in a sheet, never a deeper push (see Görevler).
- **Strings:** write Turkish in code; `Text`/`Button`/`Label` literals localize themselves, a `String` needs `String(localized:)` — never for wire values (see `contracts/i18n/README.md`, `guard.mjs`).
