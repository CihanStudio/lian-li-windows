# test-tl-speed.ps1 - TL fanlarina hiz YAZMA testi.
#
# Bu script kasa fanlarinin hizini degistirir. AIO pompasina DOKUNMAZ
# (pompa 0416:7373 numarali ayri bir cihazda, bu script sadece 0416:7372 ile konusur).
#
# Akis: temel olcum -> hizi yukselt -> dogrula -> son seviyeye ayarla -> dogrula

param(
    [ValidateRange(20,100)] [int]$TestPercent    = 70,
    [ValidateRange(20,100)] [int]$RestorePercent = 45,
    [int]$SettleSeconds = 5
)

. (Join-Path $PSScriptRoot "..\lib\LianLiTL.ps1")

function Show-Rpm {
    param($Device, [string]$Baslik)
    $s = Get-TLFans -Device $Device
    if ($null -eq $s) { Write-Host "  (cevap yok)" -ForegroundColor Yellow; return $null }
    $d = $s.Fans | Where-Object { $_.Detected } | Sort-Object Port, FanIndex
    $ozet = ($d | ForEach-Object { "P$($_.Port)F$($_.FanIndex)=$($_.RPM)" }) -join '  '
    Write-Host ("  {0,-22} {1}" -f $Baslik, $ozet) -ForegroundColor White
    return $d
}

$info = Get-TLDeviceInfo
if ($null -eq $info) { Write-Host "TL kontrolcusu bulunamadi." -ForegroundColor Red; exit 1 }

$dev = $null
try {
    $dev = [LianLi.HidCore]::Open($info)

    Write-Host ""
    Write-Host "=== 1) TEMEL OLCUM ===" -ForegroundColor Cyan
    $once = Show-Rpm -Device $dev -Baslik "mevcut"
    if ($null -eq $once -or $once.Count -eq 0) { Write-Host "Fan bulunamadi, cikiliyor." -ForegroundColor Red; exit 2 }

    Write-Host ""
    Write-Host ("=== 2) HIZ %{0} YAPILIYOR ===" -f $TestPercent) -ForegroundColor Cyan
    foreach ($f in $once) {
        $r = Set-TLFanSpeed -Device $dev -Port $f.Port -FanIndex $f.FanIndex -Percent $TestPercent
        Write-Host ("  Port {0} Fan {1} -> %{2} (duty {3})" -f $r.Port, $r.FanIndex, $r.Percent, $r.Duty) -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 120
    }

    Write-Host ("  {0} sn bekleniyor..." -f $SettleSeconds) -ForegroundColor DarkGray
    Start-Sleep -Seconds $SettleSeconds
    $sonra = Show-Rpm -Device $dev -Baslik "yeni"

    # Degisiklik gercekten oldu mu?
    $eskiOrt = ($once | Measure-Object RPM -Average).Average
    $yeniOrt = ($sonra | Measure-Object RPM -Average).Average
    Write-Host ""
    if ($yeniOrt -gt ($eskiOrt * 1.15)) {
        Write-Host ("  BASARILI: ortalama {0:N0} -> {1:N0} RPM. Komut 0xAA calisiyor." -f $eskiOrt, $yeniOrt) -ForegroundColor Green
    } else {
        Write-Host ("  DEGISIM YOK: ortalama {0:N0} -> {1:N0} RPM." -f $eskiOrt, $yeniOrt) -ForegroundColor Yellow
        Write-Host "  Muhtemel sebep: kontrolcu anakart PWM senkron modunda." -ForegroundColor Yellow
        Write-Host "  Bu durumda once 0xB1 (MB RPM sync kapat) gerekiyor." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host ("=== 3) %{0} SEVIYESINE AYARLANIYOR ===" -f $RestorePercent) -ForegroundColor Cyan
    foreach ($f in $once) {
        Set-TLFanSpeed -Device $dev -Port $f.Port -FanIndex $f.FanIndex -Percent $RestorePercent | Out-Null
        Start-Sleep -Milliseconds 120
    }
    Start-Sleep -Seconds $SettleSeconds
    Show-Rpm -Device $dev -Baslik "son" | Out-Null
    Write-Host ""
}
catch {
    Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red
    exit 3
}
finally {
    if ($null -ne $dev) { $dev.Dispose() }
}
