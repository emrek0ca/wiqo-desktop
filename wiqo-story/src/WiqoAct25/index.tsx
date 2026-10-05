import React, { useEffect, useState } from 'react';
import '@fontsource/roboto/400.css';
import '@fontsource/roboto/700.css';
import {
  AbsoluteFill, Easing, Img, Sequence, cancelRender, continueRender, delayRender,
  interpolate, spring, staticFile, useCurrentFrame, useVideoConfig,
} from 'remotion';
import {
  ASSETS, COPY, LAYOUT, LETTERS, MASCOT_ORDER, MOTION, POSES, SCENES, STYLE, VIDEO,
  type MascotName, type Pose,
} from './config';

const mix = (a: number, b: number, p: number) => a + (b - a) * p;
const ease = (frame: number, from: number, to: number) => interpolate(frame, [from, to], [0, 1], {
  extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.inOut(Easing.cubic),
});
const settle = (frame: number, fps: number, duration: number = MOTION.textEntry) => spring({
  frame: Math.max(0, frame), fps, durationInFrames: duration, config: MOTION.spring,
});

const RevealedText: React.FC<{
  lines: readonly string[]; x?: number; y: number; size?: number;
  delay?: number; color?: string; center?: boolean;
}> = ({ lines, x = STYLE.side, y, size = STYLE.headline, delay = 0, color = STYLE.ink, center = false }) => {
  const frame = useCurrentFrame();
  const { fps, width } = useVideoConfig();
  let wordIndex = 0;
  return (
    <div style={{
      position: 'absolute', left: center ? STYLE.side : x, top: y,
      width: center ? width - STYLE.side * 2 : width - x - STYLE.side,
      fontSize: size, lineHeight: STYLE.lineHeight, color, textAlign: center ? 'center' : 'left',
      letterSpacing: STYLE.tracking, fontWeight: 400,
    }}>
      {lines.map((line, lineIndex) => (
        <div key={line} style={{ overflow: 'hidden', paddingBottom: '0.13em', marginBottom: '-0.08em', whiteSpace: 'nowrap' }}>
          {line.split(' ').map((word, index) => {
            const start = delay + wordIndex++ * MOTION.wordStagger + lineIndex * MOTION.lineStagger;
            const p = settle(frame - start, fps);
            return (
              <span key={`${word}-${index}`} style={{
                display: 'inline-block', marginRight: index === line.split(' ').length - 1 ? 0 : '0.24em',
                opacity: ease(frame, start, start + MOTION.textEntry / 2),
                transform: `translateY(${(1 - p) * MOTION.textTravel}px)`,
              }}>{word}</span>
            );
          })}
        </div>
      ))}
    </div>
  );
};

const actorPose = (frame: number, fps: number, points: readonly Pose[]): Pose => {
  if (frame < points[0].frame) return { ...points[0], opacity: 0 };
  const nextIndex = points.findIndex((p) => p.frame > frame);
  if (nextIndex < 0) return points[points.length - 1];
  const a = points[nextIndex - 1];
  const b = points[nextIndex];
  const duration = b.frame - a.frame;
  const p = settle(frame - a.frame, fps, duration);
  return {
    frame, x: mix(a.x, b.x, p), y: mix(a.y, b.y, p), size: mix(a.size, b.size, p),
    opacity: mix(a.opacity, b.opacity, ease(frame, a.frame, b.frame)),
    rotation: mix(a.rotation, b.rotation, p),
  };
};

const Mascot: React.FC<{ name: MascotName; phase: number }> = ({ name, phase }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const f = Math.min(frame, MOTION.freeze);
  const p = actorPose(f, fps, POSES[name]);
  const t = f / MOTION.floatPeriod * Math.PI * 2 + phase;
  const floatY = Math.sin(t) * MOTION.floatY;
  const rotation = p.rotation + Math.sin(t * 0.7) * MOTION.floatRotation;
  const breathing = 1 + Math.sin(t * 0.8) * MOTION.breathing;
  return (
    <div style={{ position: 'absolute', left: p.x, top: p.y, width: p.size, height: p.size,
      transform: 'translate(-50%, -50%)', pointerEvents: 'none' }}>
      <Img src={staticFile(ASSETS[name])} style={{ width: '100%', height: '100%', objectFit: 'contain',
        opacity: p.opacity, transform: `translateY(${floatY}px) rotate(${rotation}deg) scale(${breathing})` }} />
    </div>
  );
};

