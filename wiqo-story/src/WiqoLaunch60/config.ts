export const VIDEO = {
  fps: 30,
  durationInFrames: 1800,
  portrait: { width: 1080, height: 1920 },
  square: { width: 1080, height: 1080 },
  landscape: { width: 1920, height: 1080 },
} as const;

export const COLORS = {
  white: '#FFFFFF',
  ink: '#0B0B0F',
  secondary: '#707070',
  muted: '#9A9A9A',
  line: '#E8E8E8',
  surface: '#F7F7F7',
  blue: '#1378F8',
  green: '#22A846',
  orange: '#F49A16',
  purple: '#8757F5',
  success: '#178B46',
  textBlue: '#005BB5',
  textGreen: '#127233',
  textOrange: '#985900',
  textPurple: '#6F42C1',
  textSuccess: '#126F38',
  textBlueOnDark: '#7DB5FF',
} as const;

export const ASSETS = {
  logo: 'w_logo.png',
  mascots: {
    blue: 'wiqo_blue.png',
    green: 'wiqo_green.png',
    orange: 'wiqo_orange.png',
    purple: 'wiqo_purple.png',
  },
  cursorOpen: 'wiqo-cursor-open.png',
  cursorClosed: 'wiqo-cursor-closed.png',
  footage: {
    pdfPhone: 'footage/phone-cv-to-pdf.mp4',
    pdfMac: 'footage/mac-working.mp4',
    screenshotPhone: 'footage/phone-screenshot.mp4',
    approvalPhone: 'footage/phone-approval.mp4',
  },
  music: 'audio/music.mp3',
  sfx: {
    click: 'audio/sfx/click.mp3',
    whoosh: 'audio/sfx/whoosh.mp3',
    tick: 'audio/sfx/tick.mp3',
    notification: 'audio/sfx/notification.mp3',
  },
  appStoreBadge: 'brand/appstore-badge.svg',
} as const;

export const HOOKS = [
  'Dosya bilgisayarda kaldı.',
  'Telefonundan bilgisayarını yönet.',
  'PDF’i bilgisayardan telefona taşıma işi bitti.',
  'Yanında olmayan dosyaya ulaşmak 10 saniye.',
  'Render bitti mi diye bakmayı bırak.',
] as const;

export const HOOK_CAPTION_LINES = [
  ['Dosya bilgisayarda kaldı.'],
  ['Telefonundan bilgisayarını', 'yönet.'],
  ['PDF’i bilgisayardan', 'telefona taşıma işi bitti.'],
  ['Yanında olmayan dosyaya', 'ulaşmak 10 saniye.'],
  ['Render bitti mi diye', 'bakmayı bırak.'],
] as const;

export type HookVariant = 0 | 1 | 2 | 3 | 4;
export type Aspect = 'portrait' | 'square' | 'landscape';

