import { PropsWithChildren } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';
import { useWiqoColors } from '@/theme';

export function AuthField({ children, focused = false, error = false }: PropsWithChildren<{ focused?: boolean; error?: boolean }>) {
  const colors = useWiqoColors();
  return (
    <View style={[styles.field, { backgroundColor: colors.inset, borderColor: error ? `${colors.danger}B3` : focused ? `${colors.accent}80` : 'transparent' }]}>
      {children}
    </View>
  );
}

export function AuthAction({ title, onPress, busy = false, disabled = false }: { title: string; onPress: () => void; busy?: boolean; disabled?: boolean }) {
  const colors = useWiqoColors();
  return (
    <Pressable
      accessibilityRole="button"
      disabled={disabled || busy}
      onPress={onPress}
      android_ripple={{ color: colors.onAccent === '#FFFFFF' ? 'rgba(255,255,255,0.18)' : 'rgba(0,0,0,0.12)', borderless: false }}
      style={({ pressed }) => [styles.action, { backgroundColor: colors.accent, opacity: disabled ? 0.48 : pressed ? 0.86 : 1, transform: [{ scale: pressed ? 0.98 : 1 }] }]}
    >
      {busy ? <ActivityIndicator color={colors.onAccent} /> : <Text style={[styles.actionText, { color: colors.onAccent }]}>{title}</Text>}
    </Pressable>
  );
}

export function InlineError({ message }: { message: string }) {
  const colors = useWiqoColors();
  return <Text accessibilityRole="alert" style={[styles.error, { color: colors.danger }]}>{message}</Text>;
}

export const authTextStyles = StyleSheet.create({
  input: { flex: 1, minHeight: 48, paddingHorizontal: 0, paddingVertical: 0, fontSize: 16 },
  helper: { fontSize: 12, lineHeight: 17 },
  muted: { fontSize: 13 },
});

const styles = StyleSheet.create({
  field: { minHeight: 48, paddingHorizontal: 14, borderRadius: 12, borderWidth: 1.5, flexDirection: 'row', alignItems: 'center' },
  action: { minHeight: 44, borderRadius: 999, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 16, overflow: 'hidden' },
  actionText: { fontSize: 15, fontWeight: '600' },
  error: { fontSize: 13, lineHeight: 18 },
});
