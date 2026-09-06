# test-nv-fan.ps1 - GPU fan yazma testi (ClientFanCoolersSetControl).
# Kisa manuel pencere, ardindan MUTLAKA otomatik moda geri donus.

param(
    [ValidateRange(30,100)] [int]$TestPercent = 50,
    [int]$HoldSeconds = 12
)

. (Join-Path $PSScriptRoot "..\lib\NvApi.ps1")

function Show-Gpu {
    param([IntPtr]$Gpu, [string]$Etiket)
    $t = Get-NvTemp -Gpu $Gpu
    $f = Get-NvFans -Gpu $Gpu
    $rpm = ($f | ForEach-Object { "$($_.Rpm)" }) -join ' / '
    $lvl = ($f | ForEach-Object { "%$($_.Level)" }) -join ' / '
    Write-Host ("  {0,-16} {1} C   RPM {2,-14} seviye {3}" -f $Etiket, $t, $rpm, $lvl) -ForegroundColor White
}

$gpus = Get-NvGpus
if ($gpus.Count -eq 0) { Write-Host "GPU bulunamadi." -ForegroundColor Red; exit 1 }
$gpu = $gpus[0]

try {
    Write-Host ""
    Write-Host "=== 1) MEVCUT (otomatik) ===" -ForegroundColor Cyan
    Show-Gpu -Gpu $gpu -Etiket "baslangic"

    Write-Host ""
    Write-Host ("=== 2) MANUEL %{0} ===" -f $TestPercent) -ForegroundColor Cyan
    $r = Set-NvFans -Gpu $gpu -Percent $TestPercent
    $renk = if ($r.Ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0}: {1}   (fan sayisi: {2})" -f $r.Stage, $r.Message, $r.CoolerCount) -ForegroundColor $renk
    if (-not $r.Ok -and $r.Code -eq -137) {
        Write-Host "  -> Bu scripti YONETICI olarak acilmis bir PowerShell'de calistir." -ForegroundColor Yellow
    }
    Start-Sleep -Seconds $HoldSeconds
    Show-Gpu -Gpu $gpu -Etiket ("manuel %" + $TestPercent)

    Write-Host ""
    Write-Host "=== 3) OTOMATIGE GERI DON ===" -ForegroundColor Cyan
    $r2 = Set-NvFans -Gpu $gpu -Auto
    Write-Host ("  {0}: {1}" -f $r2.Stage, $r2.Message) -ForegroundColor $(if ($r2.Ok) { 'Green' } else { 'Yellow' })
    Start-Sleep -Seconds $HoldSeconds
    Show-Gpu -Gpu $gpu -Etiket "otomatik"
    Write-Host ""
    Write-Host "GPU fanlari otomatik moda birakildi." -ForegroundColor Green
}
catch {
    Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Guvenlik: otomatik moda donduruluyor..." -ForegroundColor Yellow
    try { Set-NvFans -Gpu $gpu -Auto | Out-Null } catch {}
    exit 3
}
