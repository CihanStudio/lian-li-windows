# test-tepsi.ps1 - Tepsiye kucultme ve tepsiye acilma yollarini sinar.
#
# NEDEN VAR: bu davranis iki olayda saklidir (Add_Resize, Add_Shown) ve gozle
# bakmadan sinanmasi zor. test-arayuz.ps1'deki yontem kullaniliyor: sondaki
# Application.Run cagrisi olculen bir blokla degistiriliyor.
#
# NEDEN AYRI SURECLER: olcum betigi ayni oturumda IKI KEZ calistirilamiyor -
# HidCore gomulu C# tipini Add-Type ile kuruyor, ikinci kez "tip zaten var"
# diye patliyor. Bu yuzden her senaryo kendi powershell surecinde kosuyor ve
# sonucunu JSON dosyasina birakiyor.
#
# Donanim GEREKTIRMEZ, yonetici GEREKTIRMEZ (-NoElevate ile calisir). Ama
# test-arayuz.ps1 den FARKLI olarak pencereyi gercekten aciyor, yani takili
# donanim varsa uygulamayi kisa sure calistirmis olur - SADECE OKUR, hicbir
# sey yazmaz ve sonunda cihazlari kapatir.
#
# Kullanim: powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-tepsi.ps1

$ErrorActionPreference = 'Stop'
$kok = Split-Path $PSScriptRoot -Parent
$src = Get-Content -LiteralPath (Join-Path $kok "CoolApp.ps1") -Raw

if ($src -notmatch '\[System\.Windows\.Forms\.Application\]::Run\(\$form\)') {
    throw "CoolApp.ps1 icinde Application.Run satiri bulunamadi - test uyarlanmali."
}

$olcumBlogu = @'
$global:TepsiSonuc = @{}

if ($Minimized) {
    # Acilista tepsiye inme yolu: pencere hic gorunmeden gizlenmeli.
    # Gorunmezligi saglayan ayarlar CoolApp'in kendisinde, Run'dan hemen
    # once - test onlara dokunmuyor, sonucunu olcuyor.
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()

    $global:TepsiSonuc['acilista-gizli']    = (-not $form.Visible)
    $global:TepsiSonuc['acilista-simge']    = $script:Tepsi.Visible
    $global:TepsiSonuc['gorev-cubugu-geri'] = $form.ShowInTaskbar
    $global:TepsiSonuc['saydamlik-geri']    = ($form.Opacity -eq 1)
}
else {
    # Resize olayi ancak GERCEKTEN gosterilmis pencerede tetikleniyor -
    # tutamaci elle olusturmak yetmiyor (denendi, olay hic gelmedi ve test
    # yanlis "gecti" dedi). Bu yuzden pencere aciliyor ama Opacity=0 ile
    # gorunmez, gorev cubuguna da dusmuyor: test kimseyi rahatsiz etmesin.
    $form.Opacity = 0
    $form.ShowInTaskbar = $false
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()

    $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
    [System.Windows.Forms.Application]::DoEvents()
    $global:TepsiSonuc['gizlendi']      = (-not $form.Visible)
    $global:TepsiSonuc['simge-acildi']  = $script:Tepsi.Visible
    $global:TepsiSonuc['yoklama-durdu'] = (-not $script:DurumZamanlayici.Enabled)

    Show-Pencere
    [System.Windows.Forms.Application]::DoEvents()
    $global:TepsiSonuc['geri-geldi']      = $form.Visible
    $global:TepsiSonuc['normal-boyut']    = ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal)
    $global:TepsiSonuc['simge-kapandi']   = (-not $script:Tepsi.Visible)
    $global:TepsiSonuc['yoklama-basladi'] = $script:DurumZamanlayici.Enabled

    # Dil degisince tepsi menusu de yeniden yazilmali - unutulursa menu
    # eski dilde takili kalir.
    Set-Dil -Kod 'tr'; Update-Dil
    $trGoster = $script:TepsiGoster.Text
    Set-Dil -Kod 'en'; Update-Dil
    $global:TepsiSonuc['menu-cevriliyor'] = ($trGoster -ne $script:TepsiGoster.Text)
}

