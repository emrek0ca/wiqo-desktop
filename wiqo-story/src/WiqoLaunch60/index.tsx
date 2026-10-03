import React from 'react';
import {
  AbsoluteFill,
  Easing,
  Sequence,
  interpolate,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import { AudioTrack, CaptionTrack } from './components';
import {
  AUDIO,
  COLORS,
  EDITS,
  MOTION,
  OUTPUTS,
  SCENES,
  VIDEO,
  type Aspect,
  type HookVariant,
  type SceneKey,
} from './config';
import { usePublicAvailability, type PublicAvailability } from './media';
import {
  Scene1Hook,
  Scene2Problem,
  Scene3Brand,
  Scene4Pdf,
  Scene5Screenshot,
  Scene6LongWork,
  Scene7Trust,
  Scene8Cta,
  type SceneProps,
} from './scenes';

export type EditSegment = {
  sourceFrom: number;
  duration: number;
  outputFrom: number;
};

export type WiqoLaunchProps = {
  aspect: Aspect;
  hookVariant: HookVariant;
  showCaptions: boolean;
  musicVolume: number;
  segments: readonly EditSegment[];
};

const SCENE_COMPONENTS: Record<SceneKey, React.FC<SceneProps>> = {
  hook: Scene1Hook,
  problem: Scene2Problem,
  brand: Scene3Brand,
  pdf: Scene4Pdf,
  screenshot: Scene5Screenshot,
  longWork: Scene6LongWork,
  trust: Scene7Trust,
  cta: Scene8Cta,
};

const sceneKeys = Object.keys(SCENES) as SceneKey[];

const transitionFramesFor = (key: SceneKey): number =>
  key === 'hook' || key === 'problem' ? 0 : MOTION.transitionFrames;

const SceneLayer: React.FC<{
  sceneKey: SceneKey;
  sourceOffset: number;
  hookVariant: HookVariant;
  availability: PublicAvailability;
  aspect: Aspect;
  duration: number;
}> = ({ sceneKey, sourceOffset, hookVariant, availability, aspect, duration }) => {
  const localFrame = useCurrentFrame() + sourceOffset;
  const { fps, width, height } = useVideoConfig();
  const scene = SCENES[sceneKey];
  const entryFrames = transitionFramesFor(sceneKey);
  const sceneIndex = sceneKeys.indexOf(sceneKey);
  const hasNextScene = sceneIndex < sceneKeys.length - 1;
  const exitFrames = hasNextScene ? transitionFramesFor(sceneKeys[sceneIndex + 1]) : 0;
  const enterOpacity = entryFrames === 0
    ? 1
    : interpolate(localFrame, [0, entryFrames], [0, 1], {
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
      easing: Easing.inOut(Easing.cubic),
    });
  const exitOpacity = exitFrames === 0
    ? 1
    : interpolate(
      localFrame,
      [duration - exitFrames, duration + exitFrames],
      [1, 0],
      { extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.inOut(Easing.cubic) },
    );

  const Component = SCENE_COMPONENTS[sceneKey];
  return (
    <AbsoluteFill style={{ opacity: enterOpacity * exitOpacity }}>
      <Component
        sourceOffset={sourceOffset}
        hookVariant={hookVariant}
        availability={availability}
        aspect={aspect}
      />
    </AbsoluteFill>
  );
};

const MappedSegment: React.FC<{
  segment: EditSegment;
  hookVariant: HookVariant;
  showCaptions: boolean;
  availability: PublicAvailability;
  aspect: Aspect;
  musicVolume: number;
}> = ({ segment, hookVariant, showCaptions, availability, aspect, musicVolume }) => {
  const localFrame = useCurrentFrame();
  const { height } = useVideoConfig();
  const segmentEnd = segment.sourceFrom + segment.duration;

  return (
    <AbsoluteFill style={{ backgroundColor: COLORS.white }}>
      {sceneKeys.map((sceneKey, index) => {
        const scene = SCENES[sceneKey];
        const duration = scene.to - scene.from;
        const hasNextScene = index < sceneKeys.length - 1;
        const exitExtension = hasNextScene ? transitionFramesFor(sceneKeys[index + 1]) : 0;
        const sourceStart = Math.max(segment.sourceFrom, scene.from);
        const sourceEnd = Math.min(segmentEnd, scene.to + exitExtension);
        if (sourceEnd <= sourceStart) return null;

        const sequenceFrom = sourceStart - segment.sourceFrom;
        const sourceOffset = sourceStart - scene.from;
        const sceneVisibleDuration = sourceEnd - sourceStart;

        return (
          <Sequence
            key={`${sceneKey}-${segment.outputFrom}-${sourceStart}`}
            from={sequenceFrom}
            durationInFrames={sceneVisibleDuration}
            name={`Wiqo ${scene.title}`}
          >
            <SceneLayer
              sceneKey={sceneKey}
              sourceOffset={sourceOffset}
              hookVariant={hookVariant}
              availability={availability}
              aspect={aspect}
              duration={duration}
            />
          </Sequence>
        );
      })}
      <CaptionTrack
        frame={segment.sourceFrom + localFrame}
        hookVariant={hookVariant}
        show={showCaptions}
        aspect={aspect}
        height={height}
      />
      <AudioTrack
        sourceFrom={segment.sourceFrom}
        duration={segment.duration}
        availability={availability}
        musicVolume={musicVolume}
      />
    </AbsoluteFill>
  );
};

export const WiqoLaunchFilm: React.FC<WiqoLaunchProps> = ({
  aspect,
  hookVariant,
  showCaptions,
  musicVolume,
  segments,
}) => {
  const availability = usePublicAvailability();
  return (
    <AbsoluteFill style={{ backgroundColor: COLORS.white }}>
      {segments.map((segment) => (
        <Sequence
          key={`${segment.sourceFrom}-${segment.outputFrom}`}
          from={segment.outputFrom}
          durationInFrames={segment.duration}
          name={`Kaynak ${segment.sourceFrom}`}
        >
          <MappedSegment
            segment={segment}
            hookVariant={hookVariant}
            showCaptions={showCaptions}
            availability={availability}
            aspect={aspect}
            musicVolume={musicVolume}
          />
        </Sequence>
      ))}
    </AbsoluteFill>
  );
};

export const WIQO_LAUNCH_DEFAULTS = {
  aspect: 'portrait' as const,
  hookVariant: 0 as const,
  showCaptions: true,
  musicVolume: AUDIO.defaultMusicVolume,
  segments: EDITS.main,
};

export const WIQO_LAUNCH_60_DURATION = VIDEO.durationInFrames;
export const WIQO_LAUNCH_15_DURATION = OUTPUTS.shortDuration;
export const WIQO_BUMPER_DURATION = OUTPUTS.bumperDuration;
