# LcdDaemon.ps1 - Fan LCD ekranlarini besleyen arka plan sureci.
#
# YONETICI YETKISI GEREKMEZ.
#
# NEDEN AYRI BIR SUREC:
#   Ekranlarda GIF SAKLANMIYOR. Cihazin video kodegi yok; animasyon, JPEG
#   karelerinin saniyede ~14 kez gonderilmesiyle olusuyor. Yani biri surekli
#   beslemezse goruntu son karede donar.
#   Kullanici "programi kapatinca da donmeye devam etsin" istedigi icin akis
#   CoolApp'in icinden alinip bu bagimsiz surece tasindi. CoolApp artik
#   ekranlari kendisi surmuyor; sadece bu sureci baslatip durduruyor.
#
# DENETIM (adlandirilmis cekirdek nesneleri, ayni oturum icinde):
#   Local\WinTempLcdRunning : bu surec calisirken var olan mutex.
#                             Baskasi acabiliyorsa daemon calisiyordur.
#   Local\WinTempLcdStop    : kurulunca dongu temiz sekilde cikar.
#
# Durumunu `lcd-durum.json` dosyasina yazar; CoolApp oradan okur.
#
# ELLE KULLANIM
#   powershell -NoProfile -ExecutionPolicy Bypass -File LcdDaemon.ps1
#   powershell ... -File LcdDaemon.ps1 -Stop        (calisani durdurur)

[CmdletBinding()]
param(
    [string]$Config,
    [switch]$Stop
)

$ErrorActionPreference = 'Stop'

$script:MutexAdi = "Local\WinTempLcdRunning"
$script:StopAdi  = "Local\WinTempLcdStop"

if (-not $Config) { $Config = Join-Path $PSScriptRoot "ekranlar.json" }
$script:DurumYolu = Join-Path $PSScriptRoot "lcd-durum.json"

# --- -Stop: calisan daemon'a cikmasini soyle, sonra bitir ---
if ($Stop) {
    try {
        $ev = [System.Threading.EventWaitHandle]::OpenExisting($script:StopAdi)
        [void]$ev.Set()
        $ev.Dispose()
    }
    catch { }   # zaten calismiyor
    exit 0
}

# --- Tek ornek: zaten calisiyorsa cik ---
$yeni = $false
$mutex = New-Object System.Threading.Mutex($true, $script:MutexAdi, [ref]$yeni)
if (-not $yeni) {
    $mutex.Dispose()
    exit 0
}

. (Join-Path $PSScriptRoot "lib\LianLiLcd.ps1")

# Durdurma olayi - her acilista sifirlanir, yoksa onceki cikis sinyali
# yeni daemon'u aninda oldururdu.
$olayYeni = $false
$stopOlay = New-Object System.Threading.EventWaitHandle(
    $false, [System.Threading.EventResetMode]::ManualReset, $script:StopAdi, [ref]$olayYeni)
[void]$stopOlay.Reset()

# DURUM: metin DEGIL kod yazilir.
#
# Bu surec Windows acilisinda arayuzden once baslayabiliyor ve kullanicinin
# hangi dili sectigini bilmesi gerekmiyor. Bu yuzden 'akis' / 'ekran-yok'
# gibi DEGISMEZ KODLAR yazar; ceviriyi okuyan taraf (CoolApp) yapar.
# Boylece kullanici dili degistirdiginde daemon'u yeniden baslatmak
# gerekmiyor.
#
# 'Durum' alani (Ingilizce duz metin) elle inceleme icin KORUNUYOR - json'a
# bakan biri kod tablosunu ezberlemek zorunda kalmasin.
$script:Durum = @{
    DurumKod  = "basliyor"
    Durum     = "starting"
    Fps       = 0.0
    Hareketli = 0
    Sabit     = 0
    Hata      = $null
    Not       = $null
}

function Set-DurumKod {
    param([Parameter(Mandatory)][string]$Kod, [string]$Metin)
    $script:Durum.DurumKod = $Kod
    $script:Durum.Durum    = if ($Metin) { $Metin } else { $Kod }
}

function Write-Durum {
    try {
        $script:Durum.Zaman = (Get-Date).ToString('o')
        $script:Durum | ConvertTo-Json | Set-Content -Path $script:DurumYolu -Encoding UTF8
    }
    catch { }   # durum yazamamak akisi durdurmamali
}

