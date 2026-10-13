import { router } from 'expo-router';
import * as Haptics from 'expo-haptics';
import { LinearGradient } from 'expo-linear-gradient';
import { MaterialCommunityIcons } from '@expo/vector-icons';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  AccessibilityInfo,
  Animated,
  Image,
  Keyboard,
  KeyboardAvoidingView,
  Linking,
  LayoutAnimation,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  UIManager,
  View,
  useWindowDimensions,
  useColorScheme,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useAuth } from '@/auth/AuthProvider';
import { AuthApiError } from '@/data/auth-api';
import { authTextStyles, AuthAction, AuthField, InlineError } from '@/components/auth/AuthPrimitives';
import { useWiqoColors } from '@/theme';

const MARK = require('../../../assets/wiqo/mark.png');
const MARK_DARK = require('../../../assets/wiqo/mark-dark.png');
const BACKGROUND = require('../../../assets/wiqo/login-background.png');
const PRIVACY_URL = 'https://wiqoai.com/privacy';
const TERMS_URL = 'https://wiqoai.com/terms';

export function AuthScreen() {
  const { login, register } = useAuth();
  const colors = useWiqoColors();
  const insets = useSafeAreaInsets();
  const scheme = useColorScheme();
  const { height } = useWindowDimensions();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [inviteCode, setInviteCode] = useState('');
  const [registering, setRegistering] = useState(false);
  const [showPassword, setShowPassword] = useState(false);
  const [acceptedPrivacy, setAcceptedPrivacy] = useState(false);
  const [acceptedTerms, setAcceptedTerms] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [emailFocused, setEmailFocused] = useState(false);
  const [passwordFocused, setPasswordFocused] = useState(false);
  const [inviteFocused, setInviteFocused] = useState(false);
  const [reduceMotion, setReduceMotion] = useState(false);
  const emailInput = useRef<TextInput>(null);
  const passwordInput = useRef<TextInput>(null);
  const inviteInput = useRef<TextInput>(null);
  const [shake] = useState(() => new Animated.Value(0));
  const [headerEntrance] = useState(() => new Animated.Value(0));
  const [cardEntrance] = useState(() => new Animated.Value(0));
  const valid = email.trim().length > 0 && password.length >= 8 && (!registering || (acceptedPrivacy && acceptedTerms));

  useEffect(() => {
    AccessibilityInfo.isReduceMotionEnabled().then(setReduceMotion).catch(() => undefined);
    const listener = AccessibilityInfo.addEventListener('reduceMotionChanged', setReduceMotion);
    if (Platform.OS === 'android') UIManager.setLayoutAnimationEnabledExperimental?.(true);
    if (reduceMotion) {
      headerEntrance.setValue(1);
      cardEntrance.setValue(1);
    } else {
      Animated.sequence([
        Animated.timing(headerEntrance, { toValue: 1, duration: 600, useNativeDriver: true }),
        Animated.delay(120),
        Animated.timing(cardEntrance, { toValue: 1, duration: 600, useNativeDriver: true }),
      ]).start();
    }
    return () => listener.remove();
  }, [cardEntrance, headerEntrance, reduceMotion, shake]);

  const triggerError = useCallback((message: string) => {
    setError(message);
    if (!reduceMotion) {
      shake.setValue(0);
      Animated.sequence([0, 1, -1, 0.8, -0.8, 0.5, -0.5, 0].map(value =>
        Animated.timing(shake, { toValue: value, duration: 50, useNativeDriver: true }),
      )).start();
    }
    void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error).catch(() => undefined);
  }, [reduceMotion, shake]);

  const submit = useCallback(async () => {
    if (!valid || busy) return;
    Keyboard.dismiss();
    setError(null);
    setBusy(true);
    try {
      if (registering) await register(email, password, inviteCode);
      else await login(email, password);
      void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => undefined);
      router.replace('/home');
    } catch (cause) {
      triggerError(cause instanceof AuthApiError ? cause.message : 'İşlem tamamlanamadı. Lütfen tekrar dene.');
    } finally {
      setBusy(false);
    }
  }, [busy, email, inviteCode, login, password, registering, register, triggerError, valid]);

  const changeMode = () => {
    Keyboard.dismiss();
    LayoutAnimation.configureNext(LayoutAnimation.Presets.easeInEaseOut);
    setRegistering(value => !value);
    setError(null);
  };

  const forgot = () => {
    Keyboard.dismiss();
    router.push({ pathname: '/forgot-password', params: { email } });
  };

  const backgroundFade = useMemo(() => [colors.canvas, `${colors.canvas}D1`, `${colors.canvas}00`, `${colors.canvas}00`] as [string, string, string, string], [colors.canvas]);

  return (
    <View style={[styles.page, { backgroundColor: colors.canvas }]}>
      <Image source={BACKGROUND} resizeMode="cover" style={styles.backgroundImage} />
      <LinearGradient
        pointerEvents="none"
        colors={backgroundFade}
        locations={[0, 0.08, 0.24, 1]}
        style={StyleSheet.absoluteFill}
      />
      <KeyboardAvoidingView style={styles.flex} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <ScrollView
          contentContainerStyle={[styles.scrollContent, { minHeight: height - insets.top - insets.bottom, paddingTop: Math.max(insets.top, 16), paddingBottom: Math.max(insets.bottom, 24) }]}
          keyboardShouldPersistTaps="handled"
          keyboardDismissMode="on-drag"
          showsVerticalScrollIndicator={false}
        >
          <View style={[styles.spacerTop, { height: Math.max(32, height * 0.22) }]} />
          <Animated.View style={[styles.brand, { transform: [{ translateY: headerEntrance.interpolate({ inputRange: [0, 1], outputRange: [10, -Math.min(Math.max(height * 0.07, 28), 56)] }) }], opacity: headerEntrance }]}>
            <Image source={scheme === 'dark' ? MARK_DARK : MARK} style={styles.mark} accessibilityLabel="Wiqo" />
            <Text style={[styles.wordmark, { color: colors.ink }]}>Wiqo</Text>
          </Animated.View>
          <View style={styles.flexSpacer} />
          <Animated.View style={[styles.formWrap, { opacity: cardEntrance, transform: [{ translateX: shake }, { translateY: cardEntrance.interpolate({ inputRange: [0, 1], outputRange: [10, -Math.min(Math.max(height * 0.08, 32), 72)] }) }] }]}>
            <View style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.line }]}>
              <Text style={[styles.cardTitle, { color: colors.ink }]}>{registering ? 'Hesap oluştur' : 'Giriş yap'}</Text>

              <View style={styles.fields}>
                <AuthField focused={emailFocused} error={error !== null}>
                  <TextInput
                    ref={emailInput}
                    value={email}
                    onChangeText={setEmail}
                    placeholder="E-posta"
                    placeholderTextColor={colors.muted}
                    keyboardType="email-address"
                    textContentType="emailAddress"
                    autoComplete="email"
                    autoCapitalize="none"
                    autoCorrect={false}
                    returnKeyType="next"
                    onFocus={() => setEmailFocused(true)}
                    onBlur={() => setEmailFocused(false)}
                    onSubmitEditing={() => passwordInput.current?.focus()}
                    accessibilityLabel="E-posta"
                    style={[authTextStyles.input, { color: colors.ink }]}
                  />
                </AuthField>
                <AuthField focused={passwordFocused} error={error !== null}>
                  <TextInput
                    ref={passwordInput}
                    value={password}
                    onChangeText={setPassword}
                    placeholder="Şifre"
                    placeholderTextColor={colors.muted}
                    secureTextEntry={!showPassword}
                    textContentType={registering ? 'newPassword' : 'password'}
                    autoComplete={registering ? 'new-password' : 'current-password'}
                    autoCapitalize="none"
                    autoCorrect={false}
                    returnKeyType={registering ? 'next' : 'go'}
                    onFocus={() => setPasswordFocused(true)}
                    onBlur={() => setPasswordFocused(false)}
                    onSubmitEditing={() => registering ? inviteInput.current?.focus() : void submit()}
                    accessibilityLabel="Şifre"
                    style={[authTextStyles.input, { color: colors.ink }]}
                  />
                  <Pressable
                    accessibilityRole="button"
                    accessibilityLabel={showPassword ? 'Şifreyi gizle' : 'Şifreyi göster'}
                    hitSlop={6}
                    onPress={() => setShowPassword(value => !value)}
                    style={styles.eye}
                  >
                    <MaterialCommunityIcons name={showPassword ? 'eye-off-outline' : 'eye-outline'} size={20} color={colors.muted} />
                  </Pressable>
                </AuthField>
                {registering && (
                  <AuthField focused={inviteFocused}>
                    <TextInput
                      ref={inviteInput}
                      value={inviteCode}
                      onChangeText={value => setInviteCode(value.toUpperCase().slice(0, 16))}
                      placeholder="Davet kodu (opsiyonel)"
                      placeholderTextColor={colors.muted}
                      autoCapitalize="characters"
                      autoCorrect={false}
                      maxLength={16}
                      returnKeyType="go"
                      onFocus={() => setInviteFocused(true)}
                      onBlur={() => setInviteFocused(false)}
                      onSubmitEditing={() => void submit()}
                      accessibilityLabel="Davet kodu, opsiyonel"
                      style={[authTextStyles.input, { color: colors.ink }]}
                    />
                  </AuthField>
                )}
              </View>

              {registering && !inviteCode.trim() && <Text style={[authTextStyles.helper, { color: colors.muted }]}>Bir arkadaşının davet kodu varsa gir - ikiniz de 14 gün Pro kazanırsınız.</Text>}
              {!registering && (
                <Pressable accessibilityRole="button" onPress={forgot} style={styles.forgot}>
                  <Text style={[authTextStyles.muted, { color: colors.muted }]}>Şifremi unuttum</Text>
                </Pressable>
              )}

              {registering && (
                <View style={styles.consents}>
                  <Consent
                    checked={acceptedPrivacy}
                    onToggle={() => setAcceptedPrivacy(value => !value)}
                    title="Gizlilik Politikası'nı okudum. Mesaj, ses ve görsellerimin yanıt üretmek için Wiqo tarafından yapay zeka hizmet sağlayıcılarıyla işlenmesini kabul ediyorum."
                    link="Gizlilik Politikası'nı aç"
                    url={PRIVACY_URL}
                  />
                  <Consent
                    checked={acceptedTerms}
                    onToggle={() => setAcceptedTerms(value => !value)}
                    title="Kullanım Şartları'nı okudum ve kabul ediyorum."
                    link="Kullanım Şartları'nı aç"
                    url={TERMS_URL}
                  />
                </View>
              )}

              {error && <InlineError message={error} />}
              <AuthAction title={registering ? 'Hesap oluştur' : 'Giriş yap'} onPress={() => void submit()} busy={busy} disabled={!valid} />
              <Pressable accessibilityRole="button" onPress={changeMode} style={styles.switchMode}>
                <Text style={[authTextStyles.muted, { color: colors.muted }]}>
                  {registering ? 'Zaten hesabın var mı? ' : 'Hesabın yok mu? '}
                  <Text style={[styles.switchEmphasis, { color: colors.ink }]}>{registering ? 'Giriş yap' : 'Kayıt ol'}</Text>
                </Text>
              </Pressable>
            </View>
          </Animated.View>
        </ScrollView>
      </KeyboardAvoidingView>
    </View>
  );
}

