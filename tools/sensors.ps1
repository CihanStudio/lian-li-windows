# sensors.ps1 - Makineden okunabilen TUM degerleri tek yerde toplar.
#
# KULLANIM
#   .\sensors.ps1           Okunabilir tablo
#   .\sensors.ps1 -Json     Arayuz/otomasyon icin JSON
#
# YETKI
#   Yonetici GEREKMEZ: GPU (NVAPI), Lian Li fanlar/pompa (USB HID), Windows sayaclari.
#   Yonetici GEREKIR : CPU sicakligi ve gucu (PawnIO cekirdek modulu).
#   Yetki yoksa CPU bolumu UYDURULMAZ - "yonetici gerekli" diye isaretlenir.
#
# SALT OKUMA: bu betik hicbir donanim ayarini degistirmez.

[CmdletBinding()]
param([switch]$Json)

$ErrorActionPreference = 'Stop'
$libDir = Join-Path $PSScriptRoot "..\lib"
. (Join-Path $libDir "LianLiTL.ps1")
. (Join-Path $libDir "LianLiGA2.ps1")
. (Join-Path $libDir "NvApi.ps1")

function Test-Yonetici {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

$S = [ordered]@{
    Zaman   = (Get-Date).ToString('s')
    Yonetici = Test-Yonetici
    Cpu     = [ordered]@{}
    Gpu     = [ordered]@{}
    Fanlar  = [ordered]@{}
    Bellek  = [ordered]@{}
    Disk    = @()
    Notlar  = @()
}

# =====================================================================
# CPU
# =====================================================================
$ci = Get-CimInstance Win32_Processor | Select-Object -First 1
$S.Cpu.Ad        = $ci.Name.Trim()
$S.Cpu.Cekirdek  = $ci.NumberOfCores
$S.Cpu.Mantiksal = $ci.NumberOfLogicalProcessors
$S.Cpu.TabanMHz  = $ci.MaxClockSpeed

# Yuk ve efektif saat - yonetici gerektirmez (Windows performans sayaclari)
try {
    $pf = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation `
          -Filter "Name='_Total'" -ErrorAction Stop | Select-Object -First 1
    if ($pf) {
        $S.Cpu.YukYuzde = [int]$pf.PercentProcessorTime
        # Efektif saat = taban * (performans yuzdesi / 100); turbo'da 100'un ustune cikar
        $S.Cpu.EfektifMHz = [int]($ci.MaxClockSpeed * $pf.PercentProcessorPerformance / 100.0)
    }
} catch { $S.Notlar += "CPU performans sayaclari okunamadi: $($_.Exception.Message)" }

# Sicaklik / guc - PawnIO, yonetici sart
if ($S.Yonetici) {
    try {
        . (Join-Path $libDir "AmdCpu.ps1")
        $h = [IntPtr]::Zero
        try {
            $h = Open-AmdCpuModule
            $t = Get-AmdCpuTemperature -Handle $h
            if ($t.Ok) {
                $S.Cpu.TctlC = $t.Tctl
                if ($t.Ccd.Count -gt 0) { $S.Cpu.CcdC = @($t.Ccd | ForEach-Object { $_.TempC }) }

                # Iki sensor de gecerli ama AYNI SEYI olcmuyor ve bu makinede
                # aralarinda ~10 C fark var (Tctl daha yuksek):
                #   Tctl : AMD'nin fan kontrolu icin urettigi, filtrelenmis sicak nokta
                #   CCD  : cekirdek kompleksinin ham die sicakligi
                # Fan egrisi TCTL'e baglanir - dusuk olani baz almak yetersiz
                # sogutmaya yol acar. CCD ayrica bilgi olarak tutulur.
                $S.Cpu.SicaklikC = $t.Tctl
            }
            $w = Get-AmdCpuPower -Handle $h -SampleMs 400
            if ($null -ne $w) { $S.Cpu.GucW = $w }
        }
        finally { Close-PawnIOModule -Handle $h }
    }
    catch { $S.Notlar += "CPU sicakligi okunamadi: $($_.Exception.Message)" }
}
else {
    $S.Cpu.SicaklikC = $null
    $S.Cpu.Not = "CPU sicakligi/gucu icin yonetici yetkisi gerekli (PawnIO)"
}

# =====================================================================
# GPU
# =====================================================================
try {
    $gpus = Get-NvGpus
    if ($gpus.Count -gt 0) {
        $g = $gpus[0]
        $S.Gpu.Ad        = Get-NvName   -Gpu $g
        $S.Gpu.SicaklikC = Get-NvTemp   -Gpu $g

        $gf = Get-NvFans -Gpu $g
        $S.Gpu.FanRpm    = @($gf | ForEach-Object { [int]$_.Rpm })
        $S.Gpu.FanYuzde  = if ($gf.Count -gt 0) { [int]$gf[0].Level } else { $null }
        $S.Gpu.FanAralik = if ($gf.Count -gt 0) { "$($gf[0].Min)-$($gf[0].Max)" } else { $null }

        $ku = Get-NvUsage -Gpu $g
        foreach ($k in $ku.Keys) { $S.Gpu["Yuk$k"] = $ku[$k] }

        $sa = Get-NvClocks -Gpu $g
        foreach ($k in $sa.Keys) { $S.Gpu["Saat$k`MHz"] = $sa[$k] }

        $mem = Get-NvMemory -Gpu $g
        foreach ($k in $mem.Keys) { $S.Gpu["Vram$k"] = $mem[$k] }

        $S.Gpu.FanModu = "NVIDIA otomatik"
    }
    else { $S.Notlar += "NVIDIA GPU bulunamadi." }
}
catch { $S.Notlar += "GPU okunamadi: $($_.Exception.Message)" }

