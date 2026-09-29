import React from 'react';
import { Composition } from 'remotion';
import { WiqoComputerUseLaunch, WIQO_VIDEO_DURATION, WIQO_VIDEO_FPS } from './WiqoComputerUseLaunch';
import { WiqoAgentsStory } from './story';

export const RemotionRoot: React.FC = () => (
  <>
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
  </>
);
