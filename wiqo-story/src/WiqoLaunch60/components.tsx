import React from 'react';
import {
  Audio,
  Easing,
  Img,
  OffthreadVideo,
  Sequence,
  interpolate,
  spring,
  staticFile,
  useVideoConfig,
} from 'remotion';
import { getCaptionAtFrame, musicIsDuckedAtFrame } from './captions';
import {
  AUDIO,
  ASSETS,
  BEATS,
  COLORS,
  COPY,
  DEVICE,
  FOOTAGE,
  MOTION,
  SAFE_AREA,
  SFX_CUES,
  TYPE,
  type Aspect,
  type FootageKey,
  type FocusPoint,
  type HookVariant,
} from './config';
import { FONT_FAMILY } from './fonts';
import { hasPublicFile, type PublicAvailability } from './media';

export const AnimatedText: React.FC<{
  text: string;
  frame: number;
  fps: number;
  color?: string;
  fontSize: number;
  weight?: number;
  align?: 'left' | 'center' | 'right';
  maxWidth?: number | string;
  lineHeight?: number;
  letterSpacing?: string;
  delayFrames?: number;
  style?: React.CSSProperties;
}> = ({
  text,
  frame,
  fps,
  color = COLORS.ink,
  fontSize,
  weight = TYPE.headlineWeight,
  align = 'center',
  maxWidth = '86%',
  lineHeight = TYPE.lineHeight,
  letterSpacing = `${TYPE.tracking}em`,
  delayFrames = 0,
  style,
}) => {
  const words = text.split(' ');
  return (
    <div
      style={{
        width: maxWidth,
        color,
        fontFamily: `${FONT_FAMILY.headline}, sans-serif`,
        fontWeight: weight,
        fontSize,
        lineHeight,
        letterSpacing,
        textAlign: align,
        display: 'flex',
        flexWrap: 'wrap',
        justifyContent: align === 'left' ? 'flex-start' : align === 'right' ? 'flex-end' : 'center',
        columnGap: '0.23em',
        rowGap: '0.04em',
        ...style,
      }}
    >
      {words.map((word, index) => {
        const localFrame = frame - delayFrames - index * MOTION.wordStaggerFrames;
        const progress = spring({
          frame: Math.max(0, localFrame),
          fps,
          config: {
            mass: MOTION.mass,
            damping: MOTION.damping,
            stiffness: MOTION.stiffness,
            overshootClamping: true,
          },
        });
        const opacity = interpolate(progress, [0, 1], [0, 1]);
        const y = interpolate(progress, [0, 1], [MOTION.wordTravel, 0]);

        return (
          <span
            key={`${word}-${index}`}
            style={{
              display: 'inline-block',
              opacity,
              transform: `translate3d(0, ${y}px, 0)`,
              willChange: 'transform, opacity',
            }}
          >
            {word}
          </span>
        );
      })}
    </div>
  );
};

export const MascotFloat: React.FC<{
  name: keyof typeof ASSETS.mascots;
  left: number;
  top: number;
  size: number;
  frame: number;
  fps: number;
  delayFrames?: number;
  phase?: number;
  freezeAt?: number;
}> = ({ name, left, top, size, frame, fps, delayFrames = 0, phase = 0, freezeAt }) => {
  const activeFrame = Math.max(0, frame - delayFrames);
  const entrance = spring({
    frame: activeFrame,
    fps,
    config: {
      mass: MOTION.mass,
      damping: MOTION.damping,
      stiffness: MOTION.stiffness,
      overshootClamping: true,
    },
  });
  const floatFrame = freezeAt === undefined ? activeFrame : Math.min(activeFrame, freezeAt);
  const phaseRadians = (floatFrame / MOTION.mascotFloatPeriodFrames) * Math.PI * 2 + phase;
  const floatY = Math.sin(phaseRadians) * MOTION.mascotFloatAmplitude * entrance;
  const rotate = Math.sin(phaseRadians * 0.52) * 0.7 * entrance;
  const scale = interpolate(entrance, [0, 1], [0.93, 1]);
  const opacity = interpolate(entrance, [0, 1], [0, 1]);

  return (
    <div
      style={{
        position: 'absolute',
        left,
        top,
        width: size,
        height: size,
        transform: 'translate(-50%, -50%)',
        pointerEvents: 'none',
      }}
    >
      <Img
        src={staticFile(ASSETS.mascots[name])}
        style={{
          width: '100%',
          height: '100%',
          objectFit: 'contain',
          opacity,
          transform: `translate3d(0, ${-floatY}px, 0) rotate(${rotate}deg) scale(${scale})`,
          transformOrigin: '50% 50%',
          willChange: 'transform, opacity',
        }}
      />
    </div>
  );
};

