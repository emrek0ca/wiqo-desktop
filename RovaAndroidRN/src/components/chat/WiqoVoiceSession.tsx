import { MaterialCommunityIcons } from '@expo/vector-icons';
import { Modal, Pressable, SafeAreaView, ScrollView, StyleSheet, Text, View } from 'react-native';
import type { ReactNode } from 'react';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { WiqoListeningOrb } from './WiqoListeningOrb';

type Props = {
  visible: boolean;
  listening: boolean;
  working: boolean;
  speaking: boolean;
  level: number;
  transcript: string;
  errorMessage?: string;
  latestResponse?: ReactNode;
  queued: string[];
  accent: string;
  background: string;
  ink: string;
  muted: string;
  speakReplies: boolean;
  onClose: () => void;
  onOrbPress: () => void;
  onToggleSpeaker: () => void;
  onRemoveQueued: (index: number) => void;
};

export function WiqoVoiceSession({ visible, listening, working, speaking, level, transcript, errorMessage, latestResponse, queued, accent, background, ink, muted, speakReplies, onClose, onOrbPress, onToggleSpeaker, onRemoveQueued }: Props) {
  const insets = useSafeAreaInsets();
  const status = speaking ? 'Yanıtlıyor…' : working ? 'Düşünüyor…' : listening ? 'Dinliyorum…' : 'Mikrofon yeniden bağlanıyor…';
  return <Modal visible={visible} animationType="fade" transparent={false} statusBarTranslucent onRequestClose={onClose}>
    <SafeAreaView style={[styles.screen, { backgroundColor: background, paddingTop: Math.max(insets.top, 12), paddingBottom: Math.max(insets.bottom, 12) }]}>
      <View style={styles.header}>
        <View style={styles.headerSpacer} />
        <Text style={[styles.title, { color: ink }]}>Sesli sohbet</Text>
        <Pressable accessibilityRole="button" accessibilityLabel="Sesli sohbeti kapat" onPress={onClose} style={[styles.control, { backgroundColor: `${muted}14` }]}><MaterialCommunityIcons name="close" size={20} color={ink} /></Pressable>
      </View>
      <View style={styles.center}>
        <Text numberOfLines={2} style={[styles.transcript, { color: transcript ? ink : muted }]}>{transcript || status}</Text>
        <Pressable accessibilityRole="button" accessibilityLabel="Wiqo dinliyor" accessibilityHint="Duyulan cümleyi göndermek için dokun" onPress={onOrbPress} style={styles.orbButton}>
          <WiqoListeningOrb level={level} working={working || speaking} accent={accent} />
        </Pressable>
        <Text style={[styles.status, { color: muted }]}>{transcript ? status : 'Konuşmaya başlayabilirsin'}</Text>
        {errorMessage ? <Text style={[styles.voiceError, { color: '#D84A4A' }]}>{errorMessage}</Text> : null}
        {latestResponse ? <ScrollView style={styles.replyScroll} contentContainerStyle={styles.replyContent} keyboardShouldPersistTaps="handled">{latestResponse}</ScrollView> : null}
        {queued.length ? <View style={styles.queue}>{queued.map((item, index) => <Pressable key={`${index}-${item}`} accessibilityRole="button" accessibilityLabel={`Sıradaki mesajı kaldır: ${item}`} onPress={() => onRemoveQueued(index)} style={[styles.queueChip, { backgroundColor: `${muted}14` }]}><Text numberOfLines={1} style={[styles.queueText, { color: muted }]}>{item}</Text><MaterialCommunityIcons name="close" size={13} color={muted} /></Pressable>)}</View> : null}
      </View>
      <View style={styles.footer}>
        <Pressable accessibilityRole="button" accessibilityLabel={speakReplies ? 'Sesli yanıtı kapat' : 'Sesli yanıtı aç'} onPress={onToggleSpeaker} style={[styles.control, styles.speakerControl, { backgroundColor: `${muted}14` }]}>
          <MaterialCommunityIcons name={speakReplies ? 'volume-high' : 'volume-off'} size={21} color={speakReplies ? accent : muted} />
          <Text style={[styles.speakerText, { color: muted }]}>{speakReplies ? 'Ses açık' : 'Ses kapalı'}</Text>
        </Pressable>
        <Text style={[styles.footerHint, { color: muted }]}>Kapatmak için × düğmesine dokun</Text>
      </View>
    </SafeAreaView>
  </Modal>;
}

const styles = StyleSheet.create({
  screen: { flex: 1, paddingHorizontal: 24 },
  header: { minHeight: 52, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  headerSpacer: { width: 42, height: 42 },
  title: { fontSize: 17, fontWeight: '600' },
  control: { width: 42, height: 42, borderRadius: 22, alignItems: 'center', justifyContent: 'center' },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingBottom: 26 },
  transcript: { minHeight: 48, maxWidth: '100%', textAlign: 'center', fontSize: 16, lineHeight: 23 },
  orbButton: { marginVertical: 4 },
  status: { fontSize: 14, marginTop: -8 },
  voiceError: { fontSize: 13, textAlign: 'center', marginTop: 8, maxWidth: 320 },
  replyScroll: { width: '100%', maxHeight: '38%', marginTop: 12, flexGrow: 0 },
  replyContent: { paddingHorizontal: 2, paddingBottom: 12 },
  queue: { maxWidth: '100%', flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'center', gap: 6, marginTop: 14 },
  queueChip: { maxWidth: 190, minHeight: 28, flexDirection: 'row', alignItems: 'center', gap: 5, borderRadius: 16, paddingHorizontal: 9 },
  queueText: { flexShrink: 1, fontSize: 11 },
  footer: { minHeight: 74, alignItems: 'center', justifyContent: 'center', gap: 8 },
  speakerControl: { minWidth: 112, height: 42, borderRadius: 24, flexDirection: 'row', gap: 7, paddingHorizontal: 14 },
  speakerText: { fontSize: 13, fontWeight: '500' },
  footerHint: { fontSize: 11 },
});
