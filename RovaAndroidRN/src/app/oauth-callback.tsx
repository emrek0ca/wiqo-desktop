import { useEffect } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';
import { router, useLocalSearchParams } from 'expo-router';
import { useWiqoColors } from '@/theme';

export default function OAuthCallbackScreen() {
  const { status } = useLocalSearchParams<{ status?: string }>();
  const colors = useWiqoColors();
  useEffect(() => { router.replace('/settings'); }, []);
  return <View style={[styles.root, { backgroundColor: colors.canvas }]}><ActivityIndicator color={colors.accent}/><Text style={{ color: colors.muted }}>{status === 'success' ? 'Hesap bağlantısı tamamlandı…' : 'Wiqo’ya dönülüyor…'}</Text></View>;
}

const styles = StyleSheet.create({ root: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 12 } });
