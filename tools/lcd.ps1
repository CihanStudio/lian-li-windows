# lcd.ps1 - TL LCD ekranlarina goruntu bas.
#
# Yonetici yetkisi GEREKMEZ.
#
# KULLANIM
#   .\lcd.ps1 -Test                          Her ekrana kendi indeks numarasini bas
#   .\lcd.ps1 -Image resim.jpg               Ayni resmi uc ekrana da bas
#   .\lcd.ps1 -Image resim.png -Index 1      Sadece 1 numarali ekrana bas
#   .\lcd.ps1 -Image r.jpg -Rotation 180     Ters cevirerek bas
#   .\lcd.ps1 -Brightness 40                 Sadece parlakligi degistir
#
# Goruntu 400x400'e ORTADAN KIRPILARAK olceklenir (esnetilmez), cunku ekran
# fan gobeginde ve yuvarlaktir. JPEG'e cevrilir; cihazin 65535 baytlik
# sinirini asarsa kalite otomatik dusurulur.

[CmdletBinding()]
param(
    [string]$Image,
    [string]$Gif,
    [double]$Seconds = 10,
    [int]$Quality = 75,
    [switch]$Test,
    [int]$Index = -1,
    [ValidateRange(0, 100)][int]$Brightness = 100,
    [ValidateSet(0, 90, 180, 270)][int]$Rotation = 0
)

. (Join-Path $PSScriptRoot "..\lib\LianLiLcd.ps1")

if (-not $Test -and -not $Image -and -not $Gif -and -not $PSBoundParameters.ContainsKey('Brightness') -and -not $PSBoundParameters.ContainsKey('Rotation')) {
    Write-Host "Ne yapilacagi belirtilmedi. -Test, -Image, -Gif veya -Brightness kullan." -ForegroundColor Yellow
    exit 1
}

# --- Ekranlari bul ve kimliklerini oku ---
$infos = @(Get-TlLcdDeviceInfos)
if ($infos.Count -eq 0) {
    Write-Host "TL LCD ekrani bulunamadi." -ForegroundColor Red
    exit 1
}

$ekranlar = @()
foreach ($info in $infos) {
    $dev = $null
    try {
        $dev = Open-TlLcd -Info $info
        $k = Get-TlLcdIdentity -Device $dev
        $ekranlar += [PSCustomObject]@{
            Cihaz  = $dev
            Indeks = if ($null -ne $k) { $k.Indeks } else { -1 }
            Seri   = if ($null -ne $k) { $k.Seri } else { "?" }
        }
    }
    catch {
        Write-Host ("Ekran acilamadi: {0}" -f $_.Exception.Message) -ForegroundColor Red
        if ($null -ne $dev) { $dev.Dispose() }
    }
}

# Indekse gore sirala ki ciktinin sirasi fiziksel sirayla ayni olsun
$ekranlar = @($ekranlar | Sort-Object Indeks)

if ($Index -ge 0) {
    $ekranlar = @($ekranlar | Where-Object { $_.Indeks -eq $Index })
    if ($ekranlar.Count -eq 0) {
        Write-Host ("Indeks {0} olan ekran yok." -f $Index) -ForegroundColor Yellow
        exit 1
    }
}

