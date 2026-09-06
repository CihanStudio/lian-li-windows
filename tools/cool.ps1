# cool.ps1 - Tum sogutma ve isik kontrolu icin TEK komut.
#
# Hicbir ek program veya surucu gerektirmez, YONETICI YETKISI ISTEMEZ.
# Dogrudan Windows'un yerlesik HID yigini uzerinden donanimla konusur.
#
# Kapsam:
#   Lian Li TL fanlari (hiz + RGB)   -> USB HID 0416:7372   [yazilir]
#   Galahad II AIO pompasi           -> USB HID 0416:7373   [yazilir]
#   NVIDIA GPU sicaklik/fan          -> nvapi64.dll         [sadece okunur]
#
# GPU fanlari bilerek NVIDIA'nin otomatik egrisinde birakilmistir: fan yazmak
# yonetici yetkisi ister (NVAPI -137) ve GPU'yu dusuk hizda sabitlemek termal
# risk yaratir. GPU kendi sicakligina gore kendini yonetir.
#
# KULLANIM
#   .\cool.ps1                     Durum
#   .\cool.ps1 -Level 30           Tum fanlar + pompa %30
#   .\cool.ps1 -Quiet              Kisayol: %25
#   .\cool.ps1 -Max                Kisayol: %100
#   .\cool.ps1 -Color 00A0FF       Sabit renk
#   .\cool.ps1 -Level 40 -Color FF0000
#   .\cool.ps1 -Mode Rainbow       Efekt modu
#   .\cool.ps1 -LightsOff          Isiklari kapat
#   .\cool.ps1 -Modes              Efekt listesi
#
# GUVENLIK TABANLARI
#   Pompa fanlarla birlikte duser ama asla %40 altina inmez (-PumpMin ile degisir).
#   Fanlar varsayilan olarak %20 altina inmez (-MinFan 0 ile tamamen serbest birakilir).

[CmdletBinding()]
param(
    [ValidateRange(0,100)] [int]$Level = -1,
    [switch]$Quiet,
    [switch]$Max,
    [string]$Color,
    [string]$Mode,
    [ValidateRange(0,4)] [int]$Brightness = 4,      # TL fanlari icin (4 = en parlak)
    [ValidateRange(0,8)] [int]$AioBrightness = 2,   # AIO icin (olculen calisan deger 2)
    [ValidateRange(0,4)] [int]$Speed = 2,
    [switch]$LightsOff,
    [switch]$Modes,
    [ValidateRange(0,100)] [int]$MinFan  = 20,
    [ValidateRange(40,100)][int]$PumpMin = 40,
    [switch]$NoPump,
    [switch]$NoPumpLight
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "..\lib\LianLiTL.ps1")
. (Join-Path $PSScriptRoot "..\lib\LianLiGA2.ps1")
. (Join-Path $PSScriptRoot "..\lib\NvApi.ps1")

if ($Modes) {
    Write-Host "Kullanilabilir isik modlari:" -ForegroundColor Cyan
    Get-TLModes | ForEach-Object { "  $_" }
    exit 0
}

if ($Quiet) { $Level = 25 }
if ($Max)   { $Level = 100 }

$tlDev  = $null
$ga2Dev = $null

function Write-Baslik { param([string]$T) Write-Host ""; Write-Host $T -ForegroundColor Cyan }

