# diag-lcd-anim.ps1 - LCD animasyonunun hangi yolla calistigini bul.
#
# Yonetici yetkisi GEREKMEZ.
#
# SORUN: sabit resim (komut 0x41 + mod 1) CALISTI, ama akis (komut 0x46,
# mod 4) ekranda hicbir sey degistirmedi. Uc olasilik var; bu arac ucunu de
# sirayla deneyip hangisinin oynadigini GOZLE ayirt etmemizi saglar.
#
#   A) 0x46 akis, mod DEGISTIRILMEDEN (ekran mod 1'de kalir)
#      Referans kodda akis karesi gonderilirken mod hic degistirilmiyor;
#      en olasi dogru yol bu.
#   B) 0x46 akis, once mod 4 (uygulama akisi) - ilk denedigimiz, calismadi
#   C) 0x41 sabit kare + basta bir kez mod 1; her kare ACK'li
#      Yavas ama sabit resmin calistigi kanitli yol.
#
# Her varyant arasinda bekleme var ve hangisinin oynadigi ekrana yazilir.

[CmdletBinding()]
param(
    [string]$Gif = "C:\Users\Cihan\Desktop\cs\giphy (1).gif",
    [double]$EachSeconds = 8,
    [int]$Quality = 55
)

. (Join-Path $PSScriptRoot "..\lib\LianLiLcd.ps1")

$infos = @(Get-TlLcdDeviceInfos)
if ($infos.Count -eq 0) { Write-Host "TL LCD bulunamadi." -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "Kareler kodlaniyor..." -ForegroundColor DarkGray
$kareler = @(ConvertFrom-TlLcdGif -Path $Gif -Quality $Quality)
Write-Host ("  {0} kare, ortalama {1} bayt" -f $kareler.Count,
    [int](($kareler | ForEach-Object { $_.Jpeg.Length } | Measure-Object -Average).Average)) -ForegroundColor DarkGray

$ekranlar = @()
foreach ($info in $infos) {
    try {
        $dev = Open-TlLcd -Info $info
        $k = Get-TlLcdIdentity -Device $dev
        $ekranlar += [PSCustomObject]@{ Cihaz = $dev; Indeks = if ($null -ne $k) { $k.Indeks } else { -1 } }
    }
    catch { Write-Host ("Acilamadi: {0}" -f $_.Exception.Message) -ForegroundColor Red }
}
$ekranlar = @($ekranlar | Sort-Object Indeks)

function Invoke-Varyant {
    param([string]$Ad, [scriptblock]$KareGonder, [scriptblock]$Hazirlik)

    Write-Host ""
    Write-Host ("=== {0} === ({1:N0} saniye) - EKRANLARA BAK" -f $Ad, $EachSeconds) -ForegroundColor Cyan

    if ($null -ne $Hazirlik) { & $Hazirlik }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $i = 0
    $sayac = 0
    try {
        while ($sw.Elapsed.TotalSeconds -lt $EachSeconds) {
            $jpeg = $kareler[$i % $kareler.Count].Jpeg
            foreach ($e in $ekranlar) { & $KareGonder $e.Cihaz $jpeg }
            $i++; $sayac++
        }
    }
    catch { Write-Host ("  HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    $sw.Stop()
    Write-Host ("  {0} kare -> {1:N1} fps" -f $sayac, ($sayac / $sw.Elapsed.TotalSeconds)) -ForegroundColor DarkGray
}

try {
    # --- A: akis, mod degistirilmeden ---
    Invoke-Varyant -Ad "A: akis (0x46), mod degistirilmedi" -Hazirlik {
        foreach ($e in $ekranlar) {
            Set-TlLcdSettings -Device $e.Cihaz -Brightness 100 -Rotation 0 -Mode $script:LCD_MODE_SHOW_JPG
        }
    } -KareGonder {
        param($dev, $jpeg)
        $null = Send-TlLcdImageData -Device $dev -Jpeg $jpeg -Streaming
    }

    Start-Sleep -Seconds 2

    # --- B: akis, once mod 4 ---
    Invoke-Varyant -Ad "B: akis (0x46), mod 4 (uygulama akisi)" -Hazirlik {
        foreach ($e in $ekranlar) {
            Set-TlLcdSettings -Device $e.Cihaz -Brightness 100 -Rotation 0 -Mode $script:LCD_MODE_APP_SYNC
        }
    } -KareGonder {
        param($dev, $jpeg)
        $null = Send-TlLcdImageData -Device $dev -Jpeg $jpeg -Streaming
    }

    Start-Sleep -Seconds 2

    # --- C: sabit kare yolu (0x41, ACK'li) ---
    Invoke-Varyant -Ad "C: sabit kare (0x41, ACK'li)" -Hazirlik {
        foreach ($e in $ekranlar) {
            Set-TlLcdSettings -Device $e.Cihaz -Brightness 100 -Rotation 0 -Mode $script:LCD_MODE_SHOW_JPG
        }
    } -KareGonder {
        param($dev, $jpeg)
        $null = Send-TlLcdImageData -Device $dev -Jpeg $jpeg
    }
}
finally { foreach ($e in $ekranlar) { $e.Cihaz.Dispose() } }

Write-Host ""
Write-Host "HANGI BOLUMDE goruntu oynadi? A, B, C, birkaci veya hicbiri?" -ForegroundColor Cyan
Write-Host ""
