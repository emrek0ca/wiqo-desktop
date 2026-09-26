using System.Runtime.InteropServices;

namespace RovaWindows.Native;

/// Media keys as a real key press, which every Windows media session (Spotify, browsers, the
/// system media transport controls) already listens to.
internal static class MediaKeys
{
    internal static bool Press(string action)
    {
        ushort key = action switch
        {
            "playPause" => NativeMethods.VkMediaPlayPause,
            "nextTrack" => NativeMethods.VkMediaNextTrack,
            "previousTrack" => NativeMethods.VkMediaPrevTrack,
            _ => 0
        };
        if (key == 0) return false;
        var inputs = new[]
        {
            Key(key, 0),
            Key(key, NativeMethods.KeyEventFKeyUp)
        };
        return NativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<NativeMethods.Input>()) == inputs.Length;
    }

    private static NativeMethods.Input Key(ushort key, uint flags) => new()
    {
        Type = NativeMethods.InputKeyboard,
        Union = new NativeMethods.InputUnion { Keyboard = new NativeMethods.KeyboardInput { VirtualKey = key, Flags = flags } }
    };
}
