import * as Crypto from 'expo-crypto';
import * as SecureStore from 'expo-secure-store';
import * as SQLite from 'expo-sqlite';

const databaseName = 'wiqo-local-cache.db';
const encryptionKeyName = 'wiqo-local-cache-key-v1';
const maxEntryBytes = 1_500_000;
const maxEntries = 320;

type CacheRow = { value: string; written_at: number; expires_at: number; stale_until: number };
export type CacheEntry<T> = { value: T; fresh: boolean; ageMs: number };

let databasePromise: Promise<SQLite.SQLiteDatabase | null> | null = null;
const inFlight = new Map<string, Promise<unknown>>();

async function cacheDatabase(): Promise<SQLite.SQLiteDatabase | null> {
  if (!databasePromise) {
    databasePromise = (async () => {
      try {
        let key = await SecureStore.getItemAsync(encryptionKeyName);
        if (!key) {
          key = Array.from(await Crypto.getRandomBytesAsync(32), byte => byte.toString(16).padStart(2, '0')).join('');
          await SecureStore.setItemAsync(encryptionKeyName, key, {
            keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
          });
        }
        const database = await SQLite.openDatabaseAsync(databaseName);
        await database.execAsync(`PRAGMA key = '${key}'; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;`);
        await database.execAsync(`
          CREATE TABLE IF NOT EXISTS cache_entries (
            scope TEXT NOT NULL,
            cache_key TEXT NOT NULL,
            value TEXT NOT NULL,
            written_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            stale_until INTEGER NOT NULL,
            PRIMARY KEY (scope, cache_key)
          );
          CREATE INDEX IF NOT EXISTS cache_entries_expiry ON cache_entries(stale_until);
        `);
        return database;
      } catch {
        return null;
      }
    })();
  }
  return databasePromise;
}

export async function cacheScopeForToken(token: string): Promise<string> {
  return Crypto.digestStringAsync(Crypto.CryptoDigestAlgorithm.SHA256, token);
}

export async function readCache<T>(scope: string, key: string, maxStaleMs = Number.MAX_SAFE_INTEGER): Promise<CacheEntry<T> | null> {
  const database = await cacheDatabase();
  if (!database) return null;
  try {
    const row = await database.getFirstAsync<CacheRow>(
      'SELECT value, written_at, expires_at, stale_until FROM cache_entries WHERE scope = ? AND cache_key = ?',
      scope,
      key,
    );
    if (!row) return null;
    const now = Date.now();
    const ageMs = Math.max(0, now - row.written_at);
    if (now > row.stale_until || ageMs > maxStaleMs) {
      await database.runAsync('DELETE FROM cache_entries WHERE scope = ? AND cache_key = ?', scope, key);
      return null;
    }
    return { value: JSON.parse(row.value) as T, fresh: now <= row.expires_at, ageMs };
  } catch {
    return null;
  }
}

export async function writeCache(scope: string, key: string, value: unknown, ttlMs: number, staleMs = ttlMs): Promise<void> {
  const database = await cacheDatabase();
  if (!database) return;
  try {
    const serialized = JSON.stringify(value);
    if (serialized.length > maxEntryBytes) return;
    const now = Date.now();
    await database.runAsync(
      `INSERT INTO cache_entries(scope, cache_key, value, written_at, expires_at, stale_until)
       VALUES(?, ?, ?, ?, ?, ?)
       ON CONFLICT(scope, cache_key) DO UPDATE SET value=excluded.value, written_at=excluded.written_at, expires_at=excluded.expires_at, stale_until=excluded.stale_until`,
      scope,
      key,
      serialized,
      now,
      now + ttlMs,
      now + ttlMs + staleMs,
    );
    await database.runAsync('DELETE FROM cache_entries WHERE stale_until < ?', now);
    await database.runAsync(`DELETE FROM cache_entries WHERE rowid IN (
      SELECT rowid FROM cache_entries ORDER BY written_at DESC LIMIT -1 OFFSET ?
    )`, maxEntries);
  } catch {
    // Cache writes are best-effort and never block a successful server response.
  }
}

export async function removeCache(scope: string, key: string): Promise<void> {
  const database = await cacheDatabase();
  if (!database) return;
  try { await database.runAsync('DELETE FROM cache_entries WHERE scope = ? AND cache_key = ?', scope, key); } catch { /* best effort */ }
}

export async function removeCachePrefix(scope: string, prefix: string): Promise<void> {
  const database = await cacheDatabase();
  if (!database) return;
  try { await database.runAsync('DELETE FROM cache_entries WHERE scope = ? AND cache_key LIKE ?', scope, `${prefix.replace(/[\%_]/g, '\\$&')}%`); } catch { /* best effort */ }
}

export async function clearCacheScope(scope: string): Promise<void> {
  const database = await cacheDatabase();
  if (!database) return;
  try { await database.runAsync('DELETE FROM cache_entries WHERE scope = ?', scope); } catch { /* best effort */ }
}

export function singleFlight<T>(key: string, load: () => Promise<T>): Promise<T> {
  const existing = inFlight.get(key);
  if (existing) return existing as Promise<T>;
  const request = load().finally(() => inFlight.delete(key));
  inFlight.set(key, request);
  return request;
}
