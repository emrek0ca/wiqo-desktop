import { useEffect, useRef } from 'react';
import { Animated, Easing, StyleSheet, View } from 'react-native';

const MASCOTS = {
  general: require('../../../assets/mascots/general.png'),
  research: require('../../../assets/mascots/research.png'),
  developer: require('../../../assets/mascots/developer.png'),
  execution: require('../../../assets/mascots/execution.png'),
} as const;

export type MascotPersona = keyof typeof MASCOTS;

export function normalizeMascotPersona(value: unknown): MascotPersona {
  return typeof value === 'string' && value in MASCOTS ? value as MascotPersona : 'general';
}

export function WiqoAgentMascot({ persona, size = 44, isWorking = false }: { persona?: unknown; size?: number; isWorking?: boolean }) {
  const motion = useRef(new Animated.Value(0)).current;
  const kind = normalizeMascotPersona(persona);
  useEffect(() => {
    motion.stopAnimation();
    motion.setValue(0);
    if (!isWorking) return;
    const duration = kind === 'execution' ? 360 : kind === 'developer' ? 600 : 1150;
    const animation = Animated.loop(Animated.sequence([
      Animated.timing(motion, { toValue: 1, duration, easing: Easing.inOut(Easing.sin), useNativeDriver: true }),
      Animated.timing(motion, { toValue: 0, duration, easing: Easing.inOut(Easing.sin), useNativeDriver: true }),
    ]));
    animation.start();
    return () => animation.stop();
  }, [isWorking, kind, motion]);

  const translateY = motion.interpolate({ inputRange: [0, 1], outputRange: [0, kind === 'developer' ? -1.5 : -2.5] });
  const translateX = kind === 'execution' ? motion.interpolate({ inputRange: [0, 1], outputRange: [-1.6, 1.6] }) : 0;
  const rotate = kind === 'research' ? motion.interpolate({ inputRange: [0, 1], outputRange: ['-7deg', '7deg'] }) : kind === 'execution' ? '-4deg' : '0deg';
  const scale = kind === 'developer' ? motion.interpolate({ inputRange: [0, 1], outputRange: [1, 1.035] }) : 1;
  const displaySize = size * 1.3;

  return <View accessible accessibilityLabel={`${kind} ajan${isWorking ? ', çalışıyor' : ''}`} style={{ width: displaySize, height: displaySize, padding: displaySize * 0.035 }}>
    <Animated.Image source={MASCOTS[kind]} resizeMode="contain" style={[styles.image, { transform: [{ translateX }, { translateY }, { rotate }, { scale }] }]} />
    {isWorking ? <View style={[styles.working, { width: Math.max(9, displaySize * 0.18), height: Math.max(9, displaySize * 0.18), borderRadius: displaySize }]} /> : null}
  </View>;
}

const styles = StyleSheet.create({ image: { width: '100%', height: '100%' }, working: { position: 'absolute', right: 1, bottom: 1, backgroundColor: '#35A56B', borderColor: '#FFFFFF', borderWidth: 2 } });
