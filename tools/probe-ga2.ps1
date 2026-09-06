# probe-ga2.ps1 - Galahad II AIO'yu SORGULAR.
#
# GUVENLIK: Yalnizca 0x81 (handshake) gonderir. Pompa veya fan hizini
# DEGISTIRMEZ. Pompaya yazan 0x8A komutu bu scriptte hic cagrilmaz.

. (Join-Path $PSScriptRoot "..\lib\LianLiGA2.ps1")

Write-Host "Galahad II Trinity araniyor (VID 0x0416 / PID 0x7373, UsagePage 0xFF1B)..." -ForegroundColor Cyan

$info = Get-GA2DeviceInfo
if ($null -eq $info) { Write-Host "BULUNAMADI." -ForegroundColor Red; exit 1 }

Write-Host ("Bulundu : {0}" -f $info.Product) -ForegroundColor Green
Write-Host ("Rapor   : In={0} Out={1}" -f $info.InputLen, $info.OutputLen) -ForegroundColor DarkGray
Write-Host ""

$dev = $null
try {
    $dev = [LianLi.HidCore]::Open($info)
    Write-Host "Handshake (0x81) gonderiliyor..." -ForegroundColor Cyan
    $s = Get-GA2Status -Device $dev

    if ($null -eq $s) {
        Write-Host "Cevap gelmedi (zaman asimi)." -ForegroundColor Yellow
        exit 2
    }

    Write-Host ""
    Write-Host ("Ham cevap : {0}" -f $s.Raw) -ForegroundColor DarkGray
    Write-Host ("Veri uzn. : {0} bayt" -f $s.RawDataLen) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "=== AIO DURUMU ===" -ForegroundColor Green
    Write-Host ("  Pompa    : {0} RPM" -f $s.PumpRPM) -ForegroundColor White
    Write-Host ("  AIO fani : {0} RPM" -f $s.FanRPM) -ForegroundColor White
}
catch { Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red; exit 3 }
finally { if ($null -ne $dev) { $dev.Dispose() } }
