import { MaterialCommunityIcons } from '@expo/vector-icons';
import * as DocumentPicker from 'expo-document-picker';
import * as FileSystem from 'expo-file-system/legacy';
import * as ImagePicker from 'expo-image-picker';
import * as ImageManipulator from 'expo-image-manipulator';
import { ExpoSpeechRecognitionModule, useSpeechRecognitionEvent } from 'expo-speech-recognition';
import * as Speech from 'expo-speech';
import { memo, useCallback, useEffect, useRef, useState, type ComponentProps } from 'react';
import { router } from 'expo-router';
import {
  ActivityIndicator,
  Animated,
  Alert,
  Dimensions,
  FlatList,
  Image,
  Keyboard,
  KeyboardAvoidingView,
  Linking,
  Modal,
  NativeScrollEvent,
  NativeSyntheticEvent,
  Platform,
  Pressable,
  ScrollView,
  SectionList,
  StyleSheet,
  Text,
  TextInput,
  View,
  useWindowDimensions,
} from 'react-native';
import { SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';
import { useAuth } from '@/auth/AuthProvider';
import { ChatApiError, ChatDevice, ChatFileContent, ChatImageAttachment, ChatLiveEvent, ChatMessage, chatApi, ConversationSummary, MemoryCandidate, OpenWork, ProactiveSuggestion } from '@/data/chat-api';
import { useWiqoColors } from '@/theme';
import { useAppearance } from '@/settings/AppearanceProvider';
import { ChatReply } from '@/components/chat/ChatReply';
import { WiqoAgentMascot } from '@/components/chat/WiqoAgentMascot';
import { WiqoVoiceSession } from '@/components/chat/WiqoVoiceSession';
import { ActScreen } from '@/components/act/ActScreen';
import { cacheScopeForToken, readCache, writeCache } from '@/data/local-cache';

function newConversationId() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, character => {
    const value = Math.floor(Math.random() * 16);
    return (character === 'x' ? value : (value & 0x3) | 0x8).toString(16);
  });
}

function newMessage(role: ChatMessage['role'], content: string): ChatMessage {
  return { id: `${Date.now()}-${Math.random().toString(16).slice(2)}`, role, content, createdAt: Date.now() };
}

function conversationGroups(items: ConversationSummary[]) {
  const today: ConversationSummary[] = [];
  const yesterday: ConversationSummary[] = [];
  const week: ConversationSummary[] = [];
  const older: ConversationSummary[] = [];
  const now = new Date();
  const startToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  for (const item of items) {
    const stamp = item.updatedAt ? Date.parse(item.updatedAt) : 0;
    const date = Number.isFinite(stamp) ? stamp : 0;
    if (date >= startToday) today.push(item);
    else if (date >= startToday - 86_400_000) yesterday.push(item);
    else if (date >= startToday - 7 * 86_400_000) week.push(item);
    else older.push(item);
  }
  return [
    { title: 'Bugün', items: today },
    { title: 'Dün', items: yesterday },
    { title: 'Son 7 gün', items: week },
    { title: 'Daha eski', items: older },
  ].filter(section => section.items.length > 0);
}

function accountColor(key?: string) {
  const palette: Record<string, string> = { blue: '#2978f0', teal: '#0da0a3', green: '#33a854', orange: '#f28721', pink: '#e84987', purple: '#8c54e6', graphite: '#5c6470' };
  return palette[key ?? ''] ?? '#555bd8';
}

const automationTemplates = [
  { title: 'Sabah brifingi', prompt: "Her sabah 08:00'de hava durumunu ve takvimimdeki bugünkü etkinlikleri özetleyen bir otomasyon oluştur." },
  { title: 'Haftalık takvim özeti', prompt: "Her Pazartesi 08:30'da bu haftaki takvim etkinliklerimi özetleyen bir otomasyon oluştur." },
  { title: 'Pil uyarısı', prompt: "PC'min pili %20'nin altına düştüğünde haber veren bir otomasyon oluştur." },
];

type ChatMessageRowProps = {
  item: ChatMessage;
  colors: ReturnType<typeof useWiqoColors>;
  typeScale: number;
  activeQuestionId?: string;
  sending: boolean;
  locationCity: string;
  onLocationCityChange: (value: string) => void;
  onFollowUp: (text: string) => void;
  onClarification: (text: string, taskId: string, questionId: string) => void;
  onAsk: (text: string) => void;
  onResolveConfirmation: (messageId: string, confirmationId: string, approved: boolean) => void;
  onContinueLocation: (messageId: string, requestId: string) => void;
};

const ChatMessageRow = memo(function ChatMessageRow({ item, colors, typeScale, activeQuestionId, sending, locationCity, onLocationCityChange, onFollowUp, onClarification, onAsk, onResolveConfirmation, onContinueLocation }: ChatMessageRowProps) {
  return (
    <View style={[styles.messageRow, item.role === 'user' ? styles.userRow : styles.assistantRow]}>
      {item.role === 'user' ? <View style={[styles.messageBubble, styles.userBubble, { backgroundColor: colors.surface }]}><Text selectable style={[styles.messageText, { color: colors.ink, fontSize: 16 * typeScale, lineHeight: 23 * typeScale }]}>{item.content}</Text></View> : item.role === 'assistant' ? <View style={styles.assistantContent}>
        <ChatReply
          text={item.content}
          widgets={item.widgets}
          artifacts={item.artifacts}
          streaming={sending && !item.content}
          onFollowUp={onFollowUp}
          onClarification={onClarification}
          onAsk={onAsk}
          onFix={onFollowUp}
          onAct={onFollowUp}
          activeQuestionId={activeQuestionId}
          sending={sending}
        />
        {item.liveEvents?.map((event, index) => <Text key={`${String(event.id ?? event.type)}-${index}`} style={[styles.liveEvent, { color: colors.muted }]}>{String(event.label ?? event.summary ?? event.message ?? '')}</Text>)}
        {item.steps?.map((step, index) => <View key={String(step.id ?? index)} style={[styles.resultCard, { backgroundColor: colors.surface }]}><MaterialCommunityIcons name="laptop" size={18} color={colors.muted} /><Text style={[styles.resultCardText, { color: colors.ink }]}>{String(step.summary ?? step.type ?? 'PC görevi')}</Text></View>)}
        {item.confirmations?.map(confirmation => <View key={confirmation.id} style={[styles.confirmCard, { backgroundColor: colors.surface }]}><Text style={[styles.resultCardText, { color: colors.ink }]}>{confirmation.title}</Text><Text style={[styles.activityDetail, { color: colors.muted }]}>{confirmation.summary}</Text><View style={styles.confirmActions}><Pressable accessibilityRole="button" onPress={() => onResolveConfirmation(item.id, confirmation.id, false)}><Text style={[styles.confirmActionText, { color: colors.muted }]}>Reddet</Text></Pressable><Pressable accessibilityRole="button" onPress={() => onResolveConfirmation(item.id, confirmation.id, true)}><Text style={[styles.confirmActionText, { color: colors.accent }]}>Onayla</Text></Pressable></View></View>)}
        {item.locationRequestId ? <View style={[styles.confirmCard, { backgroundColor: colors.surface }]}><Text style={[styles.resultCardText, { color: colors.ink }]}>Hava durumu için şehir</Text><View style={styles.locationRow}><TextInput value={locationCity} onChangeText={onLocationCityChange} placeholder="Şehir adı (boş bırakılabilir)" placeholderTextColor={colors.muted} style={[styles.locationInput, { color: colors.ink }]} /><Pressable accessibilityRole="button" onPress={() => onContinueLocation(item.id, item.locationRequestId!)}><Text style={[styles.confirmActionText, { color: colors.accent }]}>Devam</Text></Pressable></View></View> : null}
      </View> : <Text style={[styles.errorText, { color: colors.danger }]}>{item.content}</Text>}
    </View>
  );
});