$ekranlar = @()
try {
    Write-Durum

    if (-not (Test-Path -LiteralPath $Config)) {
        Set-DurumKod 'ayar-yok' "no settings file"; Write-Durum; return
    }

    $ayar = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
    $atamalar = @{}
    if ($ayar.PSObject.Properties.Name -contains 'Atamalar' -and $ayar.Atamalar) {
        foreach ($p in $ayar.Atamalar.PSObject.Properties) { $atamalar[$p.Name] = [string]$p.Value }
    }
    $parlaklik = if ($ayar.PSObject.Properties.Name -contains 'Parlaklik' -and $ayar.Parlaklik) { [int]$ayar.Parlaklik } else { 100 }
    $kalite    = if ($ayar.PSObject.Properties.Name -contains 'Kalite'    -and $ayar.Kalite)    { [int]$ayar.Kalite }    else { 55 }

    $infos = @(Get-TlLcdDeviceInfos)
    if ($infos.Count -eq 0) { Set-DurumKod 'ekran-yok' "no screens found"; Write-Durum; return }

    # Indeks fiziksel konumdur, USB yolu degisse bile sabit: 2=ust, 1=orta, 0=alt
    foreach ($info in $infos) {
        $dev = Open-TlLcd -Info $info
        $k = Get-TlLcdIdentity -Device $dev
        $ekranlar += [PSCustomObject]@{
            Cihaz     = $dev
            Indeks    = if ($null -ne $k) { $k.Indeks } else { 0 }
            Kareler   = $null
            K         = 0
            SonrakiMs = 0.0
        }
    }
    $ekranlar = @($ekranlar | Sort-Object Indeks)

    # Bulunan indeksleri durum dosyasina yaz. Arayuz bunu OKUYARAK satirlarini
    # kurar; boylece ekranlari ikinci kez acip kimlik sormasi gerekmez
    # (daemon kare akitirken gelen kimlik cevabi akisla karisabilir).
    $script:Durum.Indeksler = @($ekranlar | ForEach-Object { [int]$_.Indeks })
    Write-Durum

    foreach ($e in $ekranlar) {
        try { Set-TlLcdSettings -Device $e.Cihaz -Brightness $parlaklik -Rotation 0 -Mode 1 } catch { }
    }

    # --- Kareleri hazirla ---
    Set-DurumKod 'kodlaniyor' "encoding frames"
    Write-Durum

    $hareketli = @()
    $sabitSayi = 0
    $hatalar = @()
    $notlar  = @()

    foreach ($e in $ekranlar) {
        $yol = $atamalar[[string]$e.Indeks]
        # Atanmamis ekrana DOKUNULMAZ - uzerindeki goruntu neyse oyle kalir
        if ([string]::IsNullOrWhiteSpace($yol) -or -not (Test-Path -LiteralPath $yol)) { continue }

        try { $r = ConvertTo-TlLcdFrames -Path $yol -Quality $kalite }
        catch { $hatalar += $_.Exception.Message; continue }

        if ($r.Not) { $notlar += $r.Not }

        if ($r.Animasyonlu) {
            $e.Kareler = @($r.Kareler)
            $hareketli += $e
        }
        else {
            # Sabit goruntu ACK'li yolla bir kez gonderilir ve cihazda KALICI kalir
            try {
                $null = Send-TlLcdImageData -Device $e.Cihaz -Jpeg $r.Kareler[0].Jpeg
                Set-TlLcdSettings -Device $e.Cihaz -Brightness $parlaklik -Rotation 0 -Mode 1
                $sabitSayi++
            }
            catch { $hatalar += $_.Exception.Message }
        }
    }

    if ($hatalar.Count -gt 0) { $script:Durum.Hata = $hatalar[0] }
    if ($notlar.Count  -gt 0) { $script:Durum.Not  = $notlar[0] }

    $script:Durum.Sabit = $sabitSayi

    if ($hareketli.Count -eq 0) {
        # Sabit goruntuler cihazda kalicidir; beslemeye gerek yok, cikabiliriz.
        if ($sabitSayi -gt 0) { Set-DurumKod 'sabit' "$sabitSayi static image(s) printed" }
        else                  { Set-DurumKod 'atama-yok' "no files assigned" }
        Write-Durum
        return
    }

    # --- Akis dongusu ---
    # DIKKAT: akis oncesi mod 4'e GECILMEZ. Mod 4'te cihaz 0x46 karelerini
    # ekrana basmiyor, onceki sabit goruntude kaliyor. Dogrusu mod 1.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $sayac = 0
    $olcumBasi = 0.0

    while (-not $stopOlay.WaitOne(0)) {

        $simdi = $sw.Elapsed.TotalMilliseconds
        $isYapildi = $false

        foreach ($e in $hareketli) {
            if ($simdi -lt $e.SonrakiMs) { continue }
            $kare = $e.Kareler[$e.K]
            try { $null = Send-TlLcdImageData -Device $e.Cihaz -Jpeg $kare.Jpeg -Streaming }
            catch { $script:Durum.Hata = $_.Exception.Message }

            $e.K = ($e.K + 1) % $e.Kareler.Count
            # Geri kalmissak birikmis gecikmeyi kovalamayalim
            $e.SonrakiMs = [Math]::Max($simdi, $e.SonrakiMs) + $kare.GecikmeMs
            $sayac++
            $isYapildi = $true
        }

        if (-not $isYapildi) { Start-Sleep -Milliseconds 4 }

        $gecen = ($sw.Elapsed.TotalMilliseconds - $olcumBasi) / 1000.0
        if ($gecen -ge 2.0) {
            $script:Durum.Fps = [Math]::Round($sayac / $gecen / $hareketli.Count, 1)
            $script:Durum.Hareketli = $hareketli.Count
            Set-DurumKod 'akis' ("{0} animated, {1} static screen(s)" -f $hareketli.Count, $sabitSayi)
            Write-Durum
            $sayac = 0
            $olcumBasi = $sw.Elapsed.TotalMilliseconds
        }
    }

    Set-DurumKod 'durduruldu' "stopped"
    $script:Durum.Fps = 0.0
    Write-Durum
}
catch {
    Set-DurumKod 'hata' "error"
    $script:Durum.Hata = $_.Exception.Message
    Write-Durum
}
finally {
    foreach ($e in $ekranlar) { try { $e.Cihaz.Dispose() } catch { } }
    try { $stopOlay.Dispose() } catch { }
    try { $mutex.ReleaseMutex() } catch { }
    try { $mutex.Dispose() } catch { }
}
