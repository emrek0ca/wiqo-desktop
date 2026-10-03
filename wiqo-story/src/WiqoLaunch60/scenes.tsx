import React from 'react';
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
import {
  BEATS,
  BRAND_CURSOR_PATH,
  COLORS,
  ASSETS,
  CTA_BEATS,
  COPY,
  DEVICE,
  HOOKS,
  LAYOUT,
  MOTION,
  SAFE_AREA,
  SCENES,
  TYPE,
  type Aspect,
  type HookVariant,
} from './config';
import { FONT_FAMILY } from './fonts';
import {
  AnimatedText,
  Cursor,
  MacWindow,
  MascotFloat,
  NotificationBanner,
  PhoneFrame,
  StepBadges,
} from './components';
import { hasPublicFile, type PublicAvailability } from './media';

export type SceneProps = {
  sourceOffset: number;
  hookVariant: HookVariant;
  availability: PublicAvailability;
  aspect: Aspect;
};

type SceneContext = {
  frame: number;
  fps: number;
  width: number;
  height: number;
  layout: (typeof LAYOUT)[Aspect];
};

const useSceneContext = (sourceOffset: number, aspect: Aspect): SceneContext => {
  const localFrame = useCurrentFrame();
  const { fps, width, height } = useVideoConfig();
  return {
    frame: localFrame + sourceOffset,
    fps,
    width,
    height,
    layout: LAYOUT[aspect],
  };
};