export const FocusZoom: React.FC<{
  frame: number;
  points: readonly FocusPoint[];
  children: React.ReactNode;
}> = ({ frame, points, children }) => {
  const ordered = [...points].sort((left, right) => left.frame - right.frame);
  const first = ordered[0];
  const last = ordered[ordered.length - 1];
  let scale = first.scale;
  let x = first.x;
  let y = first.y;

  if (frame >= last.frame) {
    scale = last.scale;
    x = last.x;
    y = last.y;
  } else if (frame > first.frame) {
    const index = ordered.findIndex((point, pointIndex) =>
      pointIndex > 0 && frame <= point.frame,
    );
    const left = ordered[Math.max(0, index - 1)];
    const right = ordered[index];
    const progress = interpolate(frame, [left.frame, right.frame], [0, 1], {
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
      easing: Easing.inOut(Easing.cubic),
    });
    scale = left.scale + (right.scale - left.scale) * progress;
    x = left.x + (right.x - left.x) * progress;
    y = left.y + (right.y - left.y) * progress;
  }

  return (
    <div
      style={{
        width: '100%',
        height: '100%',
        transform: `scale(${scale})`,
        transformOrigin: `${x}% ${y}%`,
        willChange: 'transform',
      }}
    >
      {children}
    </div>
  );
};

const FootageLayer: React.FC<{
  file: string;
  startFrom: number;
  endAt: number;
  speed: number;
  available: boolean;
  displayName: string;
  focus?: readonly FocusPoint[];
  frame: number;
}> = ({ file, startFrom, endAt, speed, available, displayName, focus, frame }) => {
  if (!available) {
    return <MediaPlaceholder file={file} displayName={displayName} />;
  }

  const video = (
    <OffthreadVideo
      src={staticFile(file)}
      startFrom={startFrom}
      endAt={endAt}
      playbackRate={speed}
      muted
      style={{ width: '100%', height: '100%', objectFit: 'contain', backgroundColor: '#111111' }}
    />
  );

  return focus ? (
    <FocusZoom frame={frame} points={focus}>{video}</FocusZoom>
  ) : video;
};

const MediaPlaceholder: React.FC<{ file: string; displayName: string }> = ({ file, displayName }) => (
  <div
    style={{
      width: '100%',
      height: '100%',
      backgroundColor: COLORS.surface,
      border: `1px solid ${COLORS.line}`,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      flexDirection: 'column',
      padding: '5%',
      boxSizing: 'border-box',
      textAlign: 'center',
      color: COLORS.secondary,
      fontFamily: `${FONT_FAMILY.body}, sans-serif`,
      fontWeight: TYPE.bodyWeight,
    }}
  >
    <span style={{ fontSize: TYPE.smallSize, color: COLORS.ink, marginBottom: '0.6em' }}>
      {displayName}
    </span>
    <span style={{ fontSize: TYPE.smallSize * 0.82, lineHeight: 1.35 }}>
      {`${COPY.unknownMediaPrefix} ${file.split('/').pop() ?? file}`}
    </span>
  </div>
);

