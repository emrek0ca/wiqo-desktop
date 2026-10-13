import React, { useEffect, useState } from 'react';
import '@fontsource/roboto/500.css';
import '@fontsource/roboto/600.css';
import '@fontsource/roboto/700.css';
import {
  AbsoluteFill,
  Easing,
  Img,
  Sequence,
  cancelRender,
  continueRender,
  delayRender,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import {
  ASSETS,
  COPY,
  CROPPED_SCREENSHOT,
  LAYOUT,
  LETTERS,
  MASCOTS,
  MONTAGE,
  MOTION,
  SCENES,
  SCREENSHOTS,
  STYLE,
  VIDEO,
  type MascotName,
} from './config';

const clamp = { extrapolateLeft: 'clamp' as const, extrapolateRight: 'clamp' as const };
const ease = (frame: number, from: number, to: number) => interpolate(frame, [from, to], [0, 1], {
  ...clamp,
  easing: Easing.inOut(Easing.cubic),
});
const springTo = (frame: number, fps: number, duration: number = MOTION.enter) => spring({
  frame: Math.max(0, frame),
  fps,
  durationInFrames: duration,
  config: MOTION.spring,
});

const RevealedLines: React.FC<{
  lines: readonly string[];
  y: number;
  size: number;
  body?: boolean;
}> = ({ lines, y, size, body = false }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  let wordNumber = 0;
  return (
    <div style={{
      position: 'absolute',
      top: y,
      left: STYLE.side,
      width: VIDEO.width - STYLE.side * 2,
      color: body ? STYLE.secondary : STYLE.ink,
      textAlign: 'center',
      fontFamily: STYLE.font,
      fontSize: size,
      lineHeight: body ? 1.25 : STYLE.lineHeight,
      fontWeight: body ? 500 : 600,
      letterSpacing: body ? '-0.018em' : '-0.038em',
    }}>
      {lines.map((line, lineIndex) => (
        <div key={`${line}-${lineIndex}`} style={{ overflow: 'hidden', paddingBottom: '0.12em', marginBottom: '-0.08em' }}>
          {line.split(' ').map((word, index, words) => {
            const delay = (body ? 4 : 2) + wordNumber++ * MOTION.textStagger;
            const progress = springTo(frame - delay, fps, body ? 12 : MOTION.enter);
            const opacity = ease(frame, delay, delay + 7);
            return (
              <React.Fragment key={`${word}-${index}`}>
                <span style={{
                  display: 'inline-block',
                  opacity,
                  transform: `translateY(${(1 - progress) * (body ? MOTION.bodyTravel : MOTION.headlineTravel)}px)`,
                }}>{word}</span>
                {index < words.length - 1 ? ' ' : null}
              </React.Fragment>
            );
          })}
        </div>
      ))}
    </div>
  );
};

const Mascot: React.FC<{
  name: MascotName;
  x: number;
  y: number;
  size: number;
  phase: number;
  delay?: number;
}> = ({ name, x, y, size, phase, delay = 3 }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const entry = springTo(frame - delay, fps, 20);
  const floatPhase = frame / 74 * Math.PI * 2 + phase;
  const floatY = Math.sin(floatPhase) * MOTION.mascotFloatY;
  const rotation = Math.sin(floatPhase * 0.68) * MOTION.mascotFloatRotation;
  const breathing = 1 + Math.sin(floatPhase * 0.8) * MOTION.mascotBreathing;
  return (
    <div style={{
      position: 'absolute', left: x, top: y, width: size, height: size,
      transform: `translate(-50%, calc(-50% + ${(1 - entry) * MOTION.mascotTravel}px)) scale(${0.92 + entry * 0.08}) rotate(${rotation}deg)`,
      opacity: ease(frame, delay, delay + 8), pointerEvents: 'none',
    }}>
      <Img src={staticFile(ASSETS[name])} style={{
        width: '100%', height: '100%', objectFit: 'contain',
        transform: `translateY(${floatY}px) scale(${breathing})`,
      }} />
    </div>
  );
};

const MascotForScene: React.FC<{ scene: keyof typeof MASCOTS }> = ({ scene }) => {
  if (scene === 'close') {
    return <>{MASCOTS.close.map((pose, index) => <Mascot key={pose.name} {...pose} delay={index * 5} />)}</>;
  }
  return <Mascot {...MASCOTS[scene]} />;
};

const SceneFrame: React.FC<{
  duration: number;
  children: React.ReactNode;
}> = ({ duration, children }) => {
  const frame = useCurrentFrame();
  const enter = ease(frame, 0, MOTION.transition);
  const leave = ease(frame, duration - MOTION.transition, duration + MOTION.transition);
  const opacity = enter * (1 - leave);
  const y = (1 - enter) * 26 - leave * 18;
  return <AbsoluteFill style={{ opacity, transform: `translateY(${y}px)` }}>{children}</AbsoluteFill>;
};

const ScreenshotFeature: React.FC<{
  kind: keyof typeof SCREENSHOTS;
  duration: number;
}> = ({ kind, duration }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const item = SCREENSHOTS[kind];
  const enter = springTo(frame - 4, fps, MOTION.phoneEnter);
  const focus = springTo(frame - MOTION.focusStart, fps, MOTION.focusDuration);
  const detail = springTo(frame - MOTION.detailStart, fps, MOTION.detailDuration);
  const focusX = interpolate(detail, [0, 1], [item.focus.x, item.detail.x]);
  const focusY = interpolate(detail, [0, 1], [item.focus.y, item.detail.y]);
  const focusZoom = interpolate(focus, [0, 1], [1, item.focus.zoom]);
  const zoom = interpolate(detail, [0, 1], [focusZoom, item.detail.zoom]);
  const exit = ease(frame, duration - MOTION.screenshotExit, duration + MOTION.transition);
  const sourceDisplayWidth = LAYOUT.screenshot.width / (1 - CROPPED_SCREENSHOT.left - CROPPED_SCREENSHOT.right);
  const sourceDisplayHeight = sourceDisplayWidth * CROPPED_SCREENSHOT.sourceHeight / CROPPED_SCREENSHOT.sourceWidth;
  const imageLeft = -sourceDisplayWidth * CROPPED_SCREENSHOT.left;
  const imageTop = -sourceDisplayHeight * CROPPED_SCREENSHOT.top;
  // The PNG is already offset by the crop inside the viewport. Focus coordinates
  // are therefore viewport-relative; adding the source crop offset again shifts
  // the camera and cuts off the target on the left/top.
  const focusPointX = focusX * LAYOUT.screenshot.width;
  const focusPointY = focusY * LAYOUT.screenshot.height;
  const panX = focus * (LAYOUT.screenshot.width / 2 - zoom * focusPointX);
  const panY = focus * (LAYOUT.screenshot.height / 2 - zoom * focusPointY);
  const cardScale = 0.9 + enter * 0.1;
  const phoneX = LAYOUT.screenshot.x;
  const phoneY = LAYOUT.screenshot.y;
  const mascotKind: MascotName = item.mascot;
  return (
    <>
      <RevealedLines lines={item.title} y={LAYOUT.screenshotTitle.y} size={LAYOUT.screenshotTitle.size} />
      <RevealedLines lines={item.body} y={LAYOUT.screenshotBody.y} size={LAYOUT.screenshotBody.size} body />
      <div style={{
        position: 'absolute', left: phoneX - LAYOUT.screenshot.width / 2, top: phoneY - LAYOUT.screenshot.height / 2,
        width: LAYOUT.screenshot.width, height: LAYOUT.screenshot.height,
        overflow: 'hidden', borderRadius: 58, backgroundColor: STYLE.background,
        border: `1px solid ${STYLE.faint}`,
        boxShadow: '0 18px 44px rgba(0, 0, 0, 0.075)',
        opacity: ease(frame, 0, 8) * (1 - exit),
        transform: `translate(${(1 - enter) * item.enterFromX}px, ${(1 - enter) * 92 - exit * 24}px) scale(${cardScale - exit * 0.025}) rotate(${(1 - enter) * item.enterTilt}deg)`,
      }}>
        <div style={{
          position: 'absolute', left: panX, top: panY, width: sourceDisplayWidth, height: sourceDisplayHeight,
          transformOrigin: 'top left', transform: `scale(${zoom})`,
        }}>
          <Img src={staticFile(item.asset)} style={{
            position: 'absolute', width: sourceDisplayWidth, height: sourceDisplayHeight,
            left: imageLeft, top: imageTop, objectFit: 'fill',
          }} />
        </div>
      </div>
      <Mascot name={mascotKind} x={930} y={1245} size={168} phase={kind === 'memory' ? 0.6 : kind === 'code' ? 1.8 : 3.1} />
    </>
  );
};

const MontageTile: React.FC<{
  asset: string;
  index: number;
  direction: number;
  tilt: number;
}> = ({ asset, index, direction, tilt }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const start = 7 + index * MOTION.montageStagger;
  const entry = springTo(frame - start, fps, 22);
  const sourceDisplayWidth = LAYOUT.montage.width / (1 - CROPPED_SCREENSHOT.left - CROPPED_SCREENSHOT.right);
  const sourceDisplayHeight = sourceDisplayWidth * CROPPED_SCREENSHOT.sourceHeight / CROPPED_SCREENSHOT.sourceWidth;
  return (
    <div style={{
      position: 'absolute', left: LAYOUT.montage.centers[index] - LAYOUT.montage.width / 2,
      top: LAYOUT.montage.y - LAYOUT.montage.height / 2,
      width: LAYOUT.montage.width, height: LAYOUT.montage.height,
      overflow: 'hidden', borderRadius: 36, backgroundColor: STYLE.background,
      border: `1px solid ${STYLE.faint}`, boxShadow: '0 18px 44px rgba(0, 0, 0, 0.07)',
      opacity: ease(frame, start, start + 7), zIndex: index === 1 ? 2 : 1,
      transform: `translate(${(1 - entry) * direction * 170}px, ${(1 - entry) * 80}px) scale(${0.82 + entry * 0.18}) rotate(${(1 - entry) * tilt}deg)`,
    }}>
      <Img src={staticFile(asset)} style={{
        position: 'absolute', width: sourceDisplayWidth, height: sourceDisplayHeight,
        left: -sourceDisplayWidth * CROPPED_SCREENSHOT.left,
        top: -sourceDisplayHeight * CROPPED_SCREENSHOT.top,
        objectFit: 'fill',
      }} />
    </div>
  );
};

const Hook = () => (
  <>
    <RevealedLines lines={COPY.hook} y={LAYOUT.hook.y} size={LAYOUT.hook.size} />
    <MascotForScene scene="hook" />
  </>
);

const Explain = () => (
  <>
    <RevealedLines lines={COPY.explainTitle} y={LAYOUT.explainTitle.y} size={LAYOUT.explainTitle.size} />
    <RevealedLines lines={COPY.explainBody} y={LAYOUT.explainBody.y} size={LAYOUT.explainBody.size} body />
    <MascotForScene scene="explain" />
  </>
);

const ChatToAct: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const reorder = ease(frame, LETTERS.reorderFrom, LETTERS.reorderTo);
  const remove = ease(frame, LETTERS.removeFrom, LETTERS.removeTo);
  const arc = Math.sin(reorder * Math.PI) * LETTERS.arc;
  const approach = ease(frame, LETTERS.cursorFrom, LETTERS.cursorGrab);
  const drag = ease(frame, LETTERS.cursorGrab, LETTERS.cursorRelease);
  const cursorOpacity = ease(frame, LETTERS.cursorFrom, LETTERS.cursorFrom + 5)
    * (1 - ease(frame, LETTERS.cursorRelease, LETTERS.cursorHide));
  const pressed = frame >= LETTERS.cursorGrab && frame < LETTERS.cursorRelease;
  const cursorX = LETTERS.cursorStart.x + (LETTERS.cursorTarget.x - LETTERS.cursorStart.x) * approach
    + (LETTERS.cursorEnd.x - LETTERS.cursorTarget.x) * drag;
  const cursorY = LETTERS.cursorStart.y + (LETTERS.cursorTarget.y - LETTERS.cursorStart.y) * approach
    + (LETTERS.cursorEnd.y - LETTERS.cursorTarget.y) * drag;
  const glyphs = ['C', 'H', 'A', 'T'] as const;
  return (
    <>
      {glyphs.map((letter, index) => {
        const enter = springTo(frame - LETTERS.appear - index * LETTERS.stagger, fps);
        const x = letter === 'H' ? LETTERS.startX.H : letter === 'T'
          ? LETTERS.startX.T + (LETTERS.endX.T - LETTERS.startX.T) * reorder
          : letter === 'C'
            ? LETTERS.startX.C + (LETTERS.endX.C - LETTERS.startX.C) * reorder
            : LETTERS.startX.A + (LETTERS.endX.A - LETTERS.startX.A) * reorder;
        const y = letter === 'C' ? -arc : letter === 'A' ? arc : letter === 'H' ? -remove * LETTERS.hTravel : 0;
        return (
          <div key={letter} style={{
            position: 'absolute', left: x - LETTERS.cellWidth / 2, top: LETTERS.top + y,
            width: LETTERS.cellWidth, height: LETTERS.cellHeight, fontSize: LETTERS.size,
            fontFamily: STYLE.font, fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center',
            opacity: enter * (letter === 'H' ? 1 - remove : 1),
            transform: `translateY(${(1 - enter) * 36}px)`,
          }}>{letter}</div>
        );
      })}
      <Img src={staticFile(pressed ? ASSETS.cursorClosed : ASSETS.cursorOpen)} style={{
        position: 'absolute', left: cursorX - LETTERS.cursorSize / 2, top: cursorY - LETTERS.cursorSize / 2,
        width: LETTERS.cursorSize, height: LETTERS.cursorSize, objectFit: 'contain', opacity: cursorOpacity,
        transform: `scale(${pressed ? 0.91 : 1})`,
      }} />
      <RevealedLines lines={COPY.actSubtitle} y={LAYOUT.actSubtitle.y} size={LAYOUT.actSubtitle.size} body />
      <MascotForScene scene="act" />
    </>
  );
};

