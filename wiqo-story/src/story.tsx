import React from 'react';
import '@fontsource/roboto/400.css';
import {
  AbsoluteFill,
  Easing,
  Img,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';

type MascotName = 'blue' | 'orange' | 'green' | 'purple';
export type StoryLanguage = 'en' | 'tr';
export type WiqoAgentsStoryProps = { language?: StoryLanguage };
type Pose = { x: number; y: number; rotation: number };
type SoloStage = {
  name: MascotName;
  start: number;
  exit: number;
  phraseStarts: [number, number, number];
  enterFrom: Pose;
  leaveTo: Pose;
  rotation: number;
  spring: number;
  phase: number;
};

const TIMELINE_SCALE = 1.2;
const scaledFrame = (frame: number) => Math.round(frame * TIMELINE_SCALE);

const assets: Record<MascotName, string> = {
  blue: 'wiqo_blue.png',
  orange: 'wiqo_orange.png',
  green: 'wiqo_green.png',
  purple: 'wiqo_purple.png',
};

const copy: Record<StoryLanguage, {
  intro: string;
  phrases: Record<MascotName, [string, string, string]>;
  finalHeadline: string;
  brand: string;
}> = {
  en: {
    intro: 'Meet your agents.',
    phrases: {
      blue: ['Research the web.', 'Compare the options.', 'Bring back what matters.'],
      orange: ['Analyze.', 'Plan.', 'Solve.'],
      green: ['Write.', 'Build.', 'Get work done.'],
      purple: ['Run tasks.', 'Use tools.', 'Take action.'],
    },
    finalHeadline: 'A new agent for every task.',
    brand: 'Wiqo',
  },
  tr: {
    intro: 'Ajanlarınla tanış.',
    phrases: {
      blue: ["Web'de araştır.", 'Seçenekleri karşılaştır.', 'Önemli olanı getir.'],
      orange: ['Analiz et.', 'Planla.', 'Çöz.'],
      green: ['Yaz.', 'Geliştir.', 'İşleri hallet.'],
      purple: ['Görevleri yürüt.', 'Araçları kullan.', 'Harekete geç.'],
    },
    finalHeadline: 'Her görev için yeni bir ajan.',
    brand: 'Wiqo',
  },
};

const stages: SoloStage[] = [
  {
    name: 'blue',
    start: scaledFrame(60),
    exit: scaledFrame(147),
    phraseStarts: [scaledFrame(63), scaledFrame(90), scaledFrame(117)],
    enterFrom: { x: 540, y: 2080, rotation: -3 },
    leaveTo: { x: 235, y: 1920, rotation: -7 },
    rotation: -0.3,
    spring: 88,
    phase: 0.25,
  },
  {
    name: 'orange',
    start: scaledFrame(150),
    exit: scaledFrame(237),
    phraseStarts: [scaledFrame(153), scaledFrame(180), scaledFrame(207)],
    enterFrom: { x: 1280, y: 1020, rotation: 7 },
    leaveTo: { x: -180, y: 1120, rotation: -6 },
    rotation: 0.3,
    spring: 92,
    phase: 2.05,
  },
  {
    name: 'green',
    start: scaledFrame(240),
    exit: scaledFrame(327),
    phraseStarts: [scaledFrame(243), scaledFrame(270), scaledFrame(297)],
    enterFrom: { x: -190, y: 1380, rotation: -6 },
    leaveTo: { x: 420, y: -260, rotation: 7 },
    rotation: -0.25,
    spring: 82,
    phase: 3.7,
  },
  {
    name: 'purple',
    start: scaledFrame(330),
    exit: scaledFrame(386),
    phraseStarts: [scaledFrame(332), scaledFrame(350), scaledFrame(368)],
    enterFrom: { x: 1210, y: 400, rotation: 6 },
    leaveTo: { x: 870, y: -260, rotation: 9 },
    rotation: 0.4,
    spring: 126,
    phase: 5.25,
  },
];

const mascotOrder: MascotName[] = ['blue', 'orange', 'green', 'purple'];

const eased = (frame: number, start: number, end: number) =>
  interpolate(frame, [start, end], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.inOut(Easing.cubic),
  });

const springProgress = (
  frame: number,
  at: number,
  duration: number,
  fps: number,
  stiffness = 92,
  damping = 22,
) => {
  if (frame <= at) return 0;
  if (frame >= at + duration) return 1;
  return Math.max(0, Math.min(1, spring({
    frame: frame - at,
    fps,
    config: { mass: 0.9, stiffness, damping },
  })));
};

