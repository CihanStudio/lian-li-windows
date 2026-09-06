# probe-tl.ps1 - TL kontrolcusunu SORGULAR.
#
# GUVENLIK NOTU: Bu script cihaza yalnizca 0xA1 (handshake) komutunu gonderir.
# 0xA1 bir sorgu komutudur - fan hizini, rengini veya herhangi bir ayari
# DEGISTIRMEZ. L-Connect de acilista ayni komutu gonderir.
# Hiz ayarlayan 0xAA komutu bu scriptte hic cagrilmaz.

. (Join-Path $PSScriptRoot "..\lib\LianLiTL.ps1")

Write-Host "TL kontrolcusu araniyor (VID 0x0416 / PID 0x7372, UsagePage 0xFF1B)..." -ForegroundColor Cyan

$info = Get-TLDeviceInfo
if ($null -eq $info) {
    Write-Host "BULUNAMADI. Kontrolcu takili mi?" -ForegroundColor Red
    exit 1
}

Write-Host ("Bulundu : {0}" -f $info.Product) -ForegroundColor Green
Write-Host ("Yol     : {0}" -f $info.Path) -ForegroundColor DarkGray
Write-Host ("Rapor   : In={0} bayt  Out={1} bayt" -f $info.InputLen, $info.OutputLen) -ForegroundColor DarkGray
Write-Host ""

$dev = $null
try {
    $dev = [LianLi.HidCore]::Open($info)
    Write-Host "Kanal acildi. Handshake (0xA1) gonderiliyor..." -ForegroundColor Cyan

    $sonuc = Get-TLFans -Device $dev

    if ($null -eq $sonuc) {
        Write-Host "Cihazdan cevap gelmedi (zaman asimi)." -ForegroundColor Yellow
        Write-Host "Not: L-Connect veya baska bir kontrol yazilimi acikta ise cihazi mesgul ediyor olabilir." -ForegroundColor Yellow
        exit 2
    }

    Write-Host ""
    Write-Host ("Ham cevap (ilk 32 bayt): {0}" -f $sonuc.Raw) -ForegroundColor DarkGray
    Write-Host ("Veri uzunlugu: {0} bayt  ->  {1} fan girisi" -f $sonuc.RawDataLen, $sonuc.Fans.Count) -ForegroundColor DarkGray
    Write-Host ""

    $bulunan = $sonuc.Fans | Where-Object { $_.Detected }

    if ($bulunan.Count -eq 0) {
        Write-Host "Kontrolcu cevap verdi ama takili fan bildirmedi." -ForegroundColor Yellow
        Write-Host "Tum girisler (hata ayiklama icin):" -ForegroundColor DarkGray
        $sonuc.Fans | Format-Table Port, FanIndex, Detected, RPM, InfoByte -AutoSize
    } else {
        Write-Host "=== TESPIT EDILEN FANLAR ===" -ForegroundColor Green
        $bulunan | Sort-Object Port, FanIndex | Format-Table @{L='Port';E={$_.Port}},
                                                             @{L='Fan #';E={$_.FanIndex}},
                                                             @{L='RPM';E={$_.RPM}} -AutoSize

        Write-Host "=== PORT OZETI ===" -ForegroundColor Green
        for ($p = 0; $p -lt 4; $p++) {
            $portFanlari = $bulunan | Where-Object { $_.Port -eq $p }
            if ($portFanlari.Count -gt 0) {
                $rpmListesi = ($portFanlari | Sort-Object FanIndex | ForEach-Object { "$($_.RPM) RPM" }) -join ', '
                Write-Host ("  Port {0}: {1} fan  ({2})" -f $p, $portFanlari.Count, $rpmListesi) -ForegroundColor White
            } else {
                Write-Host ("  Port {0}: bos" -f $p) -ForegroundColor DarkGray
            }
        }
    }
}
catch {
    Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red
    exit 3
}
finally {
    if ($null -ne $dev) { $dev.Dispose() }
}