const Summary: React.FC = () => (
  <>
    <RevealedLines lines={COPY.summaryTitle} y={LAYOUT.summaryTitle.y} size={LAYOUT.summaryTitle.size} />
    <RevealedLines lines={COPY.summaryBody} y={LAYOUT.summaryBody.y} size={LAYOUT.summaryBody.size} body />
    {MONTAGE.map((item, index) => <MontageTile key={item.asset} {...item} index={index} />)}
  </>
);

const Close: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const progress = springTo(frame - 30, fps, 24);
  return (
    <>
      <RevealedLines lines={COPY.closeTitle} y={LAYOUT.closeTitle.y} size={LAYOUT.closeTitle.size} />
      <div style={{
        position: 'absolute', top: LAYOUT.product.y, left: 0, width: VIDEO.width,
        color: STYLE.ink, textAlign: 'center', fontFamily: STYLE.font,
        fontSize: LAYOUT.product.size, fontWeight: 600, letterSpacing: '-0.04em',
        opacity: ease(frame, 24, 42), transform: `translateY(${(1 - progress) * 26}px) scale(${0.98 + progress * 0.02})`,
      }}>{COPY.product}</div>
      <MascotForScene scene="close" />
    </>
  );
};

const SCENE_CONTENT = {
  hook: Hook,
  explain: Explain,
  act: ChatToAct,
  memory: () => <ScreenshotFeature kind="memory" duration={SCENES.memory.to - SCENES.memory.from} />,
  code: () => <ScreenshotFeature kind="code" duration={SCENES.code.to - SCENES.code.from} />,
  voice: () => <ScreenshotFeature kind="voice" duration={SCENES.voice.to - SCENES.voice.from} />,
  summary: Summary,
  close: Close,
} as const;

