export const VIDEO = { width: 1080, height: 1920, fps: 30, frames: 900 } as const;

export const STYLE = {
  background: '#FFFFFF',
  ink: '#1F1F1F',
  secondary: '#666666',
  faint: '#E8E8E8',
  font: 'Roboto, Arial, sans-serif',
  side: 84,
  headline: 72,
  body: 37,
  lineHeight: 1.12,
  logoSize: 220,
  logoX: 540,
  logoY: 1645,
} as const;

export const ASSETS = {
  logo: 'w_logo.png',
  cursorOpen: 'wiqo-cursor-open.png',
  cursorClosed: 'wiqo-cursor-closed.png',
  blue: 'wiqo_blue.png',
  orange: 'wiqo_orange.png',
  green: 'wiqo_green.png',
  purple: 'wiqo_purple.png',
  memory: 'wiqo-act/screenshots/memory-game.png',
  code: 'wiqo-act/screenshots/code-view.png',
  voice: 'wiqo-act/screenshots/voice-followup.png',
} as const;

export type MascotName = 'blue' | 'orange' | 'green' | 'purple';

export const SCENES = {
  hook: { from: 0, to: 75 },
  explain: { from: 75, to: 135 },
  act: { from: 135, to: 210 },
  memory: { from: 210, to: 360 },
  code: { from: 360, to: 510 },
  voice: { from: 510, to: 660 },
  summary: { from: 660, to: 810 },
  close: { from: 810, to: 900 },
} as const;

export const COPY = {
  hook: ['What if your next app', 'started with a message'],
  explainTitle: ['Describe what you want'],
  explainBody: ['Wiqo builds it on your PC', 'while you follow along on your phone'],
  actSubtitle: ['From a message to working code'],
  memoryTitle: ['A simple idea', 'becomes a playable game'],
  memoryBody: ['Wiqo creates a four by four memory game', 'you can preview and try on your phone'],
  codeTitle: ['See the code', 'behind your idea'],
  codeBody: ['Switch to the project files and follow', 'the code that brings it to life'],
  voiceTitle: ['Shape the result', 'with your voice'],
  voiceBody: ['Give Wiqo the next instruction out loud', 'and keep refining your project'],
  summaryTitle: ['From first prompt', 'to a working result'],
  summaryBody: ['Build on your PC and explore', 'the result on your phone'],
  closeTitle: ['Build on your PC', 'See it on your phone'],
  product: 'Wiqo Act',
} as const;

export const MOTION = {
  transition: 9,
  enter: 14,
  textStagger: 2,
  lineStagger: 4,
  headlineTravel: 48,
  bodyTravel: 30,
  mascotTravel: 95,
  mascotFloatY: 4,
  mascotFloatRotation: 0.6,
  mascotBreathing: 0.004,
  phoneEnter: 16,
  focusStart: 4,
  focusDuration: 20,
  detailStart: 54,
  detailDuration: 24,
  screenshotExit: 9,
  montageStagger: 8,
  spring: { mass: 0.76, damping: 19, stiffness: 168, overshootClamping: true },
} as const;

export const LAYOUT = {
  hook: { y: 470, size: 82 },
  explainTitle: { y: 455, size: 82 },
  explainBody: { y: 790, size: 43 },
  screenshotTitle: { y: 126, size: 68 },
  screenshotBody: { y: 302, size: 37 },
  screenshot: { x: 540, y: 956, width: 450, height: 1058 },
  actSubtitle: { y: 1190, size: 43 },
  closeTitle: { y: 395, size: 82 },
  product: { y: 1090, size: 60 },
  summaryTitle: { y: 395, size: 78 },
  summaryBody: { y: 590, size: 42 },
  montage: { y: 1130, width: 260, height: 610, centers: [220, 540, 860] },
} as const;

export const SCREENSHOTS = {
  memory: {
    asset: ASSETS.memory,
    title: COPY.memoryTitle,
    body: COPY.memoryBody,
    mascot: 'green',
    focus: { x: 0.425, y: 0.412, zoom: 1.18 },
    detail: { x: 0.5, y: 0.43, zoom: 1.2 },
    enterFromX: 112,
    enterTilt: -3,
  },
  code: {
    asset: ASSETS.code,
    title: COPY.codeTitle,
    body: COPY.codeBody,
    mascot: 'blue',
    focus: { x: 0.44, y: 0.5, zoom: 1.1 },
    detail: { x: 0.44, y: 0.56, zoom: 1.2 },
    enterFromX: -112,
    enterTilt: 3,
  },
  voice: {
    asset: ASSETS.voice,
    title: COPY.voiceTitle,
    body: COPY.voiceBody,
    mascot: 'purple',
    focus: { x: 0.5, y: 0.84, zoom: 1.42 },
    detail: { x: 0.5, y: 0.76, zoom: 1.32 },
    enterFromX: 112,
    enterTilt: -3,
  },
} as const;

export const MONTAGE = [
  { asset: ASSETS.memory, direction: -1, tilt: -4 },
  { asset: ASSETS.code, direction: 1, tilt: 4 },
  { asset: ASSETS.voice, direction: -1, tilt: -4 },
] as const;

export const MASCOTS = {
  hook: { name: 'blue', x: 840, y: 1205, size: 280, phase: 0.2 },
  explain: { name: 'orange', x: 850, y: 1260, size: 255, phase: 1.4 },
  act: { name: 'green', x: 860, y: 1390, size: 175, phase: 2.6 },
  memory: { name: 'green', x: 930, y: 1245, size: 168, phase: 0.6 },
  code: { name: 'blue', x: 930, y: 1245, size: 168, phase: 1.8 },
  voice: { name: 'purple', x: 930, y: 1245, size: 168, phase: 3.1 },
  close: [
    { name: 'blue', x: 205, y: 1250, size: 178, phase: 0.1 },
    { name: 'orange', x: 430, y: 1280, size: 178, phase: 1.2 },
    { name: 'green', x: 650, y: 1250, size: 178, phase: 2.3 },
    { name: 'purple', x: 875, y: 1280, size: 178, phase: 3.4 },
  ],
} as const;

export const LETTERS = {
  top: 760,
  size: 246,
  cellWidth: 188,
  cellHeight: 320,
  startX: { C: 258, H: 446, A: 634, T: 822 },
  endX: { A: 352, C: 540, T: 728 },
  appear: 4,
  stagger: 2,
  removeFrom: 21,
  removeTo: 33,
  reorderFrom: 27,
  reorderTo: 56,
  arc: 118,
  hTravel: 76,
  cursorFrom: 8,
  cursorGrab: 23,
  cursorRelease: 34,
  cursorHide: 44,
  cursorStart: { x: 895, y: 1110 },
  cursorTarget: { x: 446, y: 840 },
  cursorEnd: { x: 505, y: 770 },
  cursorSize: 68,
} as const;

export const CROPPED_SCREENSHOT = {
  left: 0.12,
  right: 0.12,
  top: 0.075,
  bottom: 0.005,
  sourceWidth: 1066,
  sourceHeight: 2070,
} as const;