const ChatToAct: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const reorder = ease(frame, LETTERS.reorderFrom, LETTERS.reorderTo);
  const remove = ease(frame, LETTERS.removeFrom, LETTERS.removeTo);
  const arc = Math.sin(reorder * Math.PI) * LETTERS.arc;
  const glyphs = ['C', 'H', 'A', 'T'] as const;
  const approach = ease(frame, LETTERS.cursorFrom, LETTERS.cursorGrab);
  const drag = ease(frame, LETTERS.cursorGrab, LETTERS.cursorRelease);
  const cursorOpacity = ease(frame, LETTERS.cursorFrom, LETTERS.cursorFrom + 4)
    * (1 - ease(frame, LETTERS.cursorRelease, LETTERS.cursorHide));
  const pressed = frame >= LETTERS.cursorGrab && frame < LETTERS.cursorRelease;
  const cursorX = mix(mix(LETTERS.cursorStart.x, LETTERS.cursorTarget.x, approach), LETTERS.cursorEnd.x, drag);
  const cursorY = mix(mix(LETTERS.cursorStart.y, LETTERS.cursorTarget.y, approach), LETTERS.cursorEnd.y, drag);
  return (
    <>
      {glyphs.map((letter, index) => {
        const enter = settle(frame - LETTERS.appear - index * LETTERS.stagger, fps);
        const x = letter === 'H' ? LETTERS.startX.H : mix(LETTERS.startX[letter], LETTERS.endX[letter], reorder);
        const y = letter === 'C' ? -arc : letter === 'A' ? arc : letter === 'H' ? -remove * LETTERS.hTravel : 0;
        return (
          <div key={letter} style={{
            position: 'absolute', left: x - LETTERS.cellWidth / 2, top: LETTERS.top + y,
            width: LETTERS.cellWidth, height: LETTERS.cellHeight, fontSize: LETTERS.size,
            fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center',
            opacity: enter * (letter === 'H' ? 1 - remove : 1),
            transform: `translateY(${(1 - enter) * MOTION.textTravel}px)`,
          }}>{letter}</div>
        );
      })}
      <Img src={staticFile(pressed ? ASSETS.cursorClosed : ASSETS.cursorOpen)} style={{
        position: 'absolute', left: cursorX - LETTERS.cursorSize / 2, top: cursorY - LETTERS.cursorSize / 2,
        width: LETTERS.cursorSize, height: LETTERS.cursorSize, objectFit: 'contain', opacity: cursorOpacity,
        transform: `scale(${pressed ? 0.92 : 1})`,
      }} />
      <RevealedText lines={[COPY.act]} y={LETTERS.subtitleY} size={LETTERS.subtitleSize} center delay={LETTERS.subtitleFrom} />
    </>
  );
};

const Scene: React.FC<{ duration: number; hold: boolean; children: React.ReactNode }> = ({ duration, hold, children }) => {
  const frame = useCurrentFrame();
  const out = hold ? 1 : 1 - ease(frame, duration - MOTION.textExit, duration + MOTION.transition);
  return <AbsoluteFill style={{ opacity: out, transform: `translateY(${-MOTION.textTravel * (1 - out)}px)` }}>{children}</AbsoluteFill>;
};

const Hook = () => <RevealedText lines={COPY.hook} {...LAYOUT.hook} delay={MOTION.hookDelay} />;
const Request = () => <>
  <RevealedText lines={COPY.request} {...LAYOUT.request} />
  <RevealedText lines={COPY.task} {...LAYOUT.task} color={STYLE.secondary} delay={MOTION.requestTaskDelay} />
</>;
const Coding = () => <>
  <RevealedText lines={COPY.coding} {...LAYOUT.coding} />
  <RevealedText lines={COPY.codingBody} {...LAYOUT.codingBody} size={STYLE.body} color={STYLE.secondary} delay={MOTION.codingBodyDelay} />
</>;
const Preview = () => <>
  <RevealedText lines={COPY.preview} {...LAYOUT.preview} />
  <RevealedText lines={COPY.previewBody} {...LAYOUT.previewBody} size={STYLE.body} color={STYLE.secondary} delay={MOTION.previewBodyDelay} />
</>;
const End = () => <>
  <RevealedText lines={[COPY.product]} {...LAYOUT.endTitle} center delay={MOTION.endTitleDelay} />
  <RevealedText lines={COPY.promise} {...LAYOUT.endPromise} center delay={MOTION.endPromiseDelay} />
  <RevealedText lines={[COPY.close]} {...LAYOUT.endClose} center color={STYLE.secondary} delay={MOTION.endCloseDelay} />
</>;

const SCENE_CONTENT = { hook: Hook, request: Request, act: ChatToAct, coding: Coding, preview: Preview, end: End };

export const WiqoAct25: React.FC = () => {
  const [fontHandle] = useState(() => delayRender('Wiqo Act yerel fontları yükleniyor'));
  useEffect(() => {
    void Promise.all([
      document.fonts.load('400 108px Roboto', 'Kod için masaya dönme. ğüşöçİı'),
      document.fonts.load('700 246px Roboto', 'CHAT'),
    ]).then(() => continueRender(fontHandle)).catch((error: unknown) => cancelRender(error));
  }, [fontHandle]);
  return (
    <AbsoluteFill style={{ backgroundColor: STYLE.background, color: STYLE.ink, fontFamily: STYLE.font, overflow: 'hidden' }}>
      {(Object.keys(SCENES) as (keyof typeof SCENES)[]).map((name) => {
        const timing = SCENES[name];
        const duration = timing.to - timing.from;
        const Content = SCENE_CONTENT[name];
        return (
          <Sequence key={name} from={timing.from} durationInFrames={Math.min(duration + MOTION.transition, VIDEO.frames - timing.from)} name={name}>
            <Scene duration={duration} hold={name === 'end'}><Content /></Scene>
          </Sequence>
        );
      })}
      {MASCOT_ORDER.map((name, index) => <Mascot key={name} name={name} phase={index * 1.6} />)}
      <Img src={staticFile(ASSETS.logo)} style={{
        position: 'absolute', left: STYLE.logoX - STYLE.logoSize / 2, top: STYLE.logoY - STYLE.logoSize / 2,
        width: STYLE.logoSize, height: STYLE.logoSize, objectFit: 'contain',
      }} />
    </AbsoluteFill>
  );
};