try {
    # ---------- Cihazlari ac ----------
    $tlInfo = Get-TLDeviceInfo
    if ($tlInfo) { $tlDev = [LianLi.HidCore]::Open($tlInfo) }
    else { Write-Host "Uyari: TL fan kontrolcusu bulunamadi." -ForegroundColor Yellow }

    $ga2Info = Get-GA2DeviceInfo
    if ($ga2Info) { $ga2Dev = [LianLi.HidCore]::Open($ga2Info) }
    else { Write-Host "Uyari: Galahad II AIO bulunamadi." -ForegroundColor Yellow }

    $tlFans = @()
    if ($tlDev) {
        $hs = Get-TLFans -Device $tlDev
        if ($hs) { $tlFans = @($hs.Fans | Where-Object { $_.Detected } | Sort-Object Port, FanIndex) }
    }

    $degisti = $false

    # ---------- HIZ ----------
    if ($Level -ge 0) {
        $fanSeviye = [Math]::Max($Level, $MinFan)

        if ($tlFans.Count -gt 0) {
            foreach ($f in $tlFans) {
                Set-TLFanSpeed -Device $tlDev -Port $f.Port -FanIndex $f.FanIndex -Percent $fanSeviye | Out-Null
                Start-Sleep -Milliseconds 100
            }
            $tahmin = [int](17.5 * $fanSeviye + 155)
            $not = if ($fanSeviye -ne $Level) { " (taban %$MinFan uygulandi)" } else { "" }
            Write-Host ("Fanlar : {0} adet -> %{1}{2}   beklenen ~{3} RPM" -f $tlFans.Count, $fanSeviye, $not, $tahmin) -ForegroundColor Green
        }

        if ($ga2Dev -and -not $NoPump) {
            $script:GA2_PUMP_MIN_PERCENT = $PumpMin
            $r = Set-GA2PumpSpeed -Device $ga2Dev -Percent $Level
            $not = if ($r.Uygulanan -ne $r.Istenen) { " (taban %$($r.Taban) uygulandi)" } else { "" }
            Write-Host ("Pompa  : %{0}{1}" -f $r.Uygulanan, $not) -ForegroundColor Green
        }
        $degisti = $true
    }

    # ---------- ISIK ----------
    # Ayni renk uc ayri hedefe gider:
    #   1) TL fanlari              (TL kontrolcusu, komut 0xA3)
    #   2) Pompa basligi Ic + Dis  (AIO, komut 0x83)  -- "Tumu" kapsami bu cihazda CALISMIYOR
    #   3) Pompaya bagli fanlar    (AIO, komut 0x85)  -- ayri kanal
    #
    # AIO'nun parlaklik olcegi TL ile ayni degil: TL'de 4 en parlak, AIO'da
    # dogrulanmis calisan deger 2. Bu yuzden ayri parametre kullaniliyor.
    if ($LightsOff) {
        foreach ($f in $tlFans) {
            Set-TLFanLight -Device $tlDev -Port $f.Port -FanIndex $f.FanIndex -Off | Out-Null
            Start-Sleep -Milliseconds 100
        }
        if ($ga2Dev -and -not $NoPumpLight) {
            foreach ($sc in @('Inner','Outer')) {
                try { Set-GA2PumpLight -Device $ga2Dev -Scope $sc -Off | Out-Null } catch {}
                Start-Sleep -Milliseconds 120
            }
            try { Set-GA2FanLight -Device $ga2Dev -Off | Out-Null } catch {}
        }
        Write-Host "Isik   : kapatildi (TL fanlari + pompa basligi + AIO fanlari)" -ForegroundColor Green
        $degisti = $true
    }
    elseif ($Color -or $Mode) {
        $kMod  = if ($Mode)  { $Mode }  else { 'Static' }
        $kRenk = if ($Color) { $Color.TrimStart('#') } else { 'FF0000' }

        foreach ($f in $tlFans) {
            Set-TLFanLight -Device $tlDev -Port $f.Port -FanIndex $f.FanIndex `
                           -Mode $kMod -Colors @($kRenk) -Brightness $Brightness -Speed $Speed | Out-Null
            Start-Sleep -Milliseconds 100
        }
        $hedefler = @("TL fanlari")

        if ($ga2Dev -and -not $NoPumpLight) {
            # Pompa basligi: iki bolge ayri ayri
            $basarili = $true
            foreach ($sc in @('Inner','Outer')) {
                try {
                    Set-GA2PumpLight -Device $ga2Dev -Color $kRenk -Brightness $AioBrightness -Scope $sc | Out-Null
                } catch {
                    $basarili = $false
                    Write-Host ("  (pompa basligi/{0} ayarlanamadi: {1})" -f $sc, $_.Exception.Message) -ForegroundColor Yellow
                }
                Start-Sleep -Milliseconds 120
            }
            if ($basarili) { $hedefler += "pompa basligi" }

            # Pompaya bagli fanlarin isiklari
            try {
                Set-GA2FanLight -Device $ga2Dev -Color $kRenk -Brightness $AioBrightness | Out-Null
                $hedefler += "AIO fanlari"
            } catch {
                Write-Host ("  (AIO fan isiklari ayarlanamadi: {0})" -f $_.Exception.Message) -ForegroundColor Yellow
            }
        }

        Write-Host ("Isik   : mod={0} renk=#{1}  ->  {2}" -f $kMod, $kRenk, ($hedefler -join ' + ')) -ForegroundColor Green
        $degisti = $true
    }

    # ---------- DURUM ----------
    if ($degisti) { Start-Sleep -Seconds 6 }

    Write-Baslik "=== DURUM ==="

    if ($tlDev) {
        $son = (Get-TLFans -Device $tlDev).Fans | Where-Object { $_.Detected } | Sort-Object Port, FanIndex
        if ($son) {
            $ort = [int](($son | Measure-Object RPM -Average).Average)
            $liste = ($son | ForEach-Object { "$($_.RPM)" }) -join ' / '
            Write-Host ("  Kasa/radyator fanlari : {0} RPM   (ortalama {1})" -f $liste, $ort) -ForegroundColor White
        }
    }

    if ($ga2Dev) {
        $g = Get-GA2Status -Device $ga2Dev
        if ($g) {
            Write-Host ("  AIO pompasi           : {0} RPM" -f $g.PumpRPM) -ForegroundColor White
            if ($g.FanRPM -gt 0) {
                Write-Host ("  AIO fan kanali        : {0} RPM" -f $g.FanRPM) -ForegroundColor White
            }
        }
    }

    # GPU - sadece okuma
    try {
        $gpus = Get-NvGpus
        if ($gpus.Count -gt 0) {
            $gpu  = $gpus[0]
            $t    = Get-NvTemp -Gpu $gpu
            $gf   = Get-NvFans -Gpu $gpu
            $rpm  = if ($gf.Count -gt 0) { (($gf | ForEach-Object { $_.Rpm }) -join ' / ') } else { '?' }
            $durum = if (($gf | Measure-Object Rpm -Maximum).Maximum -eq 0) { 'durdu (zero-RPM)' } else { "$rpm RPM" }
            Write-Host ("  GPU                   : {0} C   fan {1}   [NVIDIA otomatik]" -f $t, $durum) -ForegroundColor White
        }
    } catch {
        Write-Host "  GPU                   : okunamadi" -ForegroundColor DarkGray
    }

    Write-Host ""
}
catch {
    Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red
    exit 3
}
finally {
    if ($tlDev)  { $tlDev.Dispose() }
    if ($ga2Dev) { $ga2Dev.Dispose() }
}