# =====================================================================
# FANLAR / POMPA  (Lian Li USB HID - yonetici gerektirmez)
# =====================================================================
$tlDev = $null; $ga2Dev = $null
try {
    $tlInfo = Get-TLDeviceInfo
    if ($tlInfo) {
        $tlDev = [LianLi.HidCore]::Open($tlInfo)
        $hs = Get-TLFans -Device $tlDev
        if ($hs) {
            $bulunan = @($hs.Fans | Where-Object { $_.Detected } | Sort-Object Port, FanIndex)
            $S.Fanlar.TlRpm   = @($bulunan | ForEach-Object { [int]$_.RPM })
            $S.Fanlar.TlSayi  = $bulunan.Count
            if ($bulunan.Count -gt 0) {
                $S.Fanlar.TlOrtRpm = [int](($bulunan | Measure-Object RPM -Average).Average)
            }
        }
    }
    else { $S.Notlar += "TL fan kontrolcusu bulunamadi." }

    $ga2Info = Get-GA2DeviceInfo
    if ($ga2Info) {
        $ga2Dev = [LianLi.HidCore]::Open($ga2Info)
        $st = Get-GA2Status -Device $ga2Dev
        if ($st) {
            $S.Fanlar.PompaRpm = [int]$st.PumpRPM
            # AIO'nun kendi fan kanali bu makinede BOS (olculdu) - 0 gelmesi normal
            $S.Fanlar.AioFanRpm = [int]$st.FanRPM
        }
    }
    else { $S.Notlar += "Galahad II AIO bulunamadi." }
}
catch { $S.Notlar += "Lian Li cihazlari okunamadi: $($_.Exception.Message)" }
finally {
    if ($tlDev)  { $tlDev.Dispose() }
    if ($ga2Dev) { $ga2Dev.Dispose() }
}

# =====================================================================
# BELLEK
# =====================================================================
try {
    $dimm = @(Get-CimInstance Win32_PhysicalMemory)
    $S.Bellek.ModulSayisi = $dimm.Count
    $S.Bellek.ToplamGB    = [int](($dimm | Measure-Object Capacity -Sum).Sum / 1GB)
    $S.Bellek.Parca       = ($dimm | Select-Object -First 1).PartNumber
    $S.Bellek.HizMHz      = ($dimm | Select-Object -First 1).ConfiguredClockSpeed

    $os = Get-CimInstance Win32_OperatingSystem
    $S.Bellek.KullanilanGB = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
    $S.Bellek.KullanimYuzde = [int](100 * ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize)
}
catch { $S.Notlar += "Bellek bilgisi okunamadi: $($_.Exception.Message)" }

# =====================================================================
# DISK SICAKLIKLARI  (yetki varsa)
# =====================================================================
try {
    foreach ($d in (Get-PhysicalDisk -ErrorAction Stop)) {
        $rc = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        if ($rc -and $rc.Temperature -gt 0) {
            $S.Disk += [ordered]@{ Ad = $d.FriendlyName; SicaklikC = [int]$rc.Temperature }
        }
    }
}
catch { $S.Notlar += "Disk sicakligi okunamadi: $($_.Exception.Message)" }

# =====================================================================
# CIKTI
# =====================================================================
if ($Json) {
    $S | ConvertTo-Json -Depth 6
    exit 0
}

