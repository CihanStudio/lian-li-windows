# PawnIO.ps1 - PawnIO cekirdek surucusu uzerinden dusuk seviye donanim erisimi.
#
# PawnIO, imzalanmis Pawn bytecode modullerini cekirdekte SANDBOX icinde calistirir.
# Modul .bin dosyalari surucuye yuklenir, sonra isimle fonksiyon cagrilir.
#
# Kurulum: winget install --id namazso.PawnIO -e
# Kutuphane: C:\Program Files\PawnIO\PawnIOLib.dll  (System32'de DEGIL)
#
# SMBUS GUVENLIK NOTU
#   SMBus'a erisen her islem oncesinde "Access_SMBUS.HTP.Method" mutex'i alinmalidir.
#   Bu mutex BIOS/ACPI ile ayni anda SMBus'a erisilmesini engeller; alinmazsa
#   veri bozulmasi veya sistem kilitlenmesi olabilir.

if (-not ('PawnIO.Lib' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace PawnIO
{
    public static class Lib
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr LoadLibraryW(string path);

        [DllImport("PawnIOLib.dll")] static extern int pawnio_version(out uint version);
        [DllImport("PawnIOLib.dll")] static extern int pawnio_open(out IntPtr handle);
        [DllImport("PawnIOLib.dll")] static extern int pawnio_load(IntPtr handle, byte[] blob, IntPtr size);
        [DllImport("PawnIOLib.dll")] static extern int pawnio_execute(
            IntPtr handle,
            [MarshalAs(UnmanagedType.LPStr)] string name,
            ulong[] input, IntPtr inSize,
            ulong[] output, IntPtr outSize,
            out IntPtr returnSize);
        [DllImport("PawnIOLib.dll")] static extern int pawnio_close(IntPtr handle);

        static bool loaded = false;

        // PawnIOLib.dll System32'de olmadigi icin once tam yoldan yuklenmeli.
        public static void EnsureLoaded()
        {
            if (loaded) return;
            string[] adaylar = new string[] {
                @"C:\Program Files\PawnIO\PawnIOLib.dll",
                @"C:\Windows\System32\PawnIOLib.dll"
            };
            foreach (var p in adaylar)
            {
                if (System.IO.File.Exists(p) && LoadLibraryW(p) != IntPtr.Zero) { loaded = true; return; }
            }
            throw new InvalidOperationException(
                "PawnIOLib.dll bulunamadi. Kurulum: winget install --id namazso.PawnIO -e");
        }

        public static uint Version()
        {
            EnsureLoaded();
            uint v;
            int hr = pawnio_version(out v);
            if (hr != 0) throw new InvalidOperationException("pawnio_version HRESULT 0x" + hr.ToString("X8"));
            return v;
        }

        public static IntPtr Open()
        {
            EnsureLoaded();
            IntPtr h;
            int hr = pawnio_open(out h);
            if (hr != 0) throw new InvalidOperationException("pawnio_open HRESULT 0x" + hr.ToString("X8"));
            return h;
        }

        public static void Load(IntPtr handle, byte[] blob)
        {
            int hr = pawnio_load(handle, blob, new IntPtr(blob.Length));
            if (hr != 0) throw new InvalidOperationException("pawnio_load HRESULT 0x" + hr.ToString("X8"));
        }

        // Basarisizsa exception atar. outCount = beklenen cikis hucre sayisi.
        public static ulong[] Execute(IntPtr handle, string name, ulong[] input, int outCount)
        {
            if (input == null) input = new ulong[0];
            ulong[] output = new ulong[Math.Max(outCount, 1)];
            IntPtr retSize;
            int hr = pawnio_execute(handle, name,
                                    input, new IntPtr(input.Length),
                                    output, new IntPtr(outCount),
                                    out retSize);
            if (hr != 0)
                throw new InvalidOperationException("pawnio_execute('" + name + "') HRESULT 0x" + hr.ToString("X8"));

            int n = retSize.ToInt32();
            if (n < 0) n = 0;
            if (n > outCount) n = outCount;
            ulong[] sonuc = new ulong[n];
            Array.Copy(output, sonuc, n);
            return sonuc;
        }

        // Hata durumunda exception atmadan HRESULT dondurur (tarama gibi islemler icin).
        public static int TryExecute(IntPtr handle, string name, ulong[] input, int outCount, out ulong[] result)
        {
            if (input == null) input = new ulong[0];
            ulong[] output = new ulong[Math.Max(outCount, 1)];
            IntPtr retSize;
            int hr = pawnio_execute(handle, name,
                                    input, new IntPtr(input.Length),
                                    output, new IntPtr(outCount),
                                    out retSize);
            if (hr != 0) { result = new ulong[0]; return hr; }

            int n = retSize.ToInt32();
            if (n < 0) n = 0;
            if (n > outCount) n = outCount;
            result = new ulong[n];
            Array.Copy(output, result, n);
            return 0;
        }

        public static void Close(IntPtr handle)
        {
            if (handle != IntPtr.Zero) pawnio_close(handle);
        }
    }
}
'@ -ErrorAction Stop
}

