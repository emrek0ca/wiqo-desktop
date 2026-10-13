import { MaterialCommunityIcons } from '@expo/vector-icons';
import { useEffect, useMemo, useRef } from 'react';
import { Animated, PanResponder, Pressable, StyleSheet, View } from 'react-native';

export type ActDockAction = {
  id: string;
  icon: React.ComponentProps<typeof MaterialCommunityIcons>['name'];
  label: string;
  selected?: boolean;
  disabled?: boolean;
  onPress: () => void;
};

type Props = {
  groups: ActDockAction[][];
  hidden: boolean;
  onHiddenChange: (hidden: boolean) => void;
  extra?: ActDockAction;
  ink: string;
  muted: string;
  surface: string;
  line: string;
};

/** iOS Act's trailing utility dock: grouped icons, a one-tap edge handle, and horizontal swipe dismissal. */
export function ActSideDock({ groups, hidden, onHiddenChange, extra, ink, muted, surface, line }: Props) {
  const dragX = useRef(new Animated.Value(0)).current;
  const visibility = useRef(new Animated.Value(hidden ? 1 : 0)).current;
  const hiddenRef = useRef(hidden);
  hiddenRef.current = hidden;
  const springBack = () => Animated.spring(dragX, { toValue: 0, useNativeDriver: true, stiffness: 240, damping: 22, mass: 0.72 }).start();
  const panResponder = useMemo(() => PanResponder.create({
    onMoveShouldSetPanResponder: (_, gesture) => Math.abs(gesture.dx) > 8 && Math.abs(gesture.dx) > Math.abs(gesture.dy),
    onPanResponderMove: (_, gesture) => dragX.setValue(hiddenRef.current ? Math.max(-64, Math.min(0, gesture.dx)) : Math.max(0, Math.min(64, gesture.dx))),
    onPanResponderRelease: (_, gesture) => {
      if (!hiddenRef.current && (gesture.dx > 36 || gesture.vx > 0.8)) onHiddenChange(true);
      else if (hiddenRef.current && (gesture.dx < -12 || gesture.vx < -0.8)) onHiddenChange(false);
      springBack();
    },
    onPanResponderTerminate: springBack,
  }), [dragX, onHiddenChange]);

  useEffect(() => {
    Animated.spring(visibility, { toValue: hidden ? 1 : 0, useNativeDriver: true, stiffness: hidden ? 260 : 190, damping: hidden ? 24 : 14, mass: 0.76 }).start();
    springBack();
  }, [hidden]);

  const grouped = groups.map((group, groupIndex) => <View key={`group-${groupIndex}`}>
    {groupIndex > 0 ? <View style={[styles.divider, { backgroundColor: line }]} /> : null}
    {group.map(action => <DockButton key={action.id} action={action} ink={ink} muted={muted} />)}
  </View>);

  return <View pointerEvents="box-none" style={styles.anchor}>
    <Animated.View pointerEvents={hidden ? 'none' : 'auto'} {...panResponder.panHandlers} style={[styles.dock, { backgroundColor: surface, borderColor: line, opacity: Animated.multiply(visibility.interpolate({ inputRange: [0, 1], outputRange: [1, 0] }), dragX.interpolate({ inputRange: [0, 64], outputRange: [1, 0.55] })), transform: [{ translateX: Animated.add(visibility.interpolate({ inputRange: [0, 1], outputRange: [0, 66] }), dragX) }, { scale: visibility.interpolate({ inputRange: [0, 1], outputRange: [1, 0.9] }) }] }]}>
      {grouped}
      {extra ? <DockButton action={extra} ink={ink} muted={muted} /> : null}
      <Pressable accessibilityRole="button" accessibilityLabel="Dock'u gizle" onPress={() => onHiddenChange(true)} style={styles.hideButton}><MaterialCommunityIcons name="chevron-right" size={16} color={muted} /></Pressable>
    </Animated.View>
    <Animated.View pointerEvents={hidden ? 'auto' : 'none'} style={{ opacity: visibility, transform: [{ translateX: visibility.interpolate({ inputRange: [0, 1], outputRange: [26, 0] }) }, { scale: visibility.interpolate({ inputRange: [0, 1], outputRange: [0.8, 1] }) }] }}>
      <Pressable {...panResponder.panHandlers} accessibilityRole="button" accessibilityLabel="Dock'u göster" onPress={() => onHiddenChange(false)} style={[styles.handle, { backgroundColor: surface, borderColor: line }]}><MaterialCommunityIcons name="chevron-left" size={16} color={muted} /></Pressable>
    </Animated.View>
  </View>;
}

function DockButton({ action, ink, muted }: { action: ActDockAction; ink: string; muted: string }) {
  return <Pressable accessibilityRole="button" accessibilityLabel={action.label} accessibilityState={{ selected: !!action.selected, disabled: !!action.disabled }} disabled={action.disabled} onPress={action.onPress} style={({ pressed }) => [styles.action, action.selected && styles.selected, action.disabled && styles.disabled, pressed && !action.disabled && styles.pressed]}>
    <MaterialCommunityIcons name={action.icon} size={18} color={action.selected ? ink : muted} />
  </Pressable>;
}

const styles = StyleSheet.create({
  anchor: { position: 'absolute', zIndex: 20, top: 0, bottom: 0, right: 0, width: 60, justifyContent: 'center', alignItems: 'flex-end' },
  dock: { width: 44, marginRight: 8, paddingVertical: 6, alignItems: 'center', borderRadius: 22, borderWidth: StyleSheet.hairlineWidth, shadowColor: '#000', shadowOffset: { width: 0, height: 3 }, shadowOpacity: 0.07, shadowRadius: 10, elevation: 3 },
  action: { width: 40, height: 40, borderRadius: 20, alignItems: 'center', justifyContent: 'center' },
  selected: { backgroundColor: 'rgba(120,120,128,0.12)' },
  disabled: { opacity: 0.36 },
  pressed: { transform: [{ scale: 0.94 }] },
  divider: { height: StyleSheet.hairlineWidth, width: 22, marginVertical: 5 },
  hideButton: { width: 40, height: 28, alignItems: 'center', justifyContent: 'center' },
  handle: { width: 22, height: 64, borderTopLeftRadius: 14, borderBottomLeftRadius: 14, borderWidth: StyleSheet.hairlineWidth, borderRightWidth: 0, alignItems: 'center', justifyContent: 'center' },
});