function Satir { param([string]$Ad, $Deger, [string]$Renk = 'White')
    if ($null -eq $Deger -or "$Deger" -eq '') { return }
    Write-Host ("  {0,-24}: {1}" -f $Ad, $Deger) -ForegroundColor $Renk
}

Write-Host ""
Write-Host "=== CPU ===" -ForegroundColor Cyan
Satir "Islemci"       $S.Cpu.Ad
Satir "Cekirdek"      ("{0} cekirdek / {1} is parcacigi" -f $S.Cpu.Cekirdek, $S.Cpu.Mantiksal)
if ($null -ne $S.Cpu.SicaklikC) {
    Satir "Sicaklik (Tctl)" ("{0} C" -f $S.Cpu.SicaklikC) 'Green'
    if ($S.Cpu.CcdC) { Satir "  CCD die" (($S.Cpu.CcdC | ForEach-Object { "$_ C" }) -join ' / ') 'DarkGray' }
} else {
    Satir "Sicaklik"  $S.Cpu.Not 'Yellow'
}
Satir "Guc"           $(if ($S.Cpu.GucW) { "{0} W" -f $S.Cpu.GucW })  'Green'
Satir "Yuk"           $(if ($null -ne $S.Cpu.YukYuzde) { "%{0}" -f $S.Cpu.YukYuzde })
Satir "Efektif saat"  $(if ($S.Cpu.EfektifMHz) { "{0} MHz  (taban {1})" -f $S.Cpu.EfektifMHz, $S.Cpu.TabanMHz })

Write-Host ""
Write-Host "=== GPU ===" -ForegroundColor Cyan
Satir "Kart"          $S.Gpu.Ad
Satir "Sicaklik"      $(if ($S.Gpu.SicaklikC) { "{0} C" -f $S.Gpu.SicaklikC }) 'Green'
Satir "Fan"           $(if ($S.Gpu.FanRpm) { "{0} RPM   (%{1}, aralik {2})" -f ($S.Gpu.FanRpm -join ' / '), $S.Gpu.FanYuzde, $S.Gpu.FanAralik })
Satir "Yuk"           $(if ($null -ne $S.Gpu.YukGpu) { "%{0}   (bellek %{1})" -f $S.Gpu.YukGpu, $S.Gpu.YukBellek })
Satir "Saat"          $(if ($S.Gpu.SaatGrafikMHz) { "{0} MHz grafik / {1} MHz bellek" -f $S.Gpu.SaatGrafikMHz, $S.Gpu.SaatBellekMHz })
Satir "VRAM"          $(if ($S.Gpu.VramToplamMB) { "{0} / {1} MB" -f $S.Gpu.VramKullanilanMB, $S.Gpu.VramToplamMB })
Satir "Fan modu"      $S.Gpu.FanModu 'DarkGray'

Write-Host ""
Write-Host "=== SOGUTMA ===" -ForegroundColor Cyan
Satir "TL fanlari"    $(if ($S.Fanlar.TlRpm) { "{0} RPM   (ortalama {1})" -f ($S.Fanlar.TlRpm -join ' / '), $S.Fanlar.TlOrtRpm }) 'Green'
Satir "AIO pompasi"   $(if ($S.Fanlar.PompaRpm) { "{0} RPM" -f $S.Fanlar.PompaRpm }) 'Green'
if ($S.Fanlar.AioFanRpm -eq 0) {
    Satir "AIO fan kanali" "0 RPM (bos - radyator fanlari TL kontrolcusunde)" 'DarkGray'
}

Write-Host ""
Write-Host "=== BELLEK ===" -ForegroundColor Cyan
Satir "Moduller"      $(if ($S.Bellek.ModulSayisi) { "{0} x {1}  ({2} GB toplam, {3} MHz)" -f $S.Bellek.ModulSayisi, $S.Bellek.Parca, $S.Bellek.ToplamGB, $S.Bellek.HizMHz })
Satir "Kullanim"      $(if ($null -ne $S.Bellek.KullanimYuzde) { "{0} GB  (%{1})" -f $S.Bellek.KullanilanGB, $S.Bellek.KullanimYuzde })

if ($S.Disk.Count -gt 0) {
    Write-Host ""
    Write-Host "=== DISK ===" -ForegroundColor Cyan
    foreach ($d in $S.Disk) { Satir $d.Ad ("{0} C" -f $d.SicaklikC) 'Green' }
}

if ($S.Notlar.Count -gt 0) {
    Write-Host ""
    Write-Host "=== NOTLAR ===" -ForegroundColor DarkYellow
    foreach ($n in $S.Notlar) { Write-Host ("  - {0}" -f $n) -ForegroundColor DarkGray }
}
Write-Host ""
