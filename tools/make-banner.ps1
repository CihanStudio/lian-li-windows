# make-banner.ps1 - README'nin ustundeki genis tanitim gorselini uretir.
#
# NEDEN CIZIM DEGIL YAZI:
#   Ureticilerin LOGOLARINI kirmizi carpiyla basmak iki acidan kotu.
#   1) Hukuki: bir markanin ADINI anmak (uyumluluk/karsilastirma) serbest
#      kabul edilir, LOGOSUNU karalayarak yayinlamak gri bolge.
#   2) Gorsel: yapay zeka ile uretilen sahte logolar bozuk harfli cikar ve
#      amator durur. Gercek yazi tipiyle dizilmis isim keskin gorunur.
#   Bu yuzden gorsel tamamen TIPOGRAFIK: kutular, isimler, carpilar.
#
# NEDEN SADECE UC PROGRAM:
#   Sadece bu uygulamanin GERCEKTEN yerine gectikleri yaziliyor. Dorduncu
#   bir kutu doldurmak icin desteklemedigimiz bir marka eklemek (Armoury
#   Crate gibi) yalan olurdu. FanControl da BILEREK YOK: o bir ureticinin
#   sismis yazilimi degil, toplulugun sevdigi acik bir arac - onu carpiyla
#   gostermek yanlis hedef olurdu.
#
# Kullanim: powershell -NoProfile -ExecutionPolicy Bypass -File tools\make-banner.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$kok    = Split-Path $PSScriptRoot -Parent
$assets = Join-Path $kok "assets"
if (-not (Test-Path $assets)) { New-Item -ItemType Directory -Path $assets | Out-Null }

# --- Palet: uygulamanin kendi renkleri ------------------------------------
$cZemin   = [System.Drawing.Color]::FromArgb(255,  32,  34,  38)   # pencere zemini
$cKutu    = [System.Drawing.Color]::FromArgb(255,  44,  47,  52)   # panel rengi
$cKenar   = [System.Drawing.Color]::FromArgb(255,  58,  62,  69)
$cSolukYz = [System.Drawing.Color]::FromArgb(255, 138, 144, 153)   # pasif metin
$cYazi    = [System.Drawing.Color]::FromArgb(255, 226, 228, 232)
$cVurgu   = [System.Drawing.Color]::FromArgb(255,   0, 160, 255)   # uygulamanin mavisi
$cUrunAd  = [System.Drawing.Color]::FromArgb(255, 176, 182, 191)   # urun adi - carpinin ustunde okunmali
$cCarpi   = [System.Drawing.Color]::FromArgb(120, 255,  70,  70)   # SAYDAM: yazinin arkasinda kalir

$tuvalG = 1280
$tuvalY = 420