export const WiqoAct30: React.FC = () => {
  const [fontHandle] = useState(() => delayRender('Loading Roboto for Wiqo Act film'));
  useEffect(() => {
    void Promise.all([
      document.fonts.load('600 82px Roboto', 'What if your next app'),
      document.fonts.load('700 246px Roboto', 'CHAT ACT'),
      document.fonts.load('500 37px Roboto', 'Wiqo builds it on your PC'),
    ]).then(() => continueRender(fontHandle)).catch((error: unknown) => cancelRender(error));
  }, [fontHandle]);

  return (
    <AbsoluteFill style={{
      backgroundColor: STYLE.background,
      color: STYLE.ink,
      fontFamily: STYLE.font,
      overflow: 'hidden',
    }}>
      {(Object.keys(SCENES) as (keyof typeof SCENES)[]).map((name) => {
        const timing = SCENES[name];
        const sceneDuration = timing.to - timing.from;
        const Content = SCENE_CONTENT[name];
        return (
          <Sequence key={name} from={timing.from} durationInFrames={Math.min(sceneDuration + MOTION.transition, VIDEO.frames - timing.from)} name={name}>
            <SceneFrame duration={sceneDuration}><Content /></SceneFrame>
          </Sequence>
        );
      })}
      <Img src={staticFile(ASSETS.logo)} style={{
        position: 'absolute', left: STYLE.logoX - STYLE.logoSize / 2, top: STYLE.logoY - STYLE.logoSize / 2,
        width: STYLE.logoSize, height: STYLE.logoSize, objectFit: 'contain',
      }} />
    </AbsoluteFill>
  );
};