const SceneShell: React.FC<{
  frame: number;
  fps: number;
  duration: number;
  background?: string;
  children: React.ReactNode;
  freezeCameraAfter?: number;
}> = ({
  frame,
  fps,
  duration,
  background = COLORS.white,
  children,
  freezeCameraAfter,
}) => {
  const cameraFrame = freezeCameraAfter === undefined ? frame : Math.min(frame, freezeCameraAfter);
  const cameraScale = interpolate(
    cameraFrame,
    [0, duration],
    [MOTION.cameraPushStart / 100, MOTION.cameraPushEnd / 100],
    {
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
      easing: Easing.inOut(Easing.cubic),
    },
  );

  return (
    <AbsoluteFill style={{ backgroundColor: background, overflow: 'hidden' }}>
      <AbsoluteFill
        style={{
          transform: `scale(${cameraScale})`,
          transformOrigin: '50% 50%',
          overflow: 'visible',
          willChange: 'transform',
        }}
      >
        {children}
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

const lineOpacity = (frame: number, start: number, end: number): number =>
  interpolate(
    frame,
    [start, start + MOTION.enterFrames, end - MOTION.exitFrames, end],
    [0, 1, 1, 0],
    { extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.inOut(Easing.cubic) },
  );

const textPosition = (top: number, left = 0.5): React.CSSProperties => ({
  position: 'absolute',
  left: `${left * 100}%`,
  top: `${top * 100}%`,
  transform: 'translate(-50%, -50%)',
});

export const Scene1Hook: React.FC<SceneProps> = (props) => {
  const { frame, fps, width, height, layout } = useSceneContext(props.sourceOffset, props.aspect);
  const phoneWidth = Math.min(width * 0.48, (height * 0.4) / DEVICE.phoneAspectHeightPerWidth);
  const phoneVisible = frame >= BEATS.hookPhoneAt;
  const hookFrame = Math.max(0, frame);

  return (
    <SceneShell
      frame={frame}
      fps={fps}
      duration={SCENES.hook.to - SCENES.hook.from}
      background={phoneVisible ? COLORS.white : COLORS.ink}
    >
      {!phoneVisible ? (
        <div style={{ ...textPosition(props.aspect === 'landscape' ? 0.43 : 0.47), width: '100%' }}>
          <AnimatedText
            text={HOOKS[props.hookVariant]}
            frame={hookFrame}
            fps={fps}
            color={COLORS.white}
            fontSize={props.aspect === 'landscape' ? TYPE.titleSize * 1.2 : TYPE.heroSize}
            maxWidth={props.aspect === 'landscape' ? '78%' : '86%'}
          />
        </div>
      ) : (
        <>
          <PhoneFrame
            availability={props.availability}
            frame={frame}
            style={{
              left: width / 2,
              top: height * (props.aspect === 'landscape' ? 0.41 : layout.hookPhoneTop),
              width: phoneWidth,
              height: phoneWidth * DEVICE.phoneAspectHeightPerWidth,
              transform: 'translate(-50%, -50%)',
              opacity: interpolate(frame, [BEATS.hookPhoneAt, BEATS.hookPhoneAt + MOTION.enterFrames], [0, 1], {
                extrapolateLeft: 'clamp',
                extrapolateRight: 'clamp',
              }),
            }}
          >
            <div
              style={{
                width: '100%',
                height: '100%',
                display: 'flex',
                flexDirection: 'column',
                alignItems: 'center',
                justifyContent: 'center',
                gap: 10,
                backgroundColor: COLORS.ink,
                color: COLORS.white,
                fontFamily: `${FONT_FAMILY.body}, sans-serif`,
                textAlign: 'center',
              }}
            >
              <span style={{ fontSize: phoneWidth * 0.19, fontWeight: 400, letterSpacing: '-0.06em' }}>
                {COPY.time}
              </span>
              <span style={{ fontSize: phoneWidth * 0.055, fontWeight: TYPE.bodyWeight, opacity: 0.78 }}>
                {COPY.scenarioPlace}
              </span>
            </div>
          </PhoneFrame>
          <div
            style={{
              position: 'absolute',
              left: '50%',
              top: height * (props.aspect === 'landscape' ? 0.87 : 0.82),
              transform: 'translate(-50%, -50%)',
              color: COLORS.ink,
              fontFamily: `${FONT_FAMILY.body}, sans-serif`,
              fontWeight: TYPE.bodyWeight,
              fontSize: TYPE.smallSize,
              opacity: interpolate(frame, [BEATS.hookPhoneAt, BEATS.hookPhoneAt + MOTION.enterFrames], [0, 1], {
                extrapolateLeft: 'clamp',
                extrapolateRight: 'clamp',
              }),
            }}
          >
            {COPY.scenario}
          </div>
        </>
      )}
    </SceneShell>
  );
};

const ScenarioMark: React.FC<{ width: number }> = ({ width }) => (
  <svg width={width} viewBox="0 0 220 110" fill="none" aria-hidden="true">
    <circle cx="48" cy="54" r="37" stroke={COLORS.blue} strokeWidth="3" />
    <path d="M48 31v24l16 9" stroke={COLORS.blue} strokeWidth="3" strokeLinecap="round" />
    <path d="M115 22v65M155 22v65M195 22v65" stroke={COLORS.line} strokeWidth="3" strokeLinecap="round" />
    <path d="M135 22v14m0 12v14m0 12v14M175 22v14m0 12v14m0 12v14" stroke={COLORS.ink} strokeWidth="3" strokeLinecap="round" />
  </svg>
);

export const Scene2Problem: React.FC<SceneProps> = (props) => {
  const { frame, fps, width, height, layout } = useSceneContext(props.sourceOffset, props.aspect);
  const scenarioTop = props.aspect === 'portrait' ? 0.66 : props.aspect === 'square' ? 0.69 : 0.72;

  return (
    <SceneShell
      frame={frame}
      fps={fps}
      duration={SCENES.problem.to - SCENES.problem.from}
    >
      <div style={{ ...textPosition(props.aspect === 'landscape' ? 0.34 : 0.36), width: '100%' }}>
        <AnimatedText
          text={COPY.problem}
          frame={frame}
          fps={fps}
          fontSize={props.aspect === 'landscape' ? TYPE.titleSize : TYPE.heroSize * 0.82}
          maxWidth={props.aspect === 'landscape' ? '74%' : '86%'}
        />
      </div>
      <div
        style={{
          position: 'absolute',
          left: '50%',
          top: `${scenarioTop * 100}%`,
          transform: 'translate(-50%, -50%)',
          display: 'flex',
          flexDirection: props.aspect === 'landscape' ? 'row' : 'column',
          alignItems: 'center',
          gap: 22,
          opacity: lineOpacity(frame, BEATS.scenarioAt, SCENES.problem.to - SCENES.problem.from),
        }}
      >
        <ScenarioMark width={props.aspect === 'landscape' ? 178 : 220} />
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8, textAlign: props.aspect === 'landscape' ? 'left' : 'center' }}>
          <span style={{ color: COLORS.secondary, fontFamily: `${FONT_FAMILY.body}, sans-serif`, fontSize: TYPE.bodySize, fontWeight: TYPE.bodyWeight }}>
            {COPY.scenario}
          </span>
          <span style={{ color: COLORS.ink, fontFamily: `${FONT_FAMILY.body}, sans-serif`, fontSize: TYPE.smallSize, fontWeight: TYPE.bodyWeight }}>
            {COPY.scenarioPlace}
          </span>
        </div>
      </div>
    </SceneShell>
  );
};

