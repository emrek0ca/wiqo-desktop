import { API_BASE_URL } from '@/data/auth-api';
import { fetch as expoFetch } from 'expo/fetch';
import { AppState } from 'react-native';
import { cacheScopeForToken, readCache, removeCachePrefix, singleFlight, writeCache } from '@/data/local-cache';

export type ChatRole = 'user' | 'assistant' | 'system';
export type ChatWidget = Record<string, unknown> & { type?: string; title?: string; detail?: string; summary?: string; question?: string; taskId?: string; questionId?: string; options?: string[]; confirmationId?: string };
export type ChatArtifact = { id: string; kind?: string; filename: string; mimeType?: string; byteCount?: number; downloadURL: string; expiresAt?: string };
export type ChatConfirmation = { id: string; kind: string; title: string; summary: string; details?: Record<string, string>; isDestructive?: boolean; requiresUserPresence?: boolean; expiresAt?: string };
export type ChatTurnResult = { reply: string; steps: Record<string, unknown>[]; executionState?: string; artifacts: ChatArtifact[]; widgets: ChatWidget[]; backendConfirmations: ChatConfirmation[]; replyIsProgress: boolean; deferredTask?: Record<string, unknown>; projectTask?: Record<string, unknown>; agentTask?: Record<string, unknown> };
export type ChatLiveEvent = { type: string; [key: string]: unknown };
export type ChatMessage = {
  id: string;
  role: ChatRole;
  content: string;
  createdAt: number;
  widgets?: ChatWidget[];
  artifacts?: ChatArtifact[];
  confirmations?: ChatConfirmation[];
  liveEvents?: ChatLiveEvent[];
  locationRequestId?: string;
  steps?: Record<string, unknown>[];
};
export type ConversationSummary = { id: string; title: string; preview: string; updatedAt?: string };
export type ChatProfile = { email: string; displayName?: string; avatarKind?: string; avatarEmoji?: string; avatarColor?: string; avatarImage?: string };
export type ChatDevice = { id: string; displayName: string; platform: string; online: boolean; lastSeenAt?: string };
export type ChatImageAttachment = { name: string; mimeType: string; dataBase64: string };
export type ChatFileContent = { name: string; type: string; byteCount: number; source: string; text: string; truncated: boolean; tables: unknown[] };
export type ActivityItem = { id: string; state: string; source: string; title: string; detail?: string; at: string; ref?: { type: string; id: string }; persona?: string };
export type SettingsProfile = ChatProfile & { createdAt?: string; preferredAddress?: string; tone?: string | null; language?: string | null; location?: string | null; proactiveEnabled: boolean };
export type SubscriptionInfo = { tier: string; label: string; source: string; expiresAt?: string | null; pcAllowed: boolean; usage: { messages: { used: number; limit: number }; images: { used: number; limit: number }; act?: { used: number; limit: number } }; resetsAt?: string | null };
export type PlanInfo = { id: string; label: string; messagesPerDay: number; imagesPerDay: number; pcAllowed: boolean; purchasableInApp?: boolean; actJobsPerDay?: number };
export type OAuthProvider = { id: string; name: string; symbol: string; summary?: string; available?: boolean };
export type OAuthConnection = { provider: string; accountLabel?: string; connectedAt: string; accessLevel?: string; status?: string };
export type ConnectionCapability = { source: string; owner: string; name: string; description: string; effect: string; status: string };
export type GoalInfo = { id: number; title: string; createdAt: string; total: number; done: number };
export type ProactiveSuggestion = { id: number; kind: string; title: string; body: string; prompt: string; createdAt: string; expiresAt?: string | null };
export type MemoryCandidate = { id: number; kind: string; content: string; sourceText: string; status: string; similarity?: number; createdAt: string };
export type OpenWork = { goal: string; detail: string; taskId?: string };

export class ChatApiError extends Error {
  constructor(message: string, readonly status?: number, readonly retryAfterMs?: number) {
    super(message);
    this.name = 'ChatApiError';
  }
}

function messageFromPayload(payload: unknown, fallback: string) {
  if (payload && typeof payload === 'object') {
    const record = payload as { error?: { message?: unknown }; message?: unknown };
    if (typeof record.error?.message === 'string' && record.error.message.trim()) return record.error.message;
    if (typeof record.message === 'string' && record.message.trim()) return record.message;
  }
  return fallback;
}