export const PhoneFrame: React.FC<{
  style: React.CSSProperties;
  availability: PublicAvailability;
  footage?: FootageKey;
  frame: number;
  children?: React.ReactNode;
}> = ({ style, availability, footage, frame, children }) => {
  const footageConfig = footage ? FOOTAGE[footage] : undefined;
  const footageAvailable = footageConfig
    ? hasPublicFile(availability, footageConfig.file)
    : false;

  return (
    <div
      style={{
        position: 'absolute',
        boxSizing: 'border-box',
        border: `${DEVICE.phoneBorder}px solid ${COLORS.ink}`,
        borderRadius: DEVICE.phoneRadius,
        backgroundColor: COLORS.ink,
        padding: DEVICE.phoneBorder,
        overflow: 'hidden',
        boxShadow: '0 12px 34px rgba(11, 11, 15, 0.10)',
        ...style,
      }}
    >
      <div
        style={{
          position: 'absolute',
          inset: DEVICE.phoneBorder,
          overflow: 'hidden',
          borderRadius: DEVICE.phoneInnerRadius,
          backgroundColor: COLORS.white,
        }}
      >
        {footageConfig ? (
          <FootageLayer
            file={footageConfig.file}
            startFrom={footageConfig.trim.startFrom}
            endAt={footageConfig.trim.endAt}
            speed={footageConfig.speed}
            available={footageAvailable}
            displayName={COPY.phoneTitle}
            focus={footageConfig.focus}
            frame={frame}
          />
        ) : children}
      </div>
      <div
        style={{
          position: 'absolute',
          top: DEVICE.phoneBorder + 5,
          left: '50%',
          width: DEVICE.phoneSpeakerWidth,
          height: DEVICE.phoneSpeakerHeight,
          borderRadius: DEVICE.phoneSpeakerHeight,
          transform: 'translateX(-50%)',
          backgroundColor: COLORS.ink,
          opacity: 0.94,
        }}
      />
    </div>
  );
};

export const MacWindow: React.FC<{
  style: React.CSSProperties;
  availability: PublicAvailability;
  footage: FootageKey;
  frame: number;
}> = ({ style, availability, footage, frame }) => {
  const footageConfig = FOOTAGE[footage];
  const footageAvailable = hasPublicFile(availability, footageConfig.file);

  return (
    <div
      style={{
        position: 'absolute',
        boxSizing: 'border-box',
        overflow: 'hidden',
        border: `1px solid ${COLORS.line}`,
        borderRadius: DEVICE.macRadius,
        backgroundColor: COLORS.white,
        boxShadow: '0 14px 36px rgba(11, 11, 15, 0.09)',
        ...style,
      }}
    >
      <div
        style={{
          height: DEVICE.macHeaderHeight,
          borderBottom: `1px solid ${COLORS.line}`,
          display: 'flex',
          alignItems: 'center',
          gap: DEVICE.windowDotSize * 0.55,
          padding: `0 ${DEVICE.windowDotSize}px`,
          boxSizing: 'border-box',
        }}
      >
        {['#FF625A', '#F5BE4F', '#36C759'].map((color, index) => (
          <span
            key={`${color}-${index}`}
            style={{
              width: DEVICE.windowDotSize,
              height: DEVICE.windowDotSize,
              borderRadius: '50%',
              backgroundColor: color,
            }}
          />
        ))}
        <span
          style={{
            position: 'absolute',
            left: '50%',
            transform: 'translateX(-50%)',
            color: COLORS.secondary,
            fontFamily: `${FONT_FAMILY.body}, sans-serif`,
            fontSize: TYPE.smallSize * 0.7,
            fontWeight: TYPE.bodyWeight,
          }}
        >
          {COPY.macTitle}
        </span>
      </div>
      <div style={{ position: 'relative', height: `calc(100% - ${DEVICE.macHeaderHeight}px)`, overflow: 'hidden' }}>
        <FootageLayer
          file={footageConfig.file}
          startFrom={footageConfig.trim.startFrom}
          endAt={footageConfig.trim.endAt}
          speed={footageConfig.speed}
          available={footageAvailable}
          displayName={COPY.macTitle}
          focus={footageConfig.focus}
          frame={frame}
        />
      </div>
    </div>
  );
};

