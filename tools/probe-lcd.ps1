# probe-lcd.ps1 - TL LCD ekranlarini tani (SALT OKUMA).
#
# Yonetici yetkisi GEREKMEZ.
#
# Sadece bilgi soran komutlar gonderilir: seri/port/indeks (62), el sikisma
# (60), yazilim surumu (61). Ekrana HICBIR SEY YAZILMAZ, ayar degistirilmez.
# Amac: protokolun dogru kuruldugunu ve uc ekranin da yanit verdigini
# gonderim yapmadan once dogrulamak.

. (Join-Path $PSScriptRoot "..\lib\LianLiLcd.ps1")

$infos = @(Get-TlLcdDeviceInfos)

Write-Host ""
Write-Host "=== TL LCD ekranlari ===" -ForegroundColor Cyan
Write-Host ("  Bulunan arayuz sayisi: {0}" -f $infos.Count) -ForegroundColor DarkGray
Write-Host ""

if ($infos.Count -eq 0) {
    Write-Host "  Cihaz yok. (VID 04FC / PID 7393 / UsagePage FF06 araniyor)" -ForegroundColor Yellow
    exit 1
}

$i = 0
foreach ($info in $infos) {
    $i++
    Write-Host ("--- Ekran {0} ---" -f $i) -ForegroundColor Cyan
    Write-Host ("  Urun      : {0}" -f $info.Product) -ForegroundColor DarkGray
    Write-Host ("  Rapor boyu: giris {0} / cikis {1} / feature {2}" -f $info.InputLen, $info.OutputLen, $info.FeatureLen) -ForegroundColor DarkGray

    $dev = $null
    try {
        $dev = Open-TlLcd -Info $info

        $kimlik = Get-TlLcdIdentity -Device $dev
        if ($null -ne $kimlik) {
            Write-Host ("  Seri      : '{0}'" -f $kimlik.Seri) -ForegroundColor Green
            Write-Host ("  Port/Indeks: {0} / {1}" -f $kimlik.Port, $kimlik.Indeks) -ForegroundColor Green
        }
        else { Write-Host "  Seri      : yanit yok" -ForegroundColor Yellow }

        $hs = Get-TlLcdHandshake -Device $dev
        if ($null -ne $hs) {
            Write-Host ("  Mod/Kare  : {0} / {1}" -f $hs.Mod, $hs.KareNo) -ForegroundColor Green
        }
        else { Write-Host "  Mod       : yanit yok" -ForegroundColor Yellow }

        $fw = Get-TlLcdFirmware -Device $dev
        if ($null -ne $fw) {
            Write-Host ("  Yazilim   : '{0}'  ({1})" -f $fw.Surum, $fw.Tarih) -ForegroundColor Green
        }
        else { Write-Host "  Yazilim   : yanit yok" -ForegroundColor Yellow }
    }
    catch {
        Write-Host ("  HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    finally { if ($null -ne $dev) { $dev.Dispose() } }

    Write-Host ""
}

Write-Host "Mod degerleri: 1=JPG gosterimi, 3=video, 4=uygulama akisi, 5=ayar, 6=test" -ForegroundColor DarkGray
Write-Host ""
