import React from 'react';
import '@fontsource/roboto/400.css';
import {
  AbsoluteFill,
  Easing,
  Img,
  Sequence,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import {
  DURATION_IN_FRAMES,
  FPS,
  SCENE_BROWSER,
  SCENE_CLICK,
  SCENE_COMMAND,
  SCENE_DESKTOP,
  SCENE_END,
  SCENE_FORMS,
  SCENE_PAYOFF,
  SCENE_RESEARCH,
} from './timing';

export type LaunchLanguage = 'tr' | 'en';
export type WiqoComputerUseLaunchProps = { language?: LaunchLanguage };
type MascotName = 'blue' | 'orange' | 'green' | 'purple';
type MascotPose = { frame: number; x: number; y: number; scale: number; opacity: number; rotation: number };
type Placement = { x: number; y: number; scale: number; rotation: number; opacity?: number };
type Beat = { frame: number; positions: Record<MascotName, Placement> };
type CopyLayout = { x: number; y: number; width: number; align: 'left' | 'center' | 'right'; offsetX: number; offsetY: number };
type ChapterCopy = { title: string; body: string; layout: CopyLayout; titleSize?: number; bodySize?: number };

const INK = '#1F1F1F';
const MUTED = '#707070';
const FONT = 'Roboto, sans-serif';
const BASE_MASCOT_SIZE = 500;
const MASCOT_ORDER: MascotName[] = ['blue', 'orange', 'green', 'purple'];
const MASCOT_ASSETS: Record<MascotName, string> = {
  blue: 'wiqo_blue.png',
  orange: 'wiqo_orange.png',
  green: 'wiqo_green.png',
  purple: 'wiqo_purple.png',
};
const FINAL_X: Record<MascotName, number> = { blue: 165, orange: 415, green: 665, purple: 915 };

const pose = (x: number, y: number, scale: number, rotation: number, opacity = 1): Placement => ({
  x, y, scale, rotation, opacity,
});

// Each beat is a waypoint in a shared choreography. The original PNGs remain
// intact; only position, rotation, uniform scale, and opacity are animated.
const beats: Beat[] = [
  { frame: 0, positions: {
    blue: pose(540, 1900, 0.62, -2, 0), orange: pose(1190, 1320, 0.52, 4, 0),
    green: pose(240, 1970, 0.54, -3, 0), purple: pose(540, -170, 0.56, 2, 0),
  } },
  { frame: 24, positions: {
    blue: pose(540, 1370, 0.63, 0), orange: pose(1190, 1320, 0.52, 4, 0),
    green: pose(240, 1970, 0.54, -3, 0), purple: pose(540, -170, 0.56, 2, 0),
  } },
  { frame: 120, positions: {
    blue: pose(500, 1300, 0.59, -1), orange: pose(1190, 1320, 0.52, 4, 0),
    green: pose(240, 1970, 0.54, -3, 0), purple: pose(540, -170, 0.56, 2, 0),
  } },
  { frame: 162, positions: {
    blue: pose(405, 1320, 0.56, -1), orange: pose(750, 1300, 0.52, 1),
    green: pose(240, 1970, 0.54, -3, 0), purple: pose(540, -170, 0.56, 2, 0),
  } },
  { frame: 218, positions: {
    blue: pose(330, 1390, 0.54, 0), orange: pose(765, 1370, 0.52, -1),
    green: pose(240, 1970, 0.54, -3, 0), purple: pose(540, -170, 0.56, 2, 0),
  } },
  { frame: 300, positions: {
    blue: pose(300, 1370, 0.53, 0), orange: pose(790, 1390, 0.49, 0),
    green: pose(540, 1950, 0.54, 2, 0), purple: pose(540, -170, 0.56, 2, 0),
  } },
  { frame: 350, positions: {
    blue: pose(310, 1480, 0.51, 0), orange: pose(780, 1480, 0.48, 0),
    green: pose(540, 1240, 0.60, -1), purple: pose(540, -170, 0.56, 2, 0),
  } },
  { frame: 420, positions: {
    blue: pose(315, 1480, 0.50, 0), orange: pose(780, 1480, 0.48, 0),
    green: pose(540, 1260, 0.58, 0), purple: pose(540, -170, 0.56, 2, 0),
  } },
  { frame: 480, positions: {
    blue: pose(325, 1360, 0.49, -1), orange: pose(755, 1360, 0.49, 1),
    green: pose(540, 1500, 0.49, 0), purple: pose(540, -170, 0.56, 2, 0),
  } },
  { frame: 525, positions: {
    blue: pose(325, 1360, 0.49, -1), orange: pose(755, 1360, 0.49, 1),
    green: pose(540, 1500, 0.49, 0), purple: pose(540, 1090, 0.57, -1),
  } },
  { frame: 620, positions: {
    blue: pose(330, 1350, 0.48, 0), orange: pose(750, 1350, 0.48, 0),
    green: pose(540, 1510, 0.48, 0), purple: pose(540, 1090, 0.56, 0),
  } },
  { frame: 660, positions: {
    blue: pose(370, 1260, 0.46, -1), orange: pose(710, 1260, 0.46, 1),
    green: pose(370, 1510, 0.46, -1), purple: pose(710, 1510, 0.46, 1),
  } },
  { frame: 720, positions: {
    blue: pose(395, 1300, 0.45, 0), orange: pose(685, 1300, 0.45, 0),
    green: pose(395, 1480, 0.45, 0), purple: pose(685, 1480, 0.45, 0),
  } },
  { frame: 820, positions: {
    blue: pose(395, 1300, 0.45, 0), orange: pose(685, 1300, 0.45, 0),
    green: pose(395, 1480, 0.45, 0), purple: pose(685, 1480, 0.45, 0),
  } },
  { frame: 840, positions: {
    blue: pose(220, 1410, 0.43, -1), orange: pose(430, 1410, 0.43, 0),
    green: pose(650, 1410, 0.43, 0), purple: pose(860, 1410, 0.43, 1),
  } },
  { frame: 930, positions: {
    blue: pose(260, 1365, 0.43, -0.5), orange: pose(450, 1365, 0.43, 0.5),
    green: pose(640, 1365, 0.43, -0.5), purple: pose(830, 1365, 0.43, 0.5),
  } },
  { frame: 980, positions: {
    blue: pose(260, 1365, 0.43, 0), orange: pose(450, 1365, 0.43, 0),
    green: pose(640, 1365, 0.43, 0), purple: pose(830, 1365, 0.43, 0),
  } },
  { frame: 1050, positions: {
    blue: pose(260, 1365, 0.43, 0), orange: pose(450, 1365, 0.43, 0),
    green: pose(640, 1365, 0.43, 0), purple: pose(830, 1365, 0.43, 0),
  } },
  { frame: 1170, positions: {
    blue: pose(165, 1980, 0.47, -1, 0), orange: pose(415, 1980, 0.47, 1, 0),
    green: pose(665, 1980, 0.47, -1, 0), purple: pose(915, 1980, 0.47, 1, 0),
  } },
  { frame: 1210, positions: {
    blue: pose(165, 1840, 0.47, -1), orange: pose(415, 1840, 0.47, 1),
    green: pose(665, 1840, 0.47, -1), purple: pose(915, 1840, 0.47, 1),
  } },
  { frame: 1260, positions: {
    blue: pose(165, 1836, 0.47, 0), orange: pose(415, 1836, 0.47, 0),
    green: pose(665, 1836, 0.47, 0), purple: pose(915, 1836, 0.47, 0),
  } },
];

const mascotPoses: Record<MascotName, MascotPose[]> = Object.fromEntries(
  MASCOT_ORDER.map((name) => [
    name,
    beats.map((beat) => ({ frame: beat.frame, ...beat.positions[name], opacity: beat.positions[name].opacity ?? 1 })),
  ]),
) as Record<MascotName, MascotPose[]>;

const smooth = (frame: number, from: number, to: number, easing = Easing.inOut(Easing.cubic)) =>
  interpolate(frame, [from, Math.max(from + 1, to)], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing,
  });