export const Cursor: React.FC<{
  frame: number;
  fps: number;
  width: number;
  height: number;
  path: readonly { frame: number; x: number; y: number; pressed?: boolean }[];
}> = ({ frame, fps, width, height, path }) => {
  const first = path[0];
  const last = path[path.length - 1];
  const currentFrame = Math.min(frame, last.frame);
  const points = path.map((point) => point.frame);
  const xValues = path.map((point) => point.x * width);
  const yValues = path.map((point) => point.y * height);
  const x = interpolate(currentFrame, points, xValues, {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.inOut(Easing.cubic),
  });
  const y = interpolate(currentFrame, points, yValues, {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.inOut(Easing.cubic),
  });
  const pressedPoint = [...path].reverse().find((point) => point.pressed && point.frame <= frame);
  const pressDelta = pressedPoint ? frame - pressedPoint.frame : MOTION.cursorPressFrames;
  const pressProgress = spring({
    frame: Math.max(0, pressDelta),
    fps,
    config: { mass: MOTION.mass, damping: MOTION.damping, stiffness: MOTION.stiffness },
  });
  const pressed = pressedPoint !== undefined && pressDelta < MOTION.cursorPressFrames;
  const image = pressed ? ASSETS.cursorClosed : ASSETS.cursorOpen;
  const opacity = interpolate(frame, [last.frame, last.frame + MOTION.exitFrames], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const pressScale = pressed
    ? interpolate(pressProgress, [0, 1], [1, 0.88])
    : 1;

  if (frame > last.frame + MOTION.exitFrames || frame < first.frame) return null;

  return (
    <Img
      src={staticFile(image)}
      style={{
        position: 'absolute',
        left: x - MOTION.cursorSize / 2,
        top: y - MOTION.cursorSize / 2,
        width: MOTION.cursorSize,
        height: MOTION.cursorSize,
        opacity,
        transform: `scale(${pressScale})`,
        transformOrigin: '50% 50%',
      }}
    />
  );
};

export const StepBadges: React.FC<{ frame: number; fps: number }> = ({ frame, fps }) => {
  return (
    <div style={{ display: 'flex', justifyContent: 'center', alignItems: 'center', gap: 24 }}>
      {COPY.pdfSteps.map((step, index) => {
        const entrance = spring({
          frame: Math.max(0, frame - BEATS.pdfStepFrames[index]),
          fps,
          config: { mass: MOTION.mass, damping: MOTION.damping, stiffness: MOTION.stiffness, overshootClamping: true },
        });
        return (
          <div
            key={step}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 10,
              opacity: entrance,
              transform: `translateY(${(1 - entrance) * MOTION.fadeDistance}px)`,
              color: COLORS.ink,
              fontFamily: `${FONT_FAMILY.body}, sans-serif`,
              fontSize: TYPE.smallSize * 0.82,
              fontWeight: TYPE.bodyWeight,
              whiteSpace: 'nowrap',
            }}
          >
            <span
              style={{
                width: 25,
                height: 25,
                borderRadius: '50%',
                display: 'flex',
                justifyContent: 'center',
                alignItems: 'center',
                backgroundColor: COLORS.success,
                color: COLORS.white,
                fontSize: TYPE.smallSize * 0.62,
                lineHeight: 1,
              }}
            >
              ✓
            </span>
            {step}
          </div>
        );
      })}
    </div>
  );
};

export const NotificationBanner: React.FC<{ frame: number; fps: number }> = ({ frame, fps }) => {
  const entrance = spring({
    frame: Math.max(0, frame - BEATS.notificationDelay),
    fps,
    config: { mass: MOTION.mass, damping: MOTION.damping, stiffness: MOTION.stiffness, overshootClamping: true },
  });
  const opacity = interpolate(
    frame,
    [0, BEATS.notificationDelay, BEATS.notificationVisibleUntil, BEATS.notificationFadeUntil],
    [0, 1, 1, 0],
    {
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
      easing: Easing.inOut(Easing.cubic),
    },
  );

  return (
    <div
      style={{
        position: 'absolute',
        top: '36%',
        left: '50%',
        width: 'min(76%, 760px)',
        padding: '24px 28px',
        display: 'flex',
        alignItems: 'center',
        gap: 22,
        boxSizing: 'border-box',
        border: `1px solid ${COLORS.line}`,
        borderRadius: DEVICE.notificationRadius,
        backgroundColor: COLORS.white,
        boxShadow: '0 14px 38px rgba(11, 11, 15, 0.10)',
        transform: `translate(-50%, ${interpolate(entrance, [0, 1], [-MOTION.fadeDistance * 2, 0])}px) scale(${interpolate(entrance, [0, 1], [0.97, 1])})`,
        opacity,
      }}
    >
      <Img src={staticFile(ASSETS.logo)} style={{ width: 54, height: 54, objectFit: 'contain' }} />
      <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
        <span style={{ color: COLORS.secondary, fontFamily: `${FONT_FAMILY.body}, sans-serif`, fontSize: TYPE.smallSize * 0.82, fontWeight: TYPE.bodyWeight }}>
          {COPY.brand}
        </span>
        <span style={{ color: COLORS.ink, fontFamily: `${FONT_FAMILY.body}, sans-serif`, fontSize: TYPE.bodySize, fontWeight: TYPE.bodyWeight }}>
          {COPY.renderComplete}
        </span>
      </div>
    </div>
  );
};

