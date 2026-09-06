# NvApi.ps1 - NVIDIA GPU fan/sicaklik erisimi.
#
# nvapi64.dll GPU SURUCUSUYLE BIRLIKTE GELIR - ayrica kurulum gerektirmez.
# Fonksiyonlar disari acik degildir; nvapi_QueryInterface(id) ile fonksiyon
# isaretcisi alinir. Kullanilan ID'ler acik kaynak projelerden dogrulanmistir.
#
# Yapilar ic ice dizi icerdigi icin .NET marshalling'i yerine HAM BAYT TAMPONU
# kullaniliyor; alanlar ofsetten okunuyor. Bu, yanlis yapi boyutundan kaynaklanan
# sessiz bozulmalari onler.
#
# Yapi boyutlari (version alani = boyut | (surum << 16)):
#   NvGpuFanCoolersStatus  : 4 + 4 + 32 + 32*52 = 1704   (surum 1)
#   NvGpuFanCoolersControl : 4 + 4 + 4 + 32 + 32*44 = 1452 (surum 1)
#   NV_GPU_THERMAL_SETTINGS_V2 : 4 + 4 + 3*20 = 68        (surum 2)

if (-not ('Nv.Api' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Nv
{
    public class GpuFan
    {
        public uint Id;
        public uint Rpm;
        public uint Min;
        public uint Max;
        public uint Level;      // mevcut yuzde
    }

    public class GpuInfo
    {
        public IntPtr Handle;
        public int Index;
        public int TempC;
        public List<GpuFan> Fans = new List<GpuFan>();
    }

    public static class Api
    {
        [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
        static extern IntPtr QueryInterface(uint id);

        // --- QueryInterface fonksiyon ID'leri ---
        const uint ID_Initialize                  = 0x0150E828;
        const uint ID_Unload                      = 0xD22BDD7E;
        const uint ID_EnumPhysicalGPUs            = 0xE5AC921F;
        const uint ID_GPU_GetThermalSettings      = 0xE3640A56;
        const uint ID_GPU_GetTachReading          = 0x5F608315;
        const uint ID_ClientFanCoolersGetStatus   = 0x35AED5E8;
        const uint ID_ClientFanCoolersGetControl  = 0x814B209F;
        const uint ID_ClientFanCoolersSetControl  = 0xA58971A5;
        const uint ID_GPU_GetFullName             = 0xCEEE8E9F;
        const uint ID_GPU_GetDynamicPstatesInfoEx = 0x60DED2ED;
        const uint ID_GPU_GetAllClockFrequencies  = 0xDCB616C3;
        const uint ID_GPU_GetMemoryInfo           = 0x07F9B368;

        // --- Yapi boyutlari ve surum degerleri ---
        const int STATUS_SIZE   = 1704;
        const int STATUS_COOLER = 52;
        const int STATUS_BASE   = 40;

        const int CONTROL_SIZE   = 1452;
        const int CONTROL_COOLER = 44;
        const int CONTROL_BASE   = 44;

        const int THERMAL_SIZE = 68;

        static uint MakeVersion(int size, uint ver) { return (uint)size | (ver << 16); }

        delegate int FnVoid();
        delegate int FnEnum(IntPtr handles, out int count);
        delegate int FnBuf(IntPtr gpu, IntPtr buf);
        delegate int FnThermal(IntPtr gpu, uint sensorIndex, IntPtr buf);
        delegate int FnTach(IntPtr gpu, out uint value);

        static T Get<T>(uint id) where T : class
        {
            IntPtr p = QueryInterface(id);
            if (p == IntPtr.Zero) return null;
            return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
        }

        static bool initialized = false;

        // Hangi fonksiyon ID'lerinin cozulebildigini raporlar (salt kontrol).
        public static Dictionary<string, bool> Probe()
        {
            var d = new Dictionary<string, bool>();
            d["Initialize"]                 = QueryInterface(ID_Initialize) != IntPtr.Zero;
            d["EnumPhysicalGPUs"]           = QueryInterface(ID_EnumPhysicalGPUs) != IntPtr.Zero;
            d["GPU_GetThermalSettings"]     = QueryInterface(ID_GPU_GetThermalSettings) != IntPtr.Zero;
            d["GPU_GetTachReading"]         = QueryInterface(ID_GPU_GetTachReading) != IntPtr.Zero;
            d["ClientFanCoolersGetStatus"]  = QueryInterface(ID_ClientFanCoolersGetStatus) != IntPtr.Zero;
            d["ClientFanCoolersGetControl"] = QueryInterface(ID_ClientFanCoolersGetControl) != IntPtr.Zero;
            d["ClientFanCoolersSetControl"] = QueryInterface(ID_ClientFanCoolersSetControl) != IntPtr.Zero;
            return d;
        }

        public static void Init()
        {
            if (initialized) return;
            var fn = Get<FnVoid>(ID_Initialize);
            if (fn == null) throw new InvalidOperationException("NvAPI_Initialize cozulemedi.");
            int r = fn();
            if (r != 0) throw new InvalidOperationException("NvAPI_Initialize hata kodu: " + r);
            initialized = true;
        }

        public static List<IntPtr> EnumGpus()
        {
            Init();
            var fn = Get<FnEnum>(ID_EnumPhysicalGPUs);
            if (fn == null) throw new InvalidOperationException("NvAPI_EnumPhysicalGPUs cozulemedi.");

            IntPtr buf = Marshal.AllocHGlobal(64 * IntPtr.Size);
            try
            {
                int count = 0;
                int r = fn(buf, out count);
                if (r != 0) throw new InvalidOperationException("EnumPhysicalGPUs hata kodu: " + r);

                var list = new List<IntPtr>();
                for (int i = 0; i < count; i++)
                    list.Add(Marshal.ReadIntPtr(buf, i * IntPtr.Size));
                return list;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        // GPU sicakligi (santigrat). Basarisizsa -1.
        public static int GetTemp(IntPtr gpu)
        {
            var fn = Get<FnThermal>(ID_GPU_GetThermalSettings);
            if (fn == null) return -1;

            IntPtr buf = Marshal.AllocHGlobal(THERMAL_SIZE);
            try
            {
                for (int i = 0; i < THERMAL_SIZE; i++) Marshal.WriteByte(buf, i, 0);
                Marshal.WriteInt32(buf, 0, (int)MakeVersion(THERMAL_SIZE, 2));

                int r = fn(gpu, 0, buf);   // sensorIndex 0
                if (r != 0) return -1;

                int count = Marshal.ReadInt32(buf, 4);
                if (count < 1) return -1;
                // sensors[0]: +0 controller, +4 defaultMin, +8 defaultMax, +12 currentTemp, +16 target
                return Marshal.ReadInt32(buf, 8 + 12);
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        // Fan durumu: id / rpm / min / max / mevcut seviye
        public static List<GpuFan> GetFans(IntPtr gpu)
        {
            var list = new List<GpuFan>();
            var fn = Get<FnBuf>(ID_ClientFanCoolersGetStatus);
            if (fn == null) return list;

            IntPtr buf = Marshal.AllocHGlobal(STATUS_SIZE);
            try
            {
                for (int i = 0; i < STATUS_SIZE; i++) Marshal.WriteByte(buf, i, 0);
                Marshal.WriteInt32(buf, 0, (int)MakeVersion(STATUS_SIZE, 1));

                int r = fn(gpu, buf);
                if (r != 0) return list;

                int count = Marshal.ReadInt32(buf, 4);
                for (int i = 0; i < count && i < 32; i++)
                {
                    int b = STATUS_BASE + i * STATUS_COOLER;
                    list.Add(new GpuFan {
                        Id    = (uint)Marshal.ReadInt32(buf, b + 0),
                        Rpm   = (uint)Marshal.ReadInt32(buf, b + 4),
                        Min   = (uint)Marshal.ReadInt32(buf, b + 8),
                        Max   = (uint)Marshal.ReadInt32(buf, b + 12),
                        Level = (uint)Marshal.ReadInt32(buf, b + 16)
                    });
                }
                return list;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        // --- GPU adi ---
        delegate int FnName(IntPtr gpu, System.Text.StringBuilder name);

        public static string GetName(IntPtr gpu)
        {
            var fn = Get<FnName>(ID_GPU_GetFullName);
            if (fn == null) return null;
            var sb = new System.Text.StringBuilder(64);   // NvAPI_ShortString = char[64]
            return fn(gpu, sb) == 0 ? sb.ToString() : null;
        }

        // --- Kullanim oranlari ---
        // NV_GPU_DYNAMIC_PSTATES_INFO_EX: version, flags, utilization[8]{present, yuzde}
        // Boyut = 4 + 4 + 8*8 = 72.  Indisler: 0=GPU, 1=Bellek denetleyici, 2=Video, 3=Veriyolu
        const int PSTATE_SIZE = 72;

        public static Dictionary<string, int> GetUtilization(IntPtr gpu)
        {
            var d = new Dictionary<string, int>();
            var fn = Get<FnBuf>(ID_GPU_GetDynamicPstatesInfoEx);
            if (fn == null) return d;

            IntPtr buf = Marshal.AllocHGlobal(PSTATE_SIZE);
            try
            {
                for (int i = 0; i < PSTATE_SIZE; i++) Marshal.WriteByte(buf, i, 0);
                Marshal.WriteInt32(buf, 0, (int)MakeVersion(PSTATE_SIZE, 1));
                if (fn(gpu, buf) != 0) return d;

                string[] adlar = { "Gpu", "Bellek", "Video", "Veriyolu" };
                for (int i = 0; i < adlar.Length; i++)
                {
                    int b = 8 + i * 8;
                    if (Marshal.ReadInt32(buf, b) == 0) continue;         // present degil
                    int yuzde = Marshal.ReadInt32(buf, b + 4);
                    if (yuzde >= 0 && yuzde <= 100) d[adlar[i]] = yuzde;
                }
                return d;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        // --- Saat frekanslari ---
        // NV_GPU_CLOCK_FREQUENCIES: version, ClockType, domain[32]{present, kHz}
        // Boyut = 4 + 4 + 32*8 = 264.  Alan indisleri: 0=Grafik, 4=Bellek, 7=Islemci, 8=Video
        const int CLOCK_SIZE = 264;

        public static Dictionary<string, int> GetClocksMHz(IntPtr gpu)
        {
            var d = new Dictionary<string, int>();
            var fn = Get<FnBuf>(ID_GPU_GetAllClockFrequencies);
            if (fn == null) return d;

            IntPtr buf = Marshal.AllocHGlobal(CLOCK_SIZE);
            try
            {
                for (int i = 0; i < CLOCK_SIZE; i++) Marshal.WriteByte(buf, i, 0);
                Marshal.WriteInt32(buf, 0, (int)MakeVersion(CLOCK_SIZE, 3));
                Marshal.WriteInt32(buf, 4, 0);    // ClockType 0 = mevcut frekans
                if (fn(gpu, buf) != 0) return d;

                var alan = new Dictionary<int, string> { { 0, "Grafik" }, { 4, "Bellek" }, { 7, "Islemci" }, { 8, "Video" } };
                foreach (var kv in alan)
                {
                    int b = 8 + kv.Key * 8;
                    if ((Marshal.ReadInt32(buf, b) & 1) == 0) continue;   // present biti
                    int khz = Marshal.ReadInt32(buf, b + 4);
                    if (khz > 0) d[kv.Value] = khz / 1000;
                }
                return d;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        // --- Video bellegi (KB cinsinden gelir) ---
        // NV_DISPLAY_DRIVER_MEMORY_INFO_V2: version + 5 alan = 24 bayt
        const int MEMINFO_SIZE = 24;

        public static Dictionary<string, int> GetMemoryMB(IntPtr gpu)
        {
            var d = new Dictionary<string, int>();
            var fn = Get<FnBuf>(ID_GPU_GetMemoryInfo);
            if (fn == null) return d;

            IntPtr buf = Marshal.AllocHGlobal(MEMINFO_SIZE);
            try
            {
                for (int i = 0; i < MEMINFO_SIZE; i++) Marshal.WriteByte(buf, i, 0);
                Marshal.WriteInt32(buf, 0, (int)MakeVersion(MEMINFO_SIZE, 2));
                if (fn(gpu, buf) != 0) return d;

                int toplamKb = Marshal.ReadInt32(buf, 4);     // dedicatedVideoMemory
                int bosKb    = Marshal.ReadInt32(buf, 20);    // curAvailableDedicatedVideoMemory
                if (toplamKb <= 0) return d;

                d["ToplamMB"] = toplamKb / 1024;
                if (bosKb > 0 && bosKb <= toplamKb)
                {
                    d["BosMB"]      = bosKb / 1024;
                    d["KullanilanMB"] = (toplamKb - bosKb) / 1024;
                }
                return d;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        // Sik karsilasilan NVAPI durum kodlari.
        public static string StatusText(int code)
        {
            switch (code)
            {
                case 0:     return "OK";
                case -1:    return "NVAPI_ERROR";
                case -3:    return "NVAPI_NO_IMPLEMENTATION";
                case -4:    return "NVAPI_API_NOT_INITIALIZED";
                case -5:    return "NVAPI_INVALID_ARGUMENT";
                case -6:    return "NVAPI_NVIDIA_DEVICE_NOT_FOUND";
                case -8:    return "NVAPI_INVALID_HANDLE";
                case -9:    return "NVAPI_INCOMPATIBLE_STRUCT_VERSION";
                case -137:  return "NVAPI_INVALID_USER_PRIVILEGE (yonetici yetkisi gerekli)";
                case -1000: return "Fonksiyon ID cozulemedi";
                default:    return "bilinmeyen kod " + code;
            }
        }

        public class SetResult
        {
            public int Code;
            public string Stage;     // "GetControl" veya "SetControl"
            public string Message;
            public int CoolerCount;
            public bool Ok { get { return Code == 0; } }
        }

        // Tum GPU fanlarini ayarlar. manual=false ise surucunun otomatik egrisine birakir.
        public static SetResult SetFans(IntPtr gpu, uint levelPercent, bool manual)
        {
            var res = new SetResult();
            var getCtrl = Get<FnBuf>(ID_ClientFanCoolersGetControl);
            var setCtrl = Get<FnBuf>(ID_ClientFanCoolersSetControl);
            if (getCtrl == null || setCtrl == null)
            {
                res.Code = -1000; res.Stage = "QueryInterface"; res.Message = StatusText(-1000);
                return res;
            }

            IntPtr buf = Marshal.AllocHGlobal(CONTROL_SIZE);
            try
            {
                for (int i = 0; i < CONTROL_SIZE; i++) Marshal.WriteByte(buf, i, 0);
                Marshal.WriteInt32(buf, 0, (int)MakeVersion(CONTROL_SIZE, 1));

                // Once mevcut kontrol blogunu oku (fan id'lerini korumak icin)
                int r = getCtrl(gpu, buf);
                if (r != 0)
                {
                    res.Code = r; res.Stage = "GetControl"; res.Message = StatusText(r);
                    return res;
                }

                int count = Marshal.ReadInt32(buf, 8);
                res.CoolerCount = count;
                for (int i = 0; i < count && i < 32; i++)
                {
                    int b = CONTROL_BASE + i * CONTROL_COOLER;
                    Marshal.WriteInt32(buf, b + 4, (int)levelPercent);   // level
                    Marshal.WriteInt32(buf, b + 8, manual ? 1 : 0);      // mode: 0=AUTO, 1=MANUAL
                }

                // Surum alanini tekrar yaz (get cagrisi degistirmis olabilir)
                Marshal.WriteInt32(buf, 0, (int)MakeVersion(CONTROL_SIZE, 1));
                int r2 = setCtrl(gpu, buf);
                res.Code = r2; res.Stage = "SetControl"; res.Message = StatusText(r2);
                return res;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }
    }
}
'@ -ErrorAction Stop
}

function Get-NvProbe   { [Nv.Api]::Probe() }
function Get-NvGpus    { [Nv.Api]::EnumGpus() }
function Get-NvTemp    { param([Parameter(Mandatory)][IntPtr]$Gpu) [Nv.Api]::GetTemp($Gpu) }
function Get-NvFans    { param([Parameter(Mandatory)][IntPtr]$Gpu) [Nv.Api]::GetFans($Gpu) }
function Get-NvName    { param([Parameter(Mandatory)][IntPtr]$Gpu) [Nv.Api]::GetName($Gpu) }
function Get-NvUsage   { param([Parameter(Mandatory)][IntPtr]$Gpu) [Nv.Api]::GetUtilization($Gpu) }
function Get-NvClocks  { param([Parameter(Mandatory)][IntPtr]$Gpu) [Nv.Api]::GetClocksMHz($Gpu) }
function Get-NvMemory  { param([Parameter(Mandatory)][IntPtr]$Gpu) [Nv.Api]::GetMemoryMB($Gpu) }
function Set-NvFans {
    param(
        [Parameter(Mandatory)][IntPtr]$Gpu,
        [ValidateRange(0,100)][int]$Percent = 0,
        [switch]$Auto
    )
    [Nv.Api]::SetFans($Gpu, [uint32]$Percent, (-not $Auto))
}