export const Scene3Brand: React.FC<SceneProps> = (props) => {
  const { frame, fps, width, height, layout } = useSceneContext(props.sourceOffset, props.aspect);
  const logoWidth = Math.min(width * 0.25, height * 0.19);
  const mascotSize = Math.min(width * (props.aspect === 'landscape' ? 0.15 : 0.26), height * 0.28);
  const horizontal = props.aspect === 'landscape';
  const logoLeft = horizontal ? width * 0.32 : width / 2;
  const mascotLeft = horizontal ? width * 0.72 : width / 2;
  const logoTop = height * layout.brandLogoTop;
  const mascotTop = height * layout.brandMascotTop;
  const titleTop = height * (horizontal ? 0.52 : props.aspect === 'square' ? 0.35 : 0.36);
  const promiseTop = height * (horizontal ? 0.68 : props.aspect === 'square' ? 0.85 : 0.77);
  const logoEntrance = spring({
    frame: Math.max(0, frame - BEATS.brandLogoDelay),
    fps,
    config: { mass: MOTION.mass, damping: MOTION.damping, stiffness: MOTION.stiffness, overshootClamping: true },
  });

  return (
    <SceneShell
      frame={frame}
      fps={fps}
      duration={SCENES.brand.to - SCENES.brand.from}
    >
      <Img
        src={staticFile(ASSETS.logo)}
        style={{
          position: 'absolute',
          left: logoLeft,
          top: logoTop,
          width: logoWidth,
          height: logoWidth,
          objectFit: 'contain',
          opacity: logoEntrance,
          transform: `translate(-50%, -50%) scale(${interpolate(logoEntrance, [0, 1], [0.94, 1])})`,
        }}
      />
      <div style={{ position: 'absolute', left: logoLeft, top: titleTop, transform: 'translate(-50%, -50%)', width: '100%' }}>
        <AnimatedText
          text={COPY.brand}
          frame={Math.max(0, frame - BEATS.brandTitleDelay)}
          fps={fps}
          fontSize={TYPE.titleSize}
          maxWidth={horizontal ? '44%' : '72%'}
        />
      </div>
      <MascotFloat
        name="blue"
        left={mascotLeft}
        top={mascotTop}
        size={mascotSize}
        frame={frame}
        fps={fps}
        delayFrames={BEATS.brandMascotDelay}
        phase={0.42}
      />
      <div style={{ position: 'absolute', left: logoLeft, top: promiseTop, transform: 'translate(-50%, -50%)', width: '100%' }}>
        <AnimatedText
          text={COPY.promise}
          frame={Math.max(0, frame - BEATS.brandPromiseDelay)}
          fps={fps}
          fontSize={TYPE.bodySize * 1.12}
          weight={TYPE.bodyWeight}
          maxWidth={horizontal ? '44%' : '82%'}
          lineHeight={1.25}
        />
      </div>
      <Cursor frame={frame} fps={fps} width={width} height={height} path={BRAND_CURSOR_PATH} />
    </SceneShell>
  );
};

