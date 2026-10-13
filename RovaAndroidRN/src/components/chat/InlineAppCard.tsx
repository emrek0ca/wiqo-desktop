import { MaterialCommunityIcons } from '@expo/vector-icons';
import { Asset } from 'expo-asset';
import * as Clipboard from 'expo-clipboard';
import * as FileSystem from 'expo-file-system/legacy';
import * as Haptics from 'expo-haptics';
import * as Sharing from 'expo-sharing';
import { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Modal, Pressable, Share, StyleSheet, Text, View, useWindowDimensions } from 'react-native';
import WebView, { type WebViewMessageEvent, type WebViewNavigation } from 'react-native-webview';
import { ChatWidget } from '@/data/chat-api';
import { useWiqoColors } from '@/theme';

const coreAsset = require('../../../assets/inline/core.html') as number;
const chartAsset = require('../../../assets/inline/chart.html') as number;
const confettiAsset = require('../../../assets/inline/confetti.html') as number;
const templatesAsset = require('../../../assets/inline/templates.html') as number;
const stateUri = `${FileSystem.documentDirectory ?? ''}wiqo-inline-app-state-v1.json`;

type Props = { widget: ChatWidget; onAsk: (text: string) => void; onFix: (text: string) => void };
type StoredStates = Record<string, Record<string, string>>;

async function readAsset(assetId: number) {
  const asset = Asset.fromModule(assetId);
  await asset.downloadAsync();
  if (!asset.localUri) throw new Error('Uygulama kaynakları yüklenemedi.');
  return FileSystem.readAsStringAsync(asset.localUri);
}

function safeJSON(value: unknown) {
  if (typeof value !== 'string' || !value) return 'null';
  try { return JSON.stringify(JSON.parse(value) as unknown).replace(/<\/script/gi, '<\\/script'); } catch { return 'null'; }
}

function scriptTag(source: string) { return `<script>${source.replace(/<\/script/gi, '<\\/script')}</script>`; }

function makeDocument(html: string, data: string | undefined, state: Record<string, string>, libraries: string[]) {
  const csp = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">`;
  const start = `window.__WIQO_STATE__=${safeJSON(JSON.stringify(state))};window.__WIQO_DATA__=${safeJSON(data)};Object.defineProperty(window,'webkit',{value:{messageHandlers:{wiqoApp:{postMessage:function(v){try{window.ReactNativeWebView.postMessage(typeof v==='string'?v:JSON.stringify(v))}catch(e){}}}}},configurable:false});`;
  const hardening = `(function(){var post=function(v){try{window.ReactNativeWebView.postMessage(JSON.stringify(v))}catch(e){}};var lock=function(o,k,v){try{Object.defineProperty(o,k,{value:v,writable:false,configurable:false})}catch(e){}};var report=function(){if(!document.body)return;var d=document.documentElement,b=document.body;post(Math.ceil(Math.max(d.scrollHeight,b.scrollHeight)))};lock(window,'open',function(){return null});['fetch','XMLHttpRequest','WebSocket','EventSource','Worker','SharedWorker','RTCPeerConnection','indexedDB','localStorage','sessionStorage','caches'].forEach(function(k){try{Object.defineProperty(window,k,{get:function(){throw new Error('Bu uygulamada kullanılamaz')},configurable:false})}catch(e){}});try{lock(navigator,'sendBeacon',undefined)}catch(e){};document.addEventListener('DOMContentLoaded',function(){report();try{new ResizeObserver(report).observe(document.documentElement)}catch(e){setInterval(report,600)}});window.addEventListener('load',report);window.addEventListener('error',function(e){post({err:String(e&&e.message||'Betik hatası').slice(0,200)})});window.addEventListener('unhandledrejection',function(e){post({err:String(e&&e.reason&&e.reason.message||'Uygulama hatası').slice(0,200)})});})();`;
  const scripts = [start, `window.wiqo=Object.freeze({data:window.__WIQO_DATA__,load:function(k){return window.__WIQO_STATE__[String(k).slice(0,40)]||null},save:function(k,v){window.ReactNativeWebView.postMessage(JSON.stringify({save:{k:String(k).slice(0,40),v:String(v).slice(0,2000)}}))},copy:function(v){window.ReactNativeWebView.postMessage(JSON.stringify({copy:String(v).slice(0,20000)}))},share:function(v){window.ReactNativeWebView.postMessage(JSON.stringify({share:String(v).slice(0,20000)}))},ask:function(v){window.ReactNativeWebView.postMessage(JSON.stringify({ask:String(v).slice(0,500)}))},haptic:function(v){window.ReactNativeWebView.postMessage(JSON.stringify({haptic:v}))}});window.WIQO_DATA=window.__WIQO_DATA__;`, ...libraries, hardening].map(scriptTag).join('');
  const document = html || '<!doctype html><html><head></head><body></body></html>';
  if (/<head[^>]*>/i.test(document)) return document.replace(/<head[^>]*>/i, match => `${match}${csp}${scripts}`);
  return `<!doctype html><html><head>${csp}${scripts}</head><body>${document}</body></html>`;
}

