using System.Net.NetworkInformation;
using System.Runtime.InteropServices;

namespace OmarchyBar;

internal static class SystemStats
{
    private static long _lastIdle;
    private static long _lastKernel;
    private static long _lastUser;
    private static bool _hasCpuSample;

    public static string Cpu()
    {
        if (!GetSystemTimes(out var idle, out var kernel, out var user))
            return "cpu --";

        if (!_hasCpuSample)
        {
            _lastIdle = idle;
            _lastKernel = kernel;
            _lastUser = user;
            _hasCpuSample = true;
            return "cpu --";
        }

        var idleDelta = idle - _lastIdle;
        var kernelDelta = kernel - _lastKernel;
        var userDelta = user - _lastUser;
        _lastIdle = idle;
        _lastKernel = kernel;
        _lastUser = user;

        var total = kernelDelta + userDelta;
        if (total <= 0)
            return "cpu --";

        var busy = total - idleDelta;
        var percent = (int)Math.Round(100.0 * busy / total);
        if (percent < 0)
            percent = 0;
        if (percent > 100)
            percent = 100;
        return $"cpu {percent}";
    }

    public static string Memory()
    {
        var status = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
        if (!GlobalMemoryStatusEx(ref status) || status.ullTotalPhys == 0)
            return "mem --";
        return $"mem {status.dwMemoryLoad}";
    }

    public static string Network()
    {
        try
        {
            var nic = NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(item =>
                item.OperationalStatus == OperationalStatus.Up
                && item.NetworkInterfaceType is not NetworkInterfaceType.Loopback and not NetworkInterfaceType.Tunnel);
            if (nic is null)
                return "off";
            if (nic.NetworkInterfaceType == NetworkInterfaceType.Wireless80211)
                return "wifi";
            if (nic.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.GigabitEthernet)
                return "eth";
            return "net";
        }
        catch
        {
            return "off";
        }
    }

    public static string Battery()
    {
        if (!GetSystemPowerStatus(out var status) || status.BatteryLifePercent == 255)
            return "ac";
        return status.ACLineStatus == 1
            ? $"ac {status.BatteryLifePercent}"
            : $"bat {status.BatteryLifePercent}";
    }

    public static string Volume()
    {
        if (!AudioVolume.TryGet(out var percent, out var muted))
            return "vol --";
        return muted ? "mute" : $"vol {percent}";
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemTimes(out long idle, out long kernel, out long user);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX buffer);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);

    [StructLayout(LayoutKind.Sequential)]
    private struct MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SYSTEM_POWER_STATUS
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }
}

internal static class AudioVolume
{
    public static bool TryGet(out int percent, out bool muted)
    {
        percent = 0;
        muted = false;
        try
        {
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            var hr = enumerator.GetDefaultAudioEndpoint(0, 1, out var device);
            if (hr != 0 || device is null)
                return false;

            var iid = typeof(IAudioEndpointVolume).GUID;
            hr = device.Activate(ref iid, 1, IntPtr.Zero, out var activated);
            if (hr != 0 || activated is not IAudioEndpointVolume volume)
                return false;

            volume.GetMasterVolumeLevelScalar(out var level);
            volume.GetMute(out var isMuted);
            percent = (int)Math.Round(level * 100);
            muted = isMuted;
            return true;
        }
        catch
        {
            return false;
        }
    }

    [ComImport]
    [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumeratorCom
    {
    }

    [ComImport]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig]
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);

        [PreserveSig]
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }

    [ComImport]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig]
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
    }

    [ComImport]
    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr client);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr client);
        [PreserveSig] int GetChannelCount(out uint count);
        [PreserveSig] int SetMasterVolumeLevel(float levelDb, IntPtr eventContext);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, IntPtr eventContext);
        [PreserveSig] int GetMasterVolumeLevel(out float levelDb);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint channel, float levelDb, IntPtr eventContext);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, IntPtr eventContext);
        [PreserveSig] int GetChannelVolumeLevel(uint channel, out float levelDb);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, IntPtr eventContext);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }
}