$bmp = New-Object System.Drawing.Bitmap($tuvalG, $tuvalY, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g   = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode     = 'AntiAlias'
$g.TextRenderingHint = 'ClearTypeGridFit'
$g.Clear($cZemin)

# --- Yazi tipleri ---------------------------------------------------------
$fUrun    = New-Object System.Drawing.Font('Segoe UI', 21, [System.Drawing.FontStyle]::Bold)
$fAltMetin= New-Object System.Drawing.Font('Segoe UI', 12)
$fSonuc   = New-Object System.Drawing.Font('Segoe UI', 26, [System.Drawing.FontStyle]::Bold)
$fSonucAlt= New-Object System.Drawing.Font('Segoe UI', 13)

function Add-YuvarlakKutu {
    <# Yuvarlatilmis kose yolu uretir. #>
    param([single]$X, [single]$Ty, [single]$Gen, [single]$Yuk, [single]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($X,               $Ty,             2*$R, 2*$R, 180, 90)
    $p.AddArc($X+$Gen-2*$R,     $Ty,             2*$R, 2*$R, 270, 90)
    $p.AddArc($X+$Gen-2*$R,     $Ty+$Yuk-2*$R,   2*$R, 2*$R,   0, 90)
    $p.AddArc($X,               $Ty+$Yuk-2*$R,   2*$R, 2*$R,  90, 90)
    $p.CloseFigure()
    return $p
}

function Write-Ortala {
    <#
      Metni dikdortgenin ORTASINA yazar ve SIGMIYORSA YAZI TIPINI KUCULTUR.

      NEDEN OTOMATIK KUCULTME: sabit punto ile "GIGABYTE Control Center"
      kutuyu tasiriyordu (denendi, harfler kenardan tasti). Elle punto
      ayarlamak yerine olcup kucultmek, ileride baska bir isim eklendiginde
      de kendiliginden dogru calisir.
    #>
    param([string]$Metin, $Yazi, $Firca, [single]$X, [single]$Ty,
          [single]$Gen, [single]$Yuk, [single]$Kenar = 24)

    $enFazla = $Gen - (2 * $Kenar)
    $kullan  = $Yazi
    $gecici  = $null
    $o = $g.MeasureString($Metin, $kullan)

    while ($o.Width -gt $enFazla -and $kullan.Size -gt 8) {
        if ($gecici) { $gecici.Dispose() }
        $gecici = New-Object System.Drawing.Font($kullan.FontFamily, ($kullan.Size - 1), $kullan.Style)
        $kullan = $gecici
        $o = $g.MeasureString($Metin, $kullan)
    }

    $g.DrawString($Metin, $kullan, $Firca, ($X + ($Gen - $o.Width)/2), ($Ty + ($Yuk - $o.Height)/2))
    if ($gecici) { $gecici.Dispose() }
}

# --- Ust sira: yerine gecilen ureticiler ----------------------------------
# SADECE gercekten yerine gecilenler (bkz. dosya basi).
$ureticiler = @(
    @{ Ad = 'L-Connect 3';            Alt = 'Lian Li fans, AIO, LCD' },
    @{ Ad = 'iCUE';                   Alt = 'Corsair memory RGB' },
    @{ Ad = 'GIGABYTE Control Center';Alt = 'motherboard suite' }
)

$kGen = 340.0; $kYuk = 130.0; $bosluk = 30.0
$toplam = ($ureticiler.Count * $kGen) + (($ureticiler.Count - 1) * $bosluk)
$x = ($tuvalG - $toplam) / 2
$kTy = 62.0

$fircaKutu   = New-Object System.Drawing.SolidBrush($cKutu)
$fircaSoluk  = New-Object System.Drawing.SolidBrush($cSolukYz)
$fircaAd     = New-Object System.Drawing.SolidBrush($cUrunAd)
$fircaYazi   = New-Object System.Drawing.SolidBrush($cYazi)
$fircaVurgu  = New-Object System.Drawing.SolidBrush($cVurgu)
$kalemKenar  = New-Object System.Drawing.Pen($cKenar, 2)
# Kalinlik 7 -> 5 ve saydamlik: carpi yazinin arkasinda kalacak, onu
# bogmayacak. Kalin ve opak hali isimleri okunmaz yapiyordu.
$kalemCarpi  = New-Object System.Drawing.Pen($cCarpi, 5)
$kalemCarpi.StartCap = 'Round'; $kalemCarpi.EndCap = 'Round'

foreach ($u in $ureticiler) {
    $yol = Add-YuvarlakKutu -X $x -Ty $kTy -Gen $kGen -Yuk $kYuk -R 12
    $g.FillPath($fircaKutu, $yol)
    $g.DrawPath($kalemKenar, $yol)

    # CIZIM SIRASI ONEMLI: once carpi, SONRA yazi.
    # Ilk denemede tersiydi ve kalin kirmizi cizgiler urun adlarinin
    # uzerini kapatip okunmaz hale getiriyordu. Carpi soluk ve yazinin
    # ARKASINDA olunca hem "iptal" mesaji veriyor hem isim okunuyor.
    $p = 30
    $g.DrawLine($kalemCarpi, ($x+$p), ($kTy+$p), ($x+$kGen-$p), ($kTy+$kYuk-$p))
    $g.DrawLine($kalemCarpi, ($x+$kGen-$p), ($kTy+$p), ($x+$p), ($kTy+$kYuk-$p))

    Write-Ortala -Metin $u.Ad  -Yazi $fUrun     -Firca $fircaAd    -X $x -Ty ($kTy + 30) -Gen $kGen -Yuk 34
    Write-Ortala -Metin $u.Alt -Yazi $fAltMetin -Firca $fircaSoluk -X $x -Ty ($kTy + 74) -Gen $kGen -Yuk 22

    $yol.Dispose()
    $x += $kGen + $bosluk
}

# --- Ortadaki asagi ok ----------------------------------------------------
$okX = $tuvalG / 2.0
$kalemOk = New-Object System.Drawing.Pen($cKenar, 4)
$g.DrawLine($kalemOk, $okX, 214.0, $okX, 244.0)
$ucgen = @(
    (New-Object System.Drawing.PointF(($okX - 11), 242.0)),
    (New-Object System.Drawing.PointF(($okX + 11), 242.0)),
    (New-Object System.Drawing.PointF($okX,        258.0))
)
$g.FillPolygon((New-Object System.Drawing.SolidBrush($cKenar)), $ucgen)

# --- Alt: yerine gecen tek uygulama ---------------------------------------
$sGen = 560.0; $sYuk = 112.0
$sX = ($tuvalG - $sGen) / 2
$sTy = 276.0

$sYol = Add-YuvarlakKutu -X $sX -Ty $sTy -Gen $sGen -Yuk $sYuk -R 14
$g.FillPath((New-Object System.Drawing.SolidBrush($cZemin)), $sYol)
$g.DrawPath((New-Object System.Drawing.Pen($cVurgu, 3)), $sYol)

Write-Ortala -Metin 'One app. One window.' -Yazi $fSonuc -Firca $fircaYazi -X $sX -Ty ($sTy + 20) -Gen $sGen -Yuk 40
Write-Ortala -Metin 'No vendor software, no background services' `
             -Yazi $fSonucAlt -Firca $fircaVurgu -X $sX -Ty ($sTy + 66) -Gen $sGen -Yuk 26

$hedef = Join-Path $assets "banner.png"
$bmp.Save($hedef, [System.Drawing.Imaging.ImageFormat]::Png)

foreach ($d in @($g, $bmp, $fUrun, $fAltMetin, $fSonuc, $fSonucAlt,
                 $fircaKutu, $fircaSoluk, $fircaAd, $fircaYazi, $fircaVurgu,
                 $kalemKenar, $kalemCarpi, $kalemOk)) {
    try { $d.Dispose() } catch { }
}

Write-Host ("yazildi: {0}  ({1} x {2}, {3} KB)" -f $hedef, $tuvalG, $tuvalY, [int]((Get-Item $hedef).Length / 1KB))