export const Scene4Pdf: React.FC<SceneProps> = (props) => {
  const { frame, fps, width, height, layout } = useSceneContext(props.sourceOffset, props.aspect);
  const phoneWidth = Math.min(
    width * layout.phoneWidth,
    (height * layout.pdfPhoneMaxHeight) / DEVICE.phoneAspectHeightPerWidth,
  );
  const macWidth = Math.min(width * layout.macWidth, (height * layout.pdfMacMaxHeight) / DEVICE.macAspectHeightPerWidth);
  const titleTop = props.aspect === 'landscape' ? height * 0.12 : height * 0.13;
  const stepTop = height * layout.stepTop;
  const sentOpacity = interpolate(
    frame,
    [BEATS.pdfSentFadeFrom, BEATS.pdfSentVisibleFrom, BEATS.pdfSentVisibleUntil, BEATS.pdfSentFadeUntil],
    [0, 1, 1, 0],
    {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.inOut(Easing.cubic),
    },
  );

  return (
    <SceneShell
      frame={frame}
      fps={fps}
      duration={SCENES.pdf.to - SCENES.pdf.from}
    >
      <div style={{ ...textPosition(titleTop / height), width: '100%' }}>
        <AnimatedText text={COPY.pdfTitle} frame={frame} fps={fps} fontSize={TYPE.titleSize} maxWidth="88%" />
      </div>
      <PhoneFrame
        footage="pdfPhone"
        availability={props.availability}
        frame={frame}
        style={{
          left: props.aspect === 'portrait' ? (width - phoneWidth) / 2 : width * layout.pdfPhoneLeft,
          top: height * layout.pdfPhoneTop,
          width: phoneWidth,
          height: phoneWidth * DEVICE.phoneAspectHeightPerWidth,
          transform: 'translateY(0)',
        }}
      />
      <MacWindow
        footage="pdfMac"
        availability={props.availability}
        frame={frame}
        style={{
          left: props.aspect === 'portrait' ? (width - macWidth) / 2 : width * layout.pdfMacLeft,
          top: height * layout.pdfMacTop,
          width: macWidth,
          height: macWidth * DEVICE.macAspectHeightPerWidth,
        }}
      />
      <div
        style={{
          position: 'absolute',
          left: '50%',
          top: stepTop,
          transform: 'translate(-50%, -50%)',
          width: '94%',
        }}
      >
        <StepBadges frame={frame} fps={fps} />
      </div>
      <div
        style={{
          position: 'absolute',
          right: SAFE_AREA.side,
          top: height * 0.38,
          color: COLORS.textSuccess,
          opacity: sentOpacity,
          fontFamily: `${FONT_FAMILY.body}, sans-serif`,
          fontWeight: TYPE.bodyWeight,
          fontSize: TYPE.smallSize,
        }}
      >
        {COPY.pdfSent}
      </div>
    </SceneShell>
  );
};

type TextBeat = { from: number; to: number; text: string };

const SCREENSHOT_BEATS: readonly TextBeat[] = [
  { from: BEATS.screenshotTextBeats[0], to: BEATS.screenshotTextBeats[1], text: COPY.screenshotQuestion },
  { from: BEATS.screenshotTextBeats[1], to: BEATS.screenshotTextBeats[2], text: COPY.screenshotReceived },
  { from: BEATS.screenshotTextBeats[2], to: BEATS.screenshotTextBeats[3], text: COPY.accounts },
  { from: BEATS.screenshotTextBeats[3], to: BEATS.screenshotTextBeats[4], text: COPY.automations },
  { from: BEATS.screenshotTextBeats[4], to: BEATS.screenshotTextBeats[5], text: COPY.menuBar },
];

export const Scene5Screenshot: React.FC<SceneProps> = (props) => {
  const { frame, fps, width, height, layout } = useSceneContext(props.sourceOffset, props.aspect);
  const phoneWidth = Math.min(
    width * layout.screenshotPhoneWidth,
    (height * (props.aspect === 'portrait' ? 0.45 : props.aspect === 'square' ? 0.56 : 0.67)) /
      DEVICE.phoneAspectHeightPerWidth,
  );
  const activeBeat = SCREENSHOT_BEATS.find(({ from, to }) => frame >= from && frame < to);
  const beatFrom = activeBeat?.from ?? 0;
  const beatTo = activeBeat?.to ?? SCENES.screenshot.to - SCENES.screenshot.from;
  const beatText = activeBeat?.text ?? COPY.screenshotQuestion;

  return (
    <SceneShell
      frame={frame}
      fps={fps}
      duration={SCENES.screenshot.to - SCENES.screenshot.from}
    >
      <div
        style={{
          ...textPosition(props.aspect === 'landscape' ? 0.18 : 0.14),
          width: '100%',
          opacity: lineOpacity(frame, beatFrom, beatTo),
        }}
      >
        <AnimatedText
          text={beatText}
          frame={Math.max(0, frame - beatFrom)}
          fps={fps}
          fontSize={props.aspect === 'landscape' ? TYPE.titleSize * 0.8 : TYPE.titleSize * 0.72}
          maxWidth={props.aspect === 'landscape' ? '74%' : '88%'}
          color={COLORS.ink}
        />
        {beatText === COPY.accounts ? (
          <div
            style={{
              position: 'absolute',
              top: '132%',
              left: '50%',
              transform: 'translateX(-50%)',
              color: COLORS.secondary,
              fontFamily: `${FONT_FAMILY.body}, sans-serif`,
              fontSize: TYPE.smallSize,
              fontWeight: TYPE.bodyWeight,
              whiteSpace: 'nowrap',
            }}
          >
            {COPY.accountsDescription}
          </div>
        ) : null}
      </div>
      <PhoneFrame
        footage="screenshotPhone"
        availability={props.availability}
        frame={frame}
        style={{
          left: props.aspect === 'landscape' ? width * 0.24 : width / 2,
          top: height * layout.screenshotPhoneTop,
          width: phoneWidth,
          height: phoneWidth * DEVICE.phoneAspectHeightPerWidth,
          transform: 'translate(-50%, 0)',
        }}
      />
    </SceneShell>
  );
};