const AnimatedText: React.FC<{
  text: string;
  start: number;
  fadeIn: number;
  holdUntil: number;
  fadeOut: number;
  y: number;
  size: number;
  maxWidth?: number;
}> = ({ text, start, fadeIn, holdUntil, fadeOut, y, size, maxWidth = 980 }) => {
  const frame = useCurrentFrame();
  let opacity = 0;
  if (frame >= start && frame < start + fadeIn) opacity = eased(frame, start, start + fadeIn);
  else if (frame >= start + fadeIn && frame < holdUntil) opacity = 1;
  else if (frame >= holdUntil && frame < fadeOut) opacity = 1 - eased(frame, holdUntil, fadeOut);

  const enter = eased(frame, start, start + fadeIn);
  const exit = eased(frame, holdUntil, fadeOut);
  const translateY = 15 * (1 - enter) - 3 * exit;

  return (
    <div
      style={{
        position: 'absolute',
        top: y,
        left: 0,
        width: '100%',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        color: '#1F1F1F',
        fontFamily: 'Roboto, sans-serif',
        fontSize: size,
        fontWeight: 400,
        lineHeight: 1.2,
        letterSpacing: -1.1,
        whiteSpace: 'nowrap',
        textAlign: 'center',
        maxWidth,
        margin: '0 auto',
        opacity,
        transform: `translateY(${translateY}px)`,
      }}
    >
      {text}
    </div>
  );
};

const Mascot: React.FC<{
  name: MascotName;
  x: number;
  y: number;
  size: number;
  rotation: number;
  scale?: number;
  opacity: number;
}> = ({ name, x, y, size, rotation, scale = 1, opacity }) => (
  <Img
    src={staticFile(assets[name])}
    style={{
      position: 'absolute',
      left: x - size / 2,
      top: y - size / 2,
      width: size,
      height: size,
      objectFit: 'contain',
      opacity,
      transform: `rotate(${rotation}deg) scale(${scale})`,
      transformOrigin: '50% 50%',
      willChange: 'transform, opacity',
    }}
  />
);

const SoloMascot: React.FC<{ stage: SoloStage }> = ({ stage }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const enter = springProgress(frame, stage.start, scaledFrame(26), fps, stage.spring, 22);
  const exit = springProgress(frame, stage.exit, scaledFrame(18), fps, 100, 25);
  const floatingTime = frame / fps;
  const floatX = Math.sin((floatingTime / (3.15 * TIMELINE_SCALE)) * Math.PI * 2 + stage.phase) * 3;
  const floatY = Math.sin((floatingTime / (2.7 * TIMELINE_SCALE)) * Math.PI * 2 + stage.phase) * 5;
  const floatRotation = Math.sin((floatingTime / (4.1 * TIMELINE_SCALE)) * Math.PI * 2 + stage.phase) * 0.65;
  const breath = 1 + Math.sin((floatingTime / (3.6 * TIMELINE_SCALE)) * Math.PI * 2 + stage.phase) * 0.005;
  const entranceOpacity = interpolate(frame, [stage.start, stage.start + scaledFrame(12)], [0, 1], {
    extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.out(Easing.quad),
  });
  const exitOpacity = interpolate(frame, [stage.exit, stage.exit + scaledFrame(12)], [0, 1], {
    extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.inOut(Easing.cubic),
  });

  const homeX = 540;
  const homeY = 1090;
  const entryX = stage.enterFrom.x + (homeX - stage.enterFrom.x) * enter;
  const entryY = stage.enterFrom.y + (homeY - stage.enterFrom.y) * enter;
  const opacity = entranceOpacity * (1 - exitOpacity);
  const rotation = stage.rotation + floatRotation + stage.leaveTo.rotation * exit;
  const scale = breath * (1 + (1 - enter) * 0.025 - exit * 0.025);

  return (
    <Mascot
      name={stage.name}
      x={entryX + (stage.leaveTo.x - homeX) * exit + floatX}
      y={entryY + (stage.leaveTo.y - homeY) * exit + floatY}
      size={430}
      rotation={rotation}
      scale={scale}
      opacity={opacity}
    />
  );
};

const IntroLogo: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const fadeInEnd = scaledFrame(18);
  const holdUntil = scaledFrame(46);
  const fadeOutEnd = scaledFrame(60);
  const fadeIn = interpolate(frame, [0, fadeInEnd], [0, 1], {
    extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic),
  });
  const fadeOut = interpolate(frame, [holdUntil, fadeOutEnd], [1, 0], {
    extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.inOut(Easing.cubic),
  });
  const enter = springProgress(frame, 0, fadeInEnd, fps, 76, 24);

  return (
    <Img
      src={staticFile('w_logo.png')}
      style={{
        position: 'absolute',
        left: 360,
        top: 785,
        width: 360,
        height: 360,
        objectFit: 'contain',
        opacity: fadeIn * fadeOut,
        transform: `translateY(${12 * (1 - enter)}px) scale(${0.985 + enter * 0.015})`,
        transformOrigin: '50% 50%',
      }}
    />
  );
};

