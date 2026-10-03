import { useEffect, useRef, useState } from 'react';
import { continueRender, delayRender, staticFile } from 'remotion';
import { ASSETS } from './config';

const MEDIA_FILES: readonly string[] = [
  ...Object.values(ASSETS.footage),
  ASSETS.music,
  ...Object.values(ASSETS.sfx),
  ASSETS.appStoreBadge,
];

export type PublicAvailability = Readonly<Record<string, boolean>>;

export const usePublicAvailability = (): PublicAvailability => {
  const [availability, setAvailability] = useState<Record<string, boolean>>({});
  const [handle] = useState(() => delayRender('Wiqo medya dosyaları kontrol ediliyor'));
  const continued = useRef(false);

  useEffect(() => {
    let mounted = true;

    void Promise.all(
      MEDIA_FILES.map(async (file) => {
        try {
          const response = await fetch(staticFile(file), { method: 'HEAD' });
          return [file, response.ok] as const;
        } catch {
          return [file, false] as const;
        }
      }),
    ).then((results) => {
      if (!mounted) return;
      setAvailability(Object.fromEntries(results));
      if (!continued.current) {
        continued.current = true;
        continueRender(handle);
      }
    });

    return () => {
      mounted = false;
    };
  }, [handle]);

  return availability;
};

export const hasPublicFile = (availability: PublicAvailability, file: string): boolean =>
  availability[file] === true;
