import * as Notifications from 'expo-notifications';
import * as SecureStore from 'expo-secure-store';
import { Platform } from 'react-native';
import { chatApi } from '@/data/chat-api';

export const ANDROID_PUSH_TOKEN_KEY = 'wiqo-android-fcm-token';

Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowBanner: true,
    shouldShowList: true,
    shouldPlaySound: true,
    shouldSetBadge: false,
  }),
});

export async function registerAndroidPushToken(sessionToken: string, deviceToken: string): Promise<void> {
  if (Platform.OS !== 'android' || deviceToken.length < 22) return;
  await chatApi.registerAndroidPushToken(sessionToken, deviceToken);
  await SecureStore.setItemAsync(ANDROID_PUSH_TOKEN_KEY, deviceToken, {
    keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
  });
}

/** Registers the native FCM token only after the user has granted notification permission. */
export async function syncAndroidPushRegistration(sessionToken: string): Promise<boolean> {
  if (Platform.OS !== 'android') return false;
  await Notifications.setNotificationChannelAsync('wiqo_updates', {
    name: 'Wiqo bildirimleri',
    importance: Notifications.AndroidImportance.HIGH,
    vibrationPattern: [0, 180, 100, 180],
  });
  const permission = await Notifications.getPermissionsAsync();
  if (!permission.granted) return false;
  const result = await Notifications.getDevicePushTokenAsync();
  if (result.type !== 'android' || typeof result.data !== 'string') {
    throw new Error('Android FCM cihaz belirteci alınamadı.');
  }
  await registerAndroidPushToken(sessionToken, result.data);
  return true;
}

export async function revokeAndroidPushRegistration(sessionToken: string): Promise<void> {
  if (Platform.OS !== 'android') return;
  const deviceToken = await SecureStore.getItemAsync(ANDROID_PUSH_TOKEN_KEY);
  if (!deviceToken) return;
  await SecureStore.deleteItemAsync(ANDROID_PUSH_TOKEN_KEY);
  await chatApi.revokeAndroidPushToken(sessionToken, deviceToken);
}
