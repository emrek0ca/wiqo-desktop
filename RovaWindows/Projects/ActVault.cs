using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace RovaWindows.Projects;

/// Wire-compatible with RovaShared/ActVault.swift; only the encrypted blobs reach the hub.
internal sealed class ActVault : IDisposable
{
    internal static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private readonly byte[] content;
    private readonly byte[] path;
    private readonly byte[] hash;
    internal string KeyId { get; }
    internal ActVault(byte[] master)
    {
        if (master.Length != 32) throw new CryptographicException();
        byte[] Derive(string info) => HKDF.DeriveKey(HashAlgorithmName.SHA256, master, 32, Encoding.UTF8.GetBytes("wiqo.act.v1"), Encoding.UTF8.GetBytes(info));
        content = Derive("content"); path = Derive("path"); hash = Derive("hash");
        KeyId = Convert.ToHexString(SHA256.HashData(master)).ToLowerInvariant();
    }
    internal static byte[] RecoveryKey(string code)
    {
        const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
        var cleaned = new string(code.ToUpperInvariant().Where(c => !char.IsWhiteSpace(c) && c != '-').ToArray());
        if (cleaned.Length != 55) throw new InvalidDataException("Kurtarma kodu geçersiz.");
        var bytes = new List<byte>(); var buffer = 0; var bits = 0;
        foreach (var c in cleaned)
        {
            var n = alphabet.IndexOf(c); if (n < 0) throw new InvalidDataException("Kurtarma kodu geçersiz.");
            buffer = (buffer << 5) | n; bits += 5;
            if (bits >= 8) { bits -= 8; bytes.Add((byte)((buffer >> bits) & 255)); }
        }
        var master = bytes.Take(32).ToArray();
        if ((buffer & ((1 << bits) - 1)) != 0 || !CryptographicOperations.FixedTimeEquals(SHA256.HashData(master).AsSpan(0, 2), bytes.Skip(32).ToArray()))
            throw new InvalidDataException("Kurtarma kodunun kontrolü başarısız.");
        return master;
    }
    internal string Seal<T>(T value)
    {
        var plain = JsonSerializer.SerializeToUtf8Bytes(value, Json);
        var combined = new byte[12 + plain.Length + 16]; RandomNumberGenerator.Fill(combined.AsSpan(0, 12));
        try
        {
            using var aes = new AesGcm(content, 16);
            aes.Encrypt(combined.AsSpan(0, 12), plain, combined.AsSpan(12, plain.Length), combined.AsSpan(12 + plain.Length, 16));
            return Convert.ToBase64String(combined);
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
    internal T Open<T>(string blob)
    {
        var combined = Convert.FromBase64String(blob);
        if (combined.Length < 28) throw new CryptographicException();
        var plain = new byte[combined.Length - 28];
        try
        {
            using var aes = new AesGcm(content, 16);
            aes.Decrypt(combined.AsSpan(0, 12), combined.AsSpan(12, plain.Length), combined.AsSpan(12 + plain.Length, 16), plain);
            return JsonSerializer.Deserialize<T>(plain, Json) ?? throw new InvalidDataException("Proje verisi okunamadı.");
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
    internal string PathToken(string value) => Convert.ToHexString(HMACSHA256.HashData(path, Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
    internal string ContentHash(string name, string value) => Convert.ToHexString(HMACSHA256.HashData(hash, Encoding.UTF8.GetBytes(name + "\0" + value))).ToLowerInvariant();
    public void Dispose() { CryptographicOperations.ZeroMemory(content); CryptographicOperations.ZeroMemory(path); CryptographicOperations.ZeroMemory(hash); }
}
