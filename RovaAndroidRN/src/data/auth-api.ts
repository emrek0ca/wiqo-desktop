export const API_BASE_URL = 'https://api.wiqoai.com';

export class AuthApiError extends Error {
  constructor(message: string, readonly status?: number, readonly code?: string) {
    super(message);
    this.name = 'AuthApiError';
  }
}

type ApiPayload = {
  ok?: unknown;
  token?: unknown;
  message?: unknown;
  error?: { message?: unknown; code?: unknown };
};

async function post(path: string, body: Record<string, string>): Promise<ApiPayload> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 25_000);
  try {
    const response = await fetch(`${API_BASE_URL}/${path}`, {
      method: 'POST',
      headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    const text = await response.text();
    let payload: ApiPayload = {};
    try {
      payload = text ? (JSON.parse(text) as ApiPayload) : {};
    } catch {
      throw new AuthApiError('Sunucudan geçersiz bir yanıt alındı. Lütfen tekrar dene.', response.status);
    }
    if (!response.ok) {
      const message = payload.error?.message;
      const safeMessage = typeof message === 'string' && message.trim().length > 0
        ? message.trim()
        : response.status === 401
          ? 'E-posta veya şifre hatalı.'
          : 'İşlem tamamlanamadı. Lütfen tekrar dene.';
      throw new AuthApiError(safeMessage, response.status,
        typeof payload.error?.code === 'string' ? payload.error.code : undefined);
    }
    return payload;
  } catch (error) {
    if (error instanceof AuthApiError) throw error;
    if (controller.signal.aborted) {
      throw new AuthApiError('Bağlantı zaman aşımına uğradı. Tekrar deneyebilirsin.');
    }
    throw new AuthApiError('Bağlantı kurulamadı. Tekrar deneyebilirsin.');
  } finally {
    clearTimeout(timeout);
  }
}

async function authenticate(path: 'auth/login' | 'auth/register' | 'auth/reset-password', body: Record<string, string>): Promise<string> {
  const payload = await post(path, body);
  if (typeof payload.token !== 'string' || payload.token.trim().length === 0) {
    throw new AuthApiError('Sunucudan geçersiz bir yanıt alındı. Lütfen tekrar dene.', 502);
  }
  return payload.token;
}

export const authApi = {
  async currentAccount(token: string) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 12_000);
    try {
      const response = await fetch(`${API_BASE_URL}/auth/me`, {
        headers: { Accept: 'application/json', Authorization: `Bearer ${token}` },
        signal: controller.signal,
      });
      const text = await response.text();
      let payload: ApiPayload = {};
      try { payload = text ? JSON.parse(text) as ApiPayload : {}; } catch { throw new AuthApiError('Sunucudan geçersiz bir yanıt alındı.', response.status); }
      if (!response.ok) throw new AuthApiError('Oturum doğrulanamadı.', response.status, typeof payload.error?.code === 'string' ? payload.error.code : undefined);
      return payload;
    } catch (cause) {
      if (cause instanceof AuthApiError) throw cause;
      throw new AuthApiError('Sunucuya şu anda ulaşılamıyor. Kaydedilmiş oturum kullanılacak.');
    } finally {
      clearTimeout(timeout);
    }
  },
  login(email: string, password: string) {
    return authenticate('auth/login', { email: email.trim(), password });
  },
  register(email: string, password: string, inviteCode: string) {
    const body: Record<string, string> = { email: email.trim(), password };
    const code = inviteCode.trim();
    if (code) body.inviteCode = code;
    return authenticate('auth/register', body);
  },
  async requestPasswordReset(email: string) {
    const payload = await post('auth/forgot-password', { email: email.trim() });
    if (payload.ok === false) {
      throw new AuthApiError(typeof payload.message === 'string' ? payload.message : 'Şifre sıfırlama kodu istenemedi.');
    }
  },
  resetPassword(email: string, code: string, newPassword: string) {
    return authenticate('auth/reset-password', { email: email.trim(), code: code.trim(), newPassword });
  },
};
