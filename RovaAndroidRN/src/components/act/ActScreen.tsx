import { MaterialCommunityIcons } from '@expo/vector-icons';
import * as DocumentPicker from 'expo-document-picker';
import * as FileSystem from 'expo-file-system/legacy';
import * as SecureStore from 'expo-secure-store';
import * as Clipboard from 'expo-clipboard';
import { useCallback, useEffect, useRef, useState, type ComponentProps } from 'react';
import { ActivityIndicator, Keyboard, Modal, Pressable, RefreshControl, ScrollView, Share, StyleSheet, Text, TextInput, View } from 'react-native';
import WebView from 'react-native-webview';
import { ActSideDock, type ActDockAction } from '@/components/act/ActSideDock';
import { ActVoiceSession } from '@/components/act/ActVoiceSession';
import { actApi, type ActRunResult, type ActWriterJob } from '@/data/act-api';
import { actStorageScope, importActRecoveryCode, loadActKeys, type ActKeys } from '@/data/act-vault';
import { useWiqoColors } from '@/theme';
import { useAppearance } from '@/settings/AppearanceProvider';

type ActChange = { path: string; before?: string; after?: string };
type ActHistory = { id: string; summary: string; date: number; verified: boolean; source: string; changes: ActChange[] };
type ActProject = { id: string; name: string; kind: 'web' | 'python'; files: Record<string, string>; history: ActHistory[]; updatedAt: number; mode: 'devices' | 'deviceOnly'; hubId?: number; version?: number; base?: Record<string, string> };
type ActTab = 'preview' | 'code' | 'history';
type VoiceStarter = (onCommand: (text: string) => void, hints: string[]) => void;
type Props = {
  token: string | null;
  startDictation?: (onResult: (text: string) => void) => void;
  startVoiceSession?: VoiceStarter;
  voiceSessionActive?: boolean;
  voiceListening?: boolean;
  voiceLevel?: number;
  voiceTranscript?: string;
  voiceWorking?: boolean;
  voiceSpeaking?: boolean;
  voiceSpeechEnabled?: boolean;
  onCloseVoiceSession?: () => void;
  onVoiceDeliver?: () => void;
  onToggleVoiceSpeaker?: () => void;
};

const acceptedExtensions = new Set(['html', 'htm', 'css', 'js', 'json', 'txt', 'md', 'py', 'svg', 'csv']);
const templates = [
  ['Sayaç', 'Artır, azalt ve sıfırla butonları olan bir sayaç uygulaması yap'],
  ['Yapılacaklar', 'Görev ekleme, silme ve tamamlandı işaretleme olan bir yapılacaklar listesi yap'],
  ['Hafıza oyunu', '4x4 kartlı basit bir hafıza kartı eşleştirme oyunu yap'],
  ['Kişisel site', 'Kişisel tanıtım sayfası yap: adım, mesleğim ve iletişim bölümü olsun'],
  ['Python', "Python ile 1'den 100'e kadar asal sayıları yazdıran bir program yap"],
] as const;