const getPose = (frame: number, fps: number, poses: MascotPose[]) => {
  const last = poses[poses.length - 1];
  if (frame >= last.frame) return last;
  let left = poses[0];
  let right = poses[1];
  for (let index = 1; index < poses.length; index += 1) {
    if (frame <= poses[index].frame) {
      left = poses[index - 1];
      right = poses[index];
      break;
    }
  }
  const springValue = spring({
    frame: Math.max(0, frame - left.frame),
    fps,
    config: { mass: 0.92, stiffness: 72, damping: 23, overshootClamping: true },
  });
  const progress = Math.max(0, Math.min(1, springValue));
  const mix = (from: number, to: number) => from + (to - from) * progress;
  return {
    frame,
    x: mix(left.x, right.x),
    y: mix(left.y, right.y),
    scale: mix(left.scale, right.scale),
    opacity: mix(left.opacity, right.opacity),
    rotation: mix(left.rotation, right.rotation),
  };
};

type DragEvent = { name: MascotName; approach: number; grab: number; release: number; settleEnd: number; dx: number; dy: number };
const DRAGS: DragEvent[] = [
  { name: 'orange', approach: 207, grab: 219, release: 252, settleEnd: 300, dx: -205, dy: -145 },
];

const dragOffset = (frame: number, name: MascotName) => {
  let x = 0;
  let y = 0;
  for (const event of DRAGS) {
    if (event.name !== name || frame < event.grab) continue;
    const progress = frame < event.release
      ? smooth(frame, event.grab, event.release, Easing.inOut(Easing.cubic))
      : 1 - smooth(frame, event.settleEnd, event.settleEnd + 36, Easing.out(Easing.cubic));
    x += event.dx * progress;
    y += event.dy * progress;
  }
  return { x, y };
};

