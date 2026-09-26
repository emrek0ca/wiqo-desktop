using System.Runtime.InteropServices;

namespace RovaWindows.Native;

/// Unicode text on the Windows clipboard through the Win32 API (no UI thread needed). Another
/// application can hold the clipboard for a moment, so opening retries briefly.
internal static class WindowsClipboard
{
    internal static string? GetText()
    {
        using var session = Open();
        if (!NativeMethods.IsClipboardFormatAvailable(NativeMethods.CfUnicodeText)) return null;
        var handle = NativeMethods.GetClipboardData(NativeMethods.CfUnicodeText);
        if (handle == IntPtr.Zero) return null;
        var pointer = NativeMethods.GlobalLock(handle);
        if (pointer == IntPtr.Zero) return null;
        try
        {
            var maxChars = (int)Math.Min((ulong)NativeMethods.GlobalSize(handle) / 2, 1_000_000);
            return Marshal.PtrToStringUni(pointer, maxChars).Split('\0')[0];
        }
        finally { NativeMethods.GlobalUnlock(handle); }
    }

    internal static void SetText(string text)
    {
        using var session = Open();
        if (!NativeMethods.EmptyClipboard()) throw new InvalidOperationException("Pano temizlenemedi.");
        var bytes = (text.Length + 1) * 2;
        var memory = NativeMethods.GlobalAlloc(NativeMethods.GmemMoveable, (UIntPtr)bytes);
        if (memory == IntPtr.Zero) throw new OutOfMemoryException();
        var owned = true;
        try
        {
            var pointer = NativeMethods.GlobalLock(memory);
            if (pointer == IntPtr.Zero) throw new InvalidOperationException("Pano belleği kilitlenemedi.");
            try
            {
                Marshal.Copy(text.ToCharArray(), 0, pointer, text.Length);
                Marshal.WriteInt16(pointer, text.Length * 2, 0);
            }
            finally { NativeMethods.GlobalUnlock(memory); }
            if (NativeMethods.SetClipboardData(NativeMethods.CfUnicodeText, memory) == IntPtr.Zero)
                throw new InvalidOperationException("Metin panoya yazılamadı.");
            owned = false; // The system owns the memory after SetClipboardData succeeds.
        }
        finally { if (owned) NativeMethods.GlobalFree(memory); }
    }

    internal static uint SequenceNumber => NativeMethods.GetClipboardSequenceNumber();

    private static Session Open()
    {
        for (var attempt = 0; attempt < 10; attempt++)
        {
            if (NativeMethods.OpenClipboard(IntPtr.Zero)) return new Session();
            Thread.Sleep(30);
        }
        throw new InvalidOperationException("Pano başka bir uygulama tarafından kullanılıyor; biraz sonra tekrar dene.");
    }

    private readonly struct Session : IDisposable
    {
        public void Dispose() => NativeMethods.CloseClipboard();
    }
}
