# test-ga2-pump.ps1 - Pompa PWM komutunu (0x8A) dogrular.
#
# Akis: mevcut olcum -> %100 -> dusuk test seviyesi (kisa sure) -> %100'e geri don.
# Dusuk seviye penceresi bilerek kisa tutulmustur.

param(
    [ValidateRange(50,90)] [int]$TestPercent = 70,
    [int]$HoldSeconds = 10
)

. (Join-Path $PSScriptRoot "..\lib\LianLiGA2.ps1")

function Show-Ga2 {
    param($Device, [string]$Etiket)
    $s = Get-GA2Status -Device $Device
    if ($null -eq $s) { Write-Host ("  {0,-14} (cevap yok)" -f $Etiket) -ForegroundColor Yellow; return $null }
    Write-Host ("  {0,-14} pompa {1,5} RPM   aio-fan {2,5} RPM" -f $Etiket, $s.PumpRPM, $s.FanRPM) -ForegroundColor White
    return $s
}

$info = Get-GA2DeviceInfo
if ($null -eq $info) { Write-Host "AIO bulunamadi." -ForegroundColor Red; exit 1 }

$dev = $null
try {
    $dev = [LianLi.HidCore]::Open($info)

    Write-Host ""
    Write-Host "=== 1) MEVCUT ===" -ForegroundColor Cyan
    $bas = Show-Ga2 -Device $dev -Etiket "baslangic"

    Write-Host ""
    Write-Host "=== 2) %100'E AYARLA ===" -ForegroundColor Cyan
    Set-GA2PumpSpeed -Device $dev -Percent 100 | Out-Null
    Start-Sleep -Seconds 6
    $tam = Show-Ga2 -Device $dev -Etiket "%100"

    Write-Host ""
    Write-Host ("=== 3) %{0} (kisa pencere) ===" -f $TestPercent) -ForegroundColor Cyan
    $r = Set-GA2PumpSpeed -Device $dev -Percent $TestPercent
    Write-Host ("  istenen %{0} -> uygulanan %{1} (taban %{2})" -f $r.Istenen, $r.Uygulanan, $r.Taban) -ForegroundColor DarkGray
    Start-Sleep -Seconds $HoldSeconds
    $dusuk = Show-Ga2 -Device $dev -Etiket ("%" + $TestPercent)

    Write-Host ""
    Write-Host "=== 4) %100'E GERI DON ===" -ForegroundColor Cyan
    Set-GA2PumpSpeed -Device $dev -Percent 100 | Out-Null
    Start-Sleep -Seconds 8
    Show-Ga2 -Device $dev -Etiket "geri %100" | Out-Null

    Write-Host ""
    if ($null -ne $tam -and $null -ne $dusuk) {
        if ($dusuk.PumpRPM -lt ($tam.PumpRPM * 0.92)) {
            Write-Host ("SONUC: Pompa kontrolu CALISIYOR ({0} -> {1} RPM)." -f $tam.PumpRPM, $dusuk.PumpRPM) -ForegroundColor Green
        } else {
            Write-Host ("SONUC: RPM anlamli degismedi ({0} -> {1}). Pompa muhtemelen sabit hizli veya MB-sync modunda." -f $tam.PumpRPM, $dusuk.PumpRPM) -ForegroundColor Yellow
        }
    }
    Write-Host "Pompa %100'de birakildi." -ForegroundColor Green
}
catch { Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red; exit 3 }
finally { if ($null -ne $dev) { $dev.Dispose() } }
