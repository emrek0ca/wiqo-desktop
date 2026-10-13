import { router, Stack } from 'expo-router';
import * as Notifications from 'expo-notifications';
import { useEffect } from 'react';
import { PaperProvider } from 'react-native-paper';
import { StatusBar } from 'react-native';
import { AuthProvider } from '@/auth/AuthProvider';
import { md3DarkTheme, md3Theme } from '@/theme';
import { accentColors, AppearanceProvider, useAppearance } from '@/settings/AppearanceProvider';

export default function RootLayout() {
  return <AppearanceProvider><AppShell /></AppearanceProvider>;
}

function AppShell() {
  const { colorScheme, accent } = useAppearance();
  const baseTheme = colorScheme === 'dark' ? md3DarkTheme : md3Theme;
  const theme = { ...baseTheme, colors: { ...baseTheme.colors, primary: accentColors[accent] } };
  return (
    <PaperProvider theme={theme}>
      <StatusBar barStyle={colorScheme === 'dark' ? 'light-content' : 'dark-content'} />
      <AuthProvider>
        <NotificationNavigation />
        <Stack screenOptions={{ headerShown: false, animation: 'fade' }}>
          <Stack.Screen name="index" />
          <Stack.Screen name="forgot-password" options={{ presentation: 'modal', animation: 'slide_from_bottom' }} />
          <Stack.Screen name="home" options={{ gestureEnabled: false }} />
          <Stack.Screen name="settings" options={{ presentation: 'modal', animation: 'slide_from_bottom', gestureEnabled: true }} />
          <Stack.Screen name="oauth-callback" options={{ headerShown: false }} />
        </Stack>
      </AuthProvider>
    </PaperProvider>
  );
}

function NotificationNavigation() {
  useEffect(() => {
    let lastHandledId = '';
    const openNotification = (response: Notifications.NotificationResponse) => {
      const request = response.notification.request;
      if (request.identifier === lastHandledId) return;
      lastHandledId = request.identifier;
      const data = request.content.data as { route?: unknown };
      if (data.route === 'activity') {
        router.push({ pathname: '/settings', params: { page: 'tasks' } });
      } else {
        router.push('/home');
      }
      void Notifications.clearLastNotificationResponseAsync();
    };
    const listener = Notifications.addNotificationResponseReceivedListener(openNotification);
    void Notifications.getLastNotificationResponseAsync().then(response => {
      if (response) openNotification(response);
    }).catch(() => undefined);
    return () => listener.remove();
  }, []);
  return null;
}
