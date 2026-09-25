using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace RovaWindows;

/// Current-user DPAPI storage for relay pairing and rotating device credentials.
internal static class WindowsSecretStore
{
    private const string PairingFileName = "pairing-token.dpapi";
    private const string CredentialsFileName = "device-session.dpapi";
    private const int CryptProtectUiForbidden = 0x1;
    private static readonly string DirectoryPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Wiqo");

    internal static void SavePairingToken(string token)
    {
        if (string.IsNullOrWhiteSpace(token) || token.Length > 200) throw new CryptographicException("Invalid pairing token.");
        Save(PairingFileName, System.Text.Encoding.UTF8.GetBytes(token));
    }

    internal static string? LoadPairingToken()
    {
        var bytes = Load(PairingFileName);
        if (bytes is null) return null;
        try { return System.Text.Encoding.UTF8.GetString(bytes); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    internal static void SaveCredentials(DeviceSessionCredentials credentials)
    {
        Save(CredentialsFileName, System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(credentials));
    }

    internal static DeviceSessionCredentials? LoadCredentials()
    {
        var bytes = Load(CredentialsFileName);
        if (bytes is null) return null;
        try { return System.Text.Json.JsonSerializer.Deserialize<DeviceSessionCredentials>(bytes, new System.Text.Json.JsonSerializerOptions(System.Text.Json.JsonSerializerDefaults.Web)); }
        catch { return null; }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    private static void Save(string fileName, byte[] plaintext)
    {
        try
        {
            Directory.CreateDirectory(DirectoryPath);
            var encrypted = Protect(plaintext);
            var path = Path.Combine(DirectoryPath, fileName);
            var temp = path + ".tmp-" + Guid.NewGuid().ToString("N");
            try { File.WriteAllBytes(temp, encrypted); File.Move(temp, path, true); }
            finally
            {
                CryptographicOperations.ZeroMemory(encrypted);
                try { File.Delete(temp); } catch { }
            }
        }
        finally { CryptographicOperations.ZeroMemory(plaintext); }
    }

    private static byte[]? Load(string fileName)
    {
        try { return Unprotect(File.ReadAllBytes(Path.Combine(DirectoryPath, fileName))); }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
        catch (CryptographicException) { return null; }
    }

    private static byte[] Protect(byte[] input) => Transform(input, protect: true);
    private static byte[] Unprotect(byte[] input) => Transform(input, protect: false);

    private static byte[] Transform(byte[] input, bool protect)
    {
        var inputHandle = Marshal.AllocHGlobal(input.Length);
        try
        {
            Marshal.Copy(input, 0, inputHandle, input.Length);
            var source = new DataBlob { Size = input.Length, Data = inputHandle };
            DataBlob destination;
            var ok = protect
                ? CryptProtectData(ref source, null, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, CryptProtectUiForbidden, out destination)
                : CryptUnprotectData(ref source, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, CryptProtectUiForbidden, out destination);
            if (!ok) throw new CryptographicException(Marshal.GetLastWin32Error());
            try
            {
                var output = new byte[destination.Size];
                Marshal.Copy(destination.Data, output, 0, destination.Size);
                return output;
            }
            finally { LocalFree(destination.Data); }
        }
        finally
        {
            Marshal.Copy(new byte[input.Length], 0, inputHandle, input.Length);
            Marshal.FreeHGlobal(inputHandle);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob { public int Size; public IntPtr Data; }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref DataBlob input, string? description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);

    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}
