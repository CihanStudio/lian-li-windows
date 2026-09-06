# HidCore.ps1 - Windows'un yerlesik HID yigini uzerinden cihaz erisimi.
# Hicbir surucu kurulmaz; sadece hid.dll / setupapi.dll / kernel32.dll cagrilir.
# Tum okuma/yazma islemleri overlapped (zaman asimli) yapilir, boylece cihaz
# cevap vermezse PowerShell kilitlenmez.

if (-not ('LianLi.HidCore' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace LianLi
{
    public class HidInfo
    {
        public string Path;
        public ushort Vid;
        public ushort Pid;
        public ushort UsagePage;
        public ushort Usage;
        public int InputLen;
        public int OutputLen;
        public int FeatureLen;
        public string Product;
    }

    public class HidDevice : IDisposable
    {
        IntPtr handle = new IntPtr(-1);
        public int InputLen;
        public int OutputLen;
        public string Path;

        internal HidDevice(IntPtr h, string path, int inLen, int outLen)
        {
            handle = h; Path = path; InputLen = inLen; OutputLen = outLen;
        }

        public bool IsOpen { get { return handle != new IntPtr(-1) && handle != IntPtr.Zero; } }

        // Cihaza tam OutputLen uzunlugunda bir output report yazar.
        // data[0] rapor ID olmalidir.
        public void Write(byte[] data, int timeoutMs)
        {
            if (!IsOpen) throw new InvalidOperationException("Cihaz acik degil.");
            byte[] buf = new byte[OutputLen];
            Array.Copy(data, buf, Math.Min(data.Length, OutputLen));

            IntPtr ev = HidCore.CreateEvent(IntPtr.Zero, true, false, null);
            IntPtr pOv = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(HidCore.OVERLAPPED)));
            try
            {
                HidCore.OVERLAPPED ov = new HidCore.OVERLAPPED();
                ov.hEvent = ev;
                Marshal.StructureToPtr(ov, pOv, false);

                uint written = 0;
                bool ok = HidCore.WriteFile(handle, buf, (uint)buf.Length, out written, pOv);
                if (!ok)
                {
                    int err = Marshal.GetLastWin32Error();
                    if (err != 997) // ERROR_IO_PENDING
                        throw new InvalidOperationException("WriteFile hatasi: " + err);

                    uint wait = HidCore.WaitForSingleObject(ev, (uint)timeoutMs);
                    if (wait != 0)
                    {
                        HidCore.CancelIoEx(handle, pOv);
                        throw new TimeoutException("Yazma zaman asimi (" + timeoutMs + " ms).");
                    }
                    if (!HidCore.GetOverlappedResult(handle, pOv, out written, false))
                        throw new InvalidOperationException("GetOverlappedResult (write) hatasi: " + Marshal.GetLastWin32Error());
                }
            }
            finally
            {
                Marshal.FreeHGlobal(pOv);
                HidCore.CloseHandle(ev);
            }
        }

        // Bir input report okur. Zaman asiminda null doner (exception atmaz).
        public byte[] Read(int timeoutMs)
        {
            if (!IsOpen) throw new InvalidOperationException("Cihaz acik degil.");
            byte[] buf = new byte[InputLen];

            IntPtr ev = HidCore.CreateEvent(IntPtr.Zero, true, false, null);
            IntPtr pOv = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(HidCore.OVERLAPPED)));
            try
            {
                HidCore.OVERLAPPED ov = new HidCore.OVERLAPPED();
                ov.hEvent = ev;
                Marshal.StructureToPtr(ov, pOv, false);

                uint read = 0;
                bool ok = HidCore.ReadFile(handle, buf, (uint)buf.Length, out read, pOv);
                if (!ok)
                {
                    int err = Marshal.GetLastWin32Error();
                    if (err != 997) return null;

                    uint wait = HidCore.WaitForSingleObject(ev, (uint)timeoutMs);
                    if (wait != 0)
                    {
                        HidCore.CancelIoEx(handle, pOv);
                        return null;
                    }
                    if (!HidCore.GetOverlappedResult(handle, pOv, out read, false))
                        return null;
                }
                if (read == 0) return null;
                byte[] outBuf = new byte[read];
                Array.Copy(buf, outBuf, (int)read);
                return outBuf;
            }
            finally
            {
                Marshal.FreeHGlobal(pOv);
                HidCore.CloseHandle(ev);
            }
        }

        public void Dispose()
        {
            if (IsOpen) { HidCore.CloseHandle(handle); handle = new IntPtr(-1); }
        }
    }

    public static class HidCore
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct OVERLAPPED
        {
            public IntPtr Internal; public IntPtr InternalHigh;
            public uint Offset; public uint OffsetHigh; public IntPtr hEvent;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        struct SP_DEVICE_INTERFACE_DETAIL_DATA { public int cbSize; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string DevicePath; }

        [StructLayout(LayoutKind.Sequential)]
        struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID; public ushort ProductID; public ushort VersionNumber; }

        [StructLayout(LayoutKind.Sequential)]
        struct HIDP_CAPS
        {
            public ushort Usage; public ushort UsagePage;
            public ushort InputReportByteLength; public ushort OutputReportByteLength; public ushort FeatureReportByteLength;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
            public ushort NumberLinkCollectionNodes;
            public ushort NumberInputButtonCaps; public ushort NumberInputValueCaps; public ushort NumberInputDataIndices;
            public ushort NumberOutputButtonCaps; public ushort NumberOutputValueCaps; public ushort NumberOutputDataIndices;
            public ushort NumberFeatureButtonCaps; public ushort NumberFeatureValueCaps; public ushort NumberFeatureDataIndices;
        }

        [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
        [DllImport("hid.dll")] static extern bool HidD_GetAttributes(IntPtr h, ref HIDD_ATTRIBUTES a);
        [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr pp);
        [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr pp);
        [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr pp, out HIDP_CAPS caps);
        [DllImport("hid.dll", CharSet = CharSet.Unicode)] static extern bool HidD_GetProductString(IntPtr h, StringBuilder b, int len);

        [DllImport("setupapi.dll", CharSet = CharSet.Auto)] static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr h, int f);
        [DllImport("setupapi.dll", CharSet = CharSet.Auto)] static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref Guid g, int i, ref SP_DEVICE_INTERFACE_DATA da);
        [DllImport("setupapi.dll", CharSet = CharSet.Auto)] static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr s, ref SP_DEVICE_INTERFACE_DATA da, ref SP_DEVICE_INTERFACE_DETAIL_DATA dd, int sz, ref int req, IntPtr dev);
        [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        internal static extern IntPtr CreateFile(string n, uint acc, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool ReadFile(IntPtr h, byte[] b, uint n, out uint read, IntPtr ov);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool WriteFile(IntPtr h, byte[] b, uint n, out uint written, IntPtr ov);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetOverlappedResult(IntPtr h, IntPtr ov, out uint n, bool wait);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool CancelIoEx(IntPtr h, IntPtr ov);
        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)] internal static extern IntPtr CreateEvent(IntPtr attr, bool manualReset, bool initialState, string name);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern uint WaitForSingleObject(IntPtr h, uint ms);

        const uint GENERIC_READ = 0x80000000;
        const uint GENERIC_WRITE = 0x40000000;
        const uint FILE_SHARE_RW = 0x00000003;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_OVERLAPPED = 0x40000000;

        // Sistemdeki tum HID arayuzlerini listeler (salt okunur, hicbir sey gondermez).
        public static List<HidInfo> Enumerate()
        {
            var results = new List<HidInfo>();
            Guid hidGuid; HidD_GetHidGuid(out hidGuid);
            IntPtr set = SetupDiGetClassDevs(ref hidGuid, IntPtr.Zero, IntPtr.Zero, 0x12);
            if (set == new IntPtr(-1)) return results;

            for (int i = 0; ; i++)
            {
                var did = new SP_DEVICE_INTERFACE_DATA();
                did.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref hidGuid, i, ref did)) break;

                var dd = new SP_DEVICE_INTERFACE_DETAIL_DATA();
                dd.cbSize = (IntPtr.Size == 8) ? 8 : 4 + Marshal.SystemDefaultCharSize;
                int req = 0;
                if (!SetupDiGetDeviceInterfaceDetail(set, ref did, ref dd, Marshal.SizeOf(dd), ref req, IntPtr.Zero)) continue;

                var info = new HidInfo();
                info.Path = dd.DevicePath;

                IntPtr h = CreateFile(dd.DevicePath, 0, FILE_SHARE_RW, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                if (h != new IntPtr(-1))
                {
                    var attr = new HIDD_ATTRIBUTES(); attr.Size = Marshal.SizeOf(typeof(HIDD_ATTRIBUTES));
                    if (HidD_GetAttributes(h, ref attr)) { info.Vid = attr.VendorID; info.Pid = attr.ProductID; }
                    var sb = new StringBuilder(256);
                    if (HidD_GetProductString(h, sb, 512)) info.Product = sb.ToString();

                    IntPtr pp;
                    if (HidD_GetPreparsedData(h, out pp))
                    {
                        HIDP_CAPS caps;
                        if (HidP_GetCaps(pp, out caps) == 0x110000)
                        {
                            info.UsagePage = caps.UsagePage; info.Usage = caps.Usage;
                            info.InputLen = caps.InputReportByteLength;
                            info.OutputLen = caps.OutputReportByteLength;
                            info.FeatureLen = caps.FeatureReportByteLength;
                        }
                        HidD_FreePreparsedData(pp);
                    }
                    CloseHandle(h);
                    results.Add(info);
                }
            }
            SetupDiDestroyDeviceInfoList(set);
            return results;
        }

        // VID/PID/UsagePage'e gore ilk eslesen arayuzu bulur.
        public static HidInfo Find(ushort vid, ushort pid, ushort usagePage)
        {
            foreach (var d in Enumerate())
                if (d.Vid == vid && d.Pid == pid && d.UsagePage == usagePage)
                    return d;
            return null;
        }

        public static HidDevice Open(HidInfo info)
        {
            IntPtr h = CreateFile(info.Path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_RW,
                                  IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);
            if (h == new IntPtr(-1))
                throw new InvalidOperationException("Cihaz acilamadi (Win32 hata " + Marshal.GetLastWin32Error() + "): " + info.Path);
            return new HidDevice(h, info.Path, info.InputLen, info.OutputLen);
        }
    }
}
'@
}
