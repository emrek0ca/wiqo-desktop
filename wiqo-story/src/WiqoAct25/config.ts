export const VIDEO = { width: 1080, height: 1920, fps: 30, frames: 750 } as const;
export const STYLE = {
  background: '#FFFFFF', ink: '#1F1F1F', secondary: '#6D6D6D',
  font: 'Roboto, Arial, sans-serif', side: 96,
  headline: 108, body: 44, lineHeight: 1.08, tracking: '-0.04em',
  logoSize: 220, logoX: 540, logoY: 1645,
} as const;

export const ASSETS = {
  logo: 'w_logo.png', cursorOpen: 'wiqo-cursor-open.png', cursorClosed: 'wiqo-cursor-closed.png',
  blue: 'wiqo_blue.png', orange: 'wiqo_orange.png', green: 'wiqo_green.png', purple: 'wiqo_purple.png',
} as const;
export type MascotName = 'blue' | 'orange' | 'green' | 'purple';
export const MASCOT_ORDER: readonly MascotName[] = ['blue', 'orange', 'green', 'purple'];

export const SCENES = {
  hook: { from: 0, to: 75 }, request: { from: 75, to: 195 },
  act: { from: 195, to: 285 }, coding: { from: 285, to: 450 },
  preview: { from: 450, to: 600 }, end: { from: 600, to: 750 },
} as const;

export const COPY = {
  hook: ['Kod için', 'masaya dönme.'], request: ['Telefondan', 'iste.'],
  task: ['“Ana ekrana', 'arama ekle.”'],
  act: 'Sohbetten eyleme.', coding: ['Wiqo,', 'Mac’te', 'kodlasın.'],
  codingBody: ['Projen bilgisayarında.', 'Kontrol telefonunda.'],
  preview: ['Sonucu', 'telefonunda', 'gör.'],
  previewBody: ['Kod ve önizleme,', 'aynı yerde.'],
  product: 'Wiqo Act', promise: ['Telefondan söyle.', 'Bilgisayarın yapsın.'],
  close: 'Kodunu doğrudan telefonunda gör.',
} as const;

export const MOTION = {
  textEntry: 20, wordStagger: 3, lineStagger: 5, textTravel: 36,
  transition: 10, textExit: 8, floatPeriod: 115, floatY: 2.4,
  floatRotation: 0.38, breathing: 0.0028, freeze: 720,
  spring: { mass: 0.8, damping: 24, stiffness: 135, overshootClamping: true },
  hookDelay: 3, requestTaskDelay: 29, codingBodyDelay: 38, previewBodyDelay: 34,
  endTitleDelay: 5, endPromiseDelay: 24, endCloseDelay: 70,
} as const;

export const LAYOUT = {
  hook: { x: STYLE.side, y: 515 }, request: { x: STYLE.side, y: 460 },
  task: { x: STYLE.side, y: 920, size: 57 },
  coding: { x: 440, y: 815, size: 101 }, codingBody: { x: STYLE.side, y: 1275 },
  preview: { x: STYLE.side, y: 475 }, previewBody: { x: STYLE.side, y: 980 },
  endTitle: { y: 525, size: 124 }, endPromise: { y: 755, size: 59 },
  endClose: { y: 1435, size: 35 },
} as const;

export const LETTERS = {
  top: 775, size: 246, cellWidth: 188, cellHeight: 320,
  startX: { C: 258, H: 446, A: 634, T: 822 }, endX: { C: 540, A: 335, T: 745 },
  appear: 5, stagger: 2, removeFrom: 21, removeTo: 33,
  reorderFrom: 29, reorderTo: 59, arc: 120, hTravel: 64,
  subtitleFrom: 60, subtitleY: 1155, subtitleSize: 43,
  cursorFrom: 7, cursorGrab: 20, cursorRelease: 32, cursorHide: 42,
  cursorStart: { x: 845, y: 1145 }, cursorTarget: { x: 446, y: 850 },
  cursorEnd: { x: 495, y: 755 }, cursorSize: 70,
} as const;

export type Pose = { frame: number; x: number; y: number; size: number; opacity: number; rotation: number };
const pose = (frame: number, x: number, y: number, size: number, opacity: number, rotation = 0): Pose =>
  ({ frame, x, y, size, opacity, rotation });

// One continuous timeline per original PNG. Text changes never remount an actor.
// Invisible waypoints reposition an actor before its next entrance.
export const POSES: Record<MascotName, readonly Pose[]> = {
  blue: [
    pose(0, 775, 1300, 390, 0, -3), pose(23, 775, 1215, 390, 1),
    pose(78, 775, 1215, 390, 1), pose(102, 755, 1200, 390, 1, -1),
    pose(181, 755, 1200, 390, 1, -1), pose(198, 775, 1240, 375, 0),
    pose(604, 220, 1285, 240, 0, -2), pose(630, 220, 1250, 240, 1),
  ],
  orange: [
    pose(195, 800, 560, 300, 0, 3), pose(215, 800, 505, 300, 1),
    pose(273, 800, 505, 300, 1), pose(292, 825, 515, 285, 0),
    pose(616, 430, 1285, 240, 0, 2), pose(642, 430, 1250, 240, 1),
  ],
  green: [
    pose(285, 215, 715, 360, 0, -3), pose(309, 245, 645, 360, 1),
    pose(434, 245, 645, 360, 1), pose(454, 220, 665, 345, 0),
    pose(628, 650, 1285, 240, 0, -2), pose(654, 650, 1250, 240, 1),
  ],
  purple: [
    pose(450, 815, 1260, 380, 0, 3), pose(474, 785, 1205, 380, 1),
    pose(586, 785, 1205, 380, 1), pose(607, 805, 1240, 365, 0),
    pose(640, 860, 1285, 240, 0, 2), pose(666, 860, 1250, 240, 1),
  ],
};