const floatingPose = (frame: number, fps: number, name: MascotName, index: number) => {
  const base = getPose(frame, fps, mascotPoses[name]);
  const time = frame / fps;
  const phase = index * 1.61 + 0.3;
  const drag = dragOffset(frame, name);
  const floatX = Math.sin((time / 3.1) * Math.PI * 2 + phase) * 2.8;
  const floatY = Math.sin((time / 2.7) * Math.PI * 2 + phase) * 5.2;
  const floatRotation = Math.sin((time / 4.2) * Math.PI * 2 + phase) * 0.52;
  const breathing = 1 + Math.sin((time / 3.6) * Math.PI * 2 + phase) * 0.0045;

  if (frame >= SCENE_END.from) {
    const rise = smooth(frame, SCENE_END.from + index * 7, SCENE_END.from + 35 + index * 7, Easing.out(Easing.cubic));
    return {
      x: FINAL_X[name] + floatX * 0.2,
      y: 1990 + (1836 - 1990) * rise + floatY * 0.2,
      scale: 0.47 * breathing,
      opacity: rise,
      rotation: base.rotation + floatRotation * 0.25,
    };
  }

  const renderedScale = base.scale * breathing;
  const halfSize = (BASE_MASCOT_SIZE * renderedScale) / 2;
  const rawX = base.x + drag.x + floatX;
  const rawY = base.y + drag.y + floatY;
  const dismissStart = SCENE_PAYOFF.from - 42 + index * 2;
  if (frame >= dismissStart) {
    const dismiss = smooth(frame, dismissStart, dismissStart + 24, Easing.inOut(Easing.cubic));
    return {
      x: Math.max(halfSize + 18, Math.min(1080 - halfSize - 18, rawX)),
      y: Math.max(halfSize + 48, Math.min(1920 - halfSize - 48, rawY)),
      scale: renderedScale * (1 - dismiss * 0.08),
      opacity: base.opacity * (1 - dismiss),
      rotation: base.rotation + floatRotation,
    };
  }
  return {
    x: Math.max(halfSize + 18, Math.min(1080 - halfSize - 18, rawX)),
    y: Math.max(halfSize + 48, Math.min(1920 - halfSize - 48, rawY)),
    scale: renderedScale,
    opacity: base.opacity,
    rotation: base.rotation + floatRotation,
  };
};

const FloatingMascot: React.FC<{ name: MascotName; index: number }> = ({ name, index }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const current = floatingPose(frame, fps, name, index);

  return (
    <Img
      src={staticFile(MASCOT_ASSETS[name])}
      style={{
        position: 'absolute',
        left: current.x - BASE_MASCOT_SIZE / 2,
        top: current.y - BASE_MASCOT_SIZE / 2,
        width: BASE_MASCOT_SIZE,
        height: BASE_MASCOT_SIZE,
        objectFit: 'contain',
        opacity: current.opacity,
        transform: 'rotate(' + current.rotation + 'deg) scale(' + current.scale + ')',
        transformOrigin: '50% 50%',
        willChange: 'transform, opacity',
      }}
    />
  );
};

