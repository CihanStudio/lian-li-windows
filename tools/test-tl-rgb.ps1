# test-tl-rgb.ps1 - TL fan RGB dogrulamasi.
# Kasaya bakarak renklerin gercekten degistigini onayla.

param([int]$HoldSeconds = 4)

. (Join-Path $PSScriptRoot "..\lib\LianLiTL.ps1")

$info = Get-TLDeviceInfo
if ($null -eq $info) { Write-Host "TL kontrolcusu bulunamadi." -ForegroundColor Red; exit 1 }

$dev = $null
try {
    $dev = [LianLi.HidCore]::Open($info)
    $fanlar = (Get-TLFans -Device $dev).Fans | Where-Object { $_.Detected } | Sort-Object Port, FanIndex
    Write-Host ("{0} fan bulundu. Kasaya bak." -f $fanlar.Count) -ForegroundColor Cyan
    Write-Host ""

    $adimlar = @(
        @{ Ad = 'KIRMIZI'; Mod = 'Static'; Renk = @('FF0000') },
        @{ Ad = 'YESIL';   Mod = 'Static'; Renk = @('00FF00') },
        @{ Ad = 'MAVI';    Mod = 'Static'; Renk = @('0000FF') },
        @{ Ad = 'GOKKUSAGI (efekt testi)'; Mod = 'Rainbow'; Renk = @('FF0000') }
    )

    foreach ($a in $adimlar) {
        Write-Host ("  -> {0}" -f $a.Ad) -ForegroundColor Yellow
        foreach ($f in $fanlar) {
            Set-TLFanLight -Device $dev -Port $f.Port -FanIndex $f.FanIndex `
                           -Mode $a.Mod -Colors $a.Renk -Brightness 4 -Speed 2 | Out-Null
            Start-Sleep -Milliseconds 100
        }
        Start-Sleep -Seconds $HoldSeconds
    }

    Write-Host ""
    Write-Host "Test bitti. Fanlar gokkusagi modunda birakildi." -ForegroundColor Green
}
catch { Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red; exit 3 }
finally { if ($null -ne $dev) { $dev.Dispose() } }
