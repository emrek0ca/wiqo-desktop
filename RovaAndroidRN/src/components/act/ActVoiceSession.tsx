import { MaterialCommunityIcons } from '@expo/vector-icons';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { WiqoListeningOrb } from '@/components/chat/WiqoListeningOrb';

type Props = {
  transcript: string;
  status: string;
  listening: boolean;
  working: boolean;
  speaking: boolean;
  level: number;
  queued: string[];
  accent: string;
  ink: string;
  muted: string;
  background: string;
  speakReplies: boolean;
  onClose: () => void;
  onDeliver: () => void;
  onToggleSpeaker: () => void;
  onRemoveQueued: (index: number) => void;
};

export function ActVoiceSession({ transcript, status, listening, working, speaking, level, queued, accent, ink, muted, background, speakReplies, onClose, onDeliver, onToggleSpeaker, onRemoveQueued }: Props) {
  return <View style={[styles.root, { backgroundColor: background }]}>
    {queued.length > 0 ? <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.queue}>
      {queued.map((item, index) => <Pressable key={`${index}-${item}`} accessibilityRole="button" accessibilityLabel="Sıradaki komutu kaldır" onPress={() => onRemoveQueued(index)} style={[styles.chip, { backgroundColor: `${muted}15` }]}>
        <Text numberOfLines={1} style={[styles.chipText, { color: muted }]}>{item}</Text><MaterialCommunityIcons name="close" size={13} color={muted} />
      </Pressable>)}
    </ScrollView> : null}
    <View style={styles.statusRow}><Text numberOfLines={2} style={[styles.status, { color: transcript ? ink : muted }]}>{transcript || status || (speaking ? 'Yanıtlıyor…' : working ? 'Düşünüyor…' : listening ? 'Dinliyorum…' : 'Mikrofon yeniden bağlanıyor…')}</Text></View>
    <View style={styles.controls}>
      <Pressable accessibilityRole="button" accessibilityLabel={speakReplies ? 'Sesli yanıtı kapat' : 'Sesli yanıtı aç'} onPress={onToggleSpeaker} style={[styles.sideControl, { backgroundColor: `${muted}16` }]}>
        <MaterialCommunityIcons name={speakReplies ? 'volume-high' : 'volume-off'} size={21} color={speakReplies ? accent : muted} />
      </Pressable>
      <Pressable accessibilityRole="button" accessibilityLabel="Duyulan komutu gönder" onPress={onDeliver} style={styles.orbButton}>
        <WiqoListeningOrb level={level} working={working || speaking} accent={accent} compact />
      </Pressable>
      <Pressable accessibilityRole="button" accessibilityLabel="Sesli oturumu kapat" onPress={onClose} style={[styles.sideControl, { backgroundColor: `${muted}16` }]}>
        <MaterialCommunityIcons name="close" size={21} color={muted} />
      </Pressable>
    </View>
  </View>;
}

const styles = StyleSheet.create({
  root: { minHeight: 188, paddingTop: 10, paddingBottom: 4, justifyContent: 'flex-end' },
  queue: { paddingHorizontal: 16, gap: 7, alignItems: 'center', paddingBottom: 8 },
  chip: { maxWidth: 220, minHeight: 28, borderRadius: 16, paddingHorizontal: 10, gap: 5, flexDirection: 'row', alignItems: 'center' },
  chipText: { maxWidth: 185, fontSize: 12 },
  statusRow: { minHeight: 28, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 18 },
  status: { fontSize: 14, textAlign: 'center' },
  controls: { minHeight: 176, paddingHorizontal: 22, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  sideControl: { width: 44, height: 44, borderRadius: 24, alignItems: 'center', justifyContent: 'center' },
  orbButton: { width: 176, height: 176, alignItems: 'center', justifyContent: 'center', overflow: 'visible' },
});