export const COPY = {
  problem: 'Yanında değil. Bilgisayarın başına dönmen gerek.',
  scenario: 'Pazar akşamı, trafikte.',
  brand: 'Wiqo',
  promise: 'Telefondan söyle, bilgisayarın yapsın.',
  pdfRequest: 'Masaüstündeki CV’mi PDF yapıp bana gönder.',
  pdfTitle: 'Bul. Çevir. Gönder.',
  pdfSteps: ['Dosya bulundu', 'PDF’e çevrildi', 'Telefona gönderildi'],
  pdfSent: 'Gönderildi',
  screenshotQuestion: 'Bilgisayarının ekran görüntüsünü telefona getir.',
  screenshotReceived: 'Ekran görüntüsü telefonunda.',
  accounts: 'Mail · Takvim · Notion',
  accountsDescription: 'Bağlı hesaplarınla çalışır.',
  automations: 'Hatırlatmalar ve otomasyonlar.',
  menuBar: 'Mac’te menü çubuğunda çalışır.',
  longWork: 'Render sürsün. Bitince haber verir.',
  renderComplete: 'Render tamamlandı',
  trustApproval: 'Riskli işler senin onayınla.',
  trustRecord: 'Her adım kayıt altında.',
  trustMethod: 'Face ID ile onay.',
  finalTitle: 'Wiqo.',
  finalDescription: 'Telefonunda bir asistan, bilgisayarında bir ekip.',
  appStore: 'App Store’da Wiqo',
  time: '20:18',
  scenarioPlace: 'Yolun ortasında.',
  macTitle: 'Masaüstü kaydı',
  phoneTitle: 'Telefon kaydı',
  unknownMediaPrefix: 'FOOTAGE:',
  menuBarIndicator: 'Wiqo menü çubuğunda çalışıyor',
  captionLines: {
    problemFirst: ['Yanında değil.'],
    problemSecond: ['Bilgisayarın başına', 'dönmen gerek.'],
    promise: ['Telefondan söyle,', 'bilgisayarın yapsın.'],
    pdfRequest: ['Masaüstündeki CV’mi PDF', 'yapıp bana gönder.'],
    pdfTitle: ['Bul. Çevir. Gönder.'],
    pdfSent: ['PDF telefona gönderildi.'],
    screenshotQuestion: ['Bilgisayarının ekranını', 'telefona getir.'],
    screenshotReceived: ['Ekran görüntüsü', 'telefonunda.'],
    accounts: ['Mail, takvim ve Notion’la', 'çalışır.'],
    automations: ['Hatırlatmalar ve', 'otomasyonlar kur.'],
    menuBar: ['Mac’te menü çubuğunda', 'çalışır.'],
    longWork: ['Render sürsün.', 'Bitince haber verir.'],
    renderComplete: ['Render tamamlandı.'],
    trustApproval: ['Riskli işler senin', 'onayınla.'],
    trustRecord: ['Her adım kayıt altında.'],
    trustMethod: ['Face ID ile onay.'],
    finalDescription: ['Telefonunda bir asistan,', 'bilgisayarında bir ekip.'],
  },
} as const;

export const SCENES = {
  hook: { from: 0, to: 90, title: 'Kanca' },
  problem: { from: 90, to: 270, title: 'Sorun' },
  brand: { from: 270, to: 450, title: 'Çözüm' },
  pdf: { from: 450, to: 900, title: 'PDF’e çevir ve gönder' },
  screenshot: { from: 900, to: 1140, title: 'Ekran görüntüsü' },
  longWork: { from: 1140, to: 1350, title: 'Uzun iş bildirimi' },
  trust: { from: 1350, to: 1560, title: 'Güven' },
  cta: { from: 1560, to: 1800, title: 'Kapanış' },
} as const;

export type SceneKey = keyof typeof SCENES;

export const FOOTAGE = {
  pdfPhone: {
    file: ASSETS.footage.pdfPhone,
    trim: { startFrom: 0, endAt: 450 },
    speed: 1,
    focus: [
      { frame: 0, x: 50, y: 50, scale: 1 },
      { frame: 48, x: 50, y: 42, scale: 1.06 },
      { frame: 130, x: 50, y: 50, scale: 1 },
      { frame: 310, x: 50, y: 58, scale: 1.04 },
      { frame: 450, x: 50, y: 50, scale: 1 },
    ],
  },
  pdfMac: {
    file: ASSETS.footage.pdfMac,
    trim: { startFrom: 0, endAt: 450 },
    speed: 3,
    focus: [
      { frame: 0, x: 50, y: 50, scale: 1 },
      { frame: 52, x: 54, y: 42, scale: 1.07 },
      { frame: 155, x: 48, y: 54, scale: 1.04 },
      { frame: 300, x: 50, y: 50, scale: 1 },
      { frame: 450, x: 50, y: 50, scale: 1 },
    ],
  },
  screenshotPhone: {
    file: ASSETS.footage.screenshotPhone,
    trim: { startFrom: 0, endAt: 240 },
    speed: 1,
    focus: [
      { frame: 0, x: 50, y: 50, scale: 1 },
      { frame: 58, x: 50, y: 46, scale: 1.08 },
      { frame: 148, x: 52, y: 52, scale: 1.03 },
      { frame: 240, x: 50, y: 50, scale: 1 },
    ],
  },
  approvalPhone: {
    file: ASSETS.footage.approvalPhone,
    trim: { startFrom: 0, endAt: 210 },
    speed: 1,
    focus: [
      { frame: 0, x: 50, y: 50, scale: 1 },
      { frame: 55, x: 50, y: 47, scale: 1.07 },
      { frame: 122, x: 50, y: 50, scale: 1.02 },
      { frame: 210, x: 50, y: 50, scale: 1 },
    ],
  },
} as const;

