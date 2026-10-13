import { Redirect } from 'expo-router';
import { ActivityIndicator, StyleSheet, View } from 'react-native';
import { useAuth } from '@/auth/AuthProvider';
import { AuthScreen } from '@/components/auth/AuthScreen';
import { useWiqoColors } from '@/theme';

export default function HomeScreen() {
  const { token, ready } = useAuth();
  const colors = useWiqoColors();
  if (!ready) return <View style={[styles.loading, { backgroundColor: colors.canvas }]}><ActivityIndicator color={colors.accent} /></View>;
  if (token) return <Redirect href="/home" />;
  return <AuthScreen />;
}

const styles = StyleSheet.create({ loading: { flex: 1, alignItems: 'center', justifyContent: 'center' } });
