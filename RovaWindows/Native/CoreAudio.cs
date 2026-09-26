using System.Runtime.InteropServices;

namespace RovaWindows.Native;

/// Master volume of the default playback device through the documented Core Audio API
/// (IMMDeviceEnumerator -> IAudioEndpointVolume). Works for every output device Windows knows,
/// without sending volume keys whose step size depends on the machine.
internal static class CoreAudio
{
    private static readonly Guid AudioEndpointVolumeId = new("5CDF2C82-841E-4546-9722-0CF74078229A");

    internal static int? GetVolumePercent() => Use(endpoint =>
    {
        Marshal.ThrowExceptionForHR(endpoint.GetMasterVolumeLevelScalar(out var level));
        return (int)Math.Round(level * 100);
    });

    internal static bool? IsMuted() => Use(endpoint =>
    {
        Marshal.ThrowExceptionForHR(endpoint.GetMute(out var muted));
        return muted;
    });

    /// Sets the level and unmutes (asking for a volume means wanting to hear it), then reads back.
    internal static int SetVolumePercent(int percent)
    {
        return Use(endpoint =>
        {
            var context = Guid.Empty;
            Marshal.ThrowExceptionForHR(endpoint.SetMasterVolumeLevelScalar(Math.Clamp(percent, 0, 100) / 100f, ref context));
            if (percent > 0) Marshal.ThrowExceptionForHR(endpoint.SetMute(false, ref context));
            Marshal.ThrowExceptionForHR(endpoint.GetMasterVolumeLevelScalar(out var level));
            return (int)Math.Round(level * 100);
        }) ?? throw new InvalidOperationException("Ses aygıtı bulunamadı.");
    }

    internal static bool ToggleMute()
    {
        return Use(endpoint =>
        {
            Marshal.ThrowExceptionForHR(endpoint.GetMute(out var muted));
            var context = Guid.Empty;
            Marshal.ThrowExceptionForHR(endpoint.SetMute(!muted, ref context));
            Marshal.ThrowExceptionForHR(endpoint.GetMute(out var after));
            return after;
        }) ?? throw new InvalidOperationException("Ses aygıtı bulunamadı.");
    }

    private static T? Use<T>(Func<IAudioEndpointVolume, T> action) where T : struct
    {
        IMMDeviceEnumerator? enumerator = null;
        IMMDevice? device = null;
        object? endpointObject = null;
        try
        {
            enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            if (enumerator.GetDefaultAudioEndpoint(0 /* eRender */, 1 /* eMultimedia */, out device) != 0 || device is null) return null;
            var id = AudioEndpointVolumeId;
            Marshal.ThrowExceptionForHR(device.Activate(ref id, 0x17 /* CLSCTX_ALL */, IntPtr.Zero, out endpointObject));
            return action((IAudioEndpointVolume)endpointObject);
        }
        finally
        {
            if (endpointObject is not null) Marshal.ReleaseComObject(endpointObject);
            if (device is not null) Marshal.ReleaseComObject(device);
            if (enumerator is not null) Marshal.ReleaseComObject(enumerator);
        }
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object endpoint);
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int GetChannelCount(out uint count);
        [PreserveSig] int SetMasterVolumeLevel(float levelDb, ref Guid context);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid context);
        [PreserveSig] int GetMasterVolumeLevel(out float levelDb);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint channel, float levelDb, ref Guid context);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid context);
        [PreserveSig] int GetChannelVolumeLevel(uint channel, out float levelDb);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid context);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }
}
