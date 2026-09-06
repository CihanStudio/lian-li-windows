# test-dil.ps1 - Dil tablosunun butunlugunu sinar. Donanim GEREKTIRMEZ.
#
#   1) Her anahtarin HEM 'en' HEM 'tr' karsiligi var mi?
#   2) Kodda cagrilan her T anahtari tabloda var mi? (yoksa arayuzde
#      [koseli-parantez] gorunur)
#   3) Tabloda kullanilmayan anahtar kaldi mi? (olu metin)
#   4) Bicimlendirme yer tutuculari ({0}, {1}) iki dilde AYNI mi?
#      Farkli olursa -f calisirken patlar veya yanlis deger yazar.
#   5) Arayuzde Turkce metin unutulmus mu? (dosyada duz Turkce dizge)
#
# Kullanim:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-dil.ps1

$ErrorActionPreference = 'Stop'
$kok = Split-Path $PSScriptRoot -Parent
. (Join-Path $kok "lib\Dil.ps1")

$hata = 0
function Basarisiz { param([string]$M) Write-Host "  HATA: $M" -ForegroundColor Red; $script:hata++ }

# --- 1) Iki dil de dolu mu -------------------------------------------------
Write-Host "1) Eksik ceviri"
foreach ($k in ($script:Metinler.Keys | Sort-Object)) {
    foreach ($d in @('en','tr')) {
        if ([string]::IsNullOrWhiteSpace($script:Metinler[$k][$d])) { Basarisiz "'$k' icin '$d' bos" }
    }
}
if ($hata -eq 0) { Write-Host "   $($script:Metinler.Count) anahtarin ikisi de dolu" -ForegroundColor Green }

# --- 2/3) Kod ile tablo ortusuyor mu --------------------------------------
Write-Host ""
Write-Host "2) Kodda cagrilan ama tabloda olmayan anahtar"
# Bu dosyanin KENDISI taranmaz: icindeki desenler ornek olarak yaziliyor ve
# gercek cagri sanilip yanlis alarm veriyordu.
$kaynaklar = @(Get-ChildItem -Path $kok -Filter *.ps1) +
             @(Get-ChildItem -Path (Join-Path $kok "tools") -Filter *.ps1 |
               Where-Object { $_.Name -ne 'test-dil.ps1' })
$kullanilan = @{}
foreach ($f in $kaynaklar) {
    $metin = Get-Content -LiteralPath $f.FullName -Raw

    # a) Dogrudan cagri:  T 'anahtar'
    foreach ($m in [regex]::Matches($metin, "T\s+'([a-z0-9\-]+)'")) {
        $kullanilan[$m.Groups[1].Value] = $true
    }

    # b) DOLAYLI cagri: anahtar bir degiskende tasiniyor olabilir
    #    (orn. on ayar dugmeleri: @{ Anahtar = 'onayar-sessiz' } ... T $o.Anahtar).
    #    Bu yuzden kaynakta tirnak icinde GECEN her tablo anahtari da
    #    "kullanilmis" sayilir - yoksa test yanlis alarm veriyordu.
    foreach ($m in [regex]::Matches($metin, "'([a-z0-9\-]+)'")) {
        $a = $m.Groups[1].Value
        if ($script:Metinler.ContainsKey($a)) { $kullanilan[$a] = $true }
    }
}
$eksik = @($kullanilan.Keys | Where-Object { -not $script:Metinler.ContainsKey($_) })
if ($eksik.Count -gt 0) { foreach ($e in $eksik) { Basarisiz "kodda '$e' cagriliyor, tabloda yok" } }
else { Write-Host "   yok - $($kullanilan.Count) anahtar cagriliyor, hepsi tabloda" -ForegroundColor Green }

Write-Host ""
Write-Host "3) Tabloda olup kullanilmayan anahtar (olu metin)"
$olu = @($script:Metinler.Keys | Where-Object { -not $kullanilan.ContainsKey($_) } | Sort-Object)
if ($olu.Count -gt 0) { Write-Host ("   " + ($olu -join ', ')) -ForegroundColor Yellow; $script:hata++ }
else { Write-Host "   yok" -ForegroundColor Green }