# --- Gecici test goruntusu uret ---
function New-TestGoruntusu {
    <# Ekranin indeksini buyuk buyuk yazan bir kare uretir; hangi fizikselm
       fanin hangi indeks oldugunu gozle eslestirmek icin. #>
    param([int]$Numara, [string]$Yol)

    $renkler = @(
        [Drawing.Color]::FromArgb(220, 40, 40),
        [Drawing.Color]::FromArgb(40, 170, 90),
        [Drawing.Color]::FromArgb(50, 110, 230)
    )
    $arka = $renkler[$Numara % $renkler.Count]

    $bmp = New-Object Drawing.Bitmap(400, 400)
    $g = [Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAlias
        $g.Clear([Drawing.Color]::Black)

        $fircaArka = New-Object Drawing.SolidBrush($arka)
        $g.FillEllipse($fircaArka, 10, 10, 380, 380)
        $fircaArka.Dispose()

        $kalem = New-Object Drawing.Pen([Drawing.Color]::White, 6)
        $g.DrawEllipse($kalem, 10, 10, 380, 380)
        $kalem.Dispose()

        $yazi = New-Object Drawing.Font("Segoe UI", 170, [Drawing.FontStyle]::Bold)
        $firca = New-Object Drawing.SolidBrush([Drawing.Color]::White)
        $bicim = New-Object Drawing.StringFormat
        $bicim.Alignment = [Drawing.StringAlignment]::Center
        $bicim.LineAlignment = [Drawing.StringAlignment]::Center
        $g.DrawString([string]$Numara, $yazi, $firca, (New-Object Drawing.RectangleF(0, 0, 400, 400)), $bicim)
        $bicim.Dispose(); $firca.Dispose(); $yazi.Dispose()
    }
    finally { $g.Dispose() }

    $bmp.Save($Yol, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

# --- Uygula ---
Write-Host ""

# --- GIF oynatma (ayri yol: kareler bir kez kodlanir, sonra dongude yazilir) ---
if ($Gif) {
    try {
        Write-Host "Kareler kodlaniyor..." -ForegroundColor DarkGray
        $olc = [Diagnostics.Stopwatch]::StartNew()
        $kareler = @(ConvertFrom-TlLcdGif -Path $Gif -Quality $Quality)
        $olc.Stop()

        if ($kareler.Count -eq 0) { throw "GIF'ten kare cikarilamadi." }

        # NOT: PowerShell 5.1'de Measure-Object -Property scriptblock KABUL ETMEZ.
        # Once degeri duz bir ozelliğe cikarip oyle olcuyoruz.
        $ortBayt = [int](($kareler | ForEach-Object { $_.Jpeg.Length } | Measure-Object -Average).Average)
        $ortGecikme = [int](($kareler | Measure-Object -Property GecikmeMs -Average).Average)
        Write-Host ("  {0} kare, ortalama {1} bayt, GIF hizi ~{2:N1} fps  ({3:N1} sn'de kodlandi)" -f `
            $kareler.Count, $ortBayt, (1000.0 / [Math]::Max(1, $ortGecikme)), $olc.Elapsed.TotalSeconds) -ForegroundColor DarkGray

        # DIKKAT: akis oncesi mod 4'e (uygulama akisi) GECILMEZ.
        # Ilk denemede mod 4 kullanildi ve ekranda hicbir sey degismedi;
        # ekran onceki sabit goruntude kaldi. Dogru yol referans koddaki
        # gibi modu 1'de (JPG gosterimi) birakip 0x46 karelerini akitmak.
        # Olculdu: mod 1'de akis calisiyor, ~17 fps.
        foreach ($e in $ekranlar) {
            Set-TlLcdSettings -Device $e.Cihaz -Brightness $Brightness -Rotation $Rotation -Mode $script:LCD_MODE_SHOW_JPG
        }

        Write-Host ("  {0:N0} saniye oynatiliyor..." -f $Seconds) -ForegroundColor DarkGray
        $sure = [Diagnostics.Stopwatch]::StartNew()
        $k = 0
        $gonderilen = 0
        while ($sure.Elapsed.TotalSeconds -lt $Seconds) {
            $kare = $kareler[$k % $kareler.Count]
            foreach ($e in $ekranlar) {
                $null = Send-TlLcdFrame -Device $e.Cihaz -Jpeg $kare.Jpeg
            }
            $gonderilen++
            $k++
            # GIF'in kendi hizindan HIZLI gidiyorsak yavaslat; yavas
            # gidiyorsak bekleme ekleme (zaten geride kaldik).
            $hedefMs = $kare.GecikmeMs
            $planlanan = $gonderilen * $hedefMs
            $fark = $planlanan - $sure.Elapsed.TotalMilliseconds
            if ($fark -gt 1) { Start-Sleep -Milliseconds ([int]$fark) }
        }
        $sure.Stop()

        Write-Host ("  {0} kare gonderildi -> ekran basina {1:N1} fps" -f `
            $gonderilen, ($gonderilen / $sure.Elapsed.TotalSeconds)) -ForegroundColor Green
    }
    catch { Write-Host ("HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    finally { foreach ($e in $ekranlar) { $e.Cihaz.Dispose() } }

    Write-Host ""
    Write-Host "EKRANLARA BAK: animasyon oynadi mi?" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

try {
    foreach ($e in $ekranlar) {
        $etiket = "Ekran {0} ({1}...)" -f $e.Indeks, $e.Seri.Substring(0, [Math]::Min(8, $e.Seri.Length))

        if ($Test) {
            $gecici = Join-Path $env:TEMP ("tl-lcd-test-{0}.png" -f $e.Indeks)
            New-TestGoruntusu -Numara $e.Indeks -Yol $gecici
            $r = Send-TlLcdImage -Device $e.Cihaz -Path $gecici -Brightness $Brightness -Rotation $Rotation
            Remove-Item $gecici -ErrorAction SilentlyContinue
            Write-Host ("  {0}  test deseni gonderildi  ({1} bayt / {2} paket)" -f $etiket, $r.JpegBayt, $r.PaketSayi) -ForegroundColor Green
        }
        elseif ($Gif) {
            # GIF tek tek degil, TUM ekranlara birlikte oynatilir; asagida.
        }
        elseif ($Image) {
            $r = Send-TlLcdImage -Device $e.Cihaz -Path $Image -Brightness $Brightness -Rotation $Rotation
            Write-Host ("  {0}  goruntu gonderildi  ({1} bayt / {2} paket)" -f $etiket, $r.JpegBayt, $r.PaketSayi) -ForegroundColor Green
        }
        else {
            Set-TlLcdSettings -Device $e.Cihaz -Brightness $Brightness -Rotation $Rotation
            Write-Host ("  {0}  parlaklik {1}, donus {2}" -f $etiket, $Brightness, $Rotation) -ForegroundColor Green
        }
    }
}
catch { Write-Host ("HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red }
finally { foreach ($e in $ekranlar) { $e.Cihaz.Dispose() } }

Write-Host ""
Write-Host "EKRANLARA BAK: goruntu degisti mi?" -ForegroundColor Cyan
Write-Host ""
