import * as SecureStore from 'expo-secure-store';
import { createContext, PropsWithChildren, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { useColorScheme } from 'react-native';

export type AppearanceMode = 'system' | 'light' | 'dark';
export type AccentName = 'wiqo' | 'sage' | 'clay' | 'mustard' | 'rose' | 'plum';
export type TextScale = 'small' | 'standard' | 'large';
type Preferences = { mode: AppearanceMode; accent: AccentName; textScale: TextScale; speakReplies: boolean };
const KEY = 'wiqo-appearance-preferences-v1';
const defaults: Preferences = { mode: 'system', accent: 'sage', textScale: 'standard', speakReplies: true };
type ContextValue = Preferences & { ready: boolean; colorScheme: 'light' | 'dark'; setPreference: <K extends keyof Preferences>(key: K, value: Preferences[K]) => void };
const Context = createContext<ContextValue | null>(null);

export const accentColors: Record<AccentName, string> = { wiqo: '#162638', sage: '#5C7A67', clay: '#AB5E47', mustard: '#AB802E', rose: '#AD6B78', plum: '#735580' };

export function AppearanceProvider({ children }: PropsWithChildren) {
  const system = useColorScheme();
  const [preferences, setPreferences] = useState(defaults);
  const [ready, setReady] = useState(false);
  useEffect(() => {
    let active = true;
    SecureStore.getItemAsync(KEY).then(raw => {
      if (!raw || !active) return;
      try {
        const value = JSON.parse(raw) as Partial<Preferences>;
        setPreferences({ ...defaults, ...value });
      } catch { /* Keep safe defaults if the stored value is malformed. */ }
    }).catch(() => undefined).finally(() => { if (active) setReady(true); });
    return () => { active = false; };
  }, []);
  const setPreference = useCallback(<K extends keyof Preferences>(key: K, value: Preferences[K]) => {
    setPreferences(current => {
      const next = { ...current, [key]: value };
      void SecureStore.setItemAsync(KEY, JSON.stringify(next)).catch(() => undefined);
      return next;
    });
  }, []);
  const colorScheme = preferences.mode === 'system' ? (system === 'dark' ? 'dark' : 'light') : preferences.mode;
  const value = useMemo(() => ({ ...preferences, ready, colorScheme, setPreference }), [preferences, ready, colorScheme, setPreference]);
  return <Context.Provider value={value}>{children}</Context.Provider>;
}

export function useAppearance() {
  const value = useContext(Context);
  if (!value) throw new Error('useAppearance must be used within AppearanceProvider');
  return value;
}

