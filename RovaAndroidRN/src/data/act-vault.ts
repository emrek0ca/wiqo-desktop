import { gcm } from '@noble/ciphers/aes.js';
import { hkdf } from '@noble/hashes/hkdf.js';
import { hmac } from '@noble/hashes/hmac.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { bytesToHex, utf8ToBytes } from '@noble/hashes/utils.js';
import * as Crypto from 'expo-crypto';
import * as SecureStore from 'expo-secure-store';

const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function encode64(bytes: Uint8Array) {
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i]; const b = bytes[i + 1]; const c = bytes[i + 2];
    out += alphabet[a >> 2] + alphabet[((a & 3) << 4) | ((b ?? 0) >> 4)] + (b === undefined ? '=' : alphabet[((b & 15) << 2) | ((c ?? 0) >> 6)]) + (c === undefined ? '=' : alphabet[c & 63]);
  }
  return out;
}
function decode64(text: string) {
  const clean = text.replace(/[^A-Za-z0-9+/=]/g, ''); const out: number[] = [];
  for (let i = 0; i < clean.length; i += 4) {
    const a = alphabet.indexOf(clean[i]); const b = alphabet.indexOf(clean[i + 1]);
    const c = clean[i + 2] === '=' ? 0 : alphabet.indexOf(clean[i + 2]); const d = clean[i + 3] === '=' ? 0 : alphabet.indexOf(clean[i + 3]);
    if (a < 0 || b < 0 || c < 0 || d < 0) throw new Error('Şifreli proje açılamadı.');
    out.push((a << 2) | (b >> 4)); if (clean[i + 2] !== '=') out.push(((b & 15) << 4) | (c >> 2)); if (clean[i + 3] !== '=') out.push(((c & 3) << 6) | d);
  }
  return new Uint8Array(out);
}
function decodeUtf8(bytes: Uint8Array) { return decodeURIComponent(Array.from(bytes, byte => `%${byte.toString(16).padStart(2, '0')}`).join('')); }

export type ActKeys = { seal: (value: unknown) => string; open: <T>(blob: string) => T | null; pathToken: (path: string) => string; contentHash: (path: string, content: string) => string; recoveryCode: string };

const base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
function encode32(bytes: Uint8Array) {
  let output = ''; let buffer = 0; let bits = 0;
  for (const byte of bytes) { buffer = (buffer << 8) | byte; bits += 8; while (bits >= 5) { output += base32Alphabet[(buffer >>> (bits - 5)) & 31]; bits -= 5; } }
  if (bits) output += base32Alphabet[(buffer << (5 - bits)) & 31];
  return output.match(/.{1,5}/g)?.join('-') ?? output;
}
function decode32(code: string) {
  const input = code.toUpperCase().replace(/[\s-]/g, ''); let output: number[] = []; let buffer = 0; let bits = 0;
  for (const character of input) { const value = base32Alphabet.indexOf(character); if (value < 0) throw new Error('Geçersiz kurtarma kodu.'); buffer = (buffer << 5) | value; bits += 5; if (bits >= 8) { output.push((buffer >>> (bits - 8)) & 255); bits -= 8; } }
  return new Uint8Array(output);
}

export async function importActRecoveryCode(scope: string, code: string) {
  try {
    const packed = decode32(code); if (packed.length !== 34) return false;
    const master = packed.slice(0, 32); const checksum = sha256(master).slice(0, 2);
    if (checksum[0] !== packed[32] || checksum[1] !== packed[33]) return false;
    await SecureStore.setItemAsync(`wiqo-act-vault-${scope.slice(0, 28)}`, encode64(master));
    return true;
  } catch { return false; }
}

export async function loadActKeys(scope: string): Promise<ActKeys> {
  const account = `wiqo-act-vault-${scope.slice(0, 28)}`;
  let encoded = await SecureStore.getItemAsync(account);
  if (!encoded) {
    encoded = encode64(Crypto.getRandomBytes(32));
    await SecureStore.setItemAsync(account, encoded);
  }
  const master = decode64(encoded);
  if (master.length !== 32) throw new Error('Act şifreleme anahtarı okunamadı.');
  const salt = utf8ToBytes('wiqo.act.v1');
  const content = hkdf(sha256, master, salt, utf8ToBytes('content'), 32);
  const path = hkdf(sha256, master, salt, utf8ToBytes('path'), 32);
  const hash = hkdf(sha256, master, salt, utf8ToBytes('hash'), 32);
  const checksum = sha256(master).slice(0, 2);
  const recoveryCode = encode32(new Uint8Array([...master, ...checksum]));
  return {
    seal(value) {
      const nonce = Crypto.getRandomBytes(12);
      const cipher = gcm(content, nonce).encrypt(utf8ToBytes(JSON.stringify(value)));
      const combined = new Uint8Array(nonce.length + cipher.length); combined.set(nonce); combined.set(cipher, nonce.length);
      return encode64(combined);
    },
    open<T>(blob: string) {
      try { const data = decode64(blob); if (data.length < 28) return null; const plaintext = gcm(content, data.slice(0, 12)).decrypt(data.slice(12)); return JSON.parse(decodeUtf8(plaintext)) as T; } catch { return null; }
    },
    pathToken(value) { return bytesToHex(hmac(sha256, path, utf8ToBytes(value))); },
    contentHash(filePath, value) { return bytesToHex(hmac(sha256, hash, utf8ToBytes(`${filePath}\0${value}`))); },
    recoveryCode,
  };
}

export async function actStorageScope(token: string | null) {
  return Crypto.digestStringAsync(Crypto.CryptoDigestAlgorithm.SHA256, token || 'guest');
}
