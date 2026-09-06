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

function Get-Cakisan {
    <#
      Ayni kap icindeki denetimlerin dikdortgenleri kesisiyor mu?
      Bu arayuzde HICBIR denetim ust uste binmemeli - binmisse biri
      digerinin uzerine ciziliyor demektir.
      Dile bagli DEGIL (konumlar sabit), bir kez bakmak yeter.
    #>
    param($Ana, [string]$Yol = 'form')
    $liste = @($Ana.Controls)
    for ($i = 0; $i -lt $liste.Count; $i++) {
        for ($j = $i + 1; $j -lt $liste.Count; $j++) {
            $a = $liste[$i]; $b = $liste[$j]
            $ra = New-Object System.Drawing.Rectangle($a.Left, $a.Top, $a.Width, $a.Height)
            $rb = New-Object System.Drawing.Rectangle($b.Left, $b.Top, $b.Width, $b.Height)
            if ($ra.IntersectsWith($rb)) {
                $kesisim = [System.Drawing.Rectangle]::Intersect($ra, $rb)
                [PSCustomObject]@{
                    Yer = $Yol
                    A   = ("{0}('{1}') {2}" -f $a.GetType().Name, $a.Text, $ra)
                    B   = ("{0}('{1}') {2}" -f $b.GetType().Name, $b.Text, $rb)
                    Ust = ("{0}x{1} px" -f $kesisim.Width, $kesisim.Height)
                }
            }
        }
    }
    foreach ($c in $liste) {
        if ($c.Controls.Count -gt 0) { Get-Cakisan -Ana $c -Yol ("{0} > {1}" -f $Yol, $c.Text.Trim()) }
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
$global:TestCakisanlar = @(Get-Cakisan -Ana $form)
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

    $cikis = 0

    Write-Host "1) Kutusuna sigmayan metin"
    if ($TestTasanlar.Count -eq 0) {
        Write-Host "   yok - iki dilde de temiz" -ForegroundColor Green
    }
    else {
        Write-Host ("   {0} metin kirpiliyor:" -f $TestTasanlar.Count) -ForegroundColor Red
        foreach ($t in $TestTasanlar) {
            Write-Host ("     [{0}] {1,-8} gerekli {2,4}px / yer {3,4}px  ->  {4}" -f `
                $t.Dil, $t.Tip, $t.Gerek, $t.Var, $t.Metin) -ForegroundColor Red
        }
        $cikis = 1
    }

    Write-Host ""
    Write-Host "2) Ust uste binen denetim"
    if ($TestCakisanlar.Count -eq 0) {
        Write-Host "   yok" -ForegroundColor Green
    }
    else {
        Write-Host ("   {0} cakisma:" -f $TestCakisanlar.Count) -ForegroundColor Red
        foreach ($c in $TestCakisanlar) {
            Write-Host ("     {0}" -f $c.Yer) -ForegroundColor Red
            Write-Host ("       {0}" -f $c.A) -ForegroundColor Red
            Write-Host ("       {0}" -f $c.B) -ForegroundColor Red
            Write-Host ("       ust uste binen alan: {0}" -f $c.Ust) -ForegroundColor Red
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
