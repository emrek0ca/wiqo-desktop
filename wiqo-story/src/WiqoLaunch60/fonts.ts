import { loadFont as loadInter } from '@remotion/google-fonts/Inter';
import { loadFont as loadManrope } from '@remotion/google-fonts/Manrope';
import { continueRender, delayRender } from 'remotion';

const fontHandle = delayRender('Wiqo film fontları yükleniyor');
const headlineFont = loadManrope('normal', {
  weights: ['700', '800'],
  subsets: ['latin', 'latin-ext'],
});
const bodyFont = loadInter('normal', {
  weights: ['500'],
  subsets: ['latin', 'latin-ext'],
});

void Promise.all([headlineFont.waitUntilDone(), bodyFont.waitUntilDone()])
  .catch((error: unknown) => {
    console.warn('Wiqo fontları yüklenemedi; sans-serif yedeği kullanılacak.', error);
  })
  .finally(() => continueRender(fontHandle));

export const FONT_FAMILY = {
  headline: headlineFont.fontFamily,
  body: bodyFont.fontFamily,
} as const;