$script:DurumZamanlayici.Stop()
$script:Tepsi.Visible = $false
$script:Tepsi.Dispose()
$form.Dispose()
try { Close-Devices } catch { }

$global:TepsiSonuc | ConvertTo-Json | Set-Content -LiteralPath $env:TEPSI_SONUC -Encoding UTF8
'@

# Gecici kopya UYGULAMA KLASORUNDE olmali: lib\ ve json yollari
# $PSScriptRoot'a gore cozuluyor.
$gecici    = Join-Path $kok "CoolApp-testTepsi.ps1"
$sonucYolu = Join-Path $env:TEMP "tepsi-sonuc.json"
Set-Content -LiteralPath $gecici -Value ($src.Replace('[System.Windows.Forms.Application]::Run($form)', $olcumBlogu)) -Encoding UTF8

# Kullanicinin dil secimi test yuzunden degismesin
$dilDosyasi = Join-Path $kok "dil.txt"
$dilYedek = if (Test-Path -LiteralPath $dilDosyasi) { Get-Content -LiteralPath $dilDosyasi -Raw } else { $null }

function Invoke-Senaryo {
    param([string[]]$Arguman)

    Remove-Item -LiteralPath $sonucYolu -Force -ErrorAction SilentlyContinue
    $env:TEPSI_SONUC = $sonucYolu

    $hepsi = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $gecici) + $Arguman
    & powershell @hepsi | Out-Null

    if (-not (Test-Path -LiteralPath $sonucYolu)) {
        throw ("Olcum betigi sonuc birakmadi: powershell " + ($Arguman -join ' '))
    }
    return (Get-Content -LiteralPath $sonucYolu -Raw | ConvertFrom-Json)
}

$cikis = 0

function Test-Sonuc {
    param($Sonuc, [string]$Ad, [string]$Aciklama)

    if ($Sonuc.$Ad) { Write-Host ("   TAMAM  {0}" -f $Aciklama) -ForegroundColor Green }
    else { Write-Host ("   HATA   {0}" -f $Aciklama) -ForegroundColor Red; $script:cikis = 1 }
}

try {
    Write-Host "1) Kucultme dugmesiyle tepsiye inme"
    $n = Invoke-Senaryo -Arguman @('-NoElevate')
    Test-Sonuc $n 'gizlendi'        'kucultunce pencere gizlendi'
    Test-Sonuc $n 'simge-acildi'    'tepsi simgesi gorundu'
    Test-Sonuc $n 'yoklama-durdu'   'gizliyken durum yoklamasi durdu'
    Test-Sonuc $n 'geri-geldi'      'geri cagirinca pencere gorundu'
    Test-Sonuc $n 'normal-boyut'    'pencere normal boyuta dondu'
    Test-Sonuc $n 'simge-kapandi'   'tepsi simgesi kayboldu'
    Test-Sonuc $n 'yoklama-basladi' 'geri gelince yoklama basladi'
    Test-Sonuc $n 'menu-cevriliyor' 'tepsi menusu dil degisimini izliyor'

    Write-Host ""
    Write-Host "2) -Minimized ile dogrudan tepsiye acilma"
    $m = Invoke-Senaryo -Arguman @('-NoElevate', '-Minimized')
    Test-Sonuc $m 'acilista-gizli'    'pencere hic gorunmedi'
    Test-Sonuc $m 'acilista-simge'    'tepsi simgesi gorundu'
    Test-Sonuc $m 'gorev-cubugu-geri' 'gorev cubugu geri acildi'
    Test-Sonuc $m 'saydamlik-geri'    'saydamlik geri acildi'
}
finally {
    Remove-Item -LiteralPath $gecici -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sonucYolu -Force -ErrorAction SilentlyContinue
    if ($null -ne $dilYedek) { Set-Content -LiteralPath $dilDosyasi -Value $dilYedek.Trim() -Encoding ASCII }
    else { Remove-Item -LiteralPath $dilDosyasi -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
if ($cikis -eq 0) { Write-Host "GECTI: tepsi davranisi calisiyor." -ForegroundColor Green }
else { Write-Host "BASARISIZ" -ForegroundColor Red }
exit $cikis