function newId() { return `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`; }
function safePath(path: string) {
  const parts = path.split('/');
  return !!path && !path.includes('\\') && !path.includes('\0') && parts.length <= 4 && parts.every(part => !!part && !part.startsWith('.'));
}
function syncable(path: string, content: string) { return safePath(path) && acceptedExtensions.has(path.split('.').pop()?.toLowerCase() ?? '') && unescape(encodeURIComponent(content)).length <= 100 * 1024; }
function escapeRegex(value: string) { return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
function makeHistory(summary: string, source: string, before: Record<string, string>, after: Record<string, string>, verified = true): ActHistory {
  const paths = new Set([...Object.keys(before), ...Object.keys(after)]);
  const changes = [...paths].sort().flatMap(path => before[path] === after[path] ? [] : [{ path, ...(before[path] !== undefined ? { before: before[path] } : {}), ...(after[path] !== undefined ? { after: after[path] } : {}) }]);
  return { id: newId(), summary, source, verified, date: Date.now(), changes };
}
function bundleWeb(files: Record<string, string>) {
  const entry = files['index.html'] ?? Object.entries(files).find(([path]) => path.toLowerCase().endsWith('.html'))?.[1];
  if (!entry) return '';
  let html = entry;
  for (const [path, content] of Object.entries(files)) {
    if (path.endsWith('.css')) html = html.replace(new RegExp(`<link\\b[^>]*href=["']${escapeRegex(path)}["'][^>]*>`, 'i'), `<style>${content.replace(/<\/style/gi, '<\\/style')}</style>`);
    if (path.endsWith('.js')) html = html.replace(new RegExp(`<script\\b[^>]*src=["']${escapeRegex(path)}["'][^>]*>\\s*<\\/script>`, 'i'), `<script>${content.replace(/<\/script/gi, '<\\/script')}</script>`);
  }
  const viewport = '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">';
  if (/<meta[^>]+name=["']viewport/i.test(html)) return html;
  return /<head[^>]*>/i.test(html) ? html.replace(/<head[^>]*>/i, match => `${match}${viewport}`) : `${viewport}${html}`;
}
function titleFromRequest(request: string) {
  const first = request.trim().split(/[.!?\n]/)[0]?.trim() || 'Yeni proje';
  return first.slice(0, 60);
}

function relativeDate(timestamp: number) {
  const minutes = Math.max(0, Math.floor((Date.now() - timestamp) / 60_000));
  if (minutes < 1) return 'şimdi';
  if (minutes < 60) return `${minutes} dk. önce`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} sa. önce`;
  const days = Math.floor(hours / 24);
  if (days === 1) return 'Dün';
  if (days < 7) return `${days} gün önce`;
  return new Date(timestamp).toLocaleDateString();
}

type HubFile = { p: string; b?: string | null; h?: string | null; d?: boolean };
function openHubFiles(rows: HubFile[], keys: ActKeys) {
  const files: Record<string, string> = {};
  for (const row of rows) {
    if (!row.b) continue;
    const envelope = keys.open<{ path: string; content: string | null }>(row.b);
    if (!envelope || !syncable(envelope.path, envelope.content ?? '') || row.p !== keys.pathToken(envelope.path) || files[envelope.path] !== undefined) throw new Error('Şifreli Act projesi bu cihazda açılamadı. Kurtarma anahtarını kontrol et.');
    if (envelope.content !== null) {
      if (row.h !== keys.contentHash(envelope.path, envelope.content)) throw new Error('Act proje dosyasının doğrulaması başarısız.');
      files[envelope.path] = envelope.content;
    }
  }
  return files;
}

function sealedFile(path: string, content: string | null, keys: ActKeys): HubFile {
  return content === null
    ? { p: keys.pathToken(path), b: keys.seal({ path, content: null }), h: null, d: true }
    : { p: keys.pathToken(path), b: keys.seal({ path, content }), h: keys.contentHash(path, content) };
}

async function syncCloudProject(source: ActProject, token: string, keys: ActKeys, onHubIdCreated?: (hubId: number) => Promise<void>): Promise<ActProject> {
  let project = { ...source, base: { ...(source.base ?? {}) }, version: source.version ?? 0 };
  if (!project.hubId) {
    const created = await actApi.createProject(token, keys.seal({ name: project.name, kind: project.kind }));
    project.hubId = created.id;
    // Keep the remote identity before snapshot/push. If a later request fails, the next refresh
    // must resume this project instead of creating another empty hub project.
    await onHubIdCreated?.(created.id);
  }
  const hubId = project.hubId;
  const snapshot = await actApi.snapshot(token, hubId);
  let remote = openHubFiles(snapshot.files, keys);
  const baseBefore = project.base ?? {};
  const localBefore = project.files;
  const localChanges = new Map<string, string | null>();
  for (const path of new Set([...Object.keys(localBefore), ...Object.keys(baseBefore)])) {
    const local = localBefore[path];
    const baseHash = baseBefore[path];
    const localHash = local === undefined ? undefined : keys.contentHash(path, local);
    if (localHash !== baseHash) localChanges.set(path, local ?? null);
  }
  const remoteHash = (path: string) => remote[path] === undefined ? undefined : keys.contentHash(path, remote[path]);
  const merged = { ...remote };
  for (const [path, localContent] of localChanges) {
    const remoteChanged = remoteHash(path) !== baseBefore[path];
    const localChanged = localContent === null ? baseBefore[path] !== undefined : keys.contentHash(path, localContent) !== baseBefore[path];
    if (remoteChanged && localChanged && localContent !== remote[path] && localContent !== null) {
      let copy = path.replace(/(\.[^./]+)?$/, ' - Android kopyası$1'); let n = 2;
      while (merged[copy] !== undefined || localBefore[copy] !== undefined) { copy = path.replace(/(\.[^./]+)?$/, ` ${n++}$1`); }
      merged[copy] = localContent;
    } else if (!remoteChanged && localContent === null) delete merged[path];
    else if (!remoteChanged && localContent !== null) merged[path] = localContent;
  }
  const changes: HubFile[] = [];
  for (const path of new Set([...Object.keys(merged), ...Object.keys(remote)])) {
    if (merged[path] !== remote[path]) changes.push(sealedFile(path, merged[path] ?? null, keys));
  }
  if (changes.length) {
    const pushed = await actApi.push(token, hubId, snapshot.version, changes, 'değişiklik', 'Android');
    if (!pushed.ok && pushed.conflict !== true) throw new Error(pushed.error || 'Act değişiklikleri senkronlanamadı.');
    if (pushed.conflict) {
      const latest = await actApi.snapshot(token, hubId);
      remote = openHubFiles(latest.files, keys);
      const retry: HubFile[] = [];
      for (const path of new Set([...Object.keys(merged), ...Object.keys(remote)])) if (merged[path] !== remote[path]) retry.push(sealedFile(path, merged[path] ?? null, keys));
      if (retry.length) {
        const result = await actApi.push(token, hubId, latest.version, retry, 'değişiklik', 'Android');
        if (!result.ok) throw new Error('Act senkronunda çakışma oluştu. Proje bu cihazda korundu.');
      }
    }
    const latest = await actApi.snapshot(token, hubId);
    remote = openHubFiles(latest.files, keys);
    project.version = latest.version;
  } else project.version = snapshot.version;
  project.files = remote;
  project.base = Object.fromEntries(Object.entries(remote).map(([path, content]) => [path, keys.contentHash(path, content)]));
  project.updatedAt = Date.now();
  return project;
}

export function ActScreen({ token, startDictation, startVoiceSession, voiceSessionActive = false, voiceListening = false, voiceLevel = 0, voiceTranscript = '', voiceWorking = false, voiceSpeaking = false, voiceSpeechEnabled = true, onCloseVoiceSession = () => undefined, onVoiceDeliver = () => undefined, onToggleVoiceSpeaker = () => undefined }: Props) {
  const colors = useWiqoColors();
  const appearance = useAppearance();
  const [projects, setProjects] = useState<ActProject[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [storeUri, setStoreUri] = useState<string | null>(null);
  const [accountScope, setAccountScope] = useState('');
  const [keys, setKeys] = useState<ActKeys | null>(null);
  const [projectId, setProjectId] = useState<string | null>(null);
  const [tab, setTab] = useState<ActTab>('preview');
  const [draft, setDraft] = useState('');
  const [notice, setNotice] = useState('');
  const [job, setJob] = useState<ActWriterJob | null>(null);
  const [busy, setBusy] = useState(false);
  const [mode, setMode] = useState<'devices' | 'deviceOnly'>('devices');
  const [searchOpen, setSearchOpen] = useState(false);
  const [search, setSearch] = useState('');
  const [fileName, setFileName] = useState('');
  const [renamingPath, setRenamingPath] = useState<string | null>(null);
  const [editingPath, setEditingPath] = useState<string | null>(null);
  const [editingText, setEditingText] = useState('');
  const [selectedPath, setSelectedPath] = useState('');
  const [runOutput, setRunOutput] = useState<ActRunResult | null>(null);
  const [previewRevision, setPreviewRevision] = useState(0);
  const [privacyOpen, setPrivacyOpen] = useState(false);
  const [recoveryInput, setRecoveryInput] = useState('');
  const [privacyNotice, setPrivacyNotice] = useState('');
  const [dockHidden, setDockHidden] = useState(false);
  const [pinnedProjectIds, setPinnedProjectIds] = useState<string[]>([]);
  const [workspaceMenuOpen, setWorkspaceMenuOpen] = useState(false);
  const [contextProject, setContextProject] = useState<ActProject | null>(null);
  const [contextFile, setContextFile] = useState<string | null>(null);
  const [pendingDelete, setPendingDelete] = useState<ActProject | null>(null);
  const [pendingPrivacyMode, setPendingPrivacyMode] = useState<'devices' | 'deviceOnly' | null>(null);
  const [previewDevice, setPreviewDevice] = useState<'phone' | 'tablet' | 'desktop'>('phone');
  const [fullScreenPreview, setFullScreenPreview] = useState(false);
  const [privacyModeOpen, setPrivacyModeOpen] = useState(false);
  const [pendingWriterConsent, setPendingWriterConsent] = useState<{ operation: 'create' | 'edit'; request: string; target?: ActProject; mode: 'devices' | 'deviceOnly' } | null>(null);
  const [actVoiceQueue, setActVoiceQueue] = useState<string[]>([]);
  const [pendingVoiceConfirm, setPendingVoiceConfirm] = useState<string | null>(null);
  const lastVoiceRequest = useRef('');
  const voiceDrainLock = useRef(false);
  const handleVoiceCommandRef = useRef<(text: string) => void>(() => undefined);
  const composerRef = useRef<TextInput>(null);
  const projectsRef = useRef(projects);
  const initialSyncToken = useRef<string | null>(null);
  const syncingRef = useRef(false);
  const [syncing, setSyncing] = useState(false);

  const project = projects.find(item => item.id === projectId) ?? null;
  const files = project ? Object.entries(project.files).sort(([a], [b]) => a.localeCompare(b)) : [];
  const visibleProjects = projects
    .filter(item => !search.trim() || item.name.toLocaleLowerCase('tr').includes(search.trim().toLocaleLowerCase('tr')))
    .sort((a, b) => Number(pinnedProjectIds.includes(b.id)) - Number(pinnedProjectIds.includes(a.id)) || b.updatedAt - a.updatedAt);
  const pageHtml = project?.kind === 'web' ? bundleWeb(project.files) : '';

  const persist = useCallback(async (next: ActProject[]) => {
    if (!storeUri) return;
    setProjects(next);
    await FileSystem.writeAsStringAsync(storeUri, JSON.stringify(next));
  }, [storeUri]);

  useEffect(() => {
    let alive = true;
    setLoaded(false);
    setProjectId(null);
    setKeys(null);
    void actStorageScope(token)
      .then(async scope => {
        if (!alive) return;
        const uri = `${FileSystem.documentDirectory ?? ''}act-projects-${scope.slice(0, 32)}.json`;
        setStoreUri(uri);
        setAccountScope(scope);
        const [loadedKeys, stored] = await Promise.all([loadActKeys(scope), FileSystem.readAsStringAsync(uri).catch(() => '[]')]);
        if (!alive) return;
        setKeys(loadedKeys);
        const values = JSON.parse(stored) as ActProject[];
        setProjects(Array.isArray(values) ? values : []);
      }).catch(() => { if (alive) setProjects([]); }).finally(() => { if (alive) setLoaded(true); });
    return () => { alive = false; };
  }, [token]);

  useEffect(() => { projectsRef.current = projects; }, [projects]);

  useEffect(() => { void SecureStore.getItemAsync('wiqo.act.dock.hidden').then(value => setDockHidden(value === '1')).catch(() => undefined); }, []);
  useEffect(() => { void SecureStore.getItemAsync('act.pinned.projects').then(value => setPinnedProjectIds(value ? JSON.parse(value) as string[] : [])).catch(() => undefined); }, []);
  const changeDockVisibility = useCallback((hidden: boolean) => {
    setDockHidden(hidden);
    void SecureStore.setItemAsync('wiqo.act.dock.hidden', hidden ? '1' : '0').catch(() => undefined);
  }, []);

  const syncAll = useCallback(async () => {
    if (!token || !keys || !storeUri || syncingRef.current) return;
    syncingRef.current = true;
    setSyncing(true);
    try {
      const { projects: remoteProjects } = await actApi.projects(token);
      const next = [...projectsRef.current];
      const importedEmptyCopies = next.filter(item =>
        Object.keys(item.files).length === 0 && item.history[0]?.source === 'Başka cihaz' &&
        next.some(other => other.id !== item.id && other.kind === item.kind && other.name.trim().toLocaleLowerCase('tr') === item.name.trim().toLocaleLowerCase('tr') && Object.keys(other.files).length > 0),
      );
      if (importedEmptyCopies.length) {
        const duplicateIds = new Set(importedEmptyCopies.map(item => item.id));
        const cleaned = next.filter(item => !duplicateIds.has(item.id));
        next.splice(0, next.length, ...cleaned);
        projectsRef.current = cleaned;
        await persist(cleaned);
      }
      const known = new Set(next.map(item => item.hubId).filter((id): id is number => typeof id === 'number'));
      for (const item of next) if (item.mode === 'devices') {
        try {
          const synced = await syncCloudProject(item, token, keys, async hubId => {
            const current = projectsRef.current.map(row => row.id === item.id ? { ...row, hubId } : row);
            const index = next.findIndex(row => row.id === item.id);
            if (index >= 0) next[index] = { ...next[index], hubId };
            projectsRef.current = current;
            await persist(current);
          });
          const index = next.findIndex(row => row.id === item.id); if (index >= 0) next[index] = synced;
          if (synced.hubId) known.add(synced.hubId);
        } catch (cause) { setNotice(cause instanceof Error ? cause.message : 'Act projesi senkronlanamadı.'); }
      }
      for (const remote of remoteProjects) {
        if (known.has(remote.id)) continue;
        const meta = keys.open<{ name?: string; kind?: string }>(remote.meta);
        if (!meta?.name || !meta.kind) continue;
        try {
          const snapshot = await actApi.snapshot(token, remote.id);
          const remoteFiles = openHubFiles(snapshot.files, keys);
          const nameKey = meta.name.trim().toLocaleLowerCase('tr');
          const duplicateEmptyProject = Object.keys(remoteFiles).length === 0 && next.some(item =>
            item.hubId !== remote.id && item.kind === (meta.kind === 'python' ? 'python' : 'web') &&
            item.name.trim().toLocaleLowerCase('tr') === nameKey && Object.keys(item.files).length > 0,
          );
          if (duplicateEmptyProject) { known.add(remote.id); continue; }
          const id = newId();
          next.push({ id, name: meta.name, kind: meta.kind === 'python' ? 'python' : 'web', files: remoteFiles, mode: 'devices', hubId: remote.id, version: snapshot.version, base: Object.fromEntries(Object.entries(remoteFiles).map(([path, content]) => [path, keys.contentHash(path, content)])), updatedAt: Date.now(), history: [makeHistory('Başka cihazdan alındı', 'Başka cihaz', {}, remoteFiles)] });
        } catch (cause) { setNotice(cause instanceof Error ? cause.message : 'Başka cihazdaki Act projesi açılamadı.'); }
      }
      await persist(next);
    } catch (cause) { setNotice(cause instanceof Error ? cause.message : 'Act projeleri sunucudan alınamadı.'); }
    finally { syncingRef.current = false; setSyncing(false); }
  }, [keys, persist, storeUri, token]);

  useEffect(() => {
    if (!loaded || !token || !keys || initialSyncToken.current === token) return;
    initialSyncToken.current = token;
    void syncAll();
  }, [keys, loaded, syncAll, token]);

  const saveProject = useCallback(async (updated: ActProject) => {
    const next = [updated, ...projects.filter(item => item.id !== updated.id)].sort((a, b) => b.updatedAt - a.updatedAt);
    await persist(next);
    projectsRef.current = next;
    if (updated.mode === 'devices' && token && keys) {
      try {
        const synced = await syncCloudProject(updated, token, keys, async hubId => {
          const checkpointed = projectsRef.current.map(item => item.id === updated.id ? { ...item, hubId } : item);
          projectsRef.current = checkpointed;
          await persist(checkpointed);
        });
        const latest = [synced, ...projectsRef.current.filter(item => item.id !== synced.id)].sort((a, b) => b.updatedAt - a.updatedAt);
        await persist(latest); projectsRef.current = latest;
      } catch (cause) { setNotice(cause instanceof Error ? `${cause.message} Proje bu cihazda kaydedildi.` : 'Proje bu cihazda kaydedildi; sunucu senkronu tamamlanamadı.'); }
    }
  }, [keys, persist, projects, token]);

  const runWriter = useCallback(async (operation: 'create' | 'edit', requestText: string, target?: ActProject) => {
    if (!token || busy || requestText.trim().length < 3) return;
    Keyboard.dismiss(); setBusy(true); setNotice('Yazar işi başlatılıyor…'); setJob({ id: '', status: 'running', progress: 'İstek sunucuya gönderiliyor…' });
    try {
      const { jobId } = await actApi.startWriter(token, { operation, request: requestText.trim(), files: target ? Object.entries(target.files).map(([path, content]) => ({ path, content })) : [], kind: target?.kind ?? 'web', ...(target ? { name: target.name } : {}) });
      setJob({ id: jobId, status: 'queued', progress: 'Sunucuya bağlandı; sıra bekleniyor.' });
      let finished = false;
      for (let attempt = 0; attempt < 150; attempt += 1) {
        const current = await actApi.writerJob(token, jobId);
        setJob(current); setNotice(current.status === 'queued' ? 'Sırada; yazar boşalınca başlayacak.' : current.progress || 'Proje hazırlanıyor…');
        if (['done', 'failed', 'cancelled'].includes(current.status)) {
          finished = true;
          await actApi.acknowledgeWriter(token, jobId).catch(() => undefined);
          if (current.status !== 'done' || !current.result) throw new Error(current.error || (current.errorCode === 'VALIDATION_FAILED' ? 'Üretilen kod doğrulamadan geçemedi; isteği değiştirip yeniden dene.' : 'Değişiklik üretilemedi.'));
          const oldFiles = target?.files ?? {};
          const nextFiles = { ...oldFiles };
          current.result.changes.forEach(change => { if (change.after === null) delete nextFiles[change.path]; else if (change.after !== null) nextFiles[change.path] = change.after; });
          const kind = current.result.kind === 'python' ? 'python' : 'web';
          const item: ActProject = target ? { ...target, name: current.result.name || target.name, kind, files: nextFiles, history: [makeHistory(current.result.summary || requestText.trim(), 'Wiqo', oldFiles, nextFiles, !current.result.needsDeviceCheck), ...target.history].slice(0, 30), updatedAt: Date.now() } : {
            id: newId(), name: current.result.name || titleFromRequest(requestText), kind, files: nextFiles,
            history: [makeHistory(current.result.summary || requestText.trim(), 'Wiqo', {}, nextFiles, !current.result.needsDeviceCheck)], updatedAt: Date.now(), mode,
          };
          await saveProject(item); setProjectId(item.id); setTab('preview'); setDraft(''); setNotice(current.result.needsDeviceCheck ? 'Değişiklik kaydedildi; bu cihazda doğrulama Android WebView ile sınırlı.' : '');
          return;
        }
        await new Promise(resolve => setTimeout(resolve, 1_500));
      }
      if (!finished) throw new Error('İşlem beklenenden uzun sürdü. Proje değişmedi; biraz sonra yeniden deneyebilirsin.');
    } catch (cause) {
      setNotice(cause instanceof Error ? cause.message : 'Act isteği tamamlanamadı.');
    } finally { setBusy(false); setJob(null); }
  }, [busy, mode, saveProject, token]);

  const submit = (requestOverride?: string) => {
    const request = (requestOverride ?? draft).trim();
    if (request.length < 3 || busy) return;
    const currentMode = project?.mode ?? mode;
    void (async () => {
      const consentKey = `act-writer-consent-${currentMode}`;
      const consent = currentMode === 'devices' ? await SecureStore.getItemAsync(consentKey).catch(() => null) : null;
      if (consent) { void runWriter(project ? 'edit' : 'create', request, project ?? undefined); return; }
      setPendingWriterConsent({ operation: project ? 'edit' : 'create', request, target: project ?? undefined, mode: currentMode });
    })();
  };

  const cancelJob = async () => {
    if (!token || !job?.id) return;
    await actApi.cancelWriter(token, job.id).catch(() => undefined);
    setNotice('Görev durdurma isteği gönderildi.');
  };

  const importFiles = async () => {
    try {
      const result = await DocumentPicker.getDocumentAsync({ multiple: true, copyToCacheDirectory: true, type: ['text/*', 'application/json', 'image/svg+xml'] });
      if (result.canceled) return;
      const picked: Record<string, string> = {};
      let skipped = 0;
      for (const asset of result.assets.slice(0, 40)) {
        const ext = asset.name.split('.').pop()?.toLowerCase() ?? '';
        if (!acceptedExtensions.has(ext) || asset.size !== undefined && asset.size > 100 * 1024) { skipped += 1; continue; }
        try { const content = await FileSystem.readAsStringAsync(asset.uri, { encoding: FileSystem.EncodingType.UTF8 }); if (syncable(asset.name, content)) picked[asset.name] = content; else skipped += 1; }
        catch { skipped += 1; }
      }
      if (!Object.keys(picked).length) { setNotice('Metin dosyası alınamadı. Desteklenenler: html, css, js, json, txt, md, py, svg, csv (en çok 100 KB).'); return; }
      const kind = !Object.keys(picked).some(path => path.endsWith('.html') || path.endsWith('.htm')) && Object.keys(picked).some(path => path.endsWith('.py')) ? 'python' : 'web';
      const entry = Object.keys(picked).find(path => path.endsWith('.html') || path.endsWith('.htm'));
      if (entry && !picked['index.html'] && Object.keys(picked).filter(path => path.endsWith('.html') || path.endsWith('.htm')).length === 1) { picked['index.html'] = picked[entry]; delete picked[entry]; }
      const item: ActProject = { id: newId(), name: result.assets[0]?.name.replace(/\.[^.]+$/, '').slice(0, 60) || 'İçe aktarılan proje', kind, files: picked, history: [makeHistory('Dosyalardan içe aktarıldı', 'İçe aktarma', {}, picked)], updatedAt: Date.now(), mode };
      await saveProject(item); setProjectId(item.id); setTab('preview'); setNotice(skipped ? `${skipped} dosya alınamadı; tür veya boyut sınırını kontrol et.` : '');
    } catch { setNotice('Dosya seçimi açılamadı.'); }
  };

  const duplicateProject = async (source = project): Promise<string | null> => {
    if (!source) return null;
    const copy: ActProject = { ...source, id: newId(), hubId: undefined, version: 0, base: {}, name: `${source.name} kopyası`.slice(0, 60), history: [makeHistory(`“${source.name}” projesinin kopyası`, 'Kopya', {}, source.files)], updatedAt: Date.now() };
    await saveProject(copy); setProjectId(copy.id); return copy.id;
  };

  const removeProject = async (item: ActProject) => {
    if (item.mode === 'devices' && item.hubId && token) {
      try { await actApi.deleteProject(token, item.hubId); }
      catch (cause) { setNotice(cause instanceof Error ? `Sunucudaki şifreli proje silinemedi: ${cause.message}` : 'Sunucudaki proje silinemedi.'); return; }
    }
    const next = projectsRef.current.filter(row => row.id !== item.id);
    await persist(next); projectsRef.current = next;
    if (projectId === item.id) setProjectId(null);
  };

  const applyProjectPrivacy = (toDevices = project?.mode === 'deviceOnly') => {
    if (!project) return;
    void (async () => {
        if (!toDevices && project.hubId && token) {
          try { await actApi.deleteProject(token, project.hubId); }
          catch (cause) { setNotice(cause instanceof Error ? `Sunucu kopyası silinemedi: ${cause.message}` : 'Sunucu kopyası silinemedi.'); return; }
        }
        const updated: ActProject = { ...project, mode: toDevices ? 'devices' : 'deviceOnly', ...(toDevices ? {} : { hubId: undefined, version: 0, base: {} }), updatedAt: Date.now() };
        if (toDevices) await saveProject(updated); else { await persist([updated, ...projectsRef.current.filter(item => item.id !== updated.id)]); projectsRef.current = [updated, ...projectsRef.current.filter(item => item.id !== updated.id)]; }
        setNotice('');
    })();
  };

  const deleteProject = () => {
    if (!project) return;
    setPendingDelete(project);
  };

  const saveManualFile = async () => {
    if (!project || !editingPath) return;
    const before = project.files; const nextFiles = { ...before, [editingPath]: editingText };
    const updated = { ...project, files: nextFiles, history: [makeHistory(`${editingPath} elle düzenlendi`, 'Elle düzenleme', before, nextFiles), ...project.history].slice(0, 30), updatedAt: Date.now() };
    await saveProject(updated); setEditingPath(null); setNotice('Dosya kaydedildi.');
  };

  const addFile = () => {
    const name = fileName.trim(); setFileName('');
    if (!project || !safePath(name) || !acceptedExtensions.has(name.split('.').pop()?.toLowerCase() ?? '') || project.files[name] && name !== renamingPath) { setNotice('Dosya adı veya türü uygun değil.'); setRenamingPath(null); return; }
    if (renamingPath && project.files[renamingPath] !== undefined) {
      const nextFiles = { ...project.files, [name]: project.files[renamingPath] }; delete nextFiles[renamingPath];
      const updated = { ...project, files: nextFiles, history: [makeHistory(`${renamingPath} yeniden adlandırıldı`, 'Elle düzenleme', project.files, nextFiles), ...project.history], updatedAt: Date.now() };
      void saveProject(updated); setSelectedPath(name); setRenamingPath(null); return;
    }
    setRenamingPath(null);
    const nextFiles = { ...project.files, [name]: '' };
    const updated = { ...project, files: nextFiles, history: [makeHistory(`${name} oluşturuldu`, 'Elle düzenleme', project.files, nextFiles), ...project.history].slice(0, 30), updatedAt: Date.now() };
    void saveProject(updated); setSelectedPath(name); setEditingPath(name); setEditingText('');
  };

  const undo = async () => {
    if (!project || project.history.length < 1) return;
    const latest = project.history[0]; const nextFiles = { ...project.files };
    latest.changes.forEach(change => { if (change.before === undefined) delete nextFiles[change.path]; else nextFiles[change.path] = change.before; });
    const updated = { ...project, files: nextFiles, history: [makeHistory(`Geri alındı: ${latest.summary}`, 'Geri alma', project.files, nextFiles), ...project.history].slice(0, 30), updatedAt: Date.now() };
    await saveProject(updated); setNotice('Son değişiklik geri alındı.');
  };

  const handleVoiceCommand = (raw: string) => {
    const sentence = raw.trim();
    if (!sentence) return;
    const command = sentence.normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/ı/g, 'i').toLocaleLowerCase('tr').replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
    const has = (...phrases: string[]) => phrases.some(phrase => command === phrase || command.startsWith(`${phrase} `));
    const exact = (...phrases: string[]) => phrases.includes(command);
    if (has('durdur', 'dur', 'iptal', 'iptal et', 'birak', 'vazgec')) {
      setPendingVoiceConfirm(null); setActVoiceQueue([]); voiceDrainLock.current = false;
      if (busy) void cancelJob();
      setNotice('Sesli komut durduruldu.'); onCloseVoiceSession(); return;
    }
    if (has('hayir', 'yapma', 'hayir yapma')) { setPendingVoiceConfirm(null); setNotice('Onay bekleyen değişiklik iptal edildi.'); return; }
    if (pendingVoiceConfirm && has('evet', 'onayla', 'evet yap', 'olur', 'tamam yap')) {
      const confirmed = pendingVoiceConfirm; setPendingVoiceConfirm(null); lastVoiceRequest.current = confirmed; submit(confirmed); return;
    }
    if (exact('tekrar yap', 'bir daha', 'aynisini yap', 'tekrarla')) {
      if (lastVoiceRequest.current) submit(lastVoiceRequest.current);
      else setNotice('Tekrarlanacak bir sesli komut yok.');
      return;
    }
    if (exact('geri al', 'son degisikligi geri al', 'geri al lutfen')) { void undo(); return; }
    if (exact('onizleme', 'onizlemeyi goster', 'sayfayi goster')) { setTab('preview'); setNotice(''); return; }
    if (exact('kodu goster', 'kod')) { setTab('code'); setNotice(''); return; }
    if (exact('gecmis', 'gecmisi goster')) { setTab('history'); setNotice(''); return; }
    if (exact('tam ekran', 'tam ekran yap')) { setFullScreenPreview(true); return; }
    if (exact('yenile', 'sayfayi yenile')) { setPreviewRevision(value => value + 1); return; }
    if (exact('koyu tema', 'karanlik tema', 'koyu gorunum')) { appearance.setPreference('mode', 'dark'); setNotice('Koyu tema açıldı.'); return; }
    if (exact('acik tema', 'aydinlik tema')) { appearance.setPreference('mode', 'light'); setNotice('Açık tema açıldı.'); return; }
    if (exact('sistem temasi', 'otomatik tema')) { appearance.setPreference('mode', 'system'); setNotice('Sistem teması seçildi.'); return; }
    if (exact('yazi boyutunu kucult', 'yaziyi kucult')) { appearance.setPreference('textScale', 'small'); return; }
    if (exact('yazi boyutunu buyut', 'yaziyi buyut')) { appearance.setPreference('textScale', 'large'); return; }
    if (exact('varsayilan yazi boyutu', 'yazi boyutu varsayilan')) { appearance.setPreference('textScale', 'standard'); return; }
    if (pendingVoiceConfirm) { setNotice('Devam etmek için “Evet” ya da “Hayır” de.'); return; }
    if (busy) {
      setActVoiceQueue(current => current.length >= 5 ? current : [...current, sentence]);
      setNotice('Komut sıraya alındı.'); return;
    }
    if (/\b(sil|silsin|sileyim|silelim|kaldir|temizle|bosalt|hepsini)\b/.test(command) || command.includes('uzerine yaz')) {
      setPendingVoiceConfirm(sentence); setNotice(`Bu değişikliği yapmamı onaylıyor musun: “${sentence}”?`); return;
    }
    lastVoiceRequest.current = sentence;
    setDraft(sentence);
    submit(sentence);
  };
  handleVoiceCommandRef.current = handleVoiceCommand;

  useEffect(() => {
    if (busy || pendingWriterConsent || pendingVoiceConfirm || !actVoiceQueue.length || voiceDrainLock.current) return;
    voiceDrainLock.current = true;
    const next = actVoiceQueue[0];
    setActVoiceQueue(current => current.slice(1));
    setTimeout(() => { voiceDrainLock.current = false; handleVoiceCommandRef.current(next); }, 250);
  }, [actVoiceQueue, busy, pendingVoiceConfirm, pendingWriterConsent]);

  const actVoiceHints = [project?.name, ...files.map(([path]) => path), 'proje oluştur', 'kodu göster', 'önizleme', 'geçmiş', 'geri al', 'durdur', 'evet', 'hayır'].filter((value): value is string => !!value);
  const startActVoice = () => { if (!voiceSessionActive) startVoiceSession?.(text => handleVoiceCommandRef.current(text), actVoiceHints); };

  const runPython = async () => {
    if (!token || !project) return;
    setBusy(true); setRunOutput(null);
    try { setRunOutput(await actApi.runPython(token, Object.entries(project.files).map(([path, content]) => ({ path, content })))); }
    catch (cause) { setNotice(cause instanceof Error ? cause.message : 'Python programı çalıştırılamadı.'); }
    finally { setBusy(false); }
  };

  const exportProject = async (target: ActProject | null = project) => {
    if (!target) return;
    const page = target.kind === 'web' ? bundleWeb(target.files) : Object.entries(target.files).map(([path, content]) => `# --- ${path} ---\n${content}`).join('\n\n');
    await Share.share({ title: target.name, message: page });
  };

  const openContext = (kind: 'workspace' | 'project' | 'file', target?: ActProject, path?: string) => {
    setContextProject(kind === 'project' ? target ?? null : null);
    setContextFile(kind === 'file' ? path ?? null : null);
    setWorkspaceMenuOpen(true);
  };

  const toggleProjectPin = (item: ActProject) => {
    const next = pinnedProjectIds.includes(item.id) ? pinnedProjectIds.filter(id => id !== item.id) : [item.id, ...pinnedProjectIds];
    setPinnedProjectIds(next);
    void SecureStore.setItemAsync('act.pinned.projects', JSON.stringify(next)).catch(() => undefined);
  };

  const dockActions: ActDockAction[][] = project ? [
    [
      { id: 'preview', icon: project.kind === 'python' ? 'play-box-outline' : 'cellphone', label: project.kind === 'python' ? 'Çıktı' : 'Önizleme', selected: tab === 'preview', onPress: () => { Keyboard.dismiss(); setTab('preview'); setEditingPath(null); } },
      { id: 'code', icon: 'code-tags', label: 'Kod', selected: tab === 'code', onPress: () => { Keyboard.dismiss(); setTab('code'); setEditingPath(null); } },
      { id: 'history', icon: 'history', label: 'Geçmiş', selected: tab === 'history', onPress: () => { Keyboard.dismiss(); setTab('history'); setEditingPath(null); } },
    ],
    ...(tab === 'preview' ? project.kind === 'web' ? [[
      { id: 'device', icon: previewDevice === 'phone' ? 'cellphone' : previewDevice === 'tablet' ? 'tablet' : 'monitor', label: `Önizleme boyutu: ${previewDevice}`, onPress: () => setPreviewDevice(value => value === 'phone' ? 'tablet' : value === 'tablet' ? 'desktop' : 'phone') },
      { id: 'fullscreen', icon: 'fullscreen', label: 'Tam ekran', onPress: () => setFullScreenPreview(true) },
      { id: 'reload', icon: 'reload', label: 'Sayfayı yenile', onPress: () => setPreviewRevision(value => value + 1) },
    ]] : [[{ id: 'run', icon: 'play', label: 'Python çalıştır', disabled: busy, onPress: () => void runPython() }]] : []),
  ] : [
    [
      { id: 'new', icon: 'plus', label: 'Yeni proje', onPress: () => { composerRef.current?.focus(); } },
      { id: 'search', icon: 'magnify', label: 'Projelerde ara', selected: searchOpen, disabled: !projects.length, onPress: () => { setSearchOpen(value => !value); if (searchOpen) setSearch(''); } },
    ],
    [
      { id: 'import', icon: 'tray-arrow-down', label: 'Dosyalardan aç', onPress: () => void importFiles() },
      { id: 'privacy', icon: 'shield-lock-outline', label: 'Gizlilik ve anahtar', onPress: () => { setPrivacyNotice(''); setPrivacyOpen(true); } },
    ],
  ];

  const contextTarget = contextProject ?? project;
  const contextItems: { id: string; label: string; icon: ComponentProps<typeof MaterialCommunityIcons>['name']; destructive?: boolean }[] = contextFile
    ? [{ id: 'edit-file', label: 'Dosyayı düzenle', icon: 'pencil-outline' }, { id: 'rename-file', label: 'Yeniden adlandır', icon: 'form-textbox' }, { id: 'delete-file', label: 'Dosyayı sil', icon: 'delete-outline', destructive: true }]
      : contextProject
      ? [{ id: 'open', label: 'Projeyi aç', icon: 'open-in-new' }, { id: 'pin', label: pinnedProjectIds.includes(contextProject.id) ? 'Üste sabitlemeyi kaldır' : 'Üste sabitle', icon: pinnedProjectIds.includes(contextProject.id) ? 'pin-off-outline' : 'pin-outline' }, { id: 'duplicate', label: 'Kopya oluştur', icon: 'content-copy' }, { id: 'export', label: 'Dışa aktar', icon: 'share-variant-outline' }, { id: 'delete', label: 'Projeyi sil', icon: 'delete-outline', destructive: true }]
      : [{ id: 'undo', label: 'Son değişikliği geri al', icon: 'undo', destructive: false }, ...(project?.kind === 'python' ? [{ id: 'run', label: 'Python çalıştır', icon: 'play' as const }] : []), { id: 'new-file', label: 'Yeni dosya', icon: 'file-plus-outline' }, { id: 'duplicate', label: 'Kopya oluştur', icon: 'content-copy' }, { id: 'export', label: 'Dışa aktar', icon: 'share-variant-outline' }, { id: 'privacy', label: 'Gizlilik ve anahtar', icon: 'shield-lock-outline' }, { id: 'delete', label: 'Projeyi sil', icon: 'delete-outline', destructive: true }];

  const chooseContextItem = (id: string) => {
    setWorkspaceMenuOpen(false);
    if (id === 'open' && contextTarget) { setProjectId(contextTarget.id); setTab('preview'); setSelectedPath(Object.keys(contextTarget.files)[0] ?? ''); }
    else if (id === 'pin' && contextTarget) toggleProjectPin(contextTarget);
    else if (id === 'duplicate' && contextTarget) void duplicateProject(contextTarget);
    else if (id === 'export' && contextTarget) void exportProject(contextTarget);
    else if (id === 'delete' && contextTarget) setPendingDelete(contextTarget);
    else if (id === 'privacy') { setPrivacyNotice(''); setPrivacyOpen(true); }
    else if (id === 'undo') void undo();
    else if (id === 'run') void runPython();
    else if (id === 'new-file') { setTab('code'); setRenamingPath(null); setFileName(' '); }
    else if (contextFile && project) {
      if (id === 'edit-file') { setSelectedPath(contextFile); setEditingPath(contextFile); setEditingText(project.files[contextFile] ?? ''); setTab('code'); }
      if (id === 'rename-file') { setSelectedPath(contextFile); setRenamingPath(contextFile); setFileName(contextFile); }
      if (id === 'delete-file') {
        const next = { ...project.files }; delete next[contextFile];
        void saveProject({ ...project, files: next, history: [makeHistory(`${contextFile} silindi`, 'Elle düzenleme', project.files, next), ...project.history].slice(0, 30), updatedAt: Date.now() });
      }
    }
    setContextProject(null); setContextFile(null);
  };

  const privacySheet = <Modal visible={privacyOpen} transparent animationType="fade" onRequestClose={() => setPrivacyOpen(false)}>
    <View style={s.modalScrim}><Pressable style={StyleSheet.absoluteFill} onPress={() => setPrivacyOpen(false)} /><View style={[s.privacySheet, { backgroundColor: colors.canvas, borderColor: colors.line }]}>
      <View style={s.privacyHeading}><Text style={[s.heading, { color: colors.ink, fontSize: 19 }]}>Gizlilik ve anahtar</Text><Pressable onPress={() => setPrivacyOpen(false)}><MaterialCommunityIcons name="close" size={22} color={colors.muted} /></Pressable></View>
      <Text style={[s.privacyCopy, { color: colors.muted }]}>Bağlı cihazlarım seçili projeler sunucuya yalnız şifreli içerik olarak gider. Aynı projeleri iOS cihazlarında açmak için bu kurtarma kodu iki cihazda da kullanılmalı.</Text>
      <View style={[s.recoveryBox, { backgroundColor: colors.surface }]}><Text selectable style={[s.recoveryCode, { color: colors.ink }]}>{keys?.recoveryCode ?? 'Anahtar yükleniyor…'}</Text><Pressable onPress={() => keys && void Clipboard.setStringAsync(keys.recoveryCode)} style={s.copyKey}><MaterialCommunityIcons name="content-copy" size={17} color={colors.accent} /><Text style={{ color: colors.accent, fontWeight: '600' }}>Kopyala</Text></Pressable></View>
      <Text style={[s.privacyCopy, { color: colors.muted }]}>Başka cihazda görünen Wiqo Act kurtarma kodunu buraya gir:</Text>
      <TextInput value={recoveryInput} onChangeText={setRecoveryInput} autoCapitalize="characters" autoCorrect={false} placeholder="ABCDE-FGHIJ-…" placeholderTextColor={colors.muted} style={[s.recoveryInput, { backgroundColor: colors.surface, color: colors.ink }]} />
      {privacyNotice ? <Text style={[s.privacyCopy, { color: colors.danger }]}>{privacyNotice}</Text> : null}
      <Pressable style={[s.importKey, { backgroundColor: colors.accent }]} onPress={() => void (async () => {
        const ok = await importActRecoveryCode(accountScope, recoveryInput);
        if (!ok) { setPrivacyNotice('Kurtarma kodu geçersiz.'); return; }
        setKeys(await loadActKeys(accountScope)); setRecoveryInput(''); setPrivacyNotice('Kurtarma anahtarı kaydedildi; projeler eşitleniyor.'); initialSyncToken.current = null; setPrivacyOpen(false);
      })()}><Text style={{ color: colors.onAccent, fontWeight: '600' }}>Kurtarma kodunu kullan</Text></Pressable>
    </View></View>
  </Modal>;

  const contextSheet = <Modal visible={workspaceMenuOpen} transparent animationType="fade" onRequestClose={() => setWorkspaceMenuOpen(false)}>
    <View style={s.menuScrim}><Pressable style={StyleSheet.absoluteFill} onPress={() => setWorkspaceMenuOpen(false)} /><View style={[s.menuSheet, { backgroundColor: colors.canvas, borderColor: colors.line }]}>
      <View style={s.menuHeading}><View style={s.menuGrip} /><Text numberOfLines={1} style={[s.menuTitle, { color: colors.ink }]}>{contextFile ?? contextTarget?.name ?? 'Proje seçenekleri'}</Text></View>
      {contextItems.map(item => <Pressable key={item.id} accessibilityRole="button" onPress={() => chooseContextItem(item.id)} style={[s.menuRow, { borderTopColor: colors.line }]}><MaterialCommunityIcons name={item.icon} size={20} color={item.destructive ? colors.danger : colors.ink} /><Text style={[s.menuRowText, { color: item.destructive ? colors.danger : colors.ink }]}>{item.label}</Text></Pressable>)}
      <Pressable onPress={() => setWorkspaceMenuOpen(false)} style={s.menuCancel}><Text style={{ color: colors.muted, fontWeight: '600' }}>Vazgeç</Text></Pressable>
    </View></View>
  </Modal>;

  const privacyModeSheet = <Modal visible={privacyModeOpen} transparent animationType="fade" onRequestClose={() => setPrivacyModeOpen(false)}>
    <View style={s.modalScrim}><Pressable style={StyleSheet.absoluteFill} onPress={() => setPrivacyModeOpen(false)} /><View style={[s.privacySheet, { backgroundColor: colors.canvas, borderColor: colors.line }]}>
      <View style={s.privacyHeading}><Text style={[s.heading, { color: colors.ink, fontSize: 19 }]}>Bu proje nerede dursun?</Text><Pressable onPress={() => setPrivacyModeOpen(false)}><MaterialCommunityIcons name="close" size={22} color={colors.muted} /></Pressable></View>
      {[['devices', 'Bağlı cihazlarım', 'Şifreli kopya bu hesaptaki cihazlarla eşitlenir.', 'lock-sync'], ['deviceOnly', 'Yalnız bu cihaz', 'Dosyalar bu cihazda kalır.', 'cellphone-lock']].map(([value, title, subtitle, icon]) => <Pressable key={value} onPress={() => { setPrivacyModeOpen(false); if (project) { if (project.mode !== value) setPendingPrivacyMode(value as 'devices' | 'deviceOnly'); } else setMode(value as 'devices' | 'deviceOnly'); }} style={[s.modeChoice, { borderColor: (project?.mode ?? mode) === value ? colors.accent : colors.line, backgroundColor: colors.surface }]}><MaterialCommunityIcons name={icon as ComponentProps<typeof MaterialCommunityIcons>['name']} size={20} color={colors.accent} /><View style={s.projectText}><Text style={{ color: colors.ink, fontWeight: '600' }}>{title}</Text><Text style={[s.projectMeta, { color: colors.muted }]}>{subtitle}</Text></View>{(project?.mode ?? mode) === value ? <MaterialCommunityIcons name="check-circle" size={20} color={colors.accent} /> : null}</Pressable>)}
    </View></View>
  </Modal>;

  const deleteSheet = <Modal visible={!!pendingDelete} transparent animationType="fade" onRequestClose={() => setPendingDelete(null)}>
    <View style={s.modalScrim}><Pressable style={StyleSheet.absoluteFill} onPress={() => setPendingDelete(null)} /><View style={[s.privacySheet, { backgroundColor: colors.canvas, borderColor: colors.line }]}>
      <Text style={[s.heading, { color: colors.ink, fontSize: 19 }]}>Proje silinsin mi?</Text><Text style={[s.privacyCopy, { color: colors.muted }]}>“{pendingDelete?.name}”: dosyalar ve geçmiş tüm cihazlardan silinir; geri alınamaz.</Text>
      <View style={s.confirmActions}><Pressable onPress={() => setPendingDelete(null)} style={s.menuCancel}><Text style={{ color: colors.muted, fontWeight: '600' }}>Vazgeç</Text></Pressable><Pressable onPress={() => { const target = pendingDelete; setPendingDelete(null); if (target) void removeProject(target); }} style={[s.menuCancel, { backgroundColor: colors.danger }]}><Text style={{ color: '#fff', fontWeight: '700' }}>Sil</Text></Pressable></View>
    </View></View>
  </Modal>;

  const writerConsentSheet = <Modal visible={!!pendingWriterConsent} transparent animationType="fade" onRequestClose={() => setPendingWriterConsent(null)}>
    <View style={s.modalScrim}><Pressable style={StyleSheet.absoluteFill} onPress={() => setPendingWriterConsent(null)} /><View style={[s.privacySheet, { backgroundColor: colors.canvas, borderColor: colors.line }]}>
      <Text style={[s.heading, { color: colors.ink, fontSize: 19 }]}>Yazara gönderilecek</Text>
      <Text style={[s.privacyCopy, { color: colors.muted }]}>{pendingWriterConsent?.mode === 'deviceOnly'
        ? 'Bu proje yalnız bu cihazda duruyor. İsteği yazmak için dosyalar bu istek boyunca yazar modele gönderilir; sunucuda saklanmaz.'
        : 'İsteği yazmak için projenin dosyaları bu istek boyunca yazara gönderilir ve sunucuda saklanmaz. Proje cihazlar arasında şifreli eşitlenir.'}</Text>
      <View style={s.confirmActions}><Pressable onPress={() => setPendingWriterConsent(null)} style={s.menuCancel}><Text style={{ color: colors.muted, fontWeight: '600' }}>Vazgeç</Text></Pressable><Pressable onPress={() => {
        const consent = pendingWriterConsent;
        setPendingWriterConsent(null);
        if (!consent) return;
        if (consent.mode === 'devices') void SecureStore.setItemAsync(`act-writer-consent-${consent.mode}`, 'yes').catch(() => undefined);
        void runWriter(consent.operation, consent.request, consent.target);
      }} style={[s.menuCancel, { backgroundColor: colors.accent }]}><Text style={{ color: colors.onAccent, fontWeight: '700' }}>Devam et</Text></Pressable></View>
    </View></View>
  </Modal>;

  const privacyConfirmSheet = <Modal visible={!!pendingPrivacyMode} transparent animationType="fade" onRequestClose={() => setPendingPrivacyMode(null)}>
    <View style={s.modalScrim}><Pressable style={StyleSheet.absoluteFill} onPress={() => setPendingPrivacyMode(null)} /><View style={[s.privacySheet, { backgroundColor: colors.canvas, borderColor: colors.line }]}>
      <Text style={[s.heading, { color: colors.ink, fontSize: 19 }]}>{pendingPrivacyMode === 'devices' ? 'Bağlı cihazlarımla eşitle?' : 'Yalnız bu cihazda tut?'}</Text><Text style={[s.privacyCopy, { color: colors.muted }]}>{pendingPrivacyMode === 'devices' ? 'Projenin şifreli bir kopyası bağlı cihazlarınla eşitlenir. Dosya içeriği sunucuda okunamaz.' : 'Şifreli sunucu kopyası silinir. Proje yalnız bu cihazda kalır.'}</Text>
      <View style={s.confirmActions}><Pressable onPress={() => setPendingPrivacyMode(null)} style={s.menuCancel}><Text style={{ color: colors.muted, fontWeight: '600' }}>Vazgeç</Text></Pressable><Pressable onPress={() => { const target = pendingPrivacyMode; setPendingPrivacyMode(null); if (target) applyProjectPrivacy(target === 'devices'); }} style={[s.menuCancel, { backgroundColor: colors.accent }]}><Text style={{ color: colors.onAccent, fontWeight: '700' }}>Devam et</Text></Pressable></View>
    </View></View>
  </Modal>;

  const fullPreview = <Modal visible={fullScreenPreview} animationType="slide" onRequestClose={() => setFullScreenPreview(false)}>
    <View style={[s.fullscreen, { backgroundColor: colors.canvas }]}><View style={[s.fullscreenHeader, { borderBottomColor: colors.line }]}><Text numberOfLines={1} style={[s.workspaceTitle, { color: colors.ink }]}>{project?.name ?? ''}</Text><Pressable accessibilityRole="button" accessibilityLabel="Tam ekrandan çık" onPress={() => setFullScreenPreview(false)} style={s.fullscreenClose}><MaterialCommunityIcons name="close" size={22} color={colors.ink} /></Pressable></View>{project?.kind === 'web' && pageHtml ? <WebView key={`${project.id}-fullscreen-${previewRevision}`} style={s.fullscreenWeb} source={{ html: pageHtml, baseUrl: 'https://localhost/' }} originWhitelist={['*']} javaScriptEnabled domStorageEnabled={false} onShouldStartLoadWithRequest={request => request.url.startsWith('about:blank') || request.url.startsWith('https://localhost') || request.url.startsWith('data:')} /> : <View style={s.emptyPreview}><Text style={{ color: colors.muted }}>Bu proje için tam ekran önizleme yok.</Text></View>}</View>
  </Modal>;

  const button = (icon: ComponentProps<typeof MaterialCommunityIcons>['name'], label: string, action: () => void, disabled = false) => <Pressable key={label} accessibilityRole="button" accessibilityLabel={label} disabled={disabled} onPress={action} style={[s.iconButton, { backgroundColor: colors.surface, borderColor: colors.line }, disabled && { opacity: 0.42 }]}><MaterialCommunityIcons name={icon} size={19} color={colors.ink} /></Pressable>;
  const dockReserve = dockHidden ? 22 : 58;

  if (!loaded) return <View style={[s.root, { backgroundColor: colors.canvas }]}><ActivityIndicator color={colors.accent} /></View>;

  if (!project) return <View style={[s.root, { backgroundColor: colors.canvas }]}>
    <View style={s.listHeader}><Text style={[s.heading, { color: colors.ink }]}>Projeler</Text></View>
    <View style={s.listBody}>
      {searchOpen ? <View style={[s.searchWrap, { backgroundColor: colors.surface }]}><MaterialCommunityIcons name="magnify" size={19} color={colors.muted} /><TextInput value={search} onChangeText={setSearch} autoCapitalize="none" autoCorrect={false} placeholder="Proje ara" placeholderTextColor={colors.muted} style={[s.searchInput, { color: colors.ink }]} />{search ? <Pressable accessibilityLabel="Aramayı temizle" onPress={() => setSearch('')}><MaterialCommunityIcons name="close-circle" size={18} color={colors.muted} /></Pressable> : null}</View> : null}
      {notice ? <Text style={[s.notice, { color: colors.danger }]}>{notice}</Text> : null}
      {projects.length ? <ScrollView keyboardShouldPersistTaps="handled" refreshControl={<RefreshControl refreshing={syncing} onRefresh={() => void syncAll()} tintColor={colors.accent} colors={[colors.accent]} />} contentContainerStyle={[s.projectList, { paddingRight: dockReserve }]}>{visibleProjects.map((item, index) => <Pressable key={item.id} onPress={() => { setProjectId(item.id); setTab('preview'); setSelectedPath(item.kind === 'python' ? Object.keys(item.files)[0] ?? '' : 'index.html'); setNotice(''); }} onLongPress={() => openContext('project', item)} style={s.projectRow}>
        <View style={s.projectRowContent}><View style={[s.projectIcon, { backgroundColor: colors.surface }]}><MaterialCommunityIcons name={item.kind === 'python' ? 'console' : 'compass-outline'} size={20} color={colors.accent} /></View><View style={s.projectText}><Text numberOfLines={1} style={[s.projectName, { color: colors.ink }]}>{item.name}</Text><Text numberOfLines={1} style={[s.projectMeta, { color: colors.muted }]}>{item.kind === 'python' ? 'Python' : 'Web'} · {relativeDate(item.updatedAt)}</Text></View>{pinnedProjectIds.includes(item.id) ? <MaterialCommunityIcons name="pin" size={15} color={colors.muted} /> : null}{item.mode === 'deviceOnly' ? <MaterialCommunityIcons name="cellphone-lock" size={15} color={colors.muted} /> : null}</View>{index < visibleProjects.length - 1 ? <View style={[s.projectSeparator, { backgroundColor: colors.line }]} /> : null}
      </Pressable>)}</ScrollView> : <ScrollView keyboardShouldPersistTaps="handled" contentContainerStyle={[s.empty, { paddingRight: dockReserve }]}><Text style={[s.emptyTitle, { color: colors.ink }]}>Ne yapmak istersin?</Text><Text style={[s.emptyCopy, { color: colors.muted }]}>Aşağıya yaz, konuşarak anlat ya da birini seç.</Text>{templates.map(([title, prompt]) => <Pressable key={title} onPress={() => { setDraft(prompt); composerRef.current?.focus(); }} style={[s.template, { borderBottomColor: colors.line }]}><View style={s.projectText}><Text style={[s.projectName, { color: colors.ink }]}>{title}</Text><Text numberOfLines={1} style={[s.projectMeta, { color: colors.muted }]}>{prompt}</Text></View><MaterialCommunityIcons name="arrow-top-left" size={18} color={colors.muted} /></Pressable>)}</ScrollView>}
      <ActSideDock groups={dockActions} hidden={dockHidden} onHiddenChange={changeDockVisibility} ink={colors.ink} muted={colors.muted} surface={colors.surface} line={colors.line} />
    </View>
    <View style={[s.composerWrap, { borderTopColor: colors.line }]}>
      {voiceSessionActive ? <ActVoiceSession transcript={voiceTranscript} status={pendingVoiceConfirm ? `Onaylıyor musun? “${pendingVoiceConfirm}” · Evet/Hayır de` : notice || (busy ? job?.progress ?? 'Wiqo projeyi düzenliyor…' : '')} listening={voiceListening} working={voiceWorking || busy} speaking={voiceSpeaking} level={voiceLevel} queued={actVoiceQueue} accent={colors.accent} ink={colors.ink} muted={colors.muted} background={colors.canvas} speakReplies={voiceSpeechEnabled} onClose={() => { setActVoiceQueue([]); setPendingVoiceConfirm(null); onCloseVoiceSession(); }} onDeliver={onVoiceDeliver} onToggleSpeaker={onToggleVoiceSpeaker} onRemoveQueued={index => setActVoiceQueue(current => current.filter((_, itemIndex) => itemIndex !== index))} /> : <>
      {busy ? <View style={s.job}><ActivityIndicator size="small" color={colors.accent} /><Text numberOfLines={2} style={[s.jobText, { color: colors.muted }]}>{notice}</Text><Pressable onPress={() => void cancelJob()}><Text style={{ color: colors.accent, fontWeight: '600' }}>Durdur</Text></Pressable></View> : null}
      <View style={s.composerRow}>
        <Pressable accessibilityRole="button" accessibilityLabel="Proje gizliliği" onPress={() => setPrivacyModeOpen(true)} style={[s.composerLeading, { backgroundColor: colors.surface }]}><MaterialCommunityIcons name={mode === 'devices' ? 'cloud-lock-outline' : 'cellphone-lock'} size={21} color={colors.accent} /></Pressable>
        <TextInput ref={composerRef} value={draft} onChangeText={setDraft} editable={!busy} multiline maxLength={12000} placeholder="Ne yapalım?" placeholderTextColor={colors.muted} style={[s.input, { color: colors.ink, backgroundColor: colors.surface }]} />
        {draft.trim().length >= 3 ? (
          <Pressable accessibilityRole="button" accessibilityLabel="Projeyi oluştur" disabled={busy} onPress={submit} style={[s.send, { backgroundColor: colors.accent }]}>
            {busy ? <ActivityIndicator size="small" color={colors.onAccent} /> : <MaterialCommunityIcons name="arrow-up" size={22} color={colors.onAccent} />}
          </Pressable>
        ) : (
          <Pressable accessibilityRole="button" accessibilityLabel="Sesli Act komutu" onPress={startActVoice} onLongPress={() => startDictation?.(text => setDraft(current => current.trim() ? `${current.trim()} ${text}` : text))} style={[s.composerLeading, { backgroundColor: colors.surface }]}>
            <MaterialCommunityIcons name="waveform" size={21} color={colors.ink} />
          </Pressable>
        )}
      </View>
      </>}
    </View>
    {contextSheet}{privacySheet}{privacyModeSheet}{deleteSheet}{privacyConfirmSheet}{writerConsentSheet}
  </View>;

  return <View style={[s.root, { backgroundColor: colors.canvas }]}>
    <View style={s.workspaceHeader}>
      <Pressable onPress={() => { Keyboard.dismiss(); setProjectId(null); setNotice(''); setEditingPath(null); }} style={s.back}><MaterialCommunityIcons name="chevron-left" size={21} color={colors.accent} /><Text style={{ color: colors.accent }}>Projeler</Text></Pressable>
      <View style={s.projectIdentity}><Text numberOfLines={1} style={[s.workspaceTitle, { color: colors.ink }]}>{project.name}</Text><Pressable accessibilityRole="button" accessibilityLabel="Proje gizliliğini değiştir" onPress={() => setPrivacyModeOpen(true)}><MaterialCommunityIcons name={project.mode === 'devices' ? 'lock-sync' : 'cellphone-lock'} size={16} color={colors.muted} /></Pressable></View>
    </View>
    <View style={[s.workspaceBody, { paddingRight: dockReserve }]}>
      {notice ? <Text numberOfLines={3} style={[s.notice, { color: colors.danger }]}>{notice}</Text> : null}
      {tab === 'preview' ? project.kind === 'web' ? pageHtml ? <View style={[s.preview, s.previewFrame, previewDevice === 'phone' && s.previewPhone, previewDevice === 'tablet' && s.previewTablet, { borderColor: colors.line }]}><WebView key={`${project.id}-${previewRevision}`} source={{ html: pageHtml, baseUrl: 'https://localhost/' }} originWhitelist={['*']} javaScriptEnabled domStorageEnabled={false} onShouldStartLoadWithRequest={request => request.url.startsWith('about:blank') || request.url.startsWith('https://localhost') || request.url.startsWith('data:')} /></View> : <View style={s.emptyPreview}><Text style={{ color: colors.muted }}>Projede açılacak bir sayfa (index.html) yok.</Text></View> : <ScrollView style={s.preview} contentContainerStyle={s.output}><Text style={[s.outputHeading, { color: colors.ink }]}>Python çıktısı</Text>{runOutput ? <Text selectable style={[s.outputText, { color: colors.ink }]}>{runOutput.stdout || runOutput.stderr || (runOutput.timedOut ? 'Çalışma süresi doldu.' : `Çıkış kodu: ${runOutput.exitCode}`)}</Text> : <Text style={[s.emptyCopy, { color: colors.muted }]}>Programı çalıştırdığında sonucu burada göreceksin.</Text>}</ScrollView> : tab === 'code' ? <View style={s.codeView}>
        <ScrollView horizontal showsHorizontalScrollIndicator={false} style={s.fileStrip}>{files.map(([path]) => <Pressable key={path} onPress={() => { setSelectedPath(path); setEditingPath(null); }} onLongPress={() => openContext('file', project, path)} style={[s.fileTab, { backgroundColor: selectedPath === path ? colors.ink : colors.surface }]}><Text numberOfLines={1} style={{ color: selectedPath === path ? colors.canvas : colors.ink, fontSize: 12 }}>{path}</Text></Pressable>)}{button('plus', 'Yeni dosya', () => { setRenamingPath(null); setFileName(' '); })}</ScrollView>
        {!!fileName && <View style={[s.composerRow, { paddingHorizontal: 12, paddingBottom: 8 }]}><TextInput autoCapitalize="none" value={fileName} onChangeText={setFileName} placeholder="dosya-adi.html" placeholderTextColor={colors.muted} style={[s.input, { color: colors.ink, backgroundColor: colors.surface }]} /><Pressable onPress={addFile} style={[s.send, { backgroundColor: colors.accent }]}><MaterialCommunityIcons name="check" size={19} color={colors.onAccent} /></Pressable><Pressable onPress={() => { setFileName(''); setRenamingPath(null); }}><MaterialCommunityIcons name="close" size={19} color={colors.muted} /></Pressable></View>}
        {selectedPath && project.files[selectedPath] !== undefined ? editingPath ? <><TextInput multiline value={editingText} onChangeText={setEditingText} autoCapitalize="none" autoCorrect={false} spellCheck={false} textAlignVertical="top" style={[s.codeEditor, { color: colors.ink, backgroundColor: colors.surface }]} /><View style={s.editorButtons}><Pressable onPress={() => setEditingPath(null)}><Text style={{ color: colors.muted }}>Vazgeç</Text></Pressable><Pressable onPress={() => void saveManualFile()}><Text style={{ color: colors.accent, fontWeight: '700' }}>Kaydet</Text></Pressable></View></> : <ScrollView style={s.codeScroll}><Pressable onPress={() => { setEditingPath(selectedPath); setEditingText(project.files[selectedPath]); }}><Text selectable style={[s.codeText, { color: colors.ink }]}>{project.files[selectedPath]}</Text></Pressable><Pressable onPress={() => { setEditingPath(selectedPath); setEditingText(project.files[selectedPath]); }} style={s.editHint}><MaterialCommunityIcons name="pencil-outline" size={17} color={colors.muted} /><Text style={{ color: colors.muted }}>Düzenlemek için dokun</Text></Pressable></ScrollView> : <View style={s.emptyPreview}><Text style={{ color: colors.muted }}>Projede dosya yok.</Text></View>}
      </View> : <ScrollView style={s.historyList} contentContainerStyle={[s.projectList, { paddingRight: 8 }]}>{project.history.map((entry, index) => <View key={entry.id} style={[s.historyRow, { borderBottomColor: colors.line }]}><MaterialCommunityIcons name={entry.verified ? 'check-circle' : 'alert-circle'} size={20} color={entry.verified ? colors.accent : '#AB802E'} /><View style={s.projectText}><Text style={[s.projectName, { color: colors.ink }]}>{entry.summary}</Text><Text style={[s.projectMeta, { color: colors.muted }]}>{entry.source} · {new Date(entry.date).toLocaleString()} · {entry.changes.length} dosya</Text></View>{index > 0 ? <Pressable disabled={busy} onPress={() => { const base = { ...project.files }; project.history.slice(0, index).forEach(changeSet => changeSet.changes.forEach(change => { if (change.before === undefined) delete base[change.path]; else base[change.path] = change.before; })); void saveProject({ ...project, files: base, history: [makeHistory(`Sürüme dönüldü: ${entry.summary}`, 'Geri yükleme', project.files, base), ...project.history], updatedAt: Date.now() }); setTab('preview'); }}><MaterialCommunityIcons name="restore" size={20} color={colors.muted} /></Pressable> : null}</View>)}</ScrollView>}
      <ActSideDock groups={dockActions} hidden={dockHidden} onHiddenChange={changeDockVisibility} extra={{ id: 'more', icon: 'dots-horizontal-circle-outline', label: 'Proje seçenekleri', onPress: () => openContext('workspace') }} ink={colors.ink} muted={colors.muted} surface={colors.surface} line={colors.line} />
    </View>
    {tab !== 'code' || !editingPath ? <View style={[s.composerWrap, { borderTopColor: colors.line }]}>
      {voiceSessionActive ? <ActVoiceSession transcript={voiceTranscript} status={pendingVoiceConfirm ? `Onaylıyor musun? “${pendingVoiceConfirm}” · Evet/Hayır de` : notice || (busy ? job?.progress ?? 'Wiqo projeyi düzenliyor…' : '')} listening={voiceListening} working={voiceWorking || busy} speaking={voiceSpeaking} level={voiceLevel} queued={actVoiceQueue} accent={colors.accent} ink={colors.ink} muted={colors.muted} background={colors.canvas} speakReplies={voiceSpeechEnabled} onClose={() => { setActVoiceQueue([]); setPendingVoiceConfirm(null); onCloseVoiceSession(); }} onDeliver={onVoiceDeliver} onToggleSpeaker={onToggleVoiceSpeaker} onRemoveQueued={index => setActVoiceQueue(current => current.filter((_, itemIndex) => itemIndex !== index))} /> : <>
      {busy ? <View style={s.job}><ActivityIndicator size="small" color={colors.accent} /><Text numberOfLines={2} style={[s.jobText, { color: colors.muted }]}>{notice}</Text><Pressable onPress={() => void cancelJob()}><Text style={{ color: colors.accent, fontWeight: '600' }}>Durdur</Text></Pressable></View> : null}
      <View style={s.composerRow}>
        <Pressable accessibilityRole="button" accessibilityLabel="Proje seçenekleri" onPress={() => openContext('workspace')} style={[s.composerLeading, { backgroundColor: colors.surface }]}><MaterialCommunityIcons name="plus" size={22} color={colors.ink} /></Pressable>
        <TextInput value={draft} onChangeText={setDraft} editable={!busy} multiline maxLength={12000} placeholder="Bu projede neyi değiştirelim?" placeholderTextColor={colors.muted} style={[s.input, { color: colors.ink, backgroundColor: colors.surface }]} />
        {draft.trim().length >= 2 ? (
          <Pressable accessibilityRole="button" accessibilityLabel="Değişikliği gönder" disabled={busy} onPress={submit} style={[s.send, { backgroundColor: draft.trim().length >= 2 ? colors.accent : colors.muted }]}>
            {busy ? <ActivityIndicator size="small" color={colors.onAccent} /> : <MaterialCommunityIcons name="arrow-up" size={22} color={colors.onAccent} />}
          </Pressable>
        ) : (
          <Pressable accessibilityRole="button" accessibilityLabel="Sesli Act komutu" onPress={startActVoice} onLongPress={() => startDictation?.(text => setDraft(current => current.trim() ? `${current.trim()} ${text}` : text))} style={[s.composerLeading, { backgroundColor: colors.surface }]}>
            <MaterialCommunityIcons name="waveform" size={21} color={colors.ink} />
          </Pressable>
        )}
      </View>
      </>}
    </View> : null}
    {contextSheet}{privacySheet}{privacyModeSheet}{deleteSheet}{privacyConfirmSheet}{writerConsentSheet}{fullPreview}
  </View>;
}

const s = StyleSheet.create({
  root: { flex: 1, minHeight: 0 },
  listHeader: { paddingHorizontal: 20, paddingVertical: 15 },
  listBody: { flex: 1, minHeight: 0 },
  heading: { fontSize: 22, fontWeight: '700' },
  projectList: { paddingHorizontal: 18, paddingBottom: 16 },
  projectRow: { paddingTop: 10 },
  projectRowContent: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingBottom: 10 },
  projectSeparator: { height: StyleSheet.hairlineWidth, marginLeft: 56 },
  projectIcon: { width: 42, height: 42, borderRadius: 12, alignItems: 'center', justifyContent: 'center' },
  projectText: { flex: 1, minWidth: 0 },
  projectName: { fontSize: 16, fontWeight: '500' },
  projectMeta: { fontSize: 13, marginTop: 3 },
  searchWrap: { height: 40, marginHorizontal: 16, marginBottom: 6, borderRadius: 11, paddingHorizontal: 11, flexDirection: 'row', alignItems: 'center', gap: 8 },
  searchInput: { flex: 1, minWidth: 0, height: 40, fontSize: 15 },
  empty: { flexGrow: 1, justifyContent: 'flex-start', paddingHorizontal: 22, paddingTop: 18, paddingBottom: 24 },
  emptyTitle: { fontWeight: '600', fontSize: 21 },
  emptyCopy: { fontSize: 14, lineHeight: 20, marginTop: 4, marginBottom: 10 },
  template: { minHeight: 58, flexDirection: 'row', alignItems: 'center', borderBottomWidth: StyleSheet.hairlineWidth, gap: 8 },
  composerWrap: { paddingHorizontal: 13, paddingVertical: 8, borderTopWidth: 0, gap: 7 },
  composerRow: { flexDirection: 'row', alignItems: 'flex-end', justifyContent: 'center', gap: 9 },
  composerLeading: { width: 44, height: 44, borderRadius: 22, alignItems: 'center', justifyContent: 'center' },
  input: { flex: 1, maxWidth: 220, minHeight: 44, maxHeight: 132, borderRadius: 24, paddingHorizontal: 16, paddingTop: 11, paddingBottom: 9, fontSize: 16 },
  send: { width: 42, height: 42, borderRadius: 24, alignItems: 'center', justifyContent: 'center', marginBottom: 3 },
  job: { flexDirection: 'row', alignItems: 'center', gap: 9, paddingHorizontal: 5, minHeight: 28 },
  jobText: { flex: 1, fontSize: 12 },
  notice: { paddingHorizontal: 18, paddingVertical: 6, fontSize: 12 },
  workspaceHeader: { minHeight: 44, flexDirection: 'row', alignItems: 'center', gap: 9, paddingHorizontal: 16 },
  back: { flexDirection: 'row', alignItems: 'center', minWidth: 92 },
  projectIdentity: { flex: 1, flexDirection: 'row', alignItems: 'center', gap: 8, minWidth: 0 },
  workspaceTitle: { flexShrink: 1, fontSize: 15, fontWeight: '600' },
  workspaceBody: { flex: 1, minHeight: 0 },
  preview: { flex: 1, marginHorizontal: 10, marginBottom: 4, borderRadius: 12, overflow: 'hidden', borderWidth: StyleSheet.hairlineWidth },
  previewFrame: { alignSelf: 'center', width: '100%' },
  previewPhone: { maxWidth: 420, borderRadius: 24 },
  previewTablet: { maxWidth: 760, borderRadius: 16 },
  emptyPreview: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  output: { padding: 18 },
  outputHeading: { fontSize: 18, fontWeight: '600' },
  outputText: { fontFamily: 'monospace', marginTop: 12, fontSize: 13, lineHeight: 19 },
  codeView: { flex: 1, minHeight: 0 },
  fileStrip: { flexGrow: 0, maxHeight: 48, paddingHorizontal: 10 },
  fileTab: { height: 32, borderRadius: 8, paddingHorizontal: 10, justifyContent: 'center', marginRight: 6 },
  codeScroll: { flex: 1, paddingHorizontal: 15, paddingVertical: 12 },
  codeText: { fontFamily: 'monospace', fontSize: 12, lineHeight: 18 },
  editHint: { alignSelf: 'flex-end', flexDirection: 'row', alignItems: 'center', gap: 5, paddingTop: 14 },
  codeEditor: { flex: 1, margin: 10, padding: 12, borderRadius: 10, fontFamily: 'monospace', fontSize: 13, lineHeight: 19 },
  editorButtons: { flexDirection: 'row', justifyContent: 'flex-end', gap: 24, padding: 14 },
  historyList: { flex: 1 },
  historyRow: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 13, borderBottomWidth: StyleSheet.hairlineWidth },
  iconButton: { width: 38, height: 38, alignItems: 'center', justifyContent: 'center', borderRadius: 20, borderWidth: StyleSheet.hairlineWidth },
  modalScrim: { flex: 1, backgroundColor: 'rgba(0,0,0,0.34)', justifyContent: 'center', padding: 22 },
  privacySheet: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 24, padding: 19, gap: 12 },
  privacyHeading: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  privacyCopy: { fontSize: 13, lineHeight: 19 },
  recoveryBox: { borderRadius: 14, padding: 12, gap: 10 },
  recoveryCode: { fontSize: 13, lineHeight: 20, fontFamily: 'monospace' },
  copyKey: { flexDirection: 'row', alignItems: 'center', gap: 7, alignSelf: 'flex-end', padding: 5 },
  recoveryInput: { borderRadius: 12, paddingHorizontal: 12, minHeight: 44, fontSize: 14 },
  importKey: { alignItems: 'center', justifyContent: 'center', height: 44, borderRadius: 22 },
  modeChoice: { minHeight: 68, borderRadius: 16, borderWidth: StyleSheet.hairlineWidth, padding: 12, flexDirection: 'row', alignItems: 'center', gap: 11 },
  confirmActions: { flexDirection: 'row', justifyContent: 'flex-end', gap: 9 },
  menuScrim: { flex: 1, backgroundColor: 'rgba(0,0,0,0.28)', justifyContent: 'flex-end', padding: 12, paddingBottom: 24 },
  menuSheet: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 24, paddingHorizontal: 16, paddingTop: 7, paddingBottom: 10, maxHeight: '82%', shadowColor: '#000', shadowOffset: { width: 0, height: 8 }, shadowOpacity: 0.12, shadowRadius: 18, elevation: 8 },
  menuHeading: { alignItems: 'center', paddingBottom: 5 },
  menuGrip: { width: 34, height: 4, borderRadius: 2, backgroundColor: 'rgba(120,120,128,0.35)', marginBottom: 12 },
  menuTitle: { fontSize: 15, fontWeight: '600', maxWidth: '95%', paddingBottom: 5 },
  menuRow: { minHeight: 49, flexDirection: 'row', alignItems: 'center', gap: 12, borderTopWidth: StyleSheet.hairlineWidth, paddingHorizontal: 5 },
  menuRowText: { fontSize: 15, fontWeight: '500' },
  menuCancel: { minHeight: 44, borderRadius: 22, paddingHorizontal: 18, alignItems: 'center', justifyContent: 'center', marginTop: 8 },
  fullscreen: { flex: 1 },
  fullscreenHeader: { minHeight: 56, borderBottomWidth: StyleSheet.hairlineWidth, flexDirection: 'row', alignItems: 'center', paddingHorizontal: 16 },
  fullscreenClose: { width: 40, height: 40, alignItems: 'center', justifyContent: 'center' },
  fullscreenWeb: { flex: 1 },
});