export type FootageKey = keyof typeof FOOTAGE;
export type FocusPoint = { frame: number; x: number; y: number; scale: number };

export const CAPTION_FRAMES = {
  problemFirstEnd: 162,
  pdfRequestEnd: 540,
  pdfTitleEnd: 805,
  pdfSentEnd: 900,
  screenshotQuestionEnd: 975,
  screenshotReceivedEnd: 1015,
  screenshotAccountsEnd: 1055,
  screenshotAutomationsEnd: 1095,
  longWorkEnd: 1202,
  renderCompleteEnd: 1260,
  menuBarEnd: 1350,
  trustApprovalEnd: 1420,
  trustMethodEnd: 1485,
  trustRecordEnd: 1560,
  finalCaptionEnd: 1770,
} as const;

export const SFX_CUES = [
  { frame: 66, file: ASSETS.sfx.click, duration: 20, volume: 0.62 },
  { frame: SCENES.problem.from, file: ASSETS.sfx.whoosh, duration: 24, volume: 0.34 },
  { frame: SCENES.brand.from, file: ASSETS.sfx.whoosh, duration: 24, volume: 0.34 },
  { frame: SCENES.pdf.from, file: ASSETS.sfx.tick, duration: 16, volume: 0.28 },
  { frame: SCENES.screenshot.from, file: ASSETS.sfx.whoosh, duration: 24, volume: 0.34 },
  { frame: SCENES.longWork.from, file: ASSETS.sfx.notification, duration: 24, volume: 0.36 },
  { frame: SCENES.trust.from, file: ASSETS.sfx.tick, duration: 16, volume: 0.28 },
  { frame: SCENES.cta.from, file: ASSETS.sfx.whoosh, duration: 24, volume: 0.34 },
] as const;

export const EDITS = {
  main: [{ sourceFrom: 0, duration: VIDEO.durationInFrames, outputFrom: 0 }],
  short: [
    { sourceFrom: SCENES.hook.from, duration: 90, outputFrom: 0 },
    { sourceFrom: SCENES.brand.from, duration: 180, outputFrom: 90 },
    { sourceFrom: SCENES.pdf.from, duration: 180, outputFrom: 270 },
  ],
  bumper: [
    { sourceFrom: SCENES.hook.from, duration: 90, outputFrom: 0 },
    { sourceFrom: SCENES.brand.from, duration: 90, outputFrom: 90 },
  ],
} as const;

export const OUTPUTS = {
  shortDuration: 450,
  bumperDuration: 180,
} as const;

export const TYPE = {
  headline: 'Manrope, sans-serif',
  body: 'Inter, sans-serif',
  headlineWeight: 800,
  bodyWeight: 500,
  heroSize: 104,
  titleSize: 80,
  subtitleSize: 48,
  bodySize: 36,
  smallSize: 27,
  captionSize: 32,
  lineHeight: 1.16,
  tracking: -0.045,
} as const;

export const SAFE_AREA = {
  side: 72,
  top: 112,
  bottom: 220,
  captionMaxWidth: 870,
} as const;

export const MOTION = {
  mass: 1,
  damping: 16,
  stiffness: 142,
  enterFrames: 12,
  exitFrames: 8,
  transitionFrames: 14,
  wordStaggerFrames: 5,
  wordTravel: 28,
  fadeDistance: 14,
  cameraPushStart: 100,
  cameraPushEnd: 106,
  finalSettleFrames: 30,
  musicDuck: 0.501,
  mascotFloatAmplitude: 8,
  mascotFloatPeriodFrames: 112,
  cursorSize: 74,
  cursorPressFrames: 8,
} as const;

export const BEATS = {
  hookPhoneAt: 66,
  scenarioAt: 54,
  brandMascotDelay: 9,
  brandLogoDelay: 4,
  brandTitleDelay: 7,
  brandPromiseDelay: 18,
  pdfStepFrames: [42, 126, 210],
  screenshotTextBeats: [0, 75, 115, 155, 195, 240],
  notificationDelay: 24,
  notificationVisibleUntil: 188,
  notificationFadeUntil: 204,
  pdfSentFadeFrom: 322,
  pdfSentVisibleFrom: 344,
  pdfSentVisibleUntil: 445,
  pdfSentFadeUntil: 450,
  trustMethodFadeFrom: 50,
  trustMethodVisibleFrom: 68,
  trustMethodVisibleUntil: 176,
  ctaMascotStagger: 6,
} as const;

