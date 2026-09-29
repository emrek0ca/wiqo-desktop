export const FPS = 60;

export const SCENE_COMMAND = { from: 0, duration: 120 };
export const SCENE_BROWSER = { from: 120, duration: 180 };
export const SCENE_RESEARCH = { from: 300, duration: 180 };
export const SCENE_CLICK = { from: 480, duration: 180 };
export const SCENE_FORMS = { from: 660, duration: 180 };
export const SCENE_DESKTOP = { from: 840, duration: 210 };
export const SCENE_PAYOFF = { from: 1050, duration: 120 };
export const SCENE_END = { from: 1170, duration: 90 };

const scenes = [
  SCENE_COMMAND,
  SCENE_BROWSER,
  SCENE_RESEARCH,
  SCENE_CLICK,
  SCENE_FORMS,
  SCENE_DESKTOP,
  SCENE_PAYOFF,
  SCENE_END,
];

export const DURATION_IN_FRAMES = Math.max(...scenes.map(({ from, duration }) => from + duration));
