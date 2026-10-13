import * as SecureStore from 'expo-secure-store';
import * as Notifications from 'expo-notifications';
import { AppState, Platform } from 'react-native';
import { createContext, PropsWithChildren, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { AuthApiError, authApi } from '@/data/auth-api';
import { cacheScopeForToken, clearCacheScope } from '@/data/local-cache';
import { registerAndroidPushToken, revokeAndroidPushRegistration, syncAndroidPushRegistration } from '@/data/push-notifications';

const TOKEN_KEY = 'wiqo-account-token';

type AuthContextValue = {
  token: string | null;
  ready: boolean;
  login: (email: string, password: string) => Promise<void>;
  register: (email: string, password: string, inviteCode: string) => Promise<void>;
  resetPassword: (email: string, code: string, password: string) => Promise<void>;
  requestPasswordReset: (email: string) => Promise<void>;
  signOut: () => Promise<void>;
};

const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: PropsWithChildren) {
  const [token, setToken] = useState<string | null>(null);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    let mounted = true;
    SecureStore.getItemAsync(TOKEN_KEY)
      .then(async value => {
        if (!value) return;
        try {
          await authApi.currentAccount(value);
          if (mounted) setToken(value);
        } catch (cause) {
          if (cause instanceof AuthApiError && cause.status === 401) {
            try { await clearCacheScope(await cacheScopeForToken(value)); } catch { /* session cleanup continues */ }
            await SecureStore.deleteItemAsync(TOKEN_KEY);
            if (mounted) setToken(null);
          } else if (mounted) {
            // Keep an existing session during a temporary server outage; protected actions
            // continue to report their own connection state and recover when the server returns.
            setToken(value);
          }
        }
      })
      .catch(() => { if (mounted) setToken(null); })
      .finally(() => { if (mounted) setReady(true); });
    return () => { mounted = false; };
  }, []);

  useEffect(() => {
    if (!token || Platform.OS !== 'android') return;
    let active = true;
    const syncIfAllowed = async () => {
      try {
        const permission = await Notifications.getPermissionsAsync();
        if (active && permission.granted) await syncAndroidPushRegistration(token);
      } catch {
        // A missing Firebase native configuration must not prevent sign-in or app startup.
      }
    };
    void syncIfAllowed();
    const tokenSubscription = Notifications.addPushTokenListener(pushToken => {
      if (pushToken.type === 'android' && typeof pushToken.data === 'string') {
        void Notifications.getPermissionsAsync().then(permission => {
          if (active && permission.granted) return registerAndroidPushToken(token, pushToken.data);
          return undefined;
        }).catch(() => undefined);
      }
    });
    const appStateSubscription = AppState.addEventListener('change', state => {
      if (state === 'active') void syncIfAllowed();
    });
    return () => {
      active = false;
      tokenSubscription.remove();
      appStateSubscription.remove();
    };
  }, [token]);

  const saveToken = useCallback(async (value: string) => {
    await SecureStore.setItemAsync(TOKEN_KEY, value, {
      keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
    });
    setToken(value);
  }, []);

  const login = useCallback(async (email: string, password: string) => {
    await saveToken(await authApi.login(email, password));
  }, [saveToken]);

  const register = useCallback(async (email: string, password: string, inviteCode: string) => {
    await saveToken(await authApi.register(email, password, inviteCode));
  }, [saveToken]);

  const resetPassword = useCallback(async (email: string, code: string, password: string) => {
    await saveToken(await authApi.resetPassword(email, code, password));
  }, [saveToken]);

  const signOut = useCallback(async () => {
    if (token && Platform.OS === 'android') {
      void revokeAndroidPushRegistration(token).catch(() => undefined);
    }
    if (token) {
      try { await clearCacheScope(await cacheScopeForToken(token)); } catch { /* sign out must not depend on cache availability */ }
    }
    await SecureStore.deleteItemAsync(TOKEN_KEY);
    setToken(null);
  }, [token]);

  const value = useMemo<AuthContextValue>(() => ({
    token, ready, login, register, resetPassword,
    requestPasswordReset: authApi.requestPasswordReset,
    signOut,
  }), [token, ready, login, register, resetPassword, signOut]);

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const value = useContext(AuthContext);
  if (!value) throw new Error('useAuth must be used inside AuthProvider');
  return value;
}