export const BRAND_CURSOR_PATH = [
  { frame: 0, x: 0.18, y: 0.59 },
  { frame: 42, x: 0.39, y: 0.51 },
  { frame: 76, x: 0.66, y: 0.46, pressed: true },
  { frame: 104, x: 0.58, y: 0.67 },
  { frame: 144, x: 0.81, y: 0.59 },
  { frame: 174, x: 0.84, y: 0.59 },
] as const;

export const CTA_BEATS = {
  logoDelay: 2,
  titleDelay: 8,
  descriptionDelay: 20,
} as const;

export const DEVICE = {
  phoneAspectHeightPerWidth: 2.06,
  phoneBorder: 7,
  phoneRadius: 48,
  phoneInnerRadius: 39,
  phoneSpeakerWidth: 82,
  phoneSpeakerHeight: 18,
  macAspectHeightPerWidth: 0.64,
  macHeaderHeight: 58,
  macRadius: 24,
  windowDotSize: 15,
  notificationRadius: 24,
} as const;

export const LAYOUT = {
  portrait: {
    hookPhoneTop: 0.54,
    brandLogoTop: 0.24,
    brandMascotTop: 0.61,
    pdfPhoneLeft: 0.08,
    pdfPhoneTop: 0.22,
    pdfPhoneMaxHeight: 0.30,
    pdfMacLeft: 0.16,
    pdfMacTop: 0.54,
    pdfMacMaxHeight: 0.24,
    stepTop: 0.79,
    phoneWidth: 0.43,
    macWidth: 0.63,
    screenshotPhoneTop: 0.24,
    screenshotPhoneWidth: 0.41,
    trustPhoneTop: 0.24,
    trustPhoneWidth: 0.41,
    ctaLogoTop: 0.18,
    ctaTitleTop: 0.36,
    ctaDescriptionTop: 0.49,
    ctaAppStoreTop: 0.61,
    ctaMascotTop: 0.75,
  },
  square: {
    hookPhoneTop: 0.52,
    brandLogoTop: 0.19,
    brandMascotTop: 0.62,
    pdfPhoneLeft: 0.06,
    pdfPhoneTop: 0.30,
    pdfPhoneMaxHeight: 0.44,
    pdfMacLeft: 0.38,
    pdfMacTop: 0.30,
    pdfMacMaxHeight: 0.48,
    stepTop: 0.22,
    phoneWidth: 0.32,
    macWidth: 0.61,
    screenshotPhoneTop: 0.28,
    screenshotPhoneWidth: 0.29,
    trustPhoneTop: 0.25,
    trustPhoneWidth: 0.29,
    ctaLogoTop: 0.13,
    ctaTitleTop: 0.29,
    ctaDescriptionTop: 0.42,
    ctaAppStoreTop: 0.53,
    ctaMascotTop: 0.63,
  },
  landscape: {
    hookPhoneTop: 0.43,
    brandLogoTop: 0.28,
    brandMascotTop: 0.56,
    pdfPhoneLeft: 0.05,
    pdfPhoneTop: 0.32,
    pdfPhoneMaxHeight: 0.40,
    pdfMacLeft: 0.22,
    pdfMacTop: 0.32,
    pdfMacMaxHeight: 0.42,
    stepTop: 0.22,
    phoneWidth: 0.19,
    macWidth: 0.60,
    screenshotPhoneTop: 0.17,
    screenshotPhoneWidth: 0.18,
    trustPhoneTop: 0.19,
    trustPhoneWidth: 0.18,
    ctaLogoTop: 0.13,
    ctaTitleTop: 0.28,
    ctaDescriptionTop: 0.42,
    ctaAppStoreTop: 0.54,
    ctaMascotTop: 0.63,
  },
} as const;

export const AUDIO = {
  defaultMusicVolume: 0.27,
  soundEffectVolume: 1,
  duckWindowBeforeFrames: 9,
  duckWindowAfterFrames: 20,
} as const;