const Cursor: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const active = DRAGS.find((event) => frame >= event.approach && frame <= event.release + 15);
  if (!active) return null;

  const index = MASCOT_ORDER.indexOf(active.name);
  const startPose = floatingPose(active.approach, fps, active.name, index);
  const target = floatingPose(frame, fps, active.name, index);
  const approach = smooth(frame, active.approach, active.grab, Easing.out(Easing.cubic));
  const hold = frame >= active.grab && frame <= active.release;
  const exit = 1 - smooth(frame, active.release, active.release + 15, Easing.inOut(Easing.cubic));
  const startX = startPose.x - 190;
  const startY = startPose.y + 140;
  const targetX = target.x + 110;
  const targetY = target.y - 75;
  const x = Math.max(52, Math.min(1028, startX + (targetX - startX) * approach));
  const y = Math.max(52, Math.min(1868, startY + (targetY - startY) * approach));
  const press = hold ? 1 : 0;
  const icon = hold ? 'wiqo-cursor-closed.png' : 'wiqo-cursor-open.png';

  return (
    <Img
      src={staticFile(icon)}
      style={{
        position: 'absolute',
        left: x - 48,
        top: y - 48,
        width: 96,
        height: 96,
        objectFit: 'contain',
        opacity: approach * exit,
        transform: 'scale(' + (0.94 + press * 0.06) + ')',
        transformOrigin: '50% 50%',
        willChange: 'transform, opacity',
      }}
    />
  );
};

const OfficialLogo: React.FC<{ x: number; y: number; size: number; opacity: number; scale: number }> = ({ x, y, size, opacity, scale }) => (
  <Img
    src={staticFile('w_logo.png')}
    style={{
      position: 'absolute',
      left: x - size / 2,
      top: y - size / 2,
      width: size,
      height: size,
      objectFit: 'contain',
      opacity,
      transform: 'scale(' + scale + ')',
      transformOrigin: '50% 50%',
    }}
  />
);

const LAYOUTS: CopyLayout[] = [
  { x: 135, y: 535, width: 810, align: 'center', offsetX: 0, offsetY: 18 },
  { x: 130, y: 410, width: 820, align: 'left', offsetX: -24, offsetY: 12 },
  { x: 215, y: 550, width: 790, align: 'right', offsetX: 26, offsetY: 14 },
  { x: 140, y: 715, width: 820, align: 'left', offsetX: -26, offsetY: 10 },
  { x: 185, y: 430, width: 825, align: 'right', offsetX: 24, offsetY: 14 },
  { x: 105, y: 595, width: 870, align: 'center', offsetX: 0, offsetY: 14 },
];

const COPY: Record<LaunchLanguage, {
  chapters: ChapterCopy[];
  firstPayoff: string;
  secondPayoff: string;
  tagline: string;
}> = {
  tr: {
    chapters: [
      { title: 'Bir görev ver.', body: 'Gerisini Wiqo tamamlasın.', layout: LAYOUTS[0], titleSize: 68, bodySize: 34 },
      { title: 'Web’de araştırır.', body: 'Sayfaları inceler, seçenekleri karşılaştırır.', layout: LAYOUTS[1] },
      { title: 'Önemli olanı bulur.', body: 'Bilgiyi toplar, sonucu anlaşılır kılar.', layout: LAYOUTS[2] },
      { title: 'Sonra işi ilerletir.', body: 'Gerekli adımları atar, seçimleri tamamlar.', layout: LAYOUTS[3] },
      { title: 'Formları da tamamlar.', body: 'Bilgileri girer, kontrol eder ve gönderir.', layout: LAYOUTS[4] },
      { title: 'Web’den masaüstüne.', body: 'Wiqo görevi baştan sona tamamlar.', layout: LAYOUTS[5] },
    ],
    firstPayoff: 'Nasıl yapılacağını anlatma.',
    secondPayoff: 'Wiqo halletsin.',
    tagline: 'Bilgisayarında işlerini senin yerine tamamlar.',
  },
  en: {
    chapters: [
      { title: 'Give Wiqo a task.', body: 'Let Wiqo take it from here.', layout: LAYOUTS[0], titleSize: 68, bodySize: 34 },
      { title: 'It researches the web.', body: 'It reviews pages and compares your options.', layout: LAYOUTS[1] },
      { title: 'It finds what matters.', body: 'It gathers the facts and makes them clear.', layout: LAYOUTS[2] },
      { title: 'Then it moves things forward.', body: 'It takes the next steps and makes selections.', layout: LAYOUTS[3] },
      { title: 'It completes the forms.', body: 'Details entered, checked, and submitted.', layout: LAYOUTS[4] },
      { title: 'From web to desktop.', body: 'Wiqo carries the task through to completion.', layout: LAYOUTS[5] },
    ],
    firstPayoff: 'Don’t tell it how.',
    secondPayoff: 'Let Wiqo do it.',
    tagline: 'Your work, completed on your computer.',
  },
};