function Consent({ checked, onToggle, title, link, url }: { checked: boolean; onToggle: () => void; title: string; link: string; url: string }) {
  const colors = useWiqoColors();
  return (
    <View style={styles.consentRow}>
      <Pressable
        accessibilityRole="checkbox"
        accessibilityState={{ checked }}
        accessibilityLabel={title}
        onPress={onToggle}
        style={styles.consentToggle}
      >
        <View style={[styles.checkbox, { backgroundColor: checked ? colors.accent : colors.inset, borderColor: checked ? colors.accent : `${colors.ink}30` }]}>
          {checked && <MaterialCommunityIcons name="check" size={16} color={colors.onAccent} />}
        </View>
        <Text style={[styles.consentText, { color: colors.ink }]}>{title}</Text>
      </Pressable>
      <Pressable accessibilityRole="link" onPress={() => { void Linking.openURL(url).catch(() => undefined); }} style={styles.legalLink}>
        <Text style={[styles.legalText, { color: colors.accent }]}>{link}</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  page: { flex: 1, overflow: 'hidden' },
  flex: { flex: 1 },
  backgroundImage: { position: 'absolute', top: 0, right: 0, bottom: 0, left: 0, width: '100%', height: '100%', opacity: 0.78 },
  scrollContent: { flexGrow: 1, paddingHorizontal: 24, justifyContent: 'space-between' },
  spacerTop: {},
  flexSpacer: { flex: 1, minHeight: 28 },
  brand: { alignItems: 'center', gap: 6 },
  mark: { width: 84, height: 84, shadowColor: '#000000', shadowOpacity: 0.2, shadowRadius: 7, shadowOffset: { width: 0, height: 3 }, elevation: 3 },
  wordmark: { fontFamily: 'sans-serif-rounded', fontSize: 32, fontWeight: '700' },
  formWrap: { width: '100%', maxWidth: 440, alignSelf: 'center' },
  card: { padding: 20, borderRadius: 20, borderWidth: StyleSheet.hairlineWidth, gap: 14, shadowColor: '#000000', shadowOpacity: 0.05, shadowRadius: 10, shadowOffset: { width: 0, height: 4 }, elevation: 4 },
  cardTitle: { fontSize: 20, lineHeight: 25, fontWeight: '600' },
  fields: { gap: 10 },
  eye: { width: 36, height: 40, alignItems: 'center', justifyContent: 'center' },
  forgot: { alignSelf: 'flex-end', minHeight: 36, justifyContent: 'center' },
  consents: { gap: 10 },
  consentRow: { gap: 4 },
  consentToggle: { minHeight: 40, flexDirection: 'row', alignItems: 'flex-start', gap: 8 },
  checkbox: { width: 22, height: 22, borderRadius: 6, borderWidth: 1, alignItems: 'center', justifyContent: 'center', marginTop: 1 },
  consentText: { flex: 1, fontSize: 12, lineHeight: 17 },
  legalLink: { minHeight: 32, justifyContent: 'center', marginLeft: 30, alignSelf: 'flex-start' },
  legalText: { fontSize: 12, fontWeight: '600' },
  switchMode: { minHeight: 38, alignItems: 'center', justifyContent: 'center' },
  switchEmphasis: { fontWeight: '600' },
});
