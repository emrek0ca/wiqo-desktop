using System.Runtime.InteropServices;

namespace RovaWindows.Native;

/// Win32 entry points the companion uses. Only documented, user-mode APIs; nothing here needs
/// elevation. Every caller checks the return value and reports a clear error.
internal static class NativeMethods
{
    // Power
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool LockWorkStation();

    [DllImport("powrprof.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetSuspendState([MarshalAs(UnmanagedType.Bool)] bool hibernate, [MarshalAs(UnmanagedType.Bool)] bool forceCritical, [MarshalAs(UnmanagedType.Bool)] bool disableWakeEvent);

    internal const int WmSysCommand = 0x0112;
    internal const int ScMonitorPower = 0xF170;
    internal static readonly IntPtr HwndBroadcast = new(0xFFFF);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool PostMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    internal struct SystemPowerStatus
    {
        public byte AcLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetSystemPowerStatus(out SystemPowerStatus status);

    [DllImport("kernel32.dll")]
    internal static extern ulong GetTickCount64();

    // Keyboard (media keys)
    internal const ushort VkMediaNextTrack = 0xB0;
    internal const ushort VkMediaPrevTrack = 0xB1;
    internal const ushort VkMediaPlayPause = 0xB3;
    internal const uint KeyEventFKeyUp = 0x0002;
    internal const uint InputKeyboard = 1;

    [StructLayout(LayoutKind.Sequential)]
    internal struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    internal struct InputUnion
    {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        // MOUSEINPUT is the largest member; reserve its size so cbSize matches the native INPUT.
        [FieldOffset(0)] public MouseInputPadding Padding;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct MouseInputPadding
    {
        public int X;
        public int Y;
        public uint Data;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Input
    {
        public uint Type;
        public InputUnion Union;
    }

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern uint SendInput(uint count, Input[] inputs, int size);

    // Clipboard
    internal const uint CfUnicodeText = 13;
    internal const uint GmemMoveable = 0x0002;

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool OpenClipboard(IntPtr owner);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CloseClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool EmptyClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern IntPtr GetClipboardData(uint format);

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern IntPtr SetClipboardData(uint format, IntPtr memory);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool IsClipboardFormatAvailable(uint format);

    [DllImport("user32.dll")]
    internal static extern uint GetClipboardSequenceNumber();

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern IntPtr GlobalLock(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GlobalUnlock(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern IntPtr GlobalFree(IntPtr memory);

    [DllImport("kernel32.dll")]
    internal static extern UIntPtr GlobalSize(IntPtr memory);

    // A message-only window: the clipboard needs an owner window, or SetClipboardData fails
    // after EmptyClipboard (documented for OpenClipboard(NULL)).
    internal static readonly IntPtr HwndMessage = new(-3);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    internal static extern IntPtr CreateWindowEx(int exStyle, string className, string windowName, int style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DestroyWindow(IntPtr window);

    // Windows and processes
    [DllImport("user32.dll")]
    internal static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    internal static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool ShowWindow(IntPtr window, int command);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool IsIconic(IntPtr window);

    internal const int SwRestore = 9;

    // Screen
    internal const int SmXVirtualScreen = 76;
    internal const int SmYVirtualScreen = 77;
    internal const int SmCxVirtualScreen = 78;
    internal const int SmCyVirtualScreen = 79;

    [DllImport("user32.dll")]
    internal static extern int GetSystemMetrics(int index);

    // Shell (Recycle Bin delete)
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct ShFileOpStruct
    {
        public IntPtr Window;
        public uint Function;
        [MarshalAs(UnmanagedType.LPWStr)] public string From;
        [MarshalAs(UnmanagedType.LPWStr)] public string? To;
        public ushort Flags;
        [MarshalAs(UnmanagedType.Bool)] public bool AnyOperationsAborted;
        public IntPtr NameMappings;
        [MarshalAs(UnmanagedType.LPWStr)] public string? ProgressTitle;
    }

    internal const uint FoDelete = 0x0003;
    internal const ushort FofSilent = 0x0004;
    internal const ushort FofNoConfirmation = 0x0010;
    internal const ushort FofAllowUndo = 0x0040;
    internal const ushort FofNoErrorUi = 0x0400;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    internal static extern int SHFileOperation(ref ShFileOpStruct operation);
}