$script:PawnIOModuleDir = Join-Path (Split-Path $PSScriptRoot -Parent) "modules"

function Get-PawnIOVersion {
    $v = [PawnIO.Lib]::Version()
    return ("{0}.{1}.{2}" -f (($v -shr 16) -band 0xFFFF), (($v -shr 8) -band 0xFF), ($v -band 0xFF))
}

function Open-PawnIOModule {
    <# Modul .bin dosyasini yukler ve calistirici handle'ini dondurur. #>
    param([Parameter(Mandatory)][string]$ModuleName)

    $path = Join-Path $script:PawnIOModuleDir $ModuleName
    if (-not (Test-Path $path)) { throw "Module not found: $path" }

    $blob = [System.IO.File]::ReadAllBytes($path)
    $h = [PawnIO.Lib]::Open()
    try {
        [PawnIO.Lib]::Load($h, $blob)
    } catch {
        [PawnIO.Lib]::Close($h)
        throw
    }
    return $h
}

function Close-PawnIOModule {
    param([IntPtr]$Handle)
    if ($Handle -and $Handle -ne [IntPtr]::Zero) { [PawnIO.Lib]::Close($Handle) }
}

# ---------------- SMBus mutex ----------------
# Cekirdek modulunun bekledigi mutex: \BaseNamedObjects\Access_SMBUS.HTP.Method
# Win32 karsiligi: Global\Access_SMBUS.HTP.Method

function Get-SmbusMutex {
    foreach ($ad in @('Global\Access_SMBUS.HTP.Method', 'Access_SMBUS.HTP.Method')) {
        try {
            $olusturuldu = $false
            $m = New-Object System.Threading.Mutex($false, $ad, [ref]$olusturuldu)
            return $m
        } catch {
            continue
        }
    }
    return $null
}

function Invoke-WithSmbusLock {
    <#
      SMBus mutex'ini alip verilen script blogunu calistirir, sonra mutlaka birakir.
      Mutex alinamazsa islemi CALISTIRMAZ - bu bilincli bir guvenlik karari.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$TimeoutMs = 5000
    )

    $m = Get-SmbusMutex
    if ($null -eq $m) { throw "Could not create the SMBus mutex; the operation is unsafe and was cancelled." }

    $alindi = $false
    try {
        try { $alindi = $m.WaitOne($TimeoutMs) }
        catch [System.Threading.AbandonedMutexException] { $alindi = $true }  # onceki sahibi cokmus, biz devraliyoruz

        if (-not $alindi) { throw "Could not acquire the SMBus mutex within $TimeoutMs ms; another process is using the bus." }
        & $Action
    }
    finally {
        if ($alindi) { try { $m.ReleaseMutex() } catch {} }
        $m.Dispose()
    }
}
