# sweep-tl.ps1 - Duty -> RPM egrisini cikarir.
# Amac: hem hiz DUSURMENIN calisip calismadigini, hem RPM okumasinin
# ne kadar gecikmeyle guncellendigini olcmek.

param(
    [int[]]$Steps = @(90, 30, 60, 45),
    [int]$SettleSeconds = 14
)

. (Join-Path $PSScriptRoot "..\lib\LianLiTL.ps1")

$info = Get-TLDeviceInfo
if ($null -eq $info) { Write-Host "TL kontrolcusu bulunamadi." -ForegroundColor Red; exit 1 }

$dev = $null
try {
    $dev = [LianLi.HidCore]::Open($info)

    $ilk = (Get-TLFans -Device $dev).Fans | Where-Object { $_.Detected } | Sort-Object Port, FanIndex
    Write-Host ("Fanlar: {0} adet (Port {1})" -f $ilk.Count, (($ilk.Port | Select-Object -Unique) -join ',')) -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("{0,-8} {1,-6} {2,-28} {3}" -f "Hedef", "Duty", "RPM (bekleme sonrasi)", "Ara olcumler") -ForegroundColor DarkGray
    Write-Host ("-" * 78) -ForegroundColor DarkGray

    foreach ($pct in $Steps) {
        $duty = [byte][Math]::Round($pct * 2.55)
        foreach ($f in $ilk) {
            Set-TLFanSpeed -Device $dev -Port $f.Port -FanIndex $f.FanIndex -Percent $pct | Out-Null
            Start-Sleep -Milliseconds 120
        }

        # Bekleme boyunca araliklarla olc: RPM guncelleme gecikmesini gormek icin
        $ara = @()
        for ($t = 0; $t -lt $SettleSeconds; $t += 4) {
            Start-Sleep -Seconds 4
            $s = (Get-TLFans -Device $dev).Fans | Where-Object { $_.Detected }
            if ($s) { $ara += [int](($s | Measure-Object RPM -Average).Average) }
        }

        $son = (Get-TLFans -Device $dev).Fans | Where-Object { $_.Detected } | Sort-Object Port, FanIndex
        $rpmStr = ($son | ForEach-Object { $_.RPM }) -join ' / '
        Write-Host ("%{0,-7} {1,-6} {2,-28} {3}" -f $pct, $duty, $rpmStr, ($ara -join ' -> ')) -ForegroundColor White
    }
    Write-Host ""
}
catch { Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red; exit 3 }
finally { if ($null -ne $dev) { $dev.Dispose() } }