export const Scene6LongWork: React.FC<SceneProps> = (props) => {
  const { frame, fps, width, height } = useSceneContext(props.sourceOffset, props.aspect);
  const statusScale = spring({
    frame: Math.max(0, frame - BEATS.notificationDelay),
    fps,
    config: { mass: MOTION.mass, damping: MOTION.damping, stiffness: MOTION.stiffness, overshootClamping: true },
  });

  return (
    <SceneShell
      frame={frame}
      fps={fps}
      duration={SCENES.longWork.to - SCENES.longWork.from}
    >
      <div style={{ ...textPosition(props.aspect === 'landscape' ? 0.22 : 0.23), width: '100%' }}>
        <AnimatedText
          text={COPY.longWork}
          frame={frame}
          fps={fps}
          fontSize={props.aspect === 'landscape' ? TYPE.titleSize : TYPE.titleSize * 0.88}
          maxWidth="86%"
        />
      </div>
      <NotificationBanner frame={frame} fps={fps} />
      <div
        style={{
          position: 'absolute',
          left: '50%',
          top: props.aspect === 'landscape' ? '71%' : '70%',
          transform: `translate(-50%, -50%) translateY(${(1 - statusScale) * MOTION.fadeDistance}px)`,
          display: 'flex',
          alignItems: 'center',
          gap: 12,
          color: COLORS.secondary,
          opacity: statusScale,
          fontFamily: `${FONT_FAMILY.body}, sans-serif`,
          fontWeight: TYPE.bodyWeight,
          fontSize: TYPE.smallSize,
          whiteSpace: 'nowrap',
        }}
      >
        <span style={{ width: 11, height: 11, borderRadius: '50%', backgroundColor: COLORS.purple }} />
        {COPY.menuBarIndicator}
      </div>
    </SceneShell>
  );
};

export const Scene7Trust: React.FC<SceneProps> = (props) => {
  const { frame, fps, width, height, layout } = useSceneContext(props.sourceOffset, props.aspect);
  const phoneWidth = Math.min(
    width * layout.trustPhoneWidth,
    (height * (props.aspect === 'portrait' ? 0.43 : props.aspect === 'square' ? 0.55 : 0.66)) /
      DEVICE.phoneAspectHeightPerWidth,
  );
  const methodOpacity = interpolate(
    frame,
    [BEATS.trustMethodFadeFrom, BEATS.trustMethodVisibleFrom, BEATS.trustMethodVisibleUntil, SCENES.trust.to - SCENES.trust.from],
    [0, 1, 1, 0],
    { extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.inOut(Easing.cubic) },
  );

  return (
    <SceneShell
      frame={frame}
      fps={fps}
      duration={SCENES.trust.to - SCENES.trust.from}
    >
      <div style={{ ...textPosition(props.aspect === 'landscape' ? 0.22 : 0.15), width: '100%' }}>
        <AnimatedText
          text={COPY.trustApproval}
          frame={frame}
          fps={fps}
          fontSize={props.aspect === 'landscape' ? TYPE.titleSize * 0.88 : TYPE.titleSize * 0.78}
          maxWidth="88%"
        />
      </div>
      <PhoneFrame
        footage="approvalPhone"
        availability={props.availability}
        frame={frame}
        style={{
          left: props.aspect === 'landscape' ? width * 0.5 : width / 2,
          top: height * layout.trustPhoneTop,
          width: phoneWidth,
          height: phoneWidth * DEVICE.phoneAspectHeightPerWidth,
          transform: 'translate(-50%, 0)',
        }}
      />
      <div
        style={{
          position: 'absolute',
          left: '50%',
          top: height * (props.aspect === 'landscape' ? 0.81 : 0.73),
          transform: 'translate(-50%, -50%)',
          opacity: methodOpacity,
          display: 'flex',
          flexDirection: props.aspect === 'landscape' ? 'row' : 'column',
          gap: 16,
          alignItems: 'center',
          color: COLORS.secondary,
          fontFamily: `${FONT_FAMILY.body}, sans-serif`,
          fontWeight: TYPE.bodyWeight,
          fontSize: TYPE.bodySize,
          whiteSpace: 'nowrap',
        }}
      >
        <span>{COPY.trustMethod}</span>
        <span style={{ width: 5, height: 5, borderRadius: '50%', backgroundColor: COLORS.blue }} />
        <span>{COPY.trustRecord}</span>
      </div>
    </SceneShell>
  );
};

