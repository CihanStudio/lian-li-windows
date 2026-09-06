# test-arayuz.ps1 - Arayuzu GERCEKTEN kurar (pencere acmadan) ve her metnin
#                   kendi denetimine sigdigini iki dilde olcer.
#
# NEDEN VAR: iki gercek hata koda bakarak degil, calisan uygulamanin ekran
# goruntusune bakarak bulundu. Ingilizce metinler Turkcesinden uzun oldugu
# icin satir adlari "Middle" / "Bottom" diye kirpiliyordu - "fan" kelimesi
# kayboluyordu ve hicbir hata verilmiyordu. Sessiz kirpilma en kotu tur:
# program calisiyor gorunuyor ama yanlis sey yaziyor.
#
# NASIL CALISIR: CoolApp.ps1 okunur, sondaki ShowDialog cagrisi denetim
# dolasan bir blokla DEGISTIRILIR ve gecici bir kopya calistirilir. Boylece
# arayuz kodu ikiye bolunmeden, uretimdeki haliyle sinaniyor.
#
# Donanim GEREKTIRMEZ, yonetici GEREKTIRMEZ (-NoElevate ile calisir).
#
# Kullanim: powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-arayuz.ps1

$ErrorActionPreference = 'Stop'
$kok = Split-Path $PSScriptRoot -Parent
$src = Get-Content -LiteralPath (Join-Path $kok "CoolApp.ps1") -Raw

if ($src -notmatch '\[void\]\$form\.ShowDialog\(\)') {
    throw "CoolApp.ps1 icinde ShowDialog satiri bulunamadi - test uyarlanmali."
}

$olcumBlogu = @'
Add-Type -AssemblyName System.Windows.Forms

function Get-Tasan {
    param($Ana, [string]$Dil)
    foreach ($c in $Ana.Controls) {
        $t   = [string]$c.Text
        $tip = $c.GetType().Name
        if ($t -and $tip -in @('Label','Button','CheckBox')) {
            $gen = [System.Windows.Forms.TextRenderer]::MeasureText($t, $c.Font).Width
            # CheckBox'ta metnin solunda kutu var, ona yer birak
            $pay = if ($tip -eq 'CheckBox') { 20 } else { 4 }

            # Cok satirli etiketler sarabilir - yuksekligi iki satiri
            # asiyorsa genislik testi anlamsiz, atlanir.
            $satirYuk = [System.Windows.Forms.TextRenderer]::MeasureText("Xy", $c.Font).Height
            $cokSatir = ($tip -eq 'Label') -and ($c.Height -ge ($satirYuk * 2))

            if (-not $cokSatir -and ($gen + $pay) -gt $c.Width) {
                [PSCustomObject]@{ Dil = $Dil; Tip = $tip; Metin = $t
                                   Gerek = ($gen + $pay); Var = $c.Width }
            }
        }
        if ($c.Controls.Count -gt 0) { Get-Tasan -Ana $c -Dil $Dil }
    }
}

$global:TestTasanlar = @()
$global:TestMetinler = @{}
foreach ($testDil in @('en','tr')) {
    Set-Dil -Kod $testDil
    Update-Dil
    $global:TestTasanlar += @(Get-Tasan -Ana $form -Dil $testDil)
    $global:TestMetinler[$testDil] = $form.Text
}
$global:TestBoyut = $form.Size
$form.Dispose()
'@

# Gecici kopya UYGULAMA KLASORUNDE olmali: lib\ ve json yollari
# $PSScriptRoot'a gore cozuluyor.
$gecici = Join-Path $kok "CoolApp-testArayuz.ps1"
Set-Content -LiteralPath $gecici -Value ($src.Replace('[void]$form.ShowDialog()', $olcumBlogu)) -Encoding UTF8

# Kullanicinin dil secimi test yuzunden degismesin
$dilDosyasi = Join-Path $kok "dil.txt"
$dilYedek = if (Test-Path -LiteralPath $dilDosyasi) { Get-Content -LiteralPath $dilDosyasi -Raw } else { $null }

try {
    . $gecici -NoElevate

    Write-Host ("Pencere : {0} x {1}" -f $TestBoyut.Width, $TestBoyut.Height)
    Write-Host ("Baslik  : en='{0}'  tr='{1}'" -f $TestMetinler['en'], $TestMetinler['tr'])
    Write-Host ""

    if ($TestTasanlar.Count -eq 0) {
        Write-Host "GECTI: iki dilde de hicbir metin kutusuna sigmiyor degil." -ForegroundColor Green
        $cikis = 0
    }
    else {
        Write-Host ("BASARISIZ - {0} metin kirpiliyor:" -f $TestTasanlar.Count) -ForegroundColor Red
        foreach ($t in $TestTasanlar) {
            Write-Host ("  [{0}] {1,-8} gerekli {2,4}px / yer {3,4}px  ->  {4}" -f `
                $t.Dil, $t.Tip, $t.Gerek, $t.Var, $t.Metin) -ForegroundColor Red
        }
        $cikis = 1
    }
}
finally {
    Remove-Item -LiteralPath $gecici -Force -ErrorAction SilentlyContinue
    if ($null -ne $dilYedek) { Set-Content -LiteralPath $dilDosyasi -Value $dilYedek.Trim() -Encoding ASCII }
    else { Remove-Item -LiteralPath $dilDosyasi -Force -ErrorAction SilentlyContinue }
}

exit $cikis