export const CaptionTrack: React.FC<{
  frame: number;
  hookVariant: HookVariant;
  show: boolean;
  aspect: Aspect;
  height: number;
}> = ({ frame, hookVariant, show, aspect, height }) => {
  if (!show) return null;
  const caption = getCaptionAtFrame(frame, hookVariant);
  if (!caption) return null;

  const localFrame = frame - caption.from;
  const { fps } = useVideoConfig();
  const entrance = spring({
    frame: localFrame,
    fps,
    config: { mass: MOTION.mass, damping: MOTION.damping, stiffness: MOTION.stiffness, overshootClamping: true },
  });
  const leave = interpolate(frame, [caption.to - MOTION.exitFrames, caption.to], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const words = caption.lines.flatMap((line) => line.trim().split(/\s+/));
  const wordIndex = Math.min(words.length - 1, Math.floor((localFrame / Math.max(1, caption.to - caption.from)) * words.length));
  let runningIndex = 0;
  const bottom = Math.max(SAFE_AREA.bottom, height * (aspect === 'portrait' ? 0.115 : 0.12));
  const captionColor = frame < BEATS.hookPhoneAt ? COLORS.white : COLORS.ink;
  const captionAccent = frame < BEATS.hookPhoneAt ? COLORS.textBlueOnDark : caption.accent;

  return (
    <div
      style={{
        position: 'absolute',
        left: SAFE_AREA.side,
        right: SAFE_AREA.side,
        bottom,
        maxWidth: SAFE_AREA.captionMaxWidth,
        marginLeft: 'auto',
        marginRight: 'auto',
        opacity: entrance * leave,
        transform: `translateY(${(1 - entrance) * MOTION.fadeDistance}px)`,
        color: captionColor,
        textAlign: 'center',
        fontFamily: `${FONT_FAMILY.body}, sans-serif`,
        fontSize: TYPE.captionSize,
        fontWeight: TYPE.bodyWeight,
        lineHeight: 1.28,
        letterSpacing: '-0.015em',
      }}
    >
      {caption.lines.map((line, lineIndex) => (
        <div key={`${caption.from}-${lineIndex}`}>
          {line.trim().split(/\s+/).map((word, index) => {
            const isActive = runningIndex === wordIndex;
            runningIndex += 1;
            return (
              <React.Fragment key={`${word}-${index}`}>
                <span style={{ color: isActive ? captionAccent : captionColor }}>{word}</span>
                {index < line.trim().split(/\s+/).length - 1 ? ' ' : ''}
              </React.Fragment>
            );
          })}
        </div>
      ))}
    </div>
  );
};

export const AudioTrack: React.FC<{
  sourceFrom: number;
  duration: number;
  availability: PublicAvailability;
  musicVolume: number;
}> = ({ sourceFrom, duration, availability, musicVolume }) => {
  const musicAvailable = hasPublicFile(availability, ASSETS.music);

  return (
    <>
      {musicAvailable ? (
        <Audio
          src={staticFile(ASSETS.music)}
          loop
          startFrom={sourceFrom}
          endAt={sourceFrom + duration}
          volume={(localFrame) =>
            musicVolume * (musicIsDuckedAtFrame(sourceFrom + localFrame) ? MOTION.musicDuck : 1)
          }
          playbackRate={1}
        />
      ) : null}
      {SFX_CUES.map((cue) => {
        const localFrom = cue.frame - sourceFrom;
        if (localFrom < 0 || localFrom >= duration || !hasPublicFile(availability, cue.file)) {
          return null;
        }
        return (
          <Sequence key={`${cue.file}-${cue.frame}`} from={localFrom} durationInFrames={cue.duration}>
            <Audio src={staticFile(cue.file)} volume={cue.volume * AUDIO.soundEffectVolume} />
          </Sequence>
        );
      })}
    </>
  );
};