const AnimatedCopy: React.FC<ChapterCopy> = ({ title, body, layout, titleSize = 64, bodySize = 30 }) => {
  const frame = useCurrentFrame();
  const { fps, durationInFrames } = useVideoConfig();
  const enterSpring = spring({
    frame: Math.max(0, frame),
    fps,
    config: { mass: 0.88, stiffness: 88, damping: 22 },
  });
  const enter = smooth(frame, 0, 26, Easing.out(Easing.cubic));
  const exit = 1 - smooth(frame, durationInFrames - 17, durationInFrames, Easing.in(Easing.cubic));
  const scale = 0.975 + Math.min(1, enterSpring) * 0.025;

  return (
    <div
      style={{
        position: 'absolute',
        left: layout.x,
        top: layout.y,
        width: layout.width,
        color: INK,
        fontFamily: FONT,
        fontWeight: 400,
        textAlign: layout.align,
        opacity: enter * exit,
        transform: 'translate(' + ((1 - enter) * layout.offsetX) + 'px, ' + ((1 - enter) * layout.offsetY) + 'px) scale(' + scale + ')',
        transformOrigin: layout.align === 'right' ? '100% 50%' : layout.align === 'left' ? '0 50%' : '50% 50%',
        willChange: 'transform, opacity',
      }}
    >
      <div style={{ fontSize: titleSize, lineHeight: 1.16, letterSpacing: -1.5 }}>{title}</div>
      <div
        style={{
          marginTop: 27,
          color: MUTED,
          fontSize: bodySize,
          lineHeight: 1.48,
          letterSpacing: -0.3,
          maxWidth: '100%',
        }}
      >
        {body}
      </div>
    </div>
  );
};

const Chapter: React.FC<{ from: number; duration: number; copy: ChapterCopy }> = ({ from, duration, copy }) => (
  <Sequence from={from} durationInFrames={duration}>
    <AbsoluteFill style={{ pointerEvents: 'none' }}>
      <AnimatedCopy {...copy} />
    </AbsoluteFill>
  </Sequence>
);

const IntroLogo: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const enter = spring({
    frame: Math.max(0, frame),
    fps,
    config: { mass: 0.9, stiffness: 78, damping: 24 },
  });
  const opacity = smooth(frame, 5, 24, Easing.out(Easing.cubic)) *
    (1 - smooth(frame, SCENE_COMMAND.duration - 16, SCENE_COMMAND.duration, Easing.in(Easing.cubic)));

  return (
    <OfficialLogo
      x={540}
      y={390}
      size={96}
      opacity={opacity}
      scale={0.94 + Math.min(1, enter) * 0.06}
    />
  );
};

