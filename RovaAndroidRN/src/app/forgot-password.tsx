import * as Haptics from 'expo-haptics';
import { MaterialCommunityIcons } from '@expo/vector-icons';
import { router, useLocalSearchParams } from 'expo-router';
import { useEffect, useRef, useState } from 'react';
import {
  Animated,
  Keyboard,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { AuthApiError } from '@/data/auth-api';
import { authTextStyles, AuthAction, AuthField, InlineError } from '@/components/auth/AuthPrimitives';
import { useAuth } from '@/auth/AuthProvider';
import { useWiqoColors } from '@/theme';

export default function ForgotPasswordScreen() {
  const params = useLocalSearchParams<{ email?: string }>();
  const colors = useWiqoColors();
  const { requestPasswordReset, resetPassword } = useAuth();
  const [email, setEmail] = useState(params.email ?? '');
  const [step, setStep] = useState<'request' | 'reset'>('request');
  const [code, setCode] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  const [cooldown, setCooldown] = useState(0);
  const [emailFocused, setEmailFocused] = useState(false);
  const [passwordFocused, setPasswordFocused] = useState(false);
  const passwordInput = useRef<TextInput>(null);
  const codeInput = useRef<TextInput>(null);
  const [shake] = useState(() => new Animated.Value(0));

  useEffect(() => {
    if (cooldown <= 0) return;
    const timer = setTimeout(() => setCooldown(value => Math.max(value - 1, 0)), 1000);
    return () => clearTimeout(timer);
  }, [cooldown]);

  useEffect(() => {
    if (step !== 'reset') return;
    const timer = setTimeout(() => codeInput.current?.focus(), 350);
    return () => clearTimeout(timer);
  }, [step]);

  const fail = (cause: unknown, fallback: string) => {
    setError(cause instanceof AuthApiError ? cause.message : fallback);
    shake.setValue(0);
    Animated.sequence([0, 1, -1, 0.7, -0.7, 0].map(value =>
      Animated.timing(shake, { toValue: value, duration: 55, useNativeDriver: true }),
    )).start();
    void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error).catch(() => undefined);
  };

  const sendCode = async () => {
    if (!email.trim() || busy) return;
    Keyboard.dismiss();
    setError(null);
    setBusy(true);
    try {
      await requestPasswordReset(email);
      setInfo(`${email.trim()} adresine bir kod gönderildi. Gelmediyse spam/gereksiz klasörünü kontrol et.`);
      setCooldown(30);
      setStep('reset');
    } catch (cause) {
      fail(cause, 'Şifre sıfırlama kodu istenemedi. Lütfen tekrar dene.');
    } finally {
      setBusy(false);
    }
  };

  const completeReset = async () => {
    if (code.length !== 6 || password.length < 8 || busy) return;
    Keyboard.dismiss();
    setError(null);
    setBusy(true);
    try {
      await resetPassword(email, code, password);
      void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => undefined);
      router.replace('/home');
    } catch (cause) {
      fail(cause, 'Şifre sıfırlanamadı. Lütfen tekrar dene.');
    } finally {
      setBusy(false);
    }
  };

  const resend = () => {
    setError(null);
    setCode('');
    setInfo(null);
    setStep('request');
  };

  return (
    <SafeAreaView style={[styles.safe, { backgroundColor: colors.canvas }]} edges={['top', 'bottom']}>
      <KeyboardAvoidingView style={styles.flex} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <View style={[styles.nav, { borderBottomColor: colors.line }]}>
          <Pressable accessibilityRole="button" accessibilityLabel="Kapat" onPress={() => router.back()} style={styles.close}>
            <MaterialCommunityIcons name="chevron-left" size={24} color={colors.accent} />
            <Text style={[styles.closeText, { color: colors.accent }]}>Kapat</Text>
          </Pressable>
          <Text style={[styles.navTitle, { color: colors.ink }]}>Şifremi Unuttum</Text>
          <View style={styles.navRight} />
        </View>
        <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled" showsVerticalScrollIndicator={false}>
          <Animated.View style={[styles.form, { transform: [{ translateX: shake }] }]}>
            {step === 'request' ? (
              <>
                <Text style={[styles.intro, { color: colors.muted }]}>E-posta adresine 6 haneli bir sıfırlama kodu göndereceğiz.</Text>
                <AuthField focused={emailFocused} error={error !== null}>
                  <TextInput
                    value={email}
                    onChangeText={setEmail}
                    placeholder="E-posta"
                    placeholderTextColor={colors.muted}
                    keyboardType="email-address"
                    textContentType="emailAddress"
                    autoComplete="email"
                    autoCapitalize="none"
                    autoCorrect={false}
                    returnKeyType="send"
                    onFocus={() => setEmailFocused(true)}
                    onBlur={() => setEmailFocused(false)}
                    onSubmitEditing={() => void sendCode()}
                    accessibilityLabel="E-posta"
                    style={[authTextStyles.input, { color: colors.ink }]}
                  />
                </AuthField>
                {error && <InlineError message={error} />}
                <AuthAction title="Kod gönder" onPress={() => void sendCode()} busy={busy} disabled={!email.trim()} />
              </>
            ) : (
              <>
                {info && <Text style={[styles.intro, { color: colors.muted }]}>{info}</Text>}
                <Pressable accessibilityLabel="6 haneli sıfırlama kodu" onPress={() => codeInput.current?.focus()} style={styles.otpRow}>
                  {Array.from({ length: 6 }, (_, index) => (
                    <View key={index} style={[styles.otpBox, { backgroundColor: colors.inset, borderColor: error ? `${colors.danger}B3` : colors.line }]}>
                      <Text style={[styles.otpDigit, { color: colors.ink }]}>{code[index] ?? ''}</Text>
                    </View>
                  ))}
                  <TextInput
                    ref={codeInput}
                    value={code}
                    onChangeText={value => setCode(value.replace(/\D/g, '').slice(0, 6))}
                    keyboardType="number-pad"
                    textContentType="oneTimeCode"
                    autoComplete="one-time-code"
                    maxLength={6}
                    accessibilityLabel="6 haneli kod"
                    style={styles.hiddenInput}
                  />
                </Pressable>
                <AuthField focused={passwordFocused} error={false}>
                  <TextInput
                    ref={passwordInput}
                    value={password}
                    onChangeText={setPassword}
                    placeholder="Yeni şifre (en az 8 karakter)"
                    placeholderTextColor={colors.muted}
                    secureTextEntry
                    textContentType="newPassword"
                    autoComplete="new-password"
                    autoCapitalize="none"
                    autoCorrect={false}
                    returnKeyType="go"
                    onFocus={() => setPasswordFocused(true)}
                    onBlur={() => setPasswordFocused(false)}
                    onSubmitEditing={() => void completeReset()}
                    accessibilityLabel="Yeni şifre, en az 8 karakter"
                    style={[authTextStyles.input, { color: colors.ink }]}
                  />
                </AuthField>
                {error && <InlineError message={error} />}
                <AuthAction title="Şifreyi sıfırla" onPress={() => void completeReset()} busy={busy} disabled={code.length !== 6 || password.length < 8} />
                <Pressable accessibilityRole="button" disabled={cooldown > 0} onPress={resend} style={styles.resend}>
                  <Text style={[authTextStyles.muted, { color: colors.muted, opacity: cooldown > 0 ? 0.55 : 1 }]}>
                    {cooldown > 0 ? `Tekrar gönder (${cooldown}sn)` : 'Kodu tekrar gönder'}
                  </Text>
                </Pressable>
              </>
            )}
          </Animated.View>
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: { flex: 1 },
  flex: { flex: 1 },
  nav: { height: 48, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', borderBottomWidth: StyleSheet.hairlineWidth, paddingHorizontal: 12 },
  close: { minWidth: 76, minHeight: 44, flexDirection: 'row', alignItems: 'center' },
  closeText: { fontSize: 15 },
  navTitle: { fontSize: 16, fontWeight: '600' },
  navRight: { width: 76 },
  content: { padding: 20, flexGrow: 1 },
  form: { gap: 16 },
  intro: { fontSize: 15, lineHeight: 21 },
  otpRow: { flexDirection: 'row', gap: 8, justifyContent: 'space-between', position: 'relative' },
  otpBox: { height: 54, flex: 1, borderRadius: 12, borderWidth: StyleSheet.hairlineWidth, alignItems: 'center', justifyContent: 'center' },
  otpDigit: { fontSize: 22, fontWeight: '600' },
  hiddenInput: { position: 'absolute', opacity: 0.01, width: 1, height: 1, bottom: 0, left: '50%' },
  resend: { minHeight: 44, alignItems: 'center', justifyContent: 'center' },
});
