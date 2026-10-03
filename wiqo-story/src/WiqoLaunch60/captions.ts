import {
  AUDIO,
  CAPTION_FRAMES,
  COLORS,
  COPY,
  HOOK_CAPTION_LINES,
  SCENES,
  type HookVariant,
} from './config';

export const CAPTION_CUES = [
  { from: SCENES.hook.from, to: SCENES.hook.to, key: 'hook', accent: COLORS.textBlue },
  { from: SCENES.problem.from, to: CAPTION_FRAMES.problemFirstEnd, key: 'problemFirst', accent: COLORS.textBlue },
  { from: CAPTION_FRAMES.problemFirstEnd, to: SCENES.problem.to, key: 'problemSecond', accent: COLORS.textBlue },
  { from: SCENES.brand.from, to: SCENES.brand.to, key: 'promise', accent: COLORS.textBlue },
  { from: SCENES.pdf.from, to: CAPTION_FRAMES.pdfRequestEnd, key: 'pdfRequest', accent: COLORS.textOrange },
  { from: CAPTION_FRAMES.pdfRequestEnd, to: CAPTION_FRAMES.pdfTitleEnd, key: 'pdfTitle', accent: COLORS.textOrange },
  { from: CAPTION_FRAMES.pdfTitleEnd, to: SCENES.pdf.to, key: 'pdfSent', accent: COLORS.textOrange },
  { from: SCENES.screenshot.from, to: CAPTION_FRAMES.screenshotQuestionEnd, key: 'screenshotQuestion', accent: COLORS.textGreen },
  { from: CAPTION_FRAMES.screenshotQuestionEnd, to: CAPTION_FRAMES.screenshotReceivedEnd, key: 'screenshotReceived', accent: COLORS.textGreen },
  { from: CAPTION_FRAMES.screenshotReceivedEnd, to: CAPTION_FRAMES.screenshotAccountsEnd, key: 'accounts', accent: COLORS.textGreen },
  { from: CAPTION_FRAMES.screenshotAccountsEnd, to: CAPTION_FRAMES.screenshotAutomationsEnd, key: 'automations', accent: COLORS.textGreen },
  { from: CAPTION_FRAMES.screenshotAutomationsEnd, to: SCENES.screenshot.to, key: 'menuBar', accent: COLORS.textGreen },
  { from: SCENES.longWork.from, to: CAPTION_FRAMES.longWorkEnd, key: 'longWork', accent: COLORS.textPurple },
  { from: CAPTION_FRAMES.longWorkEnd, to: CAPTION_FRAMES.renderCompleteEnd, key: 'renderComplete', accent: COLORS.textPurple },
  { from: CAPTION_FRAMES.renderCompleteEnd, to: SCENES.longWork.to, key: 'menuBar', accent: COLORS.textPurple },
  { from: SCENES.trust.from, to: CAPTION_FRAMES.trustApprovalEnd, key: 'trustApproval', accent: COLORS.textBlue },
  { from: CAPTION_FRAMES.trustApprovalEnd, to: CAPTION_FRAMES.trustMethodEnd, key: 'trustMethod', accent: COLORS.textBlue },
  { from: CAPTION_FRAMES.trustMethodEnd, to: SCENES.trust.to, key: 'trustRecord', accent: COLORS.textBlue },
  { from: SCENES.cta.from, to: CAPTION_FRAMES.finalCaptionEnd, key: 'finalDescription', accent: COLORS.textBlue },
] as const;

export type ActiveCaption = {
  from: number;
  to: number;
  lines: readonly string[];
  accent: string;
};

export const getCaptionAtFrame = (
  frame: number,
  hookVariant: HookVariant,
): ActiveCaption | null => {
  const cue = CAPTION_CUES.find(({ from, to }) => frame >= from && frame < to);
  if (!cue) return null;

  const lines = cue.key === 'hook'
    ? HOOK_CAPTION_LINES[hookVariant]
    : COPY.captionLines[cue.key];

  return { from: cue.from, to: cue.to, lines, accent: cue.accent };
};

export const musicIsDuckedAtFrame = (frame: number): boolean =>
  CAPTION_CUES.some(({ from, to }) =>
    frame >= from - AUDIO.duckWindowBeforeFrames &&
    frame <= to + AUDIO.duckWindowAfterFrames,
  );