export function InlineAppCard({ widget, onAsk, onFix }: Props) {
  const colors = useWiqoColors();
  const { width } = useWindowDimensions();
  const cardKey = typeof widget.stateKey === 'string' ? widget.stateKey : String(widget.widgetId ?? widget.id ?? widget.title ?? 'inline-app');
  const html = typeof widget.html === 'string' ? widget.html : '';
  const [source, setSource] = useState('');
  const [states, setStates] = useState<StoredStates>({});
  const [height, setHeight] = useState(typeof widget.height === 'number' ? Math.min(640, Math.max(120, widget.height)) : 320);
  const [scrollable, setScrollable] = useState(typeof widget.height === 'number' && widget.height > 640);
  const [error, setError] = useState('');
  const [menu, setMenu] = useState(false);
  const [fullscreen, setFullscreen] = useState(false);
  const [reloadKey, setReloadKey] = useState(0);
  const initialNavigation = useRef(true);
  const lastActionAt = useRef(0);

  const title = typeof widget.title === 'string' && widget.title ? widget.title : 'Uygulama';
  const libs = Array.isArray(widget.libs) ? widget.libs.filter((lib): lib is string => typeof lib === 'string') : [];

  useEffect(() => {
    let active = true;
    void Promise.all([
      FileSystem.readAsStringAsync(stateUri).then(value => JSON.parse(value) as StoredStates).catch(() => ({} as StoredStates)),
      readAsset(coreAsset),
      ...Array.from(new Set(libs)).map(async library => {
        const asset = library === 'chart' ? chartAsset : library === 'confetti' ? confettiAsset : library === 'templates' ? templatesAsset : undefined;
        return asset ? [library, await readAsset(asset)] as const : null;
      }),
    ]).then(([saved, core, ...loadedLibs]) => {
      if (!active) return;
      const cardState = saved[cardKey] ?? {};
      setStates(saved);
      const libraries = new Map(loadedLibs.filter((item): item is readonly [string, string] => item !== null));
      const orderedLibs = ['chart', 'confetti', 'templates'].filter(name => (name === 'chart' && libs.includes('templates')) || libs.includes(name)).flatMap(name => { const value = libraries.get(name); return value ? [value] : []; });
      const coreScript = core.replace(/window\.webkit\.messageHandlers\.wiqoApp\.postMessage/g, 'window.ReactNativeWebView.postMessage');
      const data = typeof widget.data === 'string' ? widget.data : undefined;
      const document = makeDocument(html, data, cardState, [coreScript, ...orderedLibs]);
      setSource(document);
    }).catch(() => setError('Uygulama açılamadı. Yeniden başlatmayı deneyebilirsin.'));
    return () => { active = false; };
  }, [cardKey, html, libs.join(','), reloadKey, widget.data]);

  const persistStates = (next: StoredStates) => {
    const keys = Object.keys(next).slice(-100);
    const bounded: StoredStates = {};
    let bytes = 0;
    for (const key of keys.reverse()) {
      const entry = next[key];
      const pairs = Object.entries(entry).slice(-32);
      const clean = Object.fromEntries(pairs.map(([name, value]) => [name.slice(0, 40), value.slice(0, 2_000)]));
      const size = Object.entries(clean).reduce((sum, [name, value]) => sum + name.length + value.length, 0);
      if (size > 8_000 || bytes + size > 32_000) continue;
      bounded[key] = clean;
      bytes += size;
    }
    setStates(bounded);
    void FileSystem.writeAsStringAsync(stateUri, JSON.stringify(bounded)).catch(() => undefined);
  };

  const handleMessage = (event: WebViewMessageEvent) => {
    const raw = event.nativeEvent.data;
    const numericHeight = Number(raw);
    if (Number.isFinite(numericHeight) && numericHeight > 0 && numericHeight < 20_000) { setScrollable(numericHeight > 640); setHeight(Math.min(640, Math.max(120, numericHeight))); return; }
    let message: Record<string, unknown>;
    try { message = JSON.parse(raw) as Record<string, unknown>; } catch { return; }
    const save = message.save as { k?: unknown; v?: unknown } | undefined;
    if (save && typeof save.k === 'string' && save.k.length <= 40 && typeof save.v === 'string' && save.v.length <= 2_000) {
      const updated = { ...states, [cardKey]: { ...(states[cardKey] ?? {}), [save.k]: save.v } };
      if (Object.keys(updated[cardKey]).length <= 32 && Object.entries(updated[cardKey]).reduce((sum, [key, value]) => sum + key.length + value.length, 0) <= 8_000) persistStates(updated);
    } else if (typeof message.copy === 'string' || typeof message.share === 'string' || typeof message.ask === 'string') {
      if (Date.now() - lastActionAt.current < 1_000) return;
      lastActionAt.current = Date.now();
      if (typeof message.copy === 'string') void Clipboard.setStringAsync(message.copy.slice(0, 20_000));
      else if (typeof message.share === 'string') void Share.share({ message: message.share.slice(0, 20_000) });
      else if (typeof message.ask === 'string' && message.ask.trim()) onAsk(message.ask.slice(0, 500));
    }
    else if (typeof message.haptic === 'string') {
      if (message.haptic === 'success') void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      else if (message.haptic === 'warning') void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning);
      else if (message.haptic === 'error') void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
      else void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    } else if (typeof message.err === 'string') setError(message.err.slice(0, 200));
    else if (typeof message.check === 'object' && message.check && (message.check as Record<string, unknown>).blank === true) setError('Sayfa boş göründü; içerik görüntülenemedi.');
  };

  const navigationPolicy = (request: WebViewNavigation) => {
    if (request.url === 'about:blank' || request.url.startsWith('about:blank#')) return true;
    if (initialNavigation.current && request.url.startsWith('data:')) {
      initialNavigation.current = false;
      return true;
    }
    return false;
  };

  const restart = (clearState: boolean) => {
    setError('');
    initialNavigation.current = true;
    if (clearState) {
      const next = { ...states };
      delete next[cardKey];
      persistStates(next);
    }
    setReloadKey(value => value + 1);
    setMenu(false);
  };

  const exportHtml = () => {
    const exportPage = source;
    const filename = title.replace(/[^\p{L}\p{N}._-]+/gu, '-').slice(0, 40) || 'wiqo-app';
    const uri = `${FileSystem.cacheDirectory ?? FileSystem.documentDirectory ?? ''}${filename}.html`;
    void FileSystem.writeAsStringAsync(uri, exportPage).then(() => Sharing.shareAsync(uri, { mimeType: 'text/html', dialogTitle: title })).catch(() => Share.share({ title: `${title}.html`, message: exportPage }));
    setMenu(false);
  };

  const webView = (isFullScreen: boolean) => source ? <WebView
    key={`${cardKey}-${reloadKey}-${isFullScreen ? 'full' : 'card'}`}
    source={{ html: source, baseUrl: 'about:blank' }}
    originWhitelist={['*']}
    onShouldStartLoadWithRequest={navigationPolicy}
    onMessage={handleMessage}
    javaScriptEnabled
    javaScriptCanOpenWindowsAutomatically={false}
    setSupportMultipleWindows={false}
    domStorageEnabled={false}
    sharedCookiesEnabled={false}
    thirdPartyCookiesEnabled={false}
    incognito
    cacheEnabled={false}
    allowFileAccess={false}
    allowFileAccessFromFileURLs={false}
    allowUniversalAccessFromFileURLs={false}
    mixedContentMode="never"
    allowsBackForwardNavigationGestures={false}
    scrollEnabled={isFullScreen || scrollable}
    nestedScrollEnabled
    onRenderProcessGone={() => setError('Uygulama durdu. Yeniden başlatmayı deneyebilirsin.')}
    style={[styles.webView, { height: isFullScreen ? '100%' : height, width: isFullScreen ? width : undefined, backgroundColor: colors.surface }]}
  /> : <View style={[styles.loading, { height, backgroundColor: colors.surface }]}><ActivityIndicator color={colors.muted} /></View>;

  return <View style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.line }]}>
    <View style={styles.header}>
      <MaterialCommunityIcons name="shield-lock-outline" size={15} color={colors.muted} />
      <Text numberOfLines={1} style={[styles.title, { color: colors.muted }]}>{title}</Text>
      <Pressable accessibilityRole="button" accessibilityLabel="Uygulama seçenekleri" onPress={() => setMenu(true)} style={styles.menuButton}><MaterialCommunityIcons name="dots-horizontal" size={20} color={colors.muted} /></Pressable>
    </View>
    <View style={[styles.webFrame, { height, backgroundColor: colors.canvas }]}>{webView(false)}</View>
    {error ? <View style={[styles.errorRow, { borderTopColor: colors.line }]}><MaterialCommunityIcons name="alert-circle-outline" size={17} color={colors.danger} /><Text numberOfLines={2} style={[styles.errorText, { color: colors.muted }]}>{error}</Text><Pressable onPress={() => { onFix(`“${title}” uygulaması çalışırken hata verdi (${error}). Aynı uygulamayı düzeltip yeniden göster.`); setError(''); }}><Text style={[styles.actionText, { color: colors.accent }]}>Düzelt</Text></Pressable><Pressable onPress={() => setError('')} accessibilityLabel="Kapat"><MaterialCommunityIcons name="close" size={18} color={colors.muted} /></Pressable></View> : null}
    <Modal transparent visible={menu} animationType="fade" onRequestClose={() => setMenu(false)}>
      <Pressable style={styles.scrim} onPress={() => setMenu(false)}><View style={[styles.menu, { backgroundColor: colors.canvas, borderColor: colors.line }]}>
        <Pressable style={styles.menuItem} onPress={() => restart(true)}><MaterialCommunityIcons name="restore" size={19} color={colors.ink} /><Text style={[styles.menuText, { color: colors.ink }]}>Sıfırla</Text></Pressable>
        <Pressable style={styles.menuItem} onPress={() => { initialNavigation.current = true; setFullscreen(true); setMenu(false); }}><MaterialCommunityIcons name="fullscreen" size={19} color={colors.ink} /><Text style={[styles.menuText, { color: colors.ink }]}>Tam ekran</Text></Pressable>
        <Pressable style={styles.menuItem} onPress={exportHtml}><MaterialCommunityIcons name="share-variant-outline" size={19} color={colors.ink} /><Text style={[styles.menuText, { color: colors.ink }]}>Dosya olarak paylaş</Text></Pressable>
        <Pressable style={styles.menuItem} onPress={() => { onAsk(`“${title}” uygulamasını Act içinde geliştir.`); setMenu(false); }}><MaterialCommunityIcons name="hammer-wrench" size={19} color={colors.ink} /><Text style={[styles.menuText, { color: colors.ink }]}>Act'te geliştir</Text></Pressable>
      </View></Pressable>
    </Modal>
    <Modal visible={fullscreen} animationType="slide" onRequestClose={() => setFullscreen(false)}>
      <View style={[styles.fullscreen, { paddingTop: 12, backgroundColor: colors.canvas }]}><View style={styles.fullscreenHeader}><Text numberOfLines={1} style={[styles.fullscreenTitle, { color: colors.ink }]}>{title}</Text><Pressable accessibilityRole="button" onPress={() => setFullscreen(false)} style={styles.closeButton}><Text style={[styles.actionText, { color: colors.accent }]}>Kapat</Text></Pressable></View>{webView(true)}</View>
    </Modal>
  </View>;
}

