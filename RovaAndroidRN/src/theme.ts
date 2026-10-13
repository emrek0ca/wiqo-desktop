import { MD3LightTheme, MD3DarkTheme } from 'react-native-paper';
import { accentColors, useAppearance } from '@/settings/AppearanceProvider';

export const colors = {
  light: {
    canvas: '#FFFFFF',
    surface: '#F2F2F7',
    inset: '#EFEFF4',
    ink: '#0E1F33',
    muted: '#737780',
    line: 'rgba(20, 24, 32, 0.08)',
    accent: '#162638',
    danger: '#D64045',
    onAccent: '#FFFFFF',
  },
  dark: {
    canvas: '#101114',
    surface: '#1C1D22',
    inset: '#292A30',
    ink: '#E8ECF3',
    muted: '#A9ABB2',
    line: 'rgba(255, 255, 255, 0.10)',
    accent: '#C7D4E4',
    danger: '#FFB4AB',
    onAccent: '#17212C',
  },
} as const;

export type WiqoColors = (typeof colors)[keyof typeof colors];

export const md3Theme = { ...MD3LightTheme, roundness: 12, colors: { ...MD3LightTheme.colors, primary: colors.light.accent, onPrimary: colors.light.onAccent, background: colors.light.canvas, surface: colors.light.surface, surfaceVariant: colors.light.inset, outlineVariant: colors.light.line, error: colors.light.danger } };

export const md3DarkTheme = { ...MD3DarkTheme, roundness: 12, colors: { ...MD3DarkTheme.colors, primary: colors.dark.accent, onPrimary: colors.dark.onAccent, background: colors.dark.canvas, surface: colors.dark.surface, surfaceVariant: colors.dark.inset, outlineVariant: colors.dark.line, error: colors.dark.danger } };

export function useWiqoColors(): WiqoColors {
  const { colorScheme, accent } = useAppearance();
  const base = colorScheme === 'dark' ? colors.dark : colors.light;
  return { ...base, accent: accentColors[accent] } as WiqoColors;
}