export const Scene8Cta: React.FC<SceneProps> = (props) => {
  const { frame, fps, width, height, layout } = useSceneContext(props.sourceOffset, props.aspect);
  const logoSize = Math.min(width * 0.23, height * 0.2);
  const mascotSize = Math.min(
    width * (props.aspect === 'landscape' ? 0.14 : props.aspect === 'square' ? 0.16 : 0.2),
    height * (props.aspect === 'landscape' ? 0.18 : 0.21),
  );
  const mascotXs = props.aspect === 'landscape'
    ? [0.21, 0.4, 0.6, 0.79]
    : [0.145, 0.38, 0.62, 0.855];
  const mascotNames = ['blue', 'green', 'orange', 'purple'] as const;
  const freezeAt = MOTION.enterFrames;
  const logoEntrance = spring({
    frame: Math.max(0, frame - CTA_BEATS.logoDelay),
    fps,
    config: { mass: MOTION.mass, damping: MOTION.damping, stiffness: MOTION.stiffness, overshootClamping: true },
  });
  const badgeAvailable = hasPublicFile(props.availability, ASSETS.appStoreBadge);

  return (
    <SceneShell
      frame={frame}
      fps={fps}
      duration={SCENES.cta.to - SCENES.cta.from}
      freezeCameraAfter={SCENES.cta.to - SCENES.cta.from - MOTION.finalSettleFrames}
    >
      <Img
        src={staticFile(ASSETS.logo)}
        style={{
          position: 'absolute',
          left: '50%',
          top: height * layout.ctaLogoTop,
          width: logoSize,
          height: logoSize,
          objectFit: 'contain',
          opacity: logoEntrance,
          transform: `translate(-50%, -50%) scale(${interpolate(logoEntrance, [0, 1], [0.93, 1])})`,
        }}
      />
      <div style={{ ...textPosition(layout.ctaTitleTop), width: '100%' }}>
        <AnimatedText
          text={COPY.finalTitle}
          frame={Math.max(0, frame - CTA_BEATS.titleDelay)}
          fps={fps}
          fontSize={TYPE.heroSize * 0.94}
          maxWidth="86%"
        />
      </div>
      <div style={{ ...textPosition(layout.ctaDescriptionTop), width: '100%' }}>
        <AnimatedText
          text={COPY.finalDescription}
          frame={Math.max(0, frame - CTA_BEATS.descriptionDelay)}
          fps={fps}
          fontSize={TYPE.bodySize * 1.03}
          weight={TYPE.bodyWeight}
          maxWidth="86%"
          lineHeight={1.28}
          letterSpacing="-0.02em"
        />
      </div>
      <div
        style={{
          position: 'absolute',
          left: '50%',
          top: height * layout.ctaAppStoreTop,
          transform: 'translate(-50%, -50%)',
          color: COLORS.ink,
          fontFamily: `${FONT_FAMILY.body}, sans-serif`,
          fontSize: TYPE.bodySize,
          fontWeight: TYPE.bodyWeight,
          whiteSpace: 'nowrap',
        }}
      >
        {badgeAvailable ? (
          <Img src={staticFile(ASSETS.appStoreBadge)} style={{ width: 270, height: 82, objectFit: 'contain' }} />
        ) : (
          COPY.appStore
        )}
      </div>
      {mascotNames.map((name, index) => (
        <MascotFloat
          key={name}
          name={name}
          left={width * mascotXs[index]}
          top={height * layout.ctaMascotTop}
          size={mascotSize}
          frame={frame}
          fps={fps}
          delayFrames={index * BEATS.ctaMascotStagger}
          phase={index * 1.18}
          freezeAt={freezeAt}
        />
      ))}
    </SceneShell>
  );
};