type CacheRule = { ttlMs: number; staleMs: number };

function cacheRuleForPath(path: string): CacheRule | null {
  if (path === 'profile') return { ttlMs: 60_000, staleMs: 86_400_000 };
  if (path === 'billing/subscription') return { ttlMs: 30_000, staleMs: 120_000 };
  if (path === 'billing/plans' || path === 'oauth/providers') return { ttlMs: 86_400_000, staleMs: 7 * 86_400_000 };
  if (path === 'oauth') return { ttlMs: 30_000, staleMs: 300_000 };
  if (path === 'oauth/capabilities') return { ttlMs: 300_000, staleMs: 86_400_000 };
  if (path === 'devices') return { ttlMs: 15_000, staleMs: 300_000 };
  if (path === 'activity') return { ttlMs: 15_000, staleMs: 120_000 };
  if (path === 'tasks/goals' || path === 'auth/invite-codes' || path === 'auth/me') return { ttlMs: 60_000, staleMs: 300_000 };
  if (path === 'memory/candidates') return { ttlMs: 30_000, staleMs: 300_000 };
  if (path === 'conversations') return { ttlMs: 30_000, staleMs: 86_400_000 };
  if (/^conversations\/[^/]+\/messages$/.test(path)) return { ttlMs: 60_000, staleMs: 7 * 86_400_000 };
  if (/^conversations\/[^/]+\/open-work$/.test(path)) return { ttlMs: 1_500, staleMs: 0 };
  return null;
}

async function authorizedRequest(path: string, token: string, init: RequestInit = {}) {
  const method = (init.method ?? 'GET').toUpperCase();
  const cacheRule = method === 'GET' ? cacheRuleForPath(path) : null;
  const cacheScope = cacheRule ? await cacheScopeForToken(token) : null;
  const cacheKey = `api:${path}`;
  const cached = cacheScope && cacheRule ? await readCache<unknown>(cacheScope, cacheKey, cacheRule.ttlMs + cacheRule.staleMs) : null;
  if (cached?.fresh) return cached.value;

  const load = async () => {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 90_000);
  try {
    const response = await fetch(`${API_BASE_URL}/${path}`, {
      ...init,
      signal: controller.signal,
      headers: {
        Accept: 'application/json',
        Authorization: `Bearer ${token}`,
        ...(init.headers ?? {}),
      },
    });
    const text = await response.text();
    let payload: unknown;
    try { payload = text ? JSON.parse(text) as unknown : {}; }
    catch {
      if (response.ok && response.headers.get('content-type')?.includes('text/event-stream')) return text;
      throw new ChatApiError('Sunucudan geçersiz bir yanıt alındı.');
    }
    if (!response.ok) {
      const retryAfter = response.headers.get('retry-after');
      const retrySeconds = retryAfter && /^\d+(?:\.\d+)?$/.test(retryAfter) ? Number(retryAfter) * 1_000 : undefined;
      const retryDate = retryAfter ? Date.parse(retryAfter) - Date.now() : NaN;
      const retryAfterMs = retrySeconds !== undefined ? Math.min(60_000, retrySeconds) : Number.isFinite(retryDate) ? Math.max(0, Math.min(60_000, retryDate)) : undefined;
      throw new ChatApiError(messageFromPayload(payload, 'Mesaj gönderilemedi. Tekrar deneyebilirsin.'), response.status, retryAfterMs);
    }
    return payload;
  } catch (cause) {
    if (cause instanceof ChatApiError) throw cause;
    if (controller.signal.aborted) throw new ChatApiError('Yanıt zaman aşımına uğradı. Tekrar deneyebilirsin.');
    throw new ChatApiError('Bağlantı kurulamadı. İnternetini kontrol edip tekrar dene.');
  } finally {
    clearTimeout(timeout);
  }
  };

  if (cacheScope && cacheRule) {
    try {
      return await singleFlight(`${cacheScope}:${cacheKey}`, async () => {
        const payload = await load();
        await writeCache(cacheScope, cacheKey, payload, cacheRule.ttlMs, cacheRule.staleMs);
        return payload;
      });
    } catch (cause) {
      if (cause instanceof ChatApiError && [401, 403, 404].includes(cause.status ?? 0)) throw cause;
      if (cached) return cached.value;
      throw cause;
    }
  }

  const payload = await load();
  if (method !== 'GET') {
    const scope = await cacheScopeForToken(token);
    const affectedPrefixes = path === 'profile' ? ['api:profile']
      : path.startsWith('oauth/') || path === 'oauth' ? ['api:oauth']
      : path.startsWith('devices') ? ['api:devices']
      : path.startsWith('memory/candidates') ? ['api:memory/candidates']
      : path.startsWith('proactive/suggestions') ? ['derived:proactive']
      : path.startsWith('conversations/') ? ['api:conversations']
      : [];
    await Promise.all(affectedPrefixes.map(prefix => removeCachePrefix(scope, prefix)));
  }
  return payload;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function parseSseFrame(frame: string): ChatLiveEvent | null {
  const data = frame.split(/\r?\n/).filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
  if (!data) return null;
  try { return asRecord(JSON.parse(data) as unknown) as ChatLiveEvent | null; } catch { return null; }
}