# --- 4) Yer tutucular esit mi ---------------------------------------------
Write-Host ""
Write-Host "4) {0}/{1} yer tutucu uyusmazligi"
$uyusmaz = 0
foreach ($k in ($script:Metinler.Keys | Sort-Object)) {
    $sayilar = @{}
    foreach ($d in @('en','tr')) {
        $s = @([regex]::Matches($script:Metinler[$k][$d], '\{(\d+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $sayilar[$d] = ($s -join ',')
    }
    if ($sayilar['en'] -ne $sayilar['tr']) {
        Basarisiz ("'$k' -> en:[{0}] tr:[{1}]" -f $sayilar['en'], $sayilar['tr']); $uyusmaz++
    }
}
if ($uyusmaz -eq 0) { Write-Host "   yok" -ForegroundColor Green }

# --- 5) Arayuzde unutulmus Turkce dizge -----------------------------------
# Kaba ama ise yarar: CoolApp icinde .Text = "..." veya Set-AltBilgi "..."
# seklinde DUZ dizge kalmis mi? (T ile gelenler tirnaksiz oldugu icin elenir)
Write-Host ""
Write-Host "5) CoolApp'te cevrilmemis duz metin"
$app = Get-Content -LiteralPath (Join-Path $kok "CoolApp.ps1") -Raw
$supheli = @()
foreach ($m in [regex]::Matches($app, '(?m)(\.Text\s*=\s*|Set-AltBilgi\s+)"([^"]{4,})"')) {
    $d = $m.Groups[2].Value
    # Bicimlendirme ifadeleri ve teknik dizgeler haric
    if ($d -match '^\s*$' -or $d -match '^\{' -or $d -match '^%' -or $d -match '^[\d\s\.,:%-]+$') { continue }
    $supheli += $d
}
if ($supheli.Count -gt 0) { foreach ($s in $supheli) { Basarisiz "duz metin: `"$s`"" } }
else { Write-Host "   yok" -ForegroundColor Green }

# --- 6) SIFIR argumanla bicimlendirme -------------------------------------
# GERCEK HATA: T'nin icindeki kontrol "if ($Arg -and ...)" seklindeydi.
# PowerShell tek elemanli diziyi bool baglaminda ACTIGI icin @(0) ifadesi
# $false oluyordu; port numarasi 0 olan makinede durum panelinde
# "port {0}" metni BICIMLENDIRILMEDEN goruntulendi. Bir daha olmasin.
Write-Host ""
Write-Host "6) Sifir/bos degerle bicimlendirme"
$sifirHata = 0
foreach ($deger in @(0, 0.0, '', $false)) {
    $c = T 'ram-port' @($deger)
    if ($c -match '\{\d\}') { Basarisiz ("'$deger' degeriyle yer tutucu doldurulmadi: $c"); $sifirHata++ }
}
if ($sifirHata -eq 0) { Write-Host "   0 / 0.0 / bos metin / `$false hepsi dogru bicimlendi" -ForegroundColor Green }

# --- Ornek cikti ----------------------------------------------------------
# Kullanicinin dil secimi TEST YUZUNDEN DEGISMESIN - once yedeklenir.
$yedek = $null
if (Test-Path -LiteralPath $script:DilDosyasi) { $yedek = Get-Content -LiteralPath $script:DilDosyasi -Raw }

Write-Host ""
Write-Host "Ornek metinler:"
foreach ($d in @('en','tr')) {
    Set-Dil -Kod $d
    Write-Host ("  [$d] " + (T 'baslik') + " | " + (T 'grp-sogutma').Trim() + " | " +
                (T 'hiz-not' @(40)))
    Write-Host ("       " + (T 'ekd-akis' @(3, 1)) + " | " + (T 'eksik-yok' @((T 'eksik-pompa'))))
}

if ($null -ne $yedek) { Set-Content -LiteralPath $script:DilDosyasi -Value $yedek.Trim() -Encoding ASCII }
else { Remove-Item -LiteralPath $script:DilDosyasi -ErrorAction SilentlyContinue }

Write-Host ""
if ($hata -eq 0) { Write-Host "GECTI: dil tablosu tutarli." -ForegroundColor Green; exit 0 }
Write-Host "BASARISIZ: $hata sorun" -ForegroundColor Red
exit 1