const Payoff: React.FC<{ first: string; second: string }> = ({ first, second }) => {
  const frame = useCurrentFrame();
  const { fps, durationInFrames } = useVideoConfig();
  const logoIn = smooth(frame, 0, 18, Easing.out(Easing.cubic));
  const logoOut = 1 - smooth(frame, durationInFrames - 16, durationInFrames, Easing.in(Easing.cubic));
  const firstIn = smooth(frame, 0, 16, Easing.out(Easing.cubic));
  const firstOut = 1 - smooth(frame, 55, 70, Easing.in(Easing.cubic));
  const secondSpring = spring({
    frame: Math.max(0, frame - 60),
    fps,
    config: { mass: 0.84, stiffness: 108, damping: 24 },
  });
  const secondOut = 1 - smooth(frame, durationInFrames - 16, durationInFrames, Easing.in(Easing.cubic));

  return (
    <AbsoluteFill>
      <OfficialLogo x={540} y={492} size={166} opacity={logoIn * logoOut} scale={0.94 + logoIn * 0.06} />
      <div
        style={{
          position: 'absolute', left: 80, right: 80, top: 698, color: INK, fontFamily: FONT,
          fontWeight: 400, fontSize: 60, lineHeight: 1.2, letterSpacing: -1.3, textAlign: 'center',
          opacity: firstIn * firstOut, transform: 'translateY(' + ((1 - firstIn) * 16) + 'px)',
        }}
      >
        {first}
      </div>
      <div
        style={{
          position: 'absolute', left: 60, right: 60, top: 824, color: INK, fontFamily: FONT,
          fontWeight: 400, fontSize: 94, lineHeight: 1.12, letterSpacing: -2.5, textAlign: 'center',
          opacity: Math.max(0, Math.min(1, secondSpring)) * secondOut,
          transform: 'scale(' + (0.88 + Math.min(1, secondSpring) * 0.12) + ')',
          transformOrigin: '50% 50%',
        }}
      >
        {second}
      </div>
    </AbsoluteFill>
  );
};

const EndCard: React.FC<{ tagline: string }> = ({ tagline }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const entry = spring({ frame: Math.max(0, frame), fps, config: { mass: 0.84, stiffness: 100, damping: 24 } });
  const titleOpacity = smooth(frame, 12, 31, Easing.out(Easing.cubic));
  const subtitleOpacity = smooth(frame, 23, 43, Easing.out(Easing.cubic));

  return (
    <AbsoluteFill>
      <OfficialLogo x={540} y={575} size={216} opacity={titleOpacity} scale={0.94 + Math.min(1, entry) * 0.06} />
      <div
        style={{
          position: 'absolute', left: 0, right: 0, top: 756, color: INK, fontFamily: FONT,
          fontWeight: 400, fontSize: 78, lineHeight: 1.16, letterSpacing: -1.6, textAlign: 'center',
          opacity: titleOpacity, transform: 'translateY(' + ((1 - titleOpacity) * 12) + 'px)',
        }}
      >
        Wiqo
      </div>
      <div
        style={{
          position: 'absolute', left: 68, right: 68, top: 890, color: INK, fontFamily: FONT,
          fontWeight: 400, fontSize: 33, lineHeight: 1.42, letterSpacing: -0.4, textAlign: 'center',
          opacity: subtitleOpacity, transform: 'translateY(' + ((1 - subtitleOpacity) * 12) + 'px)',
        }}
      >
        {tagline}
      </div>
    </AbsoluteFill>
  );
};

export const WiqoComputerUseLaunch: React.FC<WiqoComputerUseLaunchProps> = ({ language = 'en' }) => {
  const copy = COPY[language];
  const sceneDefinitions = [
    { timing: SCENE_COMMAND, copy: copy.chapters[0] },
    { timing: SCENE_BROWSER, copy: copy.chapters[1] },
    { timing: SCENE_RESEARCH, copy: copy.chapters[2] },
    { timing: SCENE_CLICK, copy: copy.chapters[3] },
    { timing: SCENE_FORMS, copy: copy.chapters[4] },
    { timing: SCENE_DESKTOP, copy: copy.chapters[5] },
  ];

  return (
    <AbsoluteFill style={{ backgroundColor: '#FFFFFF', overflow: 'hidden' }}>
      {MASCOT_ORDER.map((name, index) => <FloatingMascot key={name} name={name} index={index} />)}
      <Cursor />
      <Sequence from={SCENE_COMMAND.from} durationInFrames={SCENE_COMMAND.duration}>
        <IntroLogo />
      </Sequence>
      {sceneDefinitions.map(({ timing, copy: chapter }) => (
        <Chapter key={timing.from} from={timing.from} duration={timing.duration} copy={chapter} />
      ))}
      <Sequence from={SCENE_PAYOFF.from} durationInFrames={SCENE_PAYOFF.duration}>
        <Payoff first={copy.firstPayoff} second={copy.secondPayoff} />
      </Sequence>
      <Sequence from={SCENE_END.from} durationInFrames={SCENE_END.duration}>
        <EndCard tagline={copy.tagline} />
      </Sequence>
    </AbsoluteFill>
  );
};

export const WIQO_VIDEO_DURATION = DURATION_IN_FRAMES;
export const WIQO_VIDEO_FPS = FPS;