function normalizeTurn(value: Record<string, unknown>): ChatTurnResult {
  return {
    reply: typeof value.reply === 'string' ? value.reply : '',
    steps: Array.isArray(value.steps) ? value.steps as Record<string, unknown>[] : [],
    executionState: typeof value.executionState === 'string' ? value.executionState : undefined,
    artifacts: Array.isArray(value.artifacts) ? value.artifacts as ChatArtifact[] : [],
    widgets: Array.isArray(value.widgets) ? value.widgets as ChatWidget[] : [],
    backendConfirmations: Array.isArray(value.backendConfirmations) ? value.backendConfirmations as ChatConfirmation[] : [],
    replyIsProgress: value.replyIsProgress === true,
    deferredTask: asRecord(value.deferredTask) ?? undefined,
    projectTask: asRecord(value.projectTask) ?? undefined,
    agentTask: asRecord(value.agentTask) ?? undefined,
  };
}

function dispatchEvent(event: ChatLiveEvent, onStatus: (status: string) => void, onEvent: (event: ChatLiveEvent) => void): ChatTurnResult | null {
  if (event.type === 'status' && typeof event.text === 'string') onStatus(event.text);
  if (event.type === 'error') throw new ChatApiError(typeof event.message === 'string' ? event.message : 'Yanıt alınamadı. Tekrar deneyebilirsin.');
  onEvent(event);
  return event.type === 'done' ? normalizeTurn(event) : null;
}

async function resumeCopilotRequest(token: string, requestId: string, onStatus: (status: string) => void): Promise<ChatTurnResult> {
  onStatus('Bağlantı koptu; Wiqo işlemin sonucunu koruyor…');
  const deadline = Date.now() + 150_000;
  let missingCount = 0;
  let malformedCount = 0;
  let backoffMs = 750;
  while (Date.now() < deadline) {
    let retryAfterMs: number | undefined;
    try {
      const state = asRecord(await authorizedRequest(`copilot/requests/${encodeURIComponent(requestId)}`, token));
      if (!state || typeof state.status !== 'string') {
        malformedCount += 1;
        if (malformedCount >= 3) throw new ChatApiError('Sunucudan geçersiz bir yanıt alındı.');
      } else {
        malformedCount = 0;
        if (state.status === 'done') {
          const final = asRecord(state.response);
          if (final) return normalizeTurn(final);
          malformedCount += 1;
          if (malformedCount >= 3) throw new ChatApiError('İşlem sonucu sunucudan alınamadı.', 400);
        }
        if (state.status === 'failed') throw new ChatApiError(messageFromPayload(state.error, 'İşlem tamamlanamadı.'), 400);
        missingCount = 0;
      }
    } catch (cause) {
      if (cause instanceof ChatApiError) retryAfterMs = cause.retryAfterMs;
      if (cause instanceof ChatApiError && cause.status === 404) {
        missingCount += 1;
        if (missingCount >= 3) throw cause;
      } else if (cause instanceof ChatApiError && (cause.status === 401 || cause.status === 403 || (cause.status !== undefined && cause.status < 500))) {
        throw cause;
      } else if (cause instanceof ChatApiError && cause.message.includes('geçersiz')) {
        throw cause;
      } else if (cause instanceof ChatApiError && cause.status === 400) {
        throw cause;
      }
    }
    onStatus('İşlem sunucuda devam ediyor…');
    const jitteredDelay = Math.round(backoffMs * (0.85 + Math.random() * 0.3));
    await waitUntilForeground(retryAfterMs ? Math.max(jitteredDelay, retryAfterMs) : jitteredDelay, deadline);
    backoffMs = Math.min(8_000, Math.round(backoffMs * 1.7));
  }
  throw new ChatApiError('İşlem sunucuda devam ediyor olabilir. Sohbete dönüp tekrar kontrol edebilirsin.');
}