export default function ChatHomeScreen() {
  const { token, signOut } = useAuth();
  const colors = useWiqoColors();
  const { textScale, speakReplies } = useAppearance();
  const typeScale = textScale === 'small' ? 0.9 : textScale === 'large' ? 1.16 : 1;
  const insets = useSafeAreaInsets();
  const { width: windowWidth } = useWindowDimensions();
  const listRef = useRef<FlatList<ChatMessage>>(null);
  const nearLatestRef = useRef(true);
  const pendingDeltaRef = useRef({ messageId: '', text: '' });
  const deltaTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const menuChatButtonRef = useRef<View>(null);
  const menuDeviceButtonRef = useRef<View>(null);
  const menuAttachButtonRef = useRef<View>(null);
  const menuProfileButtonRef = useRef<View>(null);
  const [conversationId, setConversationId] = useState(newConversationId);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [hydratedCacheToken, setHydratedCacheToken] = useState<string | null>(null);
  const cacheHydrated = !token || hydratedCacheToken === token;
  const [draft, setDraft] = useState('');
  const [sending, setSending] = useState(false);
  const [progress, setProgress] = useState('');
  const [error, setError] = useState('');
  const [historyVisible, setHistoryVisible] = useState(false);
  const [history, setHistory] = useState<ConversationSummary[]>([]);
  const [historyLoading, setHistoryLoading] = useState(false);
  const [historyError, setHistoryError] = useState('');
  const [historyQuery, setHistoryQuery] = useState('');
  const [profile, setProfile] = useState<{ email: string; displayName?: string; avatarKind?: string; avatarEmoji?: string; avatarColor?: string; avatarImage?: string } | null>(null);
  const [contextMenu, setContextMenu] = useState<'chat' | 'attachments' | 'devices' | 'conversation' | 'confirm-delete' | 'profile' | 'templates' | null>(null);
  const [menuAnchor, setMenuAnchor] = useState<{ x: number; y: number; width: number; height: number } | null>(null);
  const [menuBounds, setMenuBounds] = useState(Dimensions.get('window'));
  const [creatingAgent, setCreatingAgent] = useState(false);
  const [locationCity, setLocationCity] = useState('');
  const [proactiveSuggestions, setProactiveSuggestions] = useState<ProactiveSuggestion[]>([]);
  const [memoryCandidates, setMemoryCandidates] = useState<MemoryCandidate[]>([]);
  const [openWork, setOpenWork] = useState<OpenWork | null>(null);
  const composerInputRef = useRef<TextInput>(null);
  const actDictationTargetRef = useRef<((text: string) => void) | null>(null);
  const actVoiceCommandRef = useRef<((text: string) => void) | null>(null);
  const voiceTargetRef = useRef<'chat' | 'act'>('chat');
  const voiceActiveRef = useRef(false);
  const voiceSendingRef = useRef(false);
  const voiceSpeakingRef = useRef(false);
  const voiceSpeechEnabledRef = useRef(speakReplies);
  const voiceTranscriptRef = useRef('');
  const voiceLastSubmittedRef = useRef('');
  const voiceRestartTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const startVoiceRecognitionRef = useRef<() => void>(() => undefined);
  const submitTranscriptRef = useRef<(text: string) => void>(() => undefined);
  const drainVoiceQueueRef = useRef<() => void>(() => undefined);
  const voiceQueueRef = useRef<string[]>([]);
  const [contextConversation, setContextConversation] = useState<ConversationSummary | null>(null);
  const [devices, setDevices] = useState<ChatDevice[]>([]);
  const [devicesLoading, setDevicesLoading] = useState(false);
  const [menuError, setMenuError] = useState('');
  const [attachments, setAttachments] = useState<ChatImageAttachment[]>([]);
  const [files, setFiles] = useState<ChatFileContent[]>([]);
  const [listening, setListening] = useState(false);
  const [voiceSessionActive, setVoiceSessionActive] = useState(false);
  const [voiceError, setVoiceError] = useState('');
  const [voiceTarget, setVoiceTarget] = useState<'chat' | 'act'>('chat');
  const [voiceLevel, setVoiceLevel] = useState(0);
  const [voiceTranscript, setVoiceTranscript] = useState('');
  const [voiceSpeaking, setVoiceSpeaking] = useState(false);
  const [voiceSpeechEnabled, setVoiceSpeechEnabled] = useState(speakReplies);
  const [voiceQueue, setVoiceQueue] = useState<string[]>([]);
  const [actMode, setActMode] = useState(false);
  const headerLeftInset = Math.max(14, insets.left);
  const headerRightInset = Math.max(6, insets.right);
  const headerActionWidth = actMode ? 44 : 82;
  const headerModeWidth = Math.max(112, Math.min(
    190,
    2 * (windowWidth / 2 - headerLeftInset - 44 - 8),
    2 * (windowWidth - headerRightInset - headerActionWidth - 8 - windowWidth / 2),
  ));
  const panelX = useRef(new Animated.Value(-304)).current;
  const scrimOpacity = useRef(new Animated.Value(0)).current;
  const panelWidth = 304;
  const visibleHistory = historyQuery.trim()
    ? history.filter(item => `${item.title} ${item.preview}`.toLocaleLowerCase('tr').includes(historyQuery.trim().toLocaleLowerCase('tr')))
    : history;
  const historySections = conversationGroups(visibleHistory);
  const contextCardWidth = Math.min(282, Math.max(220, menuBounds.width - 24));
  const contextCardHeight = Math.min(menuBounds.height * 0.76, 380);
  const estimatedMenuHeight = contextMenu === 'attachments' ? 208
    : contextMenu === 'chat' ? 256
    : contextMenu === 'templates' ? 208
    : contextMenu === 'devices' ? 300
    : contextMenu === 'profile' ? 160
    : contextMenu === 'confirm-delete' ? 190
    : 150;
  const menuPlacementHeight = Math.min(contextCardHeight, estimatedMenuHeight);
  const contextLeft = menuAnchor
    ? Math.min(Math.max(12, menuAnchor.x + menuAnchor.width / 2 - contextCardWidth / 2), menuBounds.width - contextCardWidth - 12)
    : Math.max(12, (menuBounds.width - contextCardWidth) / 2);
  const contextTop = menuAnchor
    ? Math.max(insets.top + 8, Math.min(
      menuAnchor.y > menuBounds.height * 0.58 ? menuAnchor.y - menuPlacementHeight - 8 : menuAnchor.y + menuAnchor.height + 8,
      menuBounds.height - menuPlacementHeight - Math.max(insets.bottom, 12) - 8,
    ))
    : Math.max(insets.top + 48, (menuBounds.height - contextCardHeight) / 2);
  const accountName = profile?.displayName?.trim() || profile?.email?.split('@')[0] || 'Wiqo hesabı';

  useEffect(() => {
    if (!token) { setHydratedCacheToken(null); return; }
    let active = true;
    void (async () => {
      const scope = await cacheScopeForToken(token);
      const savedId = await readCache<string>(scope, 'chat:active-id', 365 * 86_400_000);
      const restoredId = savedId?.value || conversationId;
      if (savedId?.value) setConversationId(savedId.value);
      const [savedMessages, savedHistory, savedSuggestions, savedMemory, savedProfile] = await Promise.all([
        readCache<ChatMessage[]>(scope, `chat:messages:${restoredId}`, 180 * 86_400_000),
        readCache<ConversationSummary[]>(scope, 'chat:history', 30 * 86_400_000),
        readCache<ProactiveSuggestion[]>(scope, 'derived:proactive-suggestions', 12 * 60 * 60_000),
        readCache<MemoryCandidate[]>(scope, 'api:memory/candidates', 30 * 60_000),
        readCache<{ email: string; displayName?: string; avatarKind?: string; avatarEmoji?: string; avatarColor?: string }>(scope, 'api:profile', 6 * 60 * 60_000),
      ]);
      if (!active) return;
      setMessages(savedMessages?.value ?? []);
      if (savedHistory) setHistory(savedHistory.value);
      if (savedSuggestions) setProactiveSuggestions(savedSuggestions.value);
      if (savedMemory) setMemoryCandidates(savedMemory.value.filter(candidate => candidate.status === 'pending'));
      if (savedProfile) setProfile(savedProfile.value);
      await writeCache(scope, 'chat:active-id', restoredId, 365 * 86_400_000, 365 * 86_400_000);
      setHydratedCacheToken(token);
    })().catch(() => { if (active) setHydratedCacheToken(token); });
    return () => { active = false; };
  }, [token]);

  useEffect(() => {
    if (!token || !cacheHydrated) return;
    const timer = setTimeout(() => {
      void cacheScopeForToken(token)
        .then(scope => writeCache(scope, `chat:messages:${conversationId}`, messages, 30 * 86_400_000, 150 * 86_400_000))
        .catch(() => undefined);
    }, 500);
    return () => clearTimeout(timer);
  }, [cacheHydrated, conversationId, messages, token]);

  useEffect(() => () => {
    if (deltaTimerRef.current) clearTimeout(deltaTimerRef.current);
  }, []);

  useEffect(() => {
    if (!token || !cacheHydrated) return;
    let active = true;
    void Promise.all([
      chatApi.refreshProactiveSuggestions(token).catch(() => [] as ProactiveSuggestion[]),
      chatApi.getMemoryCandidates(token).catch(() => [] as MemoryCandidate[]),
    ]).then(([suggestions, candidates]) => {
      if (!active) return;
      setProactiveSuggestions(suggestions);
      setMemoryCandidates(candidates.filter(candidate => candidate.status === 'pending'));
    });
    return () => { active = false; };
  }, [cacheHydrated, token]);

  useEffect(() => {
    if (!token || !cacheHydrated || messages.length === 0) { setOpenWork(null); return; }
    if (sending) return;
    let active = true;
    setOpenWork(null);
    void chatApi.getOpenWork(token, conversationId).then(value => { if (active) setOpenWork(value); }).catch(() => { if (active) setOpenWork(null); });
    return () => { active = false; };
  }, [cacheHydrated, conversationId, messages.length, sending, token]);

  useSpeechRecognitionEvent('start', () => setListening(true));
  useSpeechRecognitionEvent('end', () => {
    setListening(false);
    if (!voiceActiveRef.current || voiceSendingRef.current || voiceSpeakingRef.current) return;
    if (voiceRestartTimerRef.current) clearTimeout(voiceRestartTimerRef.current);
    voiceRestartTimerRef.current = setTimeout(() => startVoiceRecognitionRef.current(), 450);
  });
  useSpeechRecognitionEvent('result', event => {
    const transcript = event.results[event.results.length - 1]?.transcript?.trim();
    if (!transcript) return;
    if (voiceActiveRef.current) {
      voiceTranscriptRef.current = transcript;
      setVoiceTranscript(transcript);
      if (event.isFinal && transcript !== voiceLastSubmittedRef.current) {
        voiceLastSubmittedRef.current = transcript;
        voiceTranscriptRef.current = '';
        if (voiceTargetRef.current === 'act') {
          setVoiceTranscript(transcript);
          actVoiceCommandRef.current?.(transcript);
        } else {
          setVoiceTranscript('');
          submitTranscriptRef.current(transcript);
        }
      }
      return;
    }
    if (event.isFinal && actDictationTargetRef.current) {
      const accept = actDictationTargetRef.current;
      actDictationTargetRef.current = null;
      accept(transcript);
      return;
    }
    if (event.isFinal) setDraft(current => current.trim() ? `${current.trim()} ${transcript}` : transcript);
  });
  useSpeechRecognitionEvent('volumechange', event => setVoiceLevel(Math.max(0, Math.min(1, (event.value + 2) / 12))));
  useSpeechRecognitionEvent('error', event => {
    setListening(false);
    if (event.error !== 'aborted' && event.error !== 'no-speech') {
      const message = 'Ses tanıma kullanılamadı. Mikrofon ve konuşma hizmetini kontrol et.';
      if (voiceActiveRef.current) setVoiceError(message);
      else setError(message);
    }
  });

  const closeHistory = useCallback(() => {
    Animated.parallel([
      Animated.timing(panelX, { toValue: -panelWidth, duration: 200, useNativeDriver: true }),
      Animated.timing(scrimOpacity, { toValue: 0, duration: 180, useNativeDriver: true }),
    ]).start(({ finished }) => { if (finished) setHistoryVisible(false); });
  }, [panelX, scrimOpacity]);

  const startNewChat = useCallback(() => {
    Keyboard.dismiss();
    const id = newConversationId();
    setConversationId(id);
    if (token) void cacheScopeForToken(token).then(scope => writeCache(scope, 'chat:active-id', id, 365 * 86_400_000, 365 * 86_400_000));
    setMessages([]);
    setDraft('');
    setAttachments([]);
    setFiles([]);
    setProgress('');
    setError('');
    closeHistory();
  }, [closeHistory, token]);

  const openHistory = useCallback(async () => {
    setHistoryVisible(true);
    setHistoryError('');
    setHistoryQuery('');
    panelX.setValue(-panelWidth);
    scrimOpacity.setValue(0);
    Animated.parallel([
      Animated.spring(panelX, { toValue: 0, damping: 28, stiffness: 260, mass: 0.85, useNativeDriver: true }),
      Animated.timing(scrimOpacity, { toValue: 1, duration: 220, useNativeDriver: true }),
    ]).start();
    if (!token) return;
    const scope = await cacheScopeForToken(token);
    const cachedHistory = await readCache<ConversationSummary[]>(scope, 'chat:history', 30 * 86_400_000);
    if (cachedHistory) setHistory(cachedHistory.value);
    setHistoryLoading(!cachedHistory);
    try {
      const conversations = await chatApi.listConversations(token);
      setHistory(conversations);
      void writeCache(scope, 'chat:history', conversations, 30_000, 30 * 86_400_000);
      void chatApi.getProfile(token).then(setProfile).catch(() => undefined);
    }
    catch (cause) {
      if (!cachedHistory) setHistory([]);
      setHistoryError(cause instanceof ChatApiError ? cause.message : 'Sohbet geçmişi alınamadı.');
    }
    finally { setHistoryLoading(false); }
  }, [panelX, scrimOpacity, token]);

  const selectConversation = useCallback(async (item: ConversationSummary) => {
    if (!token) return;
    closeHistory();
    const scope = await cacheScopeForToken(token);
    void writeCache(scope, 'chat:active-id', item.id, 365 * 86_400_000, 365 * 86_400_000);
    const cachedMessages = await readCache<ChatMessage[]>(scope, `chat:messages:${item.id}`, 180 * 86_400_000);
    setConversationId(item.id);
    setMessages(cachedMessages?.value ?? []);
    setError('');
    setSending(!cachedMessages);
    try {
      const remoteMessages = await chatApi.loadMessages(token, item.id);
      setMessages(remoteMessages);
      void writeCache(scope, `chat:messages:${item.id}`, remoteMessages, 30 * 86_400_000, 150 * 86_400_000);
    }
    catch (cause) { setError(cause instanceof ChatApiError ? cause.message : 'Sohbet geçmişi yüklenemedi.'); }
    finally { setSending(false); }
  }, [closeHistory, token]);

  const openContextMenu = useCallback((menu: NonNullable<typeof contextMenu>, anchor?: View | null, point?: { x: number; y: number }) => {
    setMenuError('');
    if (anchor) {
      anchor.measureInWindow((x, y, width, height) => {
        setMenuAnchor({ x, y, width, height });
        setContextMenu(menu);
      });
    } else {
      setMenuAnchor(point ? { x: point.x, y: point.y, width: 0, height: 0 } : null);
      setContextMenu(menu);
    }
  }, []);

  const openDevices = useCallback(async (anchor?: View | null) => {
    openContextMenu('devices', anchor);
    setMenuError('');
    if (!token) return;
    setDevicesLoading(true);
    try { setDevices(await chatApi.listDevices(token)); }
    catch (cause) { setMenuError(cause instanceof ChatApiError ? cause.message : 'Cihaz bilgileri alınamadı.'); }
    finally { setDevicesLoading(false); }
  }, [openContextMenu, token]);

  const openActivity = useCallback(() => {
    setActMode(true);
    setError('');
  }, []);

  const deleteConversation = useCallback(async () => {
    if (!contextConversation || !token) return;
    setMenuError('');
    try {
      await chatApi.deleteConversation(token, contextConversation.id);
      setHistory(current => current.filter(item => item.id !== contextConversation.id));
      if (conversationId === contextConversation.id) startNewChat();
      setContextMenu(null);
      setContextConversation(null);
    } catch (cause) {
      setMenuError(cause instanceof ChatApiError ? cause.message : 'Sohbet silinemedi.');
    }
  }, [contextConversation, conversationId, startNewChat, token]);

  const pickPhotos = useCallback(async (camera = false) => {
    setContextMenu(null);
    try {
      if (camera) {
        const current = await ImagePicker.getCameraPermissionsAsync();
        const permission = current.granted ? current : await ImagePicker.requestCameraPermissionsAsync();
        if (!permission.granted) {
          if (!permission.canAskAgain) {
            Alert.alert('Kamera izni gerekli', 'Fotoğraf çekmek için Wiqo’nun kamera iznini Android ayarlarından aç.', [
              { text: 'Şimdi değil', style: 'cancel' },
              { text: 'Ayarları aç', onPress: () => { void Linking.openSettings(); } },
            ]);
          } else {
            setError('Fotoğraf çekmek için kamera izni gerekiyor.');
          }
          return;
        }
      }
      const result = camera
        ? await ImagePicker.launchCameraAsync({ mediaTypes: ['images'], base64: true, quality: 0.82 })
        : await ImagePicker.launchImageLibraryAsync({ mediaTypes: ['images'], allowsMultipleSelection: true, selectionLimit: Math.max(1, 4 - attachments.length), base64: true, quality: 0.82 });
      if (result.canceled) return;
      const fresh = [] as ChatImageAttachment[];
      for (const asset of result.assets ?? []) {
        const resize = Math.max(asset.width, asset.height) > 2048
          ? [{ resize: asset.width >= asset.height ? { width: 2048 } : { height: 2048 } }]
          : [];
        const prepared = await ImageManipulator.manipulateAsync(
          asset.uri,
          resize,
          { compress: 0.76, format: ImageManipulator.SaveFormat.JPEG, base64: true },
        );
        if (prepared.base64) fresh.push({ name: asset.fileName || `Görsel-${Date.now()}.jpg`, mimeType: 'image/jpeg', dataBase64: prepared.base64 });
      }
      if (attachments.length + fresh.length > 4) throw new Error('Bir seferde en fazla dört görsel ekleyebilirsin.');
      if (fresh.length !== (result.assets?.length ?? 0)) throw new Error('Görsel okunamadı. Tekrar seç.');
      if (fresh.some(item => item.dataBase64.length > 10_700_000) || attachments.reduce((total, item) => total + item.dataBase64.length, 0) + fresh.reduce((total, item) => total + item.dataBase64.length, 0) > 18_000_000) throw new Error('Eklerin boyutu çok büyük. Daha küçük görseller seç.');
      setAttachments(current => [...current, ...fresh]);
      setError('');
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Görsel eklenemedi.'); }
  }, [attachments.length]);

  const pickTextFiles = useCallback(async () => {
    setContextMenu(null);
    try {
      const result = await DocumentPicker.getDocumentAsync({ multiple: true, copyToCacheDirectory: true });
      if (result.canceled) return;
      if (files.length + result.assets.length > 5) throw new Error('Bir seferde en fazla beş dosya ekleyebilirsin.');
      const supported = /\.(txt|md|json|csv|tsv|html|xml|log)$/i;
      const prepared: ChatFileContent[] = [];
      for (const asset of result.assets) {
        if (!supported.test(asset.name)) throw new Error(`${asset.name}: şimdilik metin, CSV, JSON veya HTML dosyası seçebilirsin.`);
        if (asset.size && asset.size > 50 * 1024 * 1024) throw new Error(`${asset.name}: dosya 50 MB sınırını aşıyor.`);
        const text = await FileSystem.readAsStringAsync(asset.uri, { encoding: FileSystem.EncodingType.UTF8 });
        if (!text.trim()) throw new Error(`${asset.name} içinde okunabilir metin yok.`);
        prepared.push({ name: asset.name, type: /\.(csv|tsv)$/i.test(asset.name) ? 'csv' : 'text', byteCount: asset.size ?? text.length, source: 'text', text: text.slice(0, 120_000), truncated: text.length > 120_000, tables: [] });
      }
      if (prepared.reduce((total, item) => total + item.text.length, 0) > 600_000) throw new Error('Eklediğin dosyaların toplam metni çok büyük. Daha az dosya seç.');
      setFiles(current => [...current, ...prepared]);
      setError('');
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Dosya eklenemedi.'); }
  }, [files.length]);

  const startDictation = useCallback(async () => {
    if (listening) { ExpoSpeechRecognitionModule.stop(); return; }
    setError('');
    try {
      const permission = await ExpoSpeechRecognitionModule.requestPermissionsAsync();
      if (!permission.granted) {
        if (!permission.canAskAgain) {
          Alert.alert('Mikrofon izni gerekli', 'Sesle yazmayı kullanmak için Wiqo’nun mikrofon iznini Android ayarlarından aç.', [
            { text: 'Şimdi değil', style: 'cancel' },
            { text: 'Ayarları aç', onPress: () => { void Linking.openSettings(); } },
          ]);
        } else setError('Sesle yazmak için mikrofon izni gerekiyor.');
        return;
      }
      if (!ExpoSpeechRecognitionModule.isRecognitionAvailable()) { setError('Bu cihazda konuşma tanıma hizmeti kullanılamıyor.'); return; }
      ExpoSpeechRecognitionModule.start({ lang: 'tr-TR', interimResults: false, continuous: false });
    } catch {
      setError('Sesle yazma başlatılamadı. Tekrar deneyebilirsin.');
    }
  }, [listening]);

  const startVoiceRecognition = useCallback(() => {
    if (!voiceActiveRef.current || voiceSendingRef.current || voiceSpeakingRef.current) return;
    try {
      voiceLastSubmittedRef.current = '';
      ExpoSpeechRecognitionModule.start({
        lang: 'tr-TR', continuous: true, interimResults: true, addsPunctuation: true,
        volumeChangeEventOptions: { enabled: true, intervalMillis: 100 },
      });
    } catch { setError('Sesli sohbet başlatılamadı. Tekrar deneyebilirsin.'); }
  }, []);
  startVoiceRecognitionRef.current = startVoiceRecognition;

  const closeVoiceSession = useCallback(() => {
    voiceActiveRef.current = false;
    voiceSendingRef.current = false;
    voiceSpeakingRef.current = false;
    if (voiceRestartTimerRef.current) clearTimeout(voiceRestartTimerRef.current);
    voiceRestartTimerRef.current = null;
    ExpoSpeechRecognitionModule.stop();
    void Speech.stop();
    setVoiceSessionActive(false);
    setVoiceSpeaking(false);
    setVoiceTranscript('');
    setVoiceError('');
    voiceTranscriptRef.current = '';
    voiceQueueRef.current = [];
    setVoiceQueue([]);
    setVoiceLevel(0);
    voiceTargetRef.current = 'chat';
    actVoiceCommandRef.current = null;
    setVoiceTarget('chat');
  }, []);

  const startVoiceSession = useCallback(async (options?: { target?: 'chat' | 'act'; onCommand?: (text: string) => void }) => {
    if (voiceActiveRef.current) { closeVoiceSession(); return; }
    setError('');
    try {
      const permission = await ExpoSpeechRecognitionModule.requestPermissionsAsync();
      if (!permission.granted) {
        if (!permission.canAskAgain) {
          Alert.alert('Mikrofon izni gerekli', 'Sesli sohbet için Wiqo’nun mikrofon iznini Android ayarlarından aç.', [
            { text: 'Şimdi değil', style: 'cancel' },
            { text: 'Ayarları aç', onPress: () => { void Linking.openSettings(); } },
          ]);
        } else setError('Sesli sohbet için mikrofon izni gerekiyor.');
        return;
      }
      const recognitionAvailable = ExpoSpeechRecognitionModule.isRecognitionAvailable();
      voiceActiveRef.current = true;
      const target = options?.target ?? 'chat';
      voiceTargetRef.current = target;
      actVoiceCommandRef.current = target === 'act' ? options?.onCommand ?? null : null;
      setVoiceTarget(target);
      voiceSendingRef.current = false;
      voiceSpeakingRef.current = false;
      voiceSpeechEnabledRef.current = speakReplies;
      setVoiceSpeechEnabled(speakReplies);
      setVoiceTranscript('');
      voiceTranscriptRef.current = '';
      voiceLastSubmittedRef.current = '';
      setVoiceError(recognitionAvailable ? '' : 'Ses tanıma kullanılamıyor. Mikrofon ve konuşma hizmetini kontrol et.');
      voiceQueueRef.current = [];
      setVoiceQueue([]);
      setVoiceSessionActive(true);
      if (recognitionAvailable) startVoiceRecognitionRef.current();
    } catch {
      if (voiceActiveRef.current) setVoiceError('Sesli sohbet açılamadı. Mikrofon iznini kontrol edip yeniden dene.');
      else setError('Sesli sohbet açılamadı. Mikrofon iznini kontrol edip yeniden dene.');
    }
  }, [closeVoiceSession, speakReplies]);

  useEffect(() => {
    if (voiceSessionActive && ((actMode && voiceTarget !== 'act') || (!actMode && voiceTarget !== 'chat'))) closeVoiceSession();
  }, [actMode, closeVoiceSession, voiceSessionActive, voiceTarget]);

  const toggleVoiceSpeaker = useCallback(() => {
    const enabled = !voiceSpeechEnabledRef.current;
    voiceSpeechEnabledRef.current = enabled;
    setVoiceSpeechEnabled(enabled);
    if (!enabled) {
      voiceSpeakingRef.current = false;
      setVoiceSpeaking(false);
      void Speech.stop();
      if (voiceActiveRef.current) {
        if (voiceQueueRef.current.length) drainVoiceQueueRef.current();
        else startVoiceRecognitionRef.current();
      }
    }
  }, []);

  const toggleVoiceListening = useCallback(() => {
    const transcript = voiceTranscriptRef.current.trim();
    if (transcript && !voiceSendingRef.current) {
      voiceLastSubmittedRef.current = transcript;
      voiceTranscriptRef.current = '';
      setVoiceTranscript('');
      if (voiceTargetRef.current === 'act') actVoiceCommandRef.current?.(transcript);
      else submitTranscriptRef.current(transcript);
      ExpoSpeechRecognitionModule.stop();
      return;
    }
  }, []);

  const removeQueuedVoiceTurn = useCallback((index: number) => {
    voiceQueueRef.current = voiceQueueRef.current.filter((_, at) => at !== index);
    setVoiceQueue(voiceQueueRef.current);
  }, []);

  useEffect(() => () => {
    voiceActiveRef.current = false;
    if (voiceRestartTimerRef.current) clearTimeout(voiceRestartTimerRef.current);
    ExpoSpeechRecognitionModule.stop();
    void Speech.stop();
  }, []);

  const flushPendingDelta = useCallback(() => {
    if (deltaTimerRef.current) clearTimeout(deltaTimerRef.current);
    deltaTimerRef.current = null;
    const { messageId, text } = pendingDeltaRef.current;
    pendingDeltaRef.current = { messageId: '', text: '' };
    if (!messageId || !text) return;
    setMessages(current => current.map(message => message.id === messageId ? { ...message, content: `${message.content}${text}` } : message));
  }, []);

  const send = useCallback(async (textOverride?: string, clarification?: { taskId: string; questionId: string }) => {
    const text = (textOverride ?? draft).trim();
    if ((creatingAgent ? !text : !text && attachments.length === 0 && files.length === 0) || sending || !token || !cacheHydrated) return;
    Keyboard.dismiss();
    const userMessage = newMessage('user', text || 'Ekli dosyaları incele.');
    const assistantMessage = newMessage('assistant', '');
    const nextMessages = [...messages, userMessage, assistantMessage];
    setMessages(nextMessages);
    setDraft('');
    setSending(true);
    voiceSendingRef.current = voiceActiveRef.current;
    setProgress('Anlıyorum…');
    setError('');
    setCreatingAgent(false);
    let replyToSpeak = '';
    try {
      const result = await chatApi.sendMessage(token, conversationId, nextMessages.slice(0, -1), setProgress, attachments, files, creatingAgent, (event: ChatLiveEvent) => {
        if (event.type === 'usage' && event.messages && typeof event.messages === 'object') {
          const usage = event.messages as { used?: unknown; limit?: unknown };
          if (typeof usage.used === 'number' && typeof usage.limit === 'number') void chatApi.applyMessageUsage(token, usage.used, usage.limit);
        }
        if (event.type === 'delta' && typeof event.text === 'string') {
          if (pendingDeltaRef.current.messageId && pendingDeltaRef.current.messageId !== assistantMessage.id) flushPendingDelta();
          pendingDeltaRef.current.messageId = assistantMessage.id;
          pendingDeltaRef.current.text += event.text;
          if (!deltaTimerRef.current) deltaTimerRef.current = setTimeout(flushPendingDelta, 50);
          return;
        }
        if (event.type === 'reset') {
          if (deltaTimerRef.current) clearTimeout(deltaTimerRef.current);
          deltaTimerRef.current = null;
          pendingDeltaRef.current = { messageId: '', text: '' };
          setMessages(current => current.map(message => message.id === assistantMessage.id ? { ...message, content: '' } : message));
          return;
        }
        flushPendingDelta();
        setMessages(current => current.map(message => {
          if (message.id !== assistantMessage.id) return message;
          if (event.type === 'widget_update' && event.widget && typeof event.widget === 'object') {
            const widget = event.widget as Record<string, unknown> & { widgetId?: string; type?: string };
            const widgets = [...(message.widgets ?? [])];
            const existing = widgets.findIndex(item => (widget.widgetId && item.widgetId === widget.widgetId) || (!widget.widgetId && item.type === widget.type));
            if (existing >= 0) widgets[existing] = widget; else widgets.push(widget);
            return { ...message, widgets };
          }
          if (event.type === 'confirmation_needed') return { ...message, steps: Array.isArray(event.steps) ? event.steps as Record<string, unknown>[] : message.steps, confirmations: Array.isArray(event.backendConfirmations) ? event.backendConfirmations as ChatMessage['confirmations'] : message.confirmations };
          if (event.type === 'location_required' && typeof event.requestId === 'string') return { ...message, locationRequestId: event.requestId };
          if (['step_update', 'activity'].includes(event.type)) return { ...message, liveEvents: [...(message.liveEvents ?? []).slice(-5), event] };
          return message;
        }));
      }, clarification);
      flushPendingDelta();
      replyToSpeak = result.reply;
      setMessages(current => current.map(message => message.id === assistantMessage.id ? { ...message, content: result.reply || message.content, widgets: result.widgets.length ? result.widgets : message.widgets, artifacts: result.artifacts, confirmations: result.backendConfirmations, steps: result.steps } : message));
      setAttachments([]);
      setFiles([]);
      setCreatingAgent(false);
    } catch (cause) {
      flushPendingDelta();
      const message = cause instanceof ChatApiError ? cause.message : 'Yanıt alınamadı. Tekrar deneyebilirsin.';
      setMessages(current => current.filter(item => item.id !== assistantMessage.id));
      setError(message);
      if (creatingAgent) setCreatingAgent(true);
    } finally {
      setSending(false);
      setProgress('');
      voiceSendingRef.current = false;
      if (voiceActiveRef.current && replyToSpeak && voiceSpeechEnabledRef.current) {
        voiceSpeakingRef.current = true;
        setVoiceSpeaking(true);
        ExpoSpeechRecognitionModule.stop();
        Speech.speak(replyToSpeak.slice(0, Math.min(700, Speech.maxSpeechInputLength)), {
          language: 'tr-TR', rate: 0.98,
          onDone: () => {
            voiceSpeakingRef.current = false;
            setVoiceSpeaking(false);
            if (voiceActiveRef.current) drainVoiceQueueRef.current();
          },
          onError: () => {
            voiceSpeakingRef.current = false;
            setVoiceSpeaking(false);
            if (voiceActiveRef.current) drainVoiceQueueRef.current();
          },
        });
      } else if (voiceActiveRef.current) {
        if (voiceQueueRef.current.length) {
          if (voiceRestartTimerRef.current) clearTimeout(voiceRestartTimerRef.current);
          voiceRestartTimerRef.current = setTimeout(() => drainVoiceQueueRef.current(), 250);
        }
        else {
          if (voiceRestartTimerRef.current) clearTimeout(voiceRestartTimerRef.current);
          voiceRestartTimerRef.current = setTimeout(() => startVoiceRecognitionRef.current(), 250);
        }
      }
    }
  }, [attachments, cacheHydrated, conversationId, creatingAgent, draft, files, flushPendingDelta, messages, sending, token]);

  const resolveConfirmation = useCallback(async (messageId: string, confirmationId: string, approved: boolean) => {
    if (!token) return;
    try {
      await chatApi.resolveConfirmation(token, confirmationId, approved);
      setMessages(current => current.map(message => message.id === messageId ? { ...message, confirmations: (message.confirmations ?? []).filter(item => item.id !== confirmationId) } : message));
      setError('');
    } catch (cause) { setError(cause instanceof ChatApiError ? cause.message : 'Onay sunucuya iletilemedi.'); }
  }, [token]);

  const continueWeatherLocation = useCallback(async (messageId: string, requestId: string) => {
    if (!token) return;
    try {
      await chatApi.continueLocation(token, requestId, locationCity.trim() || null);
      setMessages(current => current.map(message => message.id === messageId ? { ...message, locationRequestId: undefined } : message));
      setLocationCity('');
    } catch (cause) { setError(cause instanceof ChatApiError ? cause.message : 'Konum isteği sunucuya iletilemedi.'); }
  }, [locationCity, token]);

  const sendRef = useRef(send);
  sendRef.current = send;
  submitTranscriptRef.current = text => {
    if (voiceActiveRef.current && voiceSendingRef.current) {
      if (voiceQueueRef.current.length >= 3) return;
      voiceQueueRef.current = [...voiceQueueRef.current, text];
      setVoiceQueue(voiceQueueRef.current);
      return;
    }
    void sendRef.current(text);
  };
  drainVoiceQueueRef.current = () => {
    if (!voiceActiveRef.current || voiceSendingRef.current || voiceSpeakingRef.current) return;
    const next = voiceQueueRef.current.shift();
    setVoiceQueue([...voiceQueueRef.current]);
    if (next) submitTranscriptRef.current(next);
    else startVoiceRecognitionRef.current();
  };
  const sendFollowUp = useCallback((text: string) => { void sendRef.current(text); }, []);
  const sendClarification = useCallback((text: string, taskId: string, questionId: string) => { void sendRef.current(text, { taskId, questionId }); }, []);
  const askFollowUp = useCallback((text: string) => { setDraft(text); setTimeout(() => composerInputRef.current?.focus(), 80); }, []);
  const resolveConfirmationRef = useRef(resolveConfirmation);
  resolveConfirmationRef.current = resolveConfirmation;
  const resolveConfirmationFromRow = useCallback((messageId: string, confirmationId: string, approved: boolean) => { void resolveConfirmationRef.current(messageId, confirmationId, approved); }, []);
  const continueLocationRef = useRef(continueWeatherLocation);
  continueLocationRef.current = continueWeatherLocation;
  const continueLocationFromRow = useCallback((messageId: string, requestId: string) => { void continueLocationRef.current(messageId, requestId); }, []);

  const contextualAction = (label: string, icon: ComponentProps<typeof MaterialCommunityIcons>['name'], onPress: () => void, destructive = false) => (
    <Pressable key={label} accessibilityRole="button" onPress={onPress} style={styles.contextAction}>
      <MaterialCommunityIcons name={icon} size={20} color={destructive ? colors.danger : colors.ink} />
      <Text style={[styles.contextActionText, { color: destructive ? colors.danger : colors.ink }]}>{label}</Text>
    </Pressable>
  );

  const lastChatMessage = [...messages].reverse().find(message => message.role !== 'system');
  const latestAssistantMessage = [...messages].reverse().find(message => message.role === 'assistant' && (message.content.trim() || message.widgets?.length || message.artifacts?.length));
  const activeQuestionId = lastChatMessage?.role === 'assistant'
    ? [...(lastChatMessage.widgets ?? [])].reverse().find(widget => widget.type === 'clarification' && typeof widget.questionId === 'string' && typeof widget.taskId === 'string')?.questionId
    : undefined;

  const rowRuntimeRef = useRef({ activeQuestionId, sending, locationCity });
  rowRuntimeRef.current = { activeQuestionId, sending, locationCity };
  const renderMessage = useCallback(({ item }: { item: ChatMessage }) => {
    const runtime = rowRuntimeRef.current;
    const questionId = item.role === 'assistant' ? item.widgets?.find(widget => widget.type === 'clarification' && typeof widget.questionId === 'string')?.questionId : undefined;
    const activeRowQuestion = typeof questionId === 'string' && questionId === runtime.activeQuestionId ? questionId : undefined;
    return <ChatMessageRow
      item={item}
      colors={colors}
      typeScale={typeScale}
      activeQuestionId={activeRowQuestion}
      sending={!!activeRowQuestion && runtime.sending}
      locationCity={item.locationRequestId ? runtime.locationCity : ''}
      onLocationCityChange={setLocationCity}
      onFollowUp={sendFollowUp}
      onClarification={sendClarification}
      onAsk={askFollowUp}
      onResolveConfirmation={resolveConfirmationFromRow}
      onContinueLocation={continueLocationFromRow}
    />;
  }, [askFollowUp, colors, continueLocationFromRow, resolveConfirmationFromRow, sendClarification, sendFollowUp, typeScale]);
  const handleMessageScroll = useCallback((event: NativeSyntheticEvent<NativeScrollEvent>) => {
    const { contentOffset, contentSize, layoutMeasurement } = event.nativeEvent;
    nearLatestRef.current = contentSize.height - layoutMeasurement.height - contentOffset.y < 120;
  }, []);
  const followLatestIfVisible = useCallback(() => {
    if (nearLatestRef.current) listRef.current?.scrollToEnd({ animated: false });
  }, []);

  return (
    <SafeAreaView edges={['top', 'bottom']} style={[styles.safeArea, { backgroundColor: colors.canvas }]}>
      <KeyboardAvoidingView style={styles.screen} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <View style={[styles.header, { paddingLeft: headerLeftInset, paddingRight: headerRightInset }]}>
          <Pressable accessibilityRole="button" accessibilityLabel="Sohbet geçmişi" onPress={() => void openHistory()} style={[styles.glassCircle, styles.headerCircle]}>
            <MaterialCommunityIcons name="menu" size={23} color={colors.muted} />
          </Pressable>
          <View style={[styles.modeCapsule, styles.glassSurface, { width: headerModeWidth, marginLeft: -headerModeWidth / 2, borderColor: colors.line }]}>
            <Pressable accessibilityRole="button" accessibilityState={{ selected: !actMode }} onPress={() => { setActMode(false); setError(''); }} style={[styles.modeSegment, !actMode && styles.selectedSegment, !actMode && { backgroundColor: colors.surface }]}>
              <Text style={[actMode ? styles.inactiveModeText : styles.selectedModeText, { color: actMode ? colors.muted : colors.ink }]}>Chat</Text>
            </Pressable>
            <Pressable accessibilityRole="button" accessibilityState={{ selected: actMode }} onPress={() => void openActivity()} style={[styles.modeSegment, actMode && styles.selectedSegment, actMode && { backgroundColor: colors.surface }]}>
              <Text style={[actMode ? styles.selectedModeText : styles.inactiveModeText, { color: actMode ? colors.ink : colors.muted }]}>Act</Text>
            </Pressable>
          </View>
          <View style={[styles.actionCapsule, styles.glassSurface, actMode && styles.actActionCapsule, { borderColor: colors.line }]}>
            <Pressable ref={menuDeviceButtonRef} accessibilityRole="button" accessibilityLabel="PC bağlantısı" onPress={() => void openDevices(menuDeviceButtonRef.current)} style={styles.actionButton}>
              <MaterialCommunityIcons name="laptop" size={22} color={colors.muted} />
            </Pressable>
            {!actMode && <Pressable ref={menuChatButtonRef} accessibilityRole="button" accessibilityLabel="Sohbet seçenekleri" onPress={() => openContextMenu('chat', menuChatButtonRef.current)} style={styles.actionButton}>
              <MaterialCommunityIcons name="dots-horizontal-circle-outline" size={24} color={colors.muted} />
            </Pressable>}
          </View>
        </View>

        {!actMode && messages.length === 0 && proactiveSuggestions.length > 0 && <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.recommendationStrip}>
          {proactiveSuggestions.map(suggestion => <View key={suggestion.id} style={[styles.recommendationCard, { backgroundColor: colors.surface }]}><Text style={[styles.activityTitle, { color: colors.ink }]}>{suggestion.title}</Text><Text numberOfLines={2} style={[styles.activityDetail, { color: colors.muted }]}>{suggestion.body}</Text><View style={styles.confirmActions}><Pressable onPress={() => { setProactiveSuggestions(items => items.filter(item => item.id !== suggestion.id)); void chatApi.updateProactiveSuggestion(token!, suggestion.id, 'dismiss').catch(() => undefined); }}><Text style={[styles.confirmActionText, { color: colors.muted }]}>Kapat</Text></Pressable><Pressable onPress={() => { setProactiveSuggestions(items => items.filter(item => item.id !== suggestion.id)); void chatApi.updateProactiveSuggestion(token!, suggestion.id, 'accept').catch(() => undefined); void send(suggestion.prompt); }}><Text style={[styles.confirmActionText, { color: colors.accent }]}>Sor</Text></Pressable></View></View>)}
        </ScrollView>}
        {!actMode && memoryCandidates.length > 0 && <View style={styles.recommendationStack}>{memoryCandidates.slice(0, 2).map(candidate => <View key={candidate.id} style={[styles.recommendationCard, { backgroundColor: colors.surface }]}><Text style={[styles.activityTitle, { color: colors.ink }]}>Bunu hatırlayayım mı?</Text><Text numberOfLines={2} style={[styles.activityDetail, { color: colors.muted }]}>{candidate.content}</Text><View style={styles.confirmActions}><Pressable onPress={() => { setMemoryCandidates(items => items.filter(item => item.id !== candidate.id)); void chatApi.updateMemoryCandidate(token!, candidate.id, 'dismiss').catch(() => undefined); }}><Text style={[styles.confirmActionText, { color: colors.muted }]}>Hayır</Text></Pressable><Pressable onPress={() => { setMemoryCandidates(items => items.filter(item => item.id !== candidate.id)); void chatApi.updateMemoryCandidate(token!, candidate.id, 'accept').catch(() => { void chatApi.getMemoryCandidates(token!).then(items => setMemoryCandidates(items.filter(item => item.status === 'pending'))); }); }}><Text style={[styles.confirmActionText, { color: colors.accent }]}>Hatırla</Text></Pressable></View></View>)}</View>}
        {!actMode && openWork && messages.length > 0 && !sending && <Pressable onPress={() => { setOpenWork(null); void send('devam et'); }} style={[styles.openWorkCard, { backgroundColor: colors.surface }]}><MaterialCommunityIcons name="progress-clock" size={18} color={colors.accent} /><View style={styles.resultCardBody}><Text style={[styles.activityTitle, { color: colors.ink }]}>Yarım kalan iş · Devam et</Text><Text style={[styles.activityDetail, { color: colors.muted }]}>{openWork.goal}{'\n'}{openWork.detail}</Text></View></Pressable>}

        {actMode ? <ActScreen
          token={token}
          startDictation={onResult => { actDictationTargetRef.current = onResult; void startDictation(); }}
          startVoiceSession={(onCommand, _hints) => { void startVoiceSession({ target: 'act', onCommand }); }}
          voiceSessionActive={voiceSessionActive && voiceTarget === 'act'}
          voiceListening={listening}
          voiceLevel={voiceLevel}
          voiceTranscript={voiceTranscript}
          voiceWorking={sending}
          voiceSpeaking={voiceSpeaking}
          voiceSpeechEnabled={voiceSpeechEnabled}
          onCloseVoiceSession={closeVoiceSession}
          onVoiceDeliver={toggleVoiceListening}
          onToggleVoiceSpeaker={toggleVoiceSpeaker}
        /> : messages.length === 0 ? (
          <Pressable style={styles.emptyState} onPress={Keyboard.dismiss}>
            <Image source={require('../../assets/wiqo/mark.png')} style={styles.emptyMark} accessibilityLabel="Wiqo" />
            <Text style={[styles.emptyTitle, { color: colors.ink, fontSize: 18 * typeScale }]}>Bugün ne yapalım?</Text>
          </Pressable>
        ) : (
          <FlatList
            ref={listRef}
            style={styles.messages}
            contentContainerStyle={styles.messageList}
            data={messages}
            keyExtractor={item => item.id}
            renderItem={renderMessage}
            keyboardShouldPersistTaps="handled"
            initialNumToRender={12}
            maxToRenderPerBatch={8}
            updateCellsBatchingPeriod={40}
            windowSize={7}
            scrollEventThrottle={100}
            onScroll={handleMessageScroll}
            onContentSizeChange={followLatestIfVisible}
            onLayout={followLatestIfVisible}
          />
        )}

        {!actMode && creatingAgent && <View style={[styles.agentModeRow, { backgroundColor: colors.surface }]}><MaterialCommunityIcons name="account-plus-outline" size={17} color={colors.accent} /><Text style={[styles.agentModeLabel, { color: colors.ink }]}>Ajan oluştur</Text><Pressable accessibilityRole="button" accessibilityLabel="Ajan oluştur modunu kapat" onPress={() => setCreatingAgent(false)}><MaterialCommunityIcons name="close-circle" size={20} color={colors.muted} /></Pressable></View>}
        {!actMode && !!progress && <View style={styles.progressRow}><WiqoAgentMascot persona="general" size={24} isWorking /><Text style={[styles.progressText, { color: colors.muted }]}>{progress}</Text></View>}
        {!actMode && !!error && <Text accessibilityRole="alert" style={[styles.errorText, { color: colors.danger }]}>{error}</Text>}

        {!actMode && (attachments.length > 0 || files.length > 0) && <ScrollView horizontal keyboardShouldPersistTaps="handled" style={styles.attachmentStrip} contentContainerStyle={styles.attachmentStripContent}>
          {attachments.map((item, index) => <Pressable key={`${item.name}-${index}`} onPress={() => setAttachments(current => current.filter((_, at) => at !== index))} style={[styles.attachmentChip, { backgroundColor: colors.surface }]}><MaterialCommunityIcons name="image-outline" size={15} color={colors.muted} /><Text numberOfLines={1} style={[styles.attachmentName, { color: colors.ink }]}>{item.name}</Text><MaterialCommunityIcons name="close" size={15} color={colors.muted} /></Pressable>)}
          {files.map((item, index) => <Pressable key={`${item.name}-${index}`} onPress={() => setFiles(current => current.filter((_, at) => at !== index))} style={[styles.attachmentChip, { backgroundColor: colors.surface }]}><MaterialCommunityIcons name="file-document-outline" size={15} color={colors.muted} /><Text numberOfLines={1} style={[styles.attachmentName, { color: colors.ink }]}>{item.name}</Text><MaterialCommunityIcons name="close" size={15} color={colors.muted} /></Pressable>)}
        </ScrollView>}
        {!actMode && <View style={[styles.composerOuter, { paddingBottom: Math.max(insets.bottom ? 4 : 10, 6) }]}>
          <Pressable ref={menuAttachButtonRef} accessibilityRole="button" accessibilityLabel="Ek veya dosya ekle" onPress={() => openContextMenu('attachments', menuAttachButtonRef.current)} style={[styles.glassCircle, styles.composerCircle]}>
            <MaterialCommunityIcons name={creatingAgent ? 'account-plus-outline' : 'plus'} size={22} color={colors.ink} />
          </Pressable>
          <View style={[styles.composer, styles.glassSurface, { borderColor: colors.line }]}>
            <TextInput
              ref={composerInputRef}
              value={draft}
              onChangeText={setDraft}
              placeholder={creatingAgent ? 'Ajanın ne yapsın?' : "Wiqo'ya anlat"}
              placeholderTextColor={colors.muted}
              multiline
              maxLength={12_000}
              editable={!sending && cacheHydrated}
              returnKeyType="send"
              onSubmitEditing={() => void send()}
              accessibilityLabel="Mesaj"
              style={[styles.input, { color: colors.ink, fontSize: 16 * typeScale, lineHeight: 22 * typeScale }]}
            />
          </View>
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={draft.trim() ? 'Mesajı gönder' : 'Sesli mesaj'}
            disabled={sending || !cacheHydrated}
            onPress={() => draft.trim() || attachments.length || files.length ? void send() : void startVoiceSession()}
            onLongPress={() => { if (!draft.trim() && !attachments.length && !files.length) void startDictation(); }}
            style={[styles.glassCircle, styles.composerCircle]}
          >
            {sending ? <ActivityIndicator size="small" color={colors.ink} /> : draft.trim() || attachments.length || files.length
              ? <View style={[styles.sendInner, { backgroundColor: colors.ink }]}><MaterialCommunityIcons name="arrow-up" size={18} color={colors.canvas} /></View>
              : <MaterialCommunityIcons name={listening ? 'stop' : 'waveform'} size={20} color={colors.ink} />}
          </Pressable>
        </View>}
      </KeyboardAvoidingView>

      <Modal visible={historyVisible} animationType="none" transparent statusBarTranslucent onRequestClose={closeHistory}>
        <View style={styles.modalRoot}>
          <Animated.View style={[styles.historyPanel, { width: panelWidth, backgroundColor: colors.canvas, paddingTop: Math.max(insets.top, 16), paddingBottom: Math.max(insets.bottom, 12), transform: [{ translateX: panelX }] }]}>
            <View style={styles.historyHeader}>
              <View style={[styles.searchField, { backgroundColor: colors.surface }]}>
                <MaterialCommunityIcons name="magnify" size={20} color={colors.muted} />
                <TextInput value={historyQuery} onChangeText={setHistoryQuery} placeholder="Sohbetlerde ara" placeholderTextColor={colors.muted} autoCorrect={false} returnKeyType="search" style={[styles.searchInput, { color: colors.ink }]} />
                {!!historyQuery && <Pressable accessibilityLabel="Aramayı temizle" onPress={() => setHistoryQuery('')}><MaterialCommunityIcons name="close-circle" size={18} color={colors.muted} /></Pressable>}
              </View>
              <Pressable accessibilityRole="button" accessibilityLabel="Yeni sohbet" onPress={startNewChat} style={[styles.newChatButton, { backgroundColor: colors.surface }]}>
                <MaterialCommunityIcons name="square-edit-outline" size={19} color={colors.ink} />
              </Pressable>
            </View>
            {historyLoading ? <ActivityIndicator style={styles.historyLoading} color={colors.accent} /> : historyError ? (
              <Pressable onPress={() => void openHistory()} style={styles.historyMessage}>
                <Text style={[styles.emptyHistory, { color: colors.muted }]}>{historyError}</Text>
                <Text style={[styles.retryText, { color: colors.accent }]}>Yeniden dene</Text>
              </Pressable>
            ) : (
              <SectionList
                sections={historySections.map(section => ({ title: section.title, data: section.items }))}
                keyExtractor={item => item.id}
                renderSectionHeader={({ section }) => <Text style={[styles.historySectionTitle, { color: colors.muted }]}>{section.title}</Text>}
                renderItem={({ item }) => (
                  <Pressable onPress={() => void selectConversation(item)} onLongPress={event => { setContextConversation(item); openContextMenu('conversation', null, { x: event.nativeEvent.pageX, y: event.nativeEvent.pageY }); }} delayLongPress={350} style={styles.historyItem}>
                    <Text numberOfLines={1} style={[styles.historyItemTitle, { color: colors.ink }]}>{item.title}</Text>
                  </Pressable>
                )}
                ListEmptyComponent={<Text style={[styles.emptyHistory, { color: colors.muted }]}>{historyQuery ? 'Sonuç bulunamadı' : 'Henüz sohbet yok'}</Text>}
                keyboardShouldPersistTaps="handled"
                contentContainerStyle={styles.historyList}
                initialNumToRender={12}
                maxToRenderPerBatch={8}
                updateCellsBatchingPeriod={40}
                windowSize={7}
              />
            )}
            <View style={styles.profileRow}>
              <Pressable ref={menuProfileButtonRef} accessibilityRole="button" accessibilityLabel="Profil ve hesap menüsü" onPress={() => openContextMenu('profile', menuProfileButtonRef.current)} style={styles.profileIdentity}>
                {profile?.avatarKind === 'photo' && profile.avatarImage
                  ? <Image source={{ uri: `data:image/jpeg;base64,${profile.avatarImage}` }} style={styles.profileAvatar} />
                  : <View style={[styles.profileAvatar, { backgroundColor: accountColor(profile?.avatarColor) }]}><Text style={styles.profileAvatarText}>{profile?.avatarKind === 'emoji' && profile.avatarEmoji ? profile.avatarEmoji : accountName.slice(0, 1).toLocaleUpperCase('tr')}</Text></View>}
                <Text numberOfLines={1} style={[styles.profileName, { color: colors.ink }]}>{accountName}</Text>
              </Pressable>
              <Pressable accessibilityRole="button" accessibilityLabel="Hesap menüsü" onPress={() => openContextMenu('profile', menuProfileButtonRef.current)} style={styles.signOutButton}>
                <MaterialCommunityIcons name="logout" size={18} color={colors.muted} />
              </Pressable>
            </View>
          </Animated.View>
          <Pressable style={styles.scrimTouch} onPress={closeHistory}>
            <Animated.View pointerEvents="none" style={[styles.modalScrim, { opacity: scrimOpacity }]} />
          </Pressable>
        </View>
      </Modal>

      <Modal visible={contextMenu !== null} animationType="fade" transparent statusBarTranslucent onRequestClose={() => setContextMenu(null)}>
        <View style={styles.contextRoot} onLayout={event => setMenuBounds(event.nativeEvent.layout)}>
          <Pressable style={StyleSheet.absoluteFill} onPress={() => setContextMenu(null)} />
          <View style={[styles.contextCard, { backgroundColor: colors.canvas, borderColor: colors.line, top: contextTop, left: contextLeft, width: contextCardWidth, maxHeight: contextCardHeight }]}>
            {contextMenu === 'chat' && <>
              {contextualAction('Yeni sohbet', 'message-plus-outline', () => { setContextMenu(null); startNewChat(); })}
              {contextualAction('Otomasyon şablonları', 'clock-outline', () => setContextMenu('templates'))}
            </>}
            {contextMenu === 'attachments' && <>
              {contextualAction(creatingAgent ? 'Ajan oluşturmayı kapat' : 'Ajan oluştur', creatingAgent ? 'account-check-outline' : 'account-plus-outline', () => { setContextMenu(null); setCreatingAgent(current => !current); if (!creatingAgent) setTimeout(() => composerInputRef.current?.focus(), 120); })}
              {contextualAction('Fotoğraf seç', 'image-multiple-outline', () => void pickPhotos())}
              {contextualAction('Kamerayı aç', 'camera-outline', () => void pickPhotos(true))}
              {contextualAction('Metin dosyası ekle', 'file-document-outline', () => void pickTextFiles())}
            </>}
            {contextMenu === 'devices' && <>
              <Text style={[styles.contextTitle, { color: colors.ink }]}>PC bağlantısı</Text>
              {devicesLoading ? <ActivityIndicator style={styles.contextSpinner} color={colors.accent} /> : devices.length ? devices.map(device => (
                <View key={device.id} style={styles.deviceRow}>
                  <View style={[styles.deviceDot, { backgroundColor: device.online ? '#35a56b' : colors.muted }]} />
                  <View style={styles.deviceInfo}><Text style={[styles.deviceName, { color: colors.ink }]}>{device.displayName}</Text><Text style={[styles.deviceStatus, { color: colors.muted }]}>{device.online ? 'Çevrimiçi' : 'Çevrimdışı'}{device.platform ? ` · ${device.platform}` : ''}</Text></View>
                </View>
              )) : <Text style={[styles.contextHint, { color: colors.muted }]}>{menuError || 'Hesabına bağlı bir PC görünmüyor.'}</Text>}
              {!!menuError && !!devices.length && <Text style={[styles.contextHint, { color: colors.danger }]}>{menuError}</Text>}
              {contextualAction('Yenile', 'refresh', () => void openDevices(menuDeviceButtonRef.current))}
            </>}
            {contextMenu === 'conversation' && <>
              <Text numberOfLines={2} style={[styles.contextTitle, { color: colors.ink }]}>{contextConversation?.title ?? 'Sohbet'}</Text>
              {contextualAction('Sohbeti sil', 'delete-outline', () => setContextMenu('confirm-delete'), true)}
            </>}
            {contextMenu === 'confirm-delete' && <>
              <Text style={[styles.contextTitle, { color: colors.ink }]}>Bu sohbet silinsin mi?</Text>
              <Text style={[styles.contextHint, { color: colors.muted }]}>Sohbet sunucudaki hesabından silinecek.</Text>
              {!!menuError && <Text style={[styles.contextHint, { color: colors.danger }]}>{menuError}</Text>}
              {contextualAction('Sil', 'delete-outline', () => void deleteConversation(), true)}
              {contextualAction('Vazgeç', 'close', () => setContextMenu(null))}
            </>}
            {contextMenu === 'profile' && <>
              <Text style={[styles.contextTitle, { color: colors.ink }]}>{accountName}</Text>
              {profile?.email && <Text style={[styles.contextHint, { color: colors.muted }]}>{profile.email}</Text>}
              {contextualAction('Ayarlar', 'cog-outline', () => { setContextMenu(null); closeHistory(); router.push('/settings'); })}
              {contextualAction('Çıkış yap', 'logout', () => { setContextMenu(null); void signOut(); })}
            </>}
            {contextMenu === 'templates' && <>
              <Text style={[styles.contextTitle, { color: colors.ink }]}>Otomasyon şablonları</Text>
              {automationTemplates.map(template => contextualAction(template.title, 'clock-outline', () => { setDraft(template.prompt); setContextMenu(null); }))}
            </>}
            {!!menuError && contextMenu !== 'devices' && contextMenu !== 'confirm-delete' && <Text style={[styles.contextHint, { color: colors.danger }]}>{menuError}</Text>}
          </View>
        </View>
      </Modal>

      <WiqoVoiceSession
        visible={voiceSessionActive && voiceTarget === 'chat'}
        listening={listening}
        working={sending}
        speaking={voiceSpeaking}
        level={voiceLevel}
        transcript={voiceTranscript}
        errorMessage={voiceError}
        latestResponse={latestAssistantMessage ? renderMessage({ item: latestAssistantMessage }) : null}
        queued={voiceQueue}
        accent={colors.accent}
        background={colors.canvas}
        ink={colors.ink}
        muted={colors.muted}
        speakReplies={voiceSpeechEnabled}
        onClose={closeVoiceSession}
        onOrbPress={toggleVoiceListening}
        onToggleSpeaker={toggleVoiceSpeaker}
        onRemoveQueued={removeQueuedVoiceTurn}
      />
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safeArea: { flex: 1 },
  screen: { flex: 1 },
  header: { minHeight: 60, position: 'relative', flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingVertical: 6 },
  glassSurface: { backgroundColor: 'rgba(250,250,250,0.90)', borderColor: 'rgba(100,105,110,0.20)', borderWidth: StyleSheet.hairlineWidth, shadowColor: '#000000', shadowOpacity: 0.06, shadowRadius: 7, shadowOffset: { width: 0, height: 2 }, elevation: 1 },
  glassCircle: { alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(250,250,250,0.90)', borderColor: 'rgba(100,105,110,0.20)', borderWidth: StyleSheet.hairlineWidth, shadowColor: '#000000', shadowOpacity: 0.06, shadowRadius: 7, shadowOffset: { width: 0, height: 2 }, elevation: 1 },
  headerCircle: { width: 44, height: 44, borderRadius: 22 },
  modeCapsule: { height: 44, position: 'absolute', left: '50%', top: 8, borderRadius: 23, padding: 3, flexDirection: 'row', alignItems: 'center' },
  modeSegment: { flex: 1, height: 36, alignItems: 'center', justifyContent: 'center', borderRadius: 20 },
  selectedSegment: { borderColor: 'rgba(100,105,110,0.16)', borderWidth: StyleSheet.hairlineWidth, shadowColor: '#000000', shadowOpacity: 0.08, shadowRadius: 4, shadowOffset: { width: 0, height: 1 }, elevation: 1 },
  selectedModeText: { fontSize: 15, fontWeight: '600' },
  inactiveModeText: { fontSize: 15, fontWeight: '500' },
  actionCapsule: { width: 82, height: 44, borderRadius: 23, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 2 },
  actActionCapsule: { width: 44 },
  actionButton: { width: 35, height: 38, alignItems: 'center', justifyContent: 'center' },
  emptyState: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 12, paddingBottom: 28 },
  emptyMark: { width: 96, height: 96 },
  emptyTitle: { fontSize: 18, fontWeight: '500' },
  messages: { flex: 1 },
  activityList: { padding: 18, paddingBottom: 32, gap: 18 },
  activityEmpty: { paddingVertical: 36, textAlign: 'center', fontSize: 15 },
  activitySection: { gap: 8 },
  activitySectionTitle: { paddingHorizontal: 8, paddingBottom: 2, fontSize: 13 },
  activityRow: { minHeight: 58, flexDirection: 'row', alignItems: 'center', gap: 12, paddingHorizontal: 14, paddingVertical: 10, borderRadius: 16 },
  activityText: { flex: 1, gap: 3 },
  activityTitle: { fontSize: 14, fontWeight: '600' },
  activityDetail: { fontSize: 12, lineHeight: 17 },
  resultCard: { width: '100%', flexDirection: 'row', alignItems: 'flex-start', gap: 10, borderRadius: 16, padding: 12, marginTop: 8 },
  resultCardBody: { flex: 1, gap: 4 },
  resultCardText: { flex: 1, fontSize: 14, fontWeight: '600', lineHeight: 19 },
  liveEvent: { maxWidth: '90%', marginTop: 3, fontSize: 12, lineHeight: 17 },
  confirmCard: { width: '100%', gap: 7, borderRadius: 16, padding: 12, marginTop: 8 },
  confirmActions: { flexDirection: 'row', justifyContent: 'flex-end', gap: 22, paddingTop: 5 },
  confirmActionText: { fontSize: 14, fontWeight: '600' },
  locationRow: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  locationInput: { flex: 1, minWidth: 0, borderRadius: 10, padding: 8, backgroundColor: 'rgba(120,120,128,0.10)' },
  recommendationStrip: { paddingHorizontal: 16, paddingBottom: 10, gap: 10 },
  recommendationStack: { paddingHorizontal: 16, paddingBottom: 8, gap: 8 },
  recommendationCard: { width: 260, borderRadius: 17, padding: 12, gap: 5 },
  openWorkCard: { flexDirection: 'row', gap: 10, marginHorizontal: 16, marginBottom: 8, borderRadius: 16, padding: 12 },
  messageList: { flexGrow: 1, paddingHorizontal: 0, paddingTop: 22, paddingBottom: 18, gap: 19 },
  messageRow: { width: '100%', flexDirection: 'row', alignItems: 'flex-start' },
  userRow: { justifyContent: 'flex-end', paddingHorizontal: 18 },
  assistantRow: { justifyContent: 'flex-start', paddingHorizontal: 18 },
  assistantContent: { width: '100%', flex: 1, minWidth: 0, alignSelf: 'stretch' },
  messageBubble: { maxWidth: '90%', borderRadius: 20, paddingHorizontal: 15, paddingVertical: 11 },
  userBubble: { borderTopRightRadius: 7 },
  messageText: { fontSize: 16, lineHeight: 23 },
  progressRow: { flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 20, paddingBottom: 7 },
  progressText: { fontSize: 13 },
  agentModeRow: { minHeight: 34, flexDirection: 'row', alignItems: 'center', gap: 8, borderRadius: 16, marginHorizontal: 25, marginBottom: 3, paddingHorizontal: 11 },
  agentModeLabel: { flex: 1, fontSize: 13, fontWeight: '600' },
  errorText: { marginHorizontal: 20, marginBottom: 6, fontSize: 13 },
  attachmentStrip: { maxHeight: 38, marginHorizontal: 20, marginBottom: 3 },
  attachmentStripContent: { alignItems: 'center', gap: 7 },
  attachmentChip: { height: 30, maxWidth: 210, flexDirection: 'row', alignItems: 'center', gap: 6, borderRadius: 15, paddingHorizontal: 10 },
  attachmentName: { maxWidth: 150, fontSize: 12 },
  composerOuter: { flexDirection: 'row', alignItems: 'flex-end', gap: 8, paddingHorizontal: 22, paddingTop: 5 },
  composerCircle: { width: 46, height: 46, borderRadius: 23 },
  sendInner: { width: 30, height: 30, borderRadius: 15, alignItems: 'center', justifyContent: 'center' },
  composer: { flex: 1, minHeight: 46, maxHeight: 150, flexDirection: 'row', alignItems: 'center', borderWidth: StyleSheet.hairlineWidth, borderRadius: 25, paddingHorizontal: 14, paddingVertical: 3 },
  input: { flex: 1, minHeight: 42, maxHeight: 136, paddingTop: 10, paddingBottom: 9, fontSize: 16, lineHeight: 22 },
  modalRoot: { flex: 1, flexDirection: 'row', overflow: 'hidden' },
  modalScrim: { ...StyleSheet.absoluteFillObject, backgroundColor: 'rgba(0,0,0,0.32)' },
  scrimTouch: { flex: 1 },
  historyPanel: { height: '100%', paddingHorizontal: 14, borderTopRightRadius: 30, borderBottomRightRadius: 30, overflow: 'hidden', zIndex: 1, elevation: 12, shadowColor: '#000', shadowOpacity: 0.14, shadowRadius: 24, shadowOffset: { width: 6, height: 0 } },
  historyHeader: { flexDirection: 'row', alignItems: 'center', gap: 8, paddingBottom: 10 },
  searchField: { height: 42, flex: 1, flexDirection: 'row', alignItems: 'center', gap: 8, borderRadius: 14, paddingHorizontal: 12 },
  searchInput: { flex: 1, minWidth: 0, padding: 0, fontSize: 15 },
  newChatButton: { width: 42, height: 42, borderRadius: 21, alignItems: 'center', justifyContent: 'center' },
  historyLoading: { marginTop: 32 },
  historyMessage: { paddingTop: 22 },
  retryText: { paddingHorizontal: 6, fontSize: 14, fontWeight: '600' },
  historyList: { paddingTop: 8, paddingBottom: 12 },
  historySectionTitle: { paddingHorizontal: 26, paddingTop: 14, paddingBottom: 4, fontSize: 13 },
  historyItem: { minHeight: 50, justifyContent: 'center', borderRadius: 14, paddingHorizontal: 14, paddingVertical: 9, marginHorizontal: 12 },
  historyItemTitle: { fontSize: 15, lineHeight: 20 },
  emptyHistory: { paddingHorizontal: 6, paddingVertical: 20, fontSize: 14 },
  profileRow: { minHeight: 56, flexDirection: 'row', alignItems: 'center', paddingHorizontal: 4, paddingTop: 8 },
  profileIdentity: { flex: 1, minWidth: 0, flexDirection: 'row', alignItems: 'center', gap: 12 },
  profileAvatar: { width: 36, height: 36, borderRadius: 18, alignItems: 'center', justifyContent: 'center' },
  profileAvatarText: { color: '#fff', fontSize: 16, fontWeight: '600' },
  profileName: { flex: 1, fontSize: 15, fontWeight: '600' },
  signOutButton: { width: 38, height: 38, borderRadius: 19, alignItems: 'center', justifyContent: 'center' },
  contextRoot: { flex: 1, backgroundColor: 'rgba(0,0,0,0.16)' },
  contextCard: { position: 'absolute', borderWidth: StyleSheet.hairlineWidth, borderRadius: 22, paddingHorizontal: 8, paddingVertical: 8, shadowColor: '#000', shadowOpacity: 0.18, shadowRadius: 24, shadowOffset: { width: 0, height: 8 }, elevation: 14, overflow: 'hidden' },
  contextAction: { minHeight: 48, flexDirection: 'row', alignItems: 'center', gap: 13, borderRadius: 14, paddingHorizontal: 12 },
  contextActionText: { flex: 1, fontSize: 15, fontWeight: '500' },
  contextTitle: { paddingHorizontal: 12, paddingTop: 10, paddingBottom: 7, fontSize: 16, fontWeight: '600' },
  contextHint: { paddingHorizontal: 12, paddingVertical: 8, fontSize: 13, lineHeight: 18 },
  contextSpinner: { margin: 18 },
  deviceRow: { minHeight: 50, flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 12 },
  deviceDot: { width: 9, height: 9, borderRadius: 5 },
  deviceInfo: { flex: 1, gap: 2 },
  deviceName: { fontSize: 14, fontWeight: '600' },
  deviceStatus: { fontSize: 12 },
});
