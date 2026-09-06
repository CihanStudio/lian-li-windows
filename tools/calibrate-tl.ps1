# calibrate-tl.ps1 - Ham duty baytinin gercek olcegini belirler.
# Hipotez: duty 0-100 (yuzde), 0-255 degil. Monotonluk testi.

param(
    [int[]]$Duties = @(100, 80, 60, 40, 20, 45),
    [int]$SettleSeconds = 12
)

. (Join-Path $PSScriptRoot "..\lib\LianLiTL.ps1")

$info = Get-TLDeviceInfo
if ($null -eq $info) { Write-Host "TL kontrolcusu bulunamadi." -ForegroundColor Red; exit 1 }

$dev = $null
try {
    $dev = [LianLi.HidCore]::Open($info)
    $fanlar = (Get-TLFans -Device $dev).Fans | Where-Object { $_.Detected } | Sort-Object Port, FanIndex

    Write-Host ""
    Write-Host ("{0,-8} {1,-24} {2}" -f "Duty", "RPM (fan bazinda)", "Ortalama") -ForegroundColor DarkGray
    Write-Host ("-" * 56) -ForegroundColor DarkGray

    foreach ($d in $Duties) {
        foreach ($f in $fanlar) {
            Set-TLFanDuty -Device $dev -Port $f.Port -FanIndex $f.FanIndex -Duty $d | Out-Null
            Start-Sleep -Milliseconds 120
        }
        Start-Sleep -Seconds $SettleSeconds

        $s = (Get-TLFans -Device $dev).Fans | Where-Object { $_.Detected } | Sort-Object Port, FanIndex
        $rpm = ($s | ForEach-Object { $_.RPM }) -join ' / '
        $ort = [int](($s | Measure-Object RPM -Average).Average)
        Write-Host ("{0,-8} {1,-24} {2}" -f $d, $rpm, $ort) -ForegroundColor White
    }
    Write-Host ""
}
catch { Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red; exit 3 }
finally { if ($null -ne $dev) { $dev.Dispose() } }