const FinalLogo: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const start = scaledFrame(390);
  const opacity = interpolate(frame, [start, start + scaledFrame(18)], [0, 1], {
    extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic),
  });
  const enter = springProgress(frame, start, scaledFrame(24), fps, 80, 24);
  return (
    <Img
      src={staticFile('w_logo.png')}
      style={{
        position: 'absolute',
        left: 300,
        top: 360,
        width: 480,
        height: 480,
        objectFit: 'contain',
        opacity,
        transform: `translateY(${12 * (1 - enter)}px) scale(${0.985 + enter * 0.015})`,
        transformOrigin: '50% 50%',
      }}
    />
  );
};

const FinalCard: React.FC<{ headline: string; brand: string }> = ({ headline, brand }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const start = scaledFrame(390);
  const opacity = interpolate(frame, [start, start + scaledFrame(18)], [0, 1], {
    extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic),
  });
  const enter = springProgress(frame, start, scaledFrame(24), fps, 80, 24);

  return (
    <div
      style={{
        position: 'absolute',
        inset: 0,
        color: '#1F1F1F',
        fontFamily: 'Roboto, sans-serif',
        fontWeight: 400,
        textAlign: 'center',
        opacity,
        transform: `translateY(${10 * (1 - enter)}px)`,
      }}
    >
      <div style={{ position: 'absolute', top: 758, left: 40, width: 1000, fontSize: 62, lineHeight: 1.18, letterSpacing: -1.1, whiteSpace: 'nowrap' }}>
        {headline}
      </div>
      <div style={{ position: 'absolute', top: 866, left: 0, width: '100%', fontSize: 46, lineHeight: 1.2, letterSpacing: -0.8 }}>
        {brand}
      </div>
    </div>
  );
};

const FinalMascot: React.FC<{ name: MascotName; order: number }> = ({ name, order }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const start = scaledFrame(390) + order * scaledFrame(3);
  const enter = springProgress(frame, start, scaledFrame(25), fps, 82, 23);
  const phase = order * 1.55 + 0.3;
  const float = Math.sin((frame / fps / (3.1 * TIMELINE_SCALE)) * Math.PI * 2 + phase) * 3.2;
  const opacity = interpolate(frame, [start, start + scaledFrame(9)], [0, 1], {
    extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.out(Easing.quad),
  });
  const y = 2000 + (1380 - 2000) * enter + float;

  return (
    <Mascot
      name={name}
      x={150 + order * 260}
      y={y}
      size={266}
      rotation={Math.sin((frame / fps / (4.1 * TIMELINE_SCALE)) * Math.PI * 2 + phase) * 0.55}
      scale={1 + Math.sin((frame / fps / (3.7 * TIMELINE_SCALE)) * Math.PI * 2 + phase) * 0.004}
      opacity={opacity}
    />
  );
};

export const WiqoAgentsStory: React.FC<WiqoAgentsStoryProps> = ({ language = 'en' }) => {
  const messages = copy[language];

  return (
    <AbsoluteFill style={{ backgroundColor: '#FFFFFF', overflow: 'hidden' }}>
      <AnimatedText text={messages.intro} start={0} fadeIn={scaledFrame(18)} holdUntil={scaledFrame(46)} fadeOut={scaledFrame(60)} y={770} size={66} />
      <IntroLogo />

      {stages.map((stage) => (
        <React.Fragment key={stage.name}>
          <SoloMascot stage={stage} />
          {messages.phrases[stage.name].map((text, index) => {
            const cue = stage.phraseStarts[index];
            const isFastScene = stage.name === 'purple';
            const window = {
              start: cue,
              fadeIn: scaledFrame(isFastScene ? 5 : 6),
              hold: cue + scaledFrame(isFastScene ? 14 : 18),
              end: cue + scaledFrame(isFastScene ? 19 : 24),
            };
            return (
              <AnimatedText
                key={`${stage.name}-${index}`}
                text={text}
                start={window.start}
                fadeIn={window.fadeIn}
                holdUntil={window.hold}
                fadeOut={window.end}
                y={690}
                size={62}
              />
            );
          })}
        </React.Fragment>
      ))}

      <FinalLogo />
      <FinalCard headline={messages.finalHeadline} brand={messages.brand} />
      {mascotOrder.map((name, order) => <FinalMascot key={`final-${name}`} name={name} order={order} />)}
    </AbsoluteFill>
  );
};
