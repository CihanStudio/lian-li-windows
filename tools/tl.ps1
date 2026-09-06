# tl.ps1 - TL fanlari icin tek komut arayuzu (Faz 1).
#
# Kullanim:
#   .\tl.ps1                          -> durum (fan sayisi + RPM)
#   .\tl.ps1 -Percent 40              -> TUM fanlar %40
#   .\tl.ps1 -Color 00A0FF            -> TUM fanlar sabit renk
#   .\tl.ps1 -Percent 70 -Color FF0000
#   .\tl.ps1 -Mode Rainbow            -> efekt modu
#   .\tl.ps1 -LightsOff               -> isiklari kapat
#   .\tl.ps1 -Modes                   -> kullanilabilir efekt listesi
#
# Not: Hiz olcegi 0-100'dur ve bu donanimda RPM ile dogrusaldir
#      (olculen: RPM ~= 17.5 * yuzde + 155).

[CmdletBinding()]
param(
    [ValidateRange(0,100)] [int]$Percent = -1,
    [string]$Color,
    [string]$Mode = 'Static',
    [ValidateRange(0,4)] [int]$Brightness = 4,
    [ValidateRange(0,4)] [int]$Speed = 2,
    [switch]$LightsOff,
    [switch]$Modes,
    [int]$MinPercent = 20
)

. (Join-Path $PSScriptRoot "..\lib\LianLiTL.ps1")

if ($Modes) {
    Write-Host "Kullanilabilir isik modlari:" -ForegroundColor Cyan
    Get-TLModes | ForEach-Object { "  $_" }
    exit 0
}

$info = Get-TLDeviceInfo
if ($null -eq $info) {
    Write-Host "TL kontrolcusu bulunamadi (VID 0x0416 / PID 0x7372)." -ForegroundColor Red
    exit 1
}

$dev = $null
try {
    $dev = [LianLi.HidCore]::Open($info)

    $hs = Get-TLFans -Device $dev
    if ($null -eq $hs) { Write-Host "Kontrolcu cevap vermedi." -ForegroundColor Red; exit 2 }
    $fanlar = $hs.Fans | Where-Object { $_.Detected } | Sort-Object Port, FanIndex
    if ($fanlar.Count -eq 0) { Write-Host "Takili fan bulunamadi." -ForegroundColor Yellow; exit 2 }

    $degisti = $false

    # --- HIZ ---
    if ($Percent -ge 0) {
        # Guvenlik tabani: kasa fanlarini tamamen durdurmak istemiyorsan
        $uygulanan = [Math]::Max($Percent, $MinPercent)
        if ($uygulanan -ne $Percent) {
            Write-Host ("Not: %{0} istendi, guvenlik tabani %{1} uygulandi (-MinPercent 0 ile kaldirilir)." -f $Percent, $MinPercent) -ForegroundColor Yellow
        }
        foreach ($f in $fanlar) {
            Set-TLFanSpeed -Device $dev -Port $f.Port -FanIndex $f.FanIndex -Percent $uygulanan | Out-Null
            Start-Sleep -Milliseconds 100
        }
        $tahmin = [int](17.5 * $uygulanan + 155)
        Write-Host ("Hiz: {0} fan -> %{1}  (beklenen ~{2} RPM)" -f $fanlar.Count, $uygulanan, $tahmin) -ForegroundColor Green
        $degisti = $true
    }

    # --- ISIK ---
    if ($LightsOff) {
        foreach ($f in $fanlar) {
            Set-TLFanLight -Device $dev -Port $f.Port -FanIndex $f.FanIndex -Off | Out-Null
            Start-Sleep -Milliseconds 100
        }
        Write-Host "Isiklar kapatildi." -ForegroundColor Green
        $degisti = $true
    }
    elseif ($Color -or $PSBoundParameters.ContainsKey('Mode')) {
        $renkler = if ($Color) { @($Color) } else { @('FF0000') }
        foreach ($f in $fanlar) {
            Set-TLFanLight -Device $dev -Port $f.Port -FanIndex $f.FanIndex `
                           -Mode $Mode -Colors $renkler -Brightness $Brightness -Speed $Speed | Out-Null
            Start-Sleep -Milliseconds 100
        }
        $renkStr = if ($Color) { "#$($Color.TrimStart('#'))" } else { '(mod varsayilani)' }
        Write-Host ("Isik: {0} fan -> mod={1} renk={2} parlaklik={3}" -f $fanlar.Count, $Mode, $renkStr, $Brightness) -ForegroundColor Green
        $degisti = $true
    }

    # --- DURUM ---
    if ($degisti) { Start-Sleep -Seconds 6 }

    $son = (Get-TLFans -Device $dev).Fans | Where-Object { $_.Detected } | Sort-Object Port, FanIndex
    Write-Host ""
    Write-Host "=== DURUM ===" -ForegroundColor Cyan
    $son | Format-Table @{L='Port';E={$_.Port}}, @{L='Fan';E={$_.FanIndex}}, @{L='RPM';E={$_.RPM}} -AutoSize
    Write-Host ("Ortalama: {0:N0} RPM" -f (($son | Measure-Object RPM -Average).Average)) -ForegroundColor White
}
catch { Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red; exit 3 }
finally { if ($null -ne $dev) { $dev.Dispose() } }