async function waitUntilForeground(delayMs: number, deadline: number) {
  while (AppState.currentState !== 'active') {
    if (Date.now() >= deadline) return;
    await new Promise<void>(resolve => {
      const subscription = AppState.addEventListener('change', state => {
        if (state === 'active') {
          subscription.remove();
          resolve();
        }
      });
    });
  }
  const remaining = deadline - Date.now();
  if (remaining > 0) await new Promise(resolve => setTimeout(resolve, Math.min(delayMs, remaining)));
}

function makeRequestId() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, character => {
    const value = Math.floor(Math.random() * 16);
    return (character === 'x' ? value : (value & 0x3) | 0x8).toString(16);
  });
}

export const chatApi = {
  async updateProfile(token: string, changes: Record<string, unknown>): Promise<SettingsProfile> {
    const payload = asRecord(await authorizedRequest('profile', token, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(changes) }));
    if (typeof payload?.email !== 'string') throw new ChatApiError('Profil güncellenemedi.');
    return payload as unknown as SettingsProfile;
  },

  async getSubscription(token: string, forceRefresh = false): Promise<SubscriptionInfo> {
    if (forceRefresh) await removeCachePrefix(await cacheScopeForToken(token), 'api:billing/subscription');
    return await authorizedRequest('billing/subscription', token) as SubscriptionInfo;
  },

  async verifyGooglePlayPurchase(token: string, purchaseToken: string): Promise<SubscriptionInfo> {
    const payload = asRecord(await authorizedRequest('billing/google-play/verify', token, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ purchaseToken }),
    }));
    const snapshot = asRecord(payload?.subscription);
    if (payload?.ok !== true || !snapshot || snapshot.tier !== 'pro') {
      throw new ChatApiError('Google Play satın alımı Wiqo hesabında doğrulanamadı.');
    }
    await removeCachePrefix(await cacheScopeForToken(token), 'api:billing/subscription');
    return snapshot as unknown as SubscriptionInfo;
  },

  async registerAndroidPushToken(token: string, deviceToken: string): Promise<void> {
    await authorizedRequest('notifications/fcm-token', token, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: deviceToken, applicationId: 'wiqo.android.com' }),
    });
  },

  async revokeAndroidPushToken(token: string, deviceToken?: string): Promise<void> {
    await authorizedRequest('notifications/fcm-token/revoke', token, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(deviceToken ? { token: deviceToken } : {}),
    });
  },

  async applyMessageUsage(token: string, used: number, limit: number): Promise<void> {
    if (!Number.isFinite(used) || !Number.isFinite(limit) || used < 0 || limit < 0) return;
    const scope = await cacheScopeForToken(token);
    const key = 'api:billing/subscription';
    const cached = await readCache<SubscriptionInfo>(scope, key, 150_000);
    if (!cached?.value?.usage?.messages) return;
    const updated = { ...cached.value, usage: { ...cached.value.usage, messages: { used, limit } } };
    await writeCache(scope, key, updated, 30_000, 120_000);
  },

  async getPlans(token: string): Promise<PlanInfo[]> {
    const payload = asRecord(await authorizedRequest('billing/plans', token));
    return Array.isArray(payload?.plans) ? payload.plans as PlanInfo[] : [];
  },

  async getOAuthProviders(token: string): Promise<OAuthProvider[]> {
    const payload = asRecord(await authorizedRequest('oauth/providers', token));
    return Array.isArray(payload?.providers) ? payload.providers as OAuthProvider[] : [];
  },

  async getOAuthConnections(token: string): Promise<OAuthConnection[]> {
    const payload = asRecord(await authorizedRequest('oauth', token));
    return Array.isArray(payload?.connections) ? payload.connections as OAuthConnection[] : [];
  },

  async startOAuth(token: string, provider: string): Promise<string> {
    const payload = asRecord(await authorizedRequest(`oauth/${encodeURIComponent(provider)}/start`, token));
    if (typeof payload?.url !== 'string') throw new ChatApiError('Bağlantı başlatılamadı.');
    return payload.url;
  },

  async disconnectOAuth(token: string, provider: string): Promise<void> {
    await authorizedRequest(`oauth/${encodeURIComponent(provider)}`, token, { method: 'DELETE' });
  },

  async getConnectionCapabilities(token: string): Promise<ConnectionCapability[]> {
    const payload = asRecord(await authorizedRequest('oauth/capabilities', token));
    return Array.isArray(payload?.capabilities) ? payload.capabilities as ConnectionCapability[] : [];
  },

  async setOAuthAccessLevel(token: string, provider: string, level: 'read' | 'write'): Promise<void> {
    await authorizedRequest(`oauth/${encodeURIComponent(provider)}/access`, token, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ accessLevel: level }) });
  },

  async deleteAccount(token: string, password: string): Promise<void> {
    await authorizedRequest('profile', token, { method: 'DELETE', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password }) });
  },

  async getAccountInfo(token: string): Promise<{ email: string; isFoundingMember: boolean }> {
    return await authorizedRequest('auth/me', token) as { email: string; isFoundingMember: boolean };
  },

  async getInviteCodes(token: string): Promise<{ code: string; used: boolean; createdAt: string }[]> {
    const payload = asRecord(await authorizedRequest('auth/invite-codes', token));
    return Array.isArray(payload?.codes) ? payload.codes as { code: string; used: boolean; createdAt: string }[] : [];
  },

  async getGoals(token: string): Promise<GoalInfo[]> {
    const payload = asRecord(await authorizedRequest('tasks/goals', token));
    return Array.isArray(payload?.goals) ? payload.goals as GoalInfo[] : [];
  },

  async getProfile(token: string): Promise<SettingsProfile> {
    const payload = asRecord(await authorizedRequest('profile', token));
    if (typeof payload?.email !== 'string') throw new ChatApiError('Profil bilgisi alınamadı.');
    return {
      email: payload.email,
      displayName: typeof payload.displayName === 'string' ? payload.displayName : undefined,
      avatarKind: typeof payload.avatarKind === 'string' ? payload.avatarKind : undefined,
      avatarEmoji: typeof payload.avatarEmoji === 'string' ? payload.avatarEmoji : undefined,
      avatarColor: typeof payload.avatarColor === 'string' ? payload.avatarColor : undefined,
      avatarImage: typeof payload.avatarImage === 'string' ? payload.avatarImage : undefined,
      createdAt: typeof payload.createdAt === 'string' ? payload.createdAt : undefined,
      preferredAddress: typeof payload.preferredAddress === 'string' ? payload.preferredAddress : undefined,
      tone: typeof payload.tone === 'string' ? payload.tone : null,
      language: typeof payload.language === 'string' ? payload.language : null,
      location: typeof payload.location === 'string' ? payload.location : undefined,
      proactiveEnabled: payload.proactiveEnabled === true,
    };
  },

  async listDevices(token: string): Promise<ChatDevice[]> {
    const payload = asRecord(await authorizedRequest('devices', token));
    const rows = Array.isArray(payload?.devices) ? payload.devices : [];
    return rows.flatMap(row => {
      const item = asRecord(row);
      if (typeof item?.id !== 'string') return [];
      return [{ id: item.id, displayName: typeof item.displayName === 'string' ? item.displayName : 'PC', platform: typeof item.platform === 'string' ? item.platform : '', online: item.online === true, lastSeenAt: typeof item.lastSeenAt === 'string' ? item.lastSeenAt : undefined }];
    });
  },

  async getActivity(token: string): Promise<{ needsAttention: ActivityItem[]; upcoming: ActivityItem[]; recent: ActivityItem[] }> {
    const payload = asRecord(await authorizedRequest('activity', token));
    const parse = (key: string): ActivityItem[] => (Array.isArray(payload?.[key]) ? payload[key] as unknown[] : []).flatMap(row => {
      const item = asRecord(row);
      if (typeof item?.id !== 'string' || typeof item.title !== 'string') return [];
      const ref = asRecord(item.ref);
      return [{ id: item.id, state: typeof item.state === 'string' ? item.state : '', source: typeof item.source === 'string' ? item.source : '', title: item.title, detail: typeof item.detail === 'string' ? item.detail : undefined, at: typeof item.at === 'string' ? item.at : '', ref: typeof ref?.type === 'string' && typeof ref.id === 'string' ? { type: ref.type, id: ref.id } : undefined, persona: typeof item.persona === 'string' ? item.persona : undefined }];
    });
    return { needsAttention: parse('needsAttention'), upcoming: parse('upcoming'), recent: parse('recent') };
  },

  async refreshProactiveSuggestions(token: string): Promise<ProactiveSuggestion[]> {
    const scope = await cacheScopeForToken(token);
    const cacheKey = 'derived:proactive-suggestions';
    const cached = await readCache<ProactiveSuggestion[]>(scope, cacheKey, 12 * 60 * 60_000);
    if (cached?.fresh) return cached.value;
    try {
      return await singleFlight(`${scope}:${cacheKey}`, async () => {
        const payload = asRecord(await authorizedRequest('proactive/refresh', token, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' }));
        const suggestions = Array.isArray(payload?.suggestions) ? payload.suggestions as ProactiveSuggestion[] : [];
        await writeCache(scope, cacheKey, suggestions, 15 * 60_000, 12 * 60 * 60_000);
        return suggestions;
      });
    } catch (cause) {
      if (cached) return cached.value;
      throw cause;
    }
  },

  async updateProactiveSuggestion(token: string, id: number, action: 'accept' | 'dismiss'): Promise<void> {
    await authorizedRequest(`proactive/suggestions/${id}/${action}`, token, { method: 'POST' });
  },

  async getOpenWork(token: string, conversationId: string): Promise<OpenWork | null> {
    const payload = asRecord(await authorizedRequest(`conversations/${encodeURIComponent(conversationId)}/open-work`, token));
    const work = asRecord(payload?.openWork);
    return typeof work?.goal === 'string' && typeof work.detail === 'string' ? { goal: work.goal, detail: work.detail, taskId: typeof work.taskId === 'string' ? work.taskId : undefined } : null;
  },

  async getMemoryCandidates(token: string): Promise<MemoryCandidate[]> {
    const payload = asRecord(await authorizedRequest('memory/candidates', token));
    return Array.isArray(payload?.candidates) ? payload.candidates as MemoryCandidate[] : [];
  },

  async updateMemoryCandidate(token: string, id: number, action: 'accept' | 'dismiss'): Promise<void> {
    await authorizedRequest(`memory/candidates/${id}/${action}`, token, { method: 'POST' });
  },

  async deleteConversation(token: string, id: string) {
    await authorizedRequest(`conversations/${encodeURIComponent(id)}`, token, { method: 'DELETE' });
    const scope = await cacheScopeForToken(token);
    await removeCachePrefix(scope, `chat:messages:${id}`);
  },

  async listConversations(token: string): Promise<ConversationSummary[]> {
    const payload = asRecord(await authorizedRequest('conversations', token));
    const rows = Array.isArray(payload?.conversations) ? payload.conversations : [];
    return rows.flatMap(row => {
      const item = asRecord(row);
      if (typeof item?.id !== 'string') return [];
      return [{
        id: item.id,
        title: typeof item.title === 'string' && item.title.trim() ? item.title : 'Sohbet',
        preview: typeof item.preview === 'string' ? item.preview : '',
        updatedAt: typeof item.updatedAt === 'string' ? item.updatedAt : undefined,
      }];
    });
  },

  async loadMessages(token: string, conversationId: string): Promise<ChatMessage[]> {
    const payload = asRecord(await authorizedRequest(`conversations/${encodeURIComponent(conversationId)}/messages`, token));
    const rows = Array.isArray(payload?.messages) ? payload.messages : [];
    return rows.flatMap((row, index) => {
      const item = asRecord(row);
      if ((item?.role !== 'user' && item?.role !== 'assistant' && item?.role !== 'system') || typeof item.content !== 'string') return [];
      return [{
        id: typeof item.id === 'string' ? item.id : `${conversationId}-${index}`,
        role: item.role,
        content: item.content,
        createdAt: typeof item.createdAt === 'number' ? item.createdAt : typeof item.createdAt === 'string' ? Date.parse(item.createdAt) || Date.now() + index : Date.now() + index,
        widgets: Array.isArray(item.widgets) ? item.widgets as ChatWidget[] : undefined,
        artifacts: Array.isArray(item.artifacts) ? item.artifacts as ChatArtifact[] : undefined,
        confirmations: Array.isArray(item.backendConfirmations) ? item.backendConfirmations as ChatConfirmation[] : undefined,
      }];
    });
  },

  async sendMessage(token: string, conversationId: string, history: ChatMessage[], onStatus: (status: string) => void, attachments: ChatImageAttachment[] = [], files: ChatFileContent[] = [], createAgent = false, onEvent: (event: ChatLiveEvent) => void = () => undefined, clarification?: { taskId: string; questionId: string }): Promise<ChatTurnResult> {
    const requestId = makeRequestId();
    const body = {
        conversationId,
        requestId,
        messages: history.filter(item => item.content.trim()).slice(-16).map(({ role, content }) => ({ role, content })),
        availableApps: [],
        applicationTargets: [],
        availableCapabilities: [],
        authorities: [],
        attachments,
        files,
        deviceResults: [],
        clientFeatures: ['artifact-directory-v1'],
        locale: 'tr-TR',
        ...(clarification ? { taskId: clarification.taskId, questionId: clarification.questionId } : {}),
        ...(createAgent ? { composerIntent: 'create_agent' } : {}),
    };
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 90_000);
    const finish = async (result: ChatTurnResult) => {
      const scope = await cacheScopeForToken(token);
      await Promise.all([
        removeCachePrefix(scope, 'api:conversations'),
        removeCachePrefix(scope, `chat:messages:${conversationId}`),
      ]);
      return result;
    };
    try {
      const response = await expoFetch(`${API_BASE_URL}/copilot/chat`, {
        method: 'POST', signal: controller.signal,
        headers: { 'Content-Type': 'application/json', Accept: 'text/event-stream', Authorization: `Bearer ${token}` },
        body: JSON.stringify(body),
      });
      if (response.status === 401) throw new ChatApiError('Oturumun sona erdi. Yeniden giriş yap.');
      if (!response.ok) {
        const text = await response.text();
        let payload: unknown;
        try { payload = JSON.parse(text) as unknown; } catch { payload = null; }
        throw new ChatApiError(messageFromPayload(payload, 'Mesaj gönderilemedi. Tekrar deneyebilirsin.'), response.status);
      }
      let buffer = '';
      let result: ChatTurnResult | null = null;
      if (response.body) {
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        while (!result) {
          const { value, done } = await reader.read();
          buffer += decoder.decode(value, { stream: !done });
          const frames = buffer.split(/\r?\n\r?\n/);
          buffer = frames.pop() ?? '';
          for (const frame of frames) {
            const event = parseSseFrame(frame);
            if (event) result = dispatchEvent(event, onStatus, onEvent);
            if (result) break;
          }
          if (done) break;
        }
        if (result) return await finish(result);
        const lastEvent = parseSseFrame(buffer);
        if (lastEvent) result = dispatchEvent(lastEvent, onStatus, onEvent);
      } else {
        const payload = asRecord(await response.json());
        if (payload) result = normalizeTurn(payload);
      }
      if (result) return await finish(result);
      // The iOS client never repeats the POST: it resumes from the durable request ledger.
      return await finish(await resumeCopilotRequest(token, requestId, onStatus));
    } catch (cause) {
      if (cause instanceof ChatApiError) throw cause;
      return await resumeCopilotRequest(token, requestId, onStatus);
    } finally { clearTimeout(timeout); }
  },

  async resolveConfirmation(token: string, confirmationId: string, approved: boolean) {
    return await authorizedRequest('copilot/confirm', token, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ confirmationId, approved }) });
  },

  async continueLocation(token: string, requestId: string, city: string | null) {
    return await authorizedRequest(`copilot/requests/${encodeURIComponent(requestId)}/location`, token, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ city }) });
  },
};