const styles = StyleSheet.create({
  card: { width: '100%', overflow: 'hidden', borderRadius: 18, borderWidth: StyleSheet.hairlineWidth },
  header: { minHeight: 40, flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 12 },
  title: { flex: 1, fontSize: 12, fontWeight: '600' },
  menuButton: { width: 34, height: 34, alignItems: 'center', justifyContent: 'center' },
  webFrame: { width: '100%', overflow: 'hidden' },
  webView: { flex: 1, backgroundColor: 'transparent' },
  loading: { alignItems: 'center', justifyContent: 'center' },
  errorRow: { minHeight: 40, flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 12, paddingVertical: 8, borderTopWidth: StyleSheet.hairlineWidth },
  errorText: { flex: 1, fontSize: 12, lineHeight: 16 },
  actionText: { fontSize: 13, fontWeight: '600' },
  scrim: { flex: 1, backgroundColor: 'rgba(0,0,0,0.16)', justifyContent: 'center', alignItems: 'center', padding: 24 },
  menu: { width: '100%', maxWidth: 320, borderWidth: StyleSheet.hairlineWidth, borderRadius: 20, padding: 8, elevation: 12 },
  menuItem: { minHeight: 48, flexDirection: 'row', alignItems: 'center', gap: 12, paddingHorizontal: 12 },
  menuText: { fontSize: 15 },
  fullscreen: { flex: 1 },
  fullscreenHeader: { minHeight: 46, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 16 },
  fullscreenTitle: { flex: 1, fontSize: 17, fontWeight: '600' },
  closeButton: { padding: 10 },
});
