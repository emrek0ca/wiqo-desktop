# Wiqo Act — 30-second English film

Silent vertical product film, 1080 × 1920, 30 FPS, 900 frames. Composition: `WiqoAct30`.

```sh
npm run studio
npm run lint
npm run render:act:30
```

The render is written to `out/wiqo-act-30-en.mp4`. The three supplied product screenshots are copied unchanged into `public/wiqo-act/screenshots/`; the composition crops the black margins in-frame and animates a focus zoom over each real screenshot. The UI visible inside the screenshots remains as supplied. The original Wiqo logo and four mascot PNGs are used directly from `public/`.

The scene timing, English copy, layout, assets, focus points, and motion values are centralized in `config.ts`. The logo stays at the bottom center throughout. Text and mascot movement use deterministic Remotion frame calculations; no audio or network assets are used.
