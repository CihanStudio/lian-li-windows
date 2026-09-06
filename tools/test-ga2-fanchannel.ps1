# test-ga2-fanchannel.ps1 - AIO'nun kendi fan kanalinda fan var mi?
#
# Kanali %100'e cikarip RPM bildirimi olusuyor mu diye bakar.
# Sadece hiz YUKSELTIR (guvenli yon). Pompaya dokunmaz.

param([int]$SettleSeconds = 8)

. (Join-Path $PSScriptRoot "..\lib\LianLiGA2.ps1")

$info = Get-GA2DeviceInfo
if ($null -eq $info) { Write-Host "AIO bulunamadi." -ForegroundColor Red; exit 1 }

$dev = $null
try {
    $dev = [LianLi.HidCore]::Open($info)

    Write-Host ""
    foreach ($pct in @(50, 100, 40)) {
        Set-GA2FanSpeed -Device $dev -Percent $pct | Out-Null
        Start-Sleep -Seconds $SettleSeconds
        $s = Get-GA2Status -Device $dev
        if ($s) {
            Write-Host ("  AIO fan kanali %{0,-4} -> {1,5} RPM   (pompa {2} RPM)" -f $pct, $s.FanRPM, $s.PumpRPM) -ForegroundColor White
            Write-Host ("     ham: {0}" -f $s.Raw) -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "0 RPM sabit kaldiysa AIO'nun kendi fan cikisi bostur;" -ForegroundColor Yellow
    Write-Host "radyator fanlari baska bir kontrolcuye baglidir." -ForegroundColor Yellow
}
catch { Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red; exit 3 }
finally { if ($null -ne $dev) { $dev.Dispose() } }
