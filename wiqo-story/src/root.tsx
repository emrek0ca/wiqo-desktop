import React from 'react';
import { Composition } from 'remotion';
import { WiqoAgentsStory } from './story';

export const RemotionRoot: React.FC = () => (
  <Composition
    id="WiqoAgentsStory"
    component={WiqoAgentsStory}
    defaultProps={{ language: 'en' }}
    width={1080}
    height={1920}
    fps={30}
    durationInFrames={540}
  />
);
