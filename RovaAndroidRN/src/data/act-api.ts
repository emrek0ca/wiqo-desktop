import { API_BASE_URL } from '@/data/auth-api';

export type ActWriterResult = {
  ok: boolean;
  kind: string;
  name: string;
  summary: string;
  changes: { path: string; after: string | null }[];
  needsDeviceCheck: boolean;
  problems: string[];
  text?: string | null;
};
export type ActWriterJob = {
  id: string;
  status: 'queued' | 'running' | 'done' | 'failed' | 'cancelled' | string;
  progress: string;
  error?: string | null;
  errorCode?: string | null;
  result?: ActWriterResult | null;
};
export type ActRunResult = { exitCode: number; timedOut: boolean; stdout: string; stderr: string; durationMs: number };
export type ActHubProject = { id: number; meta: string; version: number; updatedAt: string };
export type ActSealedFile = { p: string; b?: string | null; h?: string | null; d?: boolean };

async function request<T>(path: string, token: string, init: RequestInit = {}, timeoutMs = 30_000, acceptedStatuses: number[] = []): Promise<T> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(`${API_BASE_URL}/${path}`, {
      ...init,
      signal: controller.signal,
      headers: { Accept: 'application/json', Authorization: `Bearer ${token}`, ...(init.body ? { 'Content-Type': 'application/json' } : {}), ...(init.headers ?? {}) },
    });
    const body = await response.text();
    let payload: unknown = {};
    try { payload = body ? JSON.parse(body) as unknown : {}; } catch { throw new Error('Sunucudan geçersiz yanıt alındı.'); }
    if (!response.ok && !acceptedStatuses.includes(response.status)) {
      const record = payload && typeof payload === 'object' ? payload as { error?: { message?: string }; message?: string } : {};
      throw new Error(record.error?.message || record.message || `İstek tamamlanamadı (${response.status}).`);
    }
    return payload as T;
  } catch (cause) {
    if (cause instanceof Error && cause.name === 'AbortError') throw new Error('Sunucu yanıtı zaman aşımına uğradı.');
    if (cause instanceof Error) throw cause;
    throw new Error('Sunucuya bağlanılamadı.');
  } finally { clearTimeout(timeout); }
}

export const actApi = {
  startWriter(token: string, body: { operation: 'create' | 'edit'; request: string; files: { path: string; content: string }[]; kind?: string; name?: string; errors?: { level: string; text: string }[] }) {
    return request<{ jobId: string }>('code-sync/writer/jobs', token, { method: 'POST', body: JSON.stringify(body) });
  },
  writerJob(token: string, id: string) { return request<ActWriterJob>(`code-sync/writer/jobs/${encodeURIComponent(id)}`, token); },
  cancelWriter(token: string, id: string) { return request<{ ok: boolean }>(`code-sync/writer/jobs/${encodeURIComponent(id)}/cancel`, token, { method: 'POST', body: '{}' }); },
  acknowledgeWriter(token: string, id: string) { return request<{ ok: boolean }>(`code-sync/writer/jobs/${encodeURIComponent(id)}`, token, { method: 'DELETE' }); },
  runPython(token: string, files: { path: string; content: string }[]) {
    return request<ActRunResult>('code-sync/run', token, { method: 'POST', body: JSON.stringify({ files }) }, 60_000);
  },
  projects(token: string) { return request<{ projects: ActHubProject[] }>('code-sync/projects', token); },
  createProject(token: string, meta: string) { return request<{ id: number }>('code-sync/projects', token, { method: 'POST', body: JSON.stringify({ meta }) }); },
  deleteProject(token: string, id: number) { return request<{ ok: boolean }>(`code-sync/projects/${id}`, token, { method: 'DELETE' }); },
  snapshot(token: string, id: number) { return request<{ id: number; meta: string; version: number; files: ActSealedFile[] }>(`code-sync/projects/${id}/snapshot`, token); },
  changes(token: string, id: number, since: number) { return request<{ version: number; versions?: { version: number; changes: ActSealedFile[] }[]; needsSnapshot?: boolean }>(`code-sync/projects/${id}/changes?since=${since}`, token); },
  push(token: string, id: number, baseVersion: number, changes: ActSealedFile[], summary: string, device: string) {
    return request<{ ok: boolean; version?: number; merged?: boolean; conflict?: boolean; paths?: string[]; error?: string }>(`code-sync/projects/${id}/push`, token, { method: 'POST', body: JSON.stringify({ baseVersion, summary, device, changes }) }, 30_000, [409]);
  },
  waitForChange(token: string, stamp: number) { return request<{ stamp: number }>(`code-sync/wait?stamp=${stamp}`, token, {}, 40_000); },
};
