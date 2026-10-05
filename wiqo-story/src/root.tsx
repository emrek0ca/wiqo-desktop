import React from 'react';
import { Composition } from 'remotion';
import { WiqoComputerUseLaunch, WIQO_VIDEO_DURATION, WIQO_VIDEO_FPS } from './WiqoComputerUseLaunch';
import { WiqoAgentsStory } from './story';
import {
  WIQO_BUMPER_DURATION,
  WIQO_LAUNCH_15_DURATION,
  WIQO_LAUNCH_60_DURATION,
  WIQO_LAUNCH_DEFAULTS,
  WiqoLaunchFilm,
} from './WiqoLaunch60';
import { EDITS, VIDEO } from './WiqoLaunch60/config';
import { WiqoAct25 } from './WiqoAct25';
import { VIDEO as ACT_VIDEO } from './WiqoAct25/config';

export const RemotionRoot: React.FC = () => (
  <>
    <Composition
      id="WiqoAct25"
      component={WiqoAct25}
      width={ACT_VIDEO.width}
      height={ACT_VIDEO.height}
      fps={ACT_VIDEO.fps}
      durationInFrames={ACT_VIDEO.frames}
    />
    <Composition
      id="WiqoComputerUseLaunch"
      component={WiqoComputerUseLaunch}
      defaultProps={{ language: 'en' }}
      width={1080}
      height={1920}
      fps={WIQO_VIDEO_FPS}
      durationInFrames={WIQO_VIDEO_DURATION}
    />
    <Composition
      id="WiqoAgentsStory"
      component={WiqoAgentsStory}
      defaultProps={{ language: 'en' }}
      width={1080}
      height={1920}
      fps={30}
      durationInFrames={540}
    />
    <Composition
      id="WiqoLaunch60"
      component={WiqoLaunchFilm}
      defaultProps={WIQO_LAUNCH_DEFAULTS}
      width={VIDEO.portrait.width}
      height={VIDEO.portrait.height}
      fps={VIDEO.fps}
      durationInFrames={WIQO_LAUNCH_60_DURATION}
    />
    <Composition
      id="WiqoLaunch60Square"
      component={WiqoLaunchFilm}
      defaultProps={{ ...WIQO_LAUNCH_DEFAULTS, aspect: 'square' }}
      width={VIDEO.square.width}
      height={VIDEO.square.height}
      fps={VIDEO.fps}
      durationInFrames={WIQO_LAUNCH_60_DURATION}
    />
    <Composition
      id="WiqoLaunch60Landscape"
      component={WiqoLaunchFilm}
      defaultProps={{ ...WIQO_LAUNCH_DEFAULTS, aspect: 'landscape' }}
      width={VIDEO.landscape.width}
      height={VIDEO.landscape.height}
      fps={VIDEO.fps}
      durationInFrames={WIQO_LAUNCH_60_DURATION}
    />
    <Composition
      id="WiqoLaunch15"
      component={WiqoLaunchFilm}
      defaultProps={{ ...WIQO_LAUNCH_DEFAULTS, segments: EDITS.short }}
      width={VIDEO.portrait.width}
      height={VIDEO.portrait.height}
      fps={VIDEO.fps}
      durationInFrames={WIQO_LAUNCH_15_DURATION}
    />
    <Composition
      id="WiqoBumper6"
      component={WiqoLaunchFilm}
      defaultProps={{ ...WIQO_LAUNCH_DEFAULTS, segments: EDITS.bumper }}
      width={VIDEO.portrait.width}
      height={VIDEO.portrait.height}
      fps={VIDEO.fps}
      durationInFrames={WIQO_BUMPER_DURATION}
    />
  </>
);
