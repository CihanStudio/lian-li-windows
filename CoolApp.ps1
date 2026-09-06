# CoolApp.ps1 - Tum sogutma ve isik kontrolu icin TEK masaustu uygulamasi.
#
# Uretici programi yok: L-Connect, iCUE, FanControl, GIGABYTE Control Center
# hicbiri gerekmiyor. Windows'un yerlesik HID yigini + PawnIO cekirdek modulu.
#
# KONTROL EDILENLER
#   Lian Li TL fanlari       hiz + RGB      (USB HID 0416:7372)
#   Galahad II AIO pompasi   hiz + RGB      (USB HID 0416:7373)
#   Pompa basligi Ic/Dis     RGB
#   AIO fan kanali           RGB
#   Corsair DDR5 bellek      RGB            (SMBus, 4 modul)
#   TL fan LCD ekranlari     GIF dongusu    (USB HID 04FC:7393, 3 ekran)
#
# OKUNANLAR
#   CPU sicakligi/gucu, GPU sicaklik/fan/yuk, fan ve pompa devirleri
#
# GPU FANI bilerek NVIDIA'nin otomatik egrisinde birakildi: yazmak icin ayri
# yetki gerekiyor ve dusuk hizda sabitlemek termal risk.
#
# YETKI
#   Uygulama acilista BIR KEZ yonetici ister. Sebep: CPU sicakligi ve bellek
#   RGB'si cekirdek modulu (PawnIO) uzerinden gidiyor. Fanlar ve diger isiklar
#   yetki istemez; yonetici reddedilirse onlar yine calisir, digerleri kapanir.

[CmdletBinding()]
param([switch]$NoElevate)

# ---------------------------------------------------------------------------
# Yonetici yukseltmesi - kendini yeniden baslatir
# ---------------------------------------------------------------------------
function Test-Yonetici {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

$script:Yetkili = Test-Yonetici

if (-not $script:Yetkili -and -not $NoElevate) {
    try {
        Start-Process powershell -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', "`"$PSCommandPath`""
        ) -ErrorAction Stop
        exit 0
    }
    catch {
        # Kullanici UAC'yi reddetti - yetkisiz devam et, ilgili ozellikler kapali kalir
        $script:Yetkili = $false
    }
}

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Uygulama klasoru bir kez saklanir. $PSScriptRoot fonksiyon icinde de
# calisir ama acikca tutmak hem okunakli hem de sinanabilir kiliyor.
$script:AppKlasoru = $PSScriptRoot

$libDir = Join-Path $PSScriptRoot "lib"

# Dil EN BASTA yuklenir - asagidaki hata yakalayicisi bile cevrilmis metin
# kullaniyor. Varsayilan dil Windows'un dilinden gelir, kullanici secerse
# secimi diske yazilir (bkz. lib/Dil.ps1).
. (Join-Path $libDir "Dil.ps1")

# Konsol gizli calistigi icin hatalar aksi halde GORUNMEZ olurdu.
# Beklenmeyen her hatayi pencerede goster ve temiz cik.
trap {
    $mesaj = T 'catik-govde' @($_.Exception.Message, $_.ScriptStackTrace)
    [System.Windows.Forms.MessageBox]::Show($mesaj, (T 'catik-baslik'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    try { Close-Devices } catch {}
    exit 1
}

. (Join-Path $libDir "LianLiTL.ps1")
. (Join-Path $libDir "LianLiGA2.ps1")
. (Join-Path $libDir "NvApi.ps1")
# Burada yalnizca secilen dosyayi dogrulamak icin gerekli; ekranlara
# gonderimi ayri surec (LcdDaemon.ps1) kendi kopyasiyla yapar.
. (Join-Path $libDir "LianLiLcd.ps1")
if ($script:Yetkili) {
    . (Join-Path $libDir "AmdCpu.ps1")
    . (Join-Path $libDir "CorsairDram.ps1")
}

# ---------------------------------------------------------------------------
# Cihaz durumu
# ---------------------------------------------------------------------------
# TL kontrolculeri BIR LISTE: 4 port x 16 fan sinirini asan kullanicilar
# ikinci bir kontrolcu takiyor. $script:TlFanlar'daki her fan, hangi
# kontrolcuye ait oldugunu kendi 'Dev' alaninda tasir - port/fan indeksi
# kontrolcu icinde benzersiz, kontrolculer ARASINDA degil.
$script:TlDevs   = @()
$script:Ga2Dev   = $null
$script:TlFanlar = @()
$script:CpuH     = [IntPtr]::Zero
$script:SmbH     = [IntPtr]::Zero
$script:Gpu      = $null
$script:EkranSayisi = 0

# Guc hesabi icin onceki enerji sayaci (uyumadan watt hesaplamak icin)
$script:OncekiEnerji = $null
$script:OncekiZaman  = $null
$script:EnerjiBirimi = $null

# ---------------------------------------------------------------------------
# BELLEK RGB ADRESLERI
#
# DDR5'te SPD adresleri 0x50-0x57 (8 yuva), RGB denetleyicisi = SPD - 0x38.
# Yani butun olasi denetleyiciler 0x18-0x1F araliginda.
#
# NEDEN TUM ARALIGA YAZILIYOR, "BULUNAN" ADRESLERE DEGIL:
#   ACK yoklamasi bu denetleyicilerde adres bazinda GUVENILMEZ. Olculdu:
#   0x19 ve 0x1B kimi taramada yanit veriyor, kimi taramada vermiyor - ama
#   BLOK YAZMA her iki durumda da calisiyor (2. ve 4. modulun rengi
#   degistigi gozle dogrulandi). Tarama sonucuna gore adres secmek
#   modullerin yarisini SESSIZCE disarida birakiyordu.
#   Bos bir adrese yazmak zararsizdir (cihaz yoksa NACK, hicbir sey olmaz).
#   Tehlikeli araliklar (PMIC 0x48-0x4F, SPD hub 0x50-0x57) kutuphane
#   seviyesinde kalici olarak yasak - bkz. lib/Smbus.ps1.
#
# Tarama YALNIZCA hangi SMBus PORTUNDA olduklarini bulmak icin kullanilir;
# o soru ("bu portta herhangi bir sey var mi") adres bazli sorudan cok daha
# saglam cevaplaniyor.
# ---------------------------------------------------------------------------
$script:RamAdresleri = 0x18..0x1F
$script:RamPort         = 0      # Find-RamSmbusPort ile guncellenir
$script:RamPortBulundu  = $false # yoklama yanit verdi mi (durum panelinde yazilir)

function Find-RamSmbusPort {
    <#
      Bellek RGB denetleyicilerinin hangi SMBus portunda oldugunu bulur.
      Salt yoklama - hicbir veri yazilmaz (QUICK islemi veri tasimaz).
      Hicbir portta yanit yoksa port 0'a duser: bu makinede dogru olan o,
      ve yanit alinamamasi cihazin yoklugu anlamina GELMIYOR.
    #>
    param([Parameter(Mandatory)][IntPtr]$Handle)

    $enIyiPort = -1
    $enIyiSayi = 0

    foreach ($port in 0..4) {
        try { $null = Set-SmbusPort -Handle $Handle -Port $port } catch { continue }
        Start-Sleep -Milliseconds 20

        $sayi = 0
        foreach ($a in $script:RamAdresleri) {
            # QUICK, yazma yonu. TryExecute HRESULT dondurur; 0 = ACK.
            $in = @([uint64]$a, [uint64]0, [uint64]0, [uint64]0)
            $res = $null
            if ([PawnIO.Lib]::TryExecute($Handle, "ioctl_smbus_xfer", $in, 1, [ref]$res) -eq 0) { $sayi++ }
            Start-Sleep -Milliseconds 2
        }

        if ($sayi -gt $enIyiSayi) { $enIyiSayi = $sayi; $enIyiPort = $port }
    }

    try { $null = Set-SmbusPort -Handle $Handle -Port 0 } catch { }

    if ($enIyiPort -ge 0) {
        return [PSCustomObject]@{ Port = $enIyiPort; Yanit = $enIyiSayi; Bulundu = $true }
    }
    return [PSCustomObject]@{ Port = 0; Yanit = 0; Bulundu = $false }
}

function Open-Devices {
    <#
      DIKKAT - "yok" ile "bozuk" AYRI SEYLER:
      Cihazin TAKILI OLMAMASI hata degildir. AIO'su veya LCD'si olmayan bir
      kullaniciya kirmizi hata gostermek yanlis alarm olur; o durum ilgili
      bolumun basliginda anlatilir (bkz. Update-DonanimGorunumu).
      Buraya SADECE gercek basarisizlik eklenir: cihaz var ama acilamadi.
    #>
    $sorunlar = @()

    # TL kontrolculeri - kac tane varsa hepsi. Bir kontrolcu acilamazsa
    # DIGERLERI YINE DE ACILIR: tek arizali cihaz butun fanlari kaybettirmesin.
    $tlNo = 0
    foreach ($info in @(Get-TLDeviceInfos)) {
        $tlNo++
        try {
            $dev = [LianLi.HidCore]::Open($info)
            $script:TlDevs += $dev

            $hs = Get-TLFans -Device $dev
            if ($hs) {
                foreach ($f in ($hs.Fans | Where-Object { $_.Detected } | Sort-Object Port, FanIndex)) {
                    # Fan kaydina cihazi ve kacinci kontrolcu oldugunu ekle.
                    $script:TlFanlar += ($f | Add-Member -NotePropertyMembers @{
                        Dev          = $dev
                        KontrolcuNo  = $tlNo
                    } -PassThru)
                }
            }
        }
        catch { $sorunlar += (T 'ac-tl' @($tlNo, $_.Exception.Message)) }
    }

    try {
        $info = Get-GA2DeviceInfo
        if ($info) { $script:Ga2Dev = [LianLi.HidCore]::Open($info) }
    }
    catch { $sorunlar += (T 'ac-aio' @($_.Exception.Message)) }

    # LCD ekranlari BURADA SAYILMAZ: arayuz satirlari onlara gore kuruldugu
    # icin tespit daha erken yapiliyor (bkz. "EKRAN TESPITI" blogu).
    # Burada tekrar saymak, satirlarla durumu celiskiye dusurebilirdi.

    try {
        $gpus = Get-NvGpus
        if ($gpus.Count -gt 0) { $script:Gpu = $gpus[0] }
    }
    catch { $sorunlar += (T 'ac-gpu' @($_.Exception.Message)) }

    if ($script:Yetkili) {
        try {
            $script:CpuH = Open-AmdCpuModule
            $birim = Get-AmdRaplUnits -Handle $script:CpuH
            if ($birim) { $script:EnerjiBirimi = $birim.EnergyUnitJ }
        }
        catch { $sorunlar += (T 'ac-cpu' @($_.Exception.Message)) }

        try {
            $script:SmbH = Open-SmbusModule
            # Bellek hangi SMBus portunda? Anakarta gore degisir, o yuzden
            # sabit kabul edilmez - acilista bir kez yoklanir (~1 sn).
            Invoke-WithSmbusLock -TimeoutMs 10000 -Action {
                $b = Find-RamSmbusPort -Handle $script:SmbH
                $script:RamPort    = $b.Port
                # Metin DEGIL, dilden bagimsiz veri saklaniyor: kullanici dili
                # degistirdiginde durum paniosunun yeniden yoklama yapmasi
                # gerekmesin diye ceviri gosterim aninda yapiliyor.
                $script:RamPortBulundu = $b.Bulundu
            }
        }
        catch { $sorunlar += (T 'ac-bellek' @($_.Exception.Message)) }
    }

    return $sorunlar
}

function Close-Devices {
    foreach ($d in $script:TlDevs) { try { $d.Dispose() } catch {} }
    if ($script:Ga2Dev) { try { $script:Ga2Dev.Dispose() } catch {} }
    if ($script:CpuH -ne [IntPtr]::Zero) { try { Close-PawnIOModule -Handle $script:CpuH } catch {} }
    if ($script:SmbH -ne [IntPtr]::Zero) { try { Close-PawnIOModule -Handle $script:SmbH } catch {} }
}

# ---------------------------------------------------------------------------
# LCD ekranlari - AYRI BIR SUREC (LcdDaemon.ps1) tarafindan surulur
#
# NEDEN AYRI SUREC: Ekranlarda GIF SAKLANMIYOR. Animasyon, JPEG karelerinin
# saniyede ~14 kez gonderilmesiyle olusuyor; besleme kesilirse goruntu son
# karede donar. Kullanici "programi kapatinca da donmeye devam etsin"
# istedigi icin akis bu uygulamadan cikarilip bagimsiz bir surece tasindi.
# CoolApp artik ekranlari kendi surmuyor; sadece daemon'u baslatip durduruyor
# ve durumunu okuyor. Bu ayni zamanda arayuzun donmasini da engelliyor.
#
# Sabit goruntuler (jpg/png/webp) cihazda KALICI oldugu icin onlar zaten
# daemon olmadan da ekranda kalir; daemon yalnizca animasyon icin gerekli.
# ---------------------------------------------------------------------------
$script:EkranAyarYolu = Join-Path $PSScriptRoot "ekranlar.json"
$script:EkranDurumYolu = Join-Path $PSScriptRoot "lcd-durum.json"
$script:DaemonYolu    = Join-Path $PSScriptRoot "LcdDaemon.ps1"
$script:LcdMutexAdi   = "Local\WinTempLcdRunning"

# Ekran indeksleri ve adlari SABIT DEGIL - kac ekran varsa o kadar satir
# kurulur. Tespit, gerekli fonksiyonlar tanimlandiktan hemen sonra yapilir
# (bkz. "EKRAN TESPITI" blogu); arayuz kurulmadan once hazir olmasi sart.
$script:EkranIndeksleri = @()
$script:EkranAdlari     = @{}

# Arayuzun tuttugu ayar; diske yazilip daemon tarafindan okunur.
$script:EkranAyari = @{
    Atamalar  = @{}
    Parlaklik = 100
    Kalite    = 55      # "orta" - fps ile keskinlik arasindaki tatli nokta
}

function Import-EkranAyari {
    if (-not (Test-Path $script:EkranAyarYolu)) { return }
    try {
        $j = Get-Content $script:EkranAyarYolu -Raw -Encoding UTF8 | ConvertFrom-Json
        $h = @{}
        if ($j.PSObject.Properties.Name -contains 'Atamalar' -and $j.Atamalar) {
            foreach ($p in $j.Atamalar.PSObject.Properties) {
                # Dosya silinmis olabilir - yoksa atamayi geri yukleme
                if ($p.Value -and (Test-Path -LiteralPath $p.Value)) { $h[$p.Name] = [string]$p.Value }
            }
        }
        $script:EkranAyari.Atamalar = $h
        if ($j.PSObject.Properties.Name -contains 'Parlaklik' -and $j.Parlaklik) {
            $script:EkranAyari.Parlaklik = [int]$j.Parlaklik
        }
    }
    catch { }   # bozuk ayar dosyasi uygulamayi engellememeli
}

function Export-EkranAyari {
    try {
        $script:EkranAyari | ConvertTo-Json -Depth 4 |
            Set-Content -Path $script:EkranAyarYolu -Encoding UTF8
    }
    catch { }
}

function Test-LcdDaemon {
    <#
      Daemon calisiyor mu? Mutex nesnesi son tutamak kapaninca yok oldugu
      icin "acilabiliyor" = "surec yasiyor" demektir. Actigimiz tutamagi
      HEMEN birakiyoruz, yoksa nesneyi biz ayakta tutariz.
    #>
    try {
        $m = [System.Threading.Mutex]::OpenExisting($script:LcdMutexAdi)
        $m.Dispose()
        return $true
    }
    catch { return $false }
}

function Start-LcdDaemon {
    Export-EkranAyari
    if (Test-LcdDaemon) { return }

    Start-Process powershell -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', "`"$script:DaemonYolu`""
    ) -WindowStyle Hidden | Out-Null
}

function Stop-LcdDaemon {
    if (-not (Test-LcdDaemon)) { return }

    # Daemon'a cikmasini soyle. Kendi -Stop anahtarini kullaniyoruz ki
    # olayin adi tek bir yerde tanimli kalsin.
    Start-Process powershell -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', "`"$script:DaemonYolu`"", '-Stop'
    ) -WindowStyle Hidden -Wait | Out-Null

    # Cihaz tutamaklarini birakmasi icin kisa sure taniyoruz
    $bekleme = 0
    while ((Test-LcdDaemon) -and $bekleme -lt 4000) {
        Start-Sleep -Milliseconds 100
        $bekleme += 100
    }
}

function Restart-LcdDaemon {
    Stop-LcdDaemon
    Start-LcdDaemon
}

# ---------------------------------------------------------------------------
# Windows ile baslangic
#
# IKI AYRI SEY, IKI AYRI YONTEM - cunku yetki ihtiyaclari farkli:
#
#   Ekranlar (LcdDaemon)  : yonetici GEREKTIRMEZ.
#       Baslangic klasorune gizli bir kisayol konur. Basit ve temiz.
#
#   Uygulama (CoolApp)    : yonetici GEREKTIRIR (CPU sensoru + bellek RGB).
#       Baslangic klasorune konsaydi her acilista UAC penceresi cikardi.
#       Bunun yerine "en yuksek ayricalikla" bir ZAMANLANMIS GOREV
#       olusturuluyor; Windows gorevi sessizce yetkili baslatir, UAC
#       sormaz. Gorevi kurmak yonetici ister - uygulama zaten yetkili.
#
# Ikisi de tamamen kullanicinin denetiminde: kutu isaretliyse kurulur,
# kaldirilirsa silinir. Varsayilan KAPALI.
# ---------------------------------------------------------------------------
$script:BaslangicKisayolu = Join-Path ([Environment]::GetFolderPath('Startup')) "WinTemp Ekranlar.lnk"
$script:BaslangicGorevAdi = "WinTemp Sogutma"

function Test-BaslangicEkran {
    return (Test-Path -LiteralPath $script:BaslangicKisayolu)
}

function Set-BaslangicEkran {
    param([bool]$Etkin)

    if (-not $Etkin) {
        if (Test-Path -LiteralPath $script:BaslangicKisayolu) {
            Remove-Item -LiteralPath $script:BaslangicKisayolu -Force
        }
        return
    }

    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($script:BaslangicKisayolu)
    $lnk.TargetPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script:DaemonYolu
    $lnk.WorkingDirectory = $script:AppKlasoru
    $lnk.WindowStyle = 7          # simge durumunda - konsol parlamasi olmasin
    $lnk.Description = T 'kisayol-aciklama'
    $lnk.Save()
}

function Test-BaslangicUygulama {
    # schtasks bulamazsa hata metni yazar ve cikis kodu 1 olur
    $null = schtasks /Query /TN $script:BaslangicGorevAdi 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Set-BaslangicUygulama {
    param([bool]$Etkin)

    if (-not $Etkin) {
        $c = schtasks /Delete /F /TN $script:BaslangicGorevAdi 2>&1
        if ($LASTEXITCODE -ne 0 -and (Test-BaslangicUygulama)) { throw ($c -join ' ') }
        return
    }

    # DIKKAT: /TR icindeki tirnaklar schtasks'a \" olarak GECMELI, yoksa
    # bosluklu yol parcalanir ve gorev calismaz.
    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $tr = '\"' + $psExe + '\" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"' +
          (Join-Path $script:AppKlasoru "CoolApp.ps1") + '\"'

    $c = schtasks /Create /F /TN $script:BaslangicGorevAdi /SC ONLOGON /RL HIGHEST /TR $tr 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($c -join ' ') }
}

function Get-LcdDurum {
    <# Daemon'un yazdigi durum dosyasini okur. Calismiyorsa $null. #>
    if (-not (Test-Path $script:EkranDurumYolu)) { return $null }
    try { return (Get-Content $script:EkranDurumYolu -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Get-EkranDurumMetni {
    <#
      Daemon'un yazdigi durum KODUNU kullanicinin diline cevirir.

      NEDEN KOD: daemon ayri bir surec ve Windows acilisinda arayuzden once
      baslayabiliyor - hangi dilin secili oldugunu bilmesi gerekmesin diye
      metni degil kodu yaziyor. Ayrica kullanici dili degistirdiginde
      daemon'u yeniden baslatmaya gerek kalmiyor.

      GERIYE DONUK: kod alani yoksa (eski daemon hala calisiyorsa) durum
      dosyasindaki hazir metin oldugu gibi gosterilir.
    #>
    param($Durum)

    $kod = if ($Durum.PSObject.Properties.Name -contains 'DurumKod') { [string]$Durum.DurumKod } else { $null }
    if ([string]::IsNullOrWhiteSpace($kod)) { return [string]$Durum.Durum }

    $hareketli = if ($Durum.PSObject.Properties.Name -contains 'Hareketli') { [int]$Durum.Hareketli } else { 0 }
    $sabit     = if ($Durum.PSObject.Properties.Name -contains 'Sabit')     { [int]$Durum.Sabit }     else { 0 }

    switch ($kod) {
        'basliyor'    { return T 'ekd-basliyor' }
        'ayar-yok'    { return T 'ekd-ayar-yok' }
        'ekran-yok'   { return T 'ekd-ekran-yok' }
        'kodlaniyor'  { return T 'ekd-kodlaniyor' }
        'sabit'       { return T 'ekd-sabit' @($sabit) }
        'atama-yok'   { return T 'ekd-atama-yok' }
        'akis'        { return T 'ekd-akis' @($hareketli, $sabit) }
        'durduruldu'  { return T 'ekd-durduruldu' }
        'hata'        { return T 'ekd-hata' }
    }
    return [string]$Durum.Durum
}

function Get-EkranIndeksleri {
    <#
      Ekranlarin INDEKSLERINI bulur. Indeks fiziksel konumdur ve atamalarin
      anahtaridir - bu yuzden daemon'un kullandigiyla AYNI olmak ZORUNDA.
      Buyukten kucuge sirali doner (ust fandan alta).

      SIRA VE SEBEPLERI:
        1) lcd-durum.json'daki liste. Daemon zaten okumus, oradan almak
           bedava. SAYI KONTROLU sart: kullanici daemon kapaliyken ekran
           ekleyip cikarmis olabilir, eski liste o zaman yaniltir.
        2) Cihazdan oku - AMA YALNIZCA DAEMON CALISMIYORSA. Daemon kare
           akitirken cihaza kimlik sormak, cevabin akisla karismasi
           riskini tasiyor.
        3) 0..N-1 varsay. En olasi dizilim (papatya zinciri sirasi) ve
           yanlissa sonuc sessiz kalmak degil: daemon o indekse atama
           bulamaz, ekrana DOKUNMAZ - yani bozmaz.
    #>
    param([int]$Sayi)
    if ($Sayi -le 0) { return @() }

    # 1) Daemon'un yazdigi liste
    try {
        $d = Get-LcdDurum
        if ($d -and ($d.PSObject.Properties.Name -contains 'Indeksler') -and $d.Indeksler) {
            $ix = @($d.Indeksler | ForEach-Object { [int]$_ })
            if ($ix.Count -eq $Sayi) { return @($ix | Sort-Object -Descending) }
        }
    }
    catch { }

    # 2) Cihazdan oku (daemon yoksa)
    if (-not (Test-LcdDaemon)) {
        try {
            $bulunan = @()
            foreach ($info in @(Get-TlLcdDeviceInfos)) {
                $dev = $null
                try {
                    $dev = Open-TlLcd -Info $info
                    $k = Get-TlLcdIdentity -Device $dev
                    $bulunan += $(if ($null -ne $k) { [int]$k.Indeks } else { 0 })
                }
                finally { if ($dev) { try { $dev.Dispose() } catch { } } }
            }
            if ($bulunan.Count -eq $Sayi) { return @($bulunan | Sort-Object -Descending) }
        }
        catch { }
    }

    # 3) Varsayim
    return @(($Sayi - 1)..0)
}

function Get-EkranAdi {
    <#
      Satir etiketi. UC ekran ve indeksler tam 2/1/0 ise olculmus fiziksel
      eslesmeyi kullaniriz (ust/orta/alt). Baska her durumda konum hakkinda
      BILGIMIZ YOK, o yuzden uydurmayiz - sadece indeksi yaziriz.
    #>
    param([int]$Indeks, [int[]]$Tumu)
    if (@($Tumu).Count -eq 3 -and
        ($Tumu -contains 0) -and ($Tumu -contains 1) -and ($Tumu -contains 2)) {
        switch ($Indeks) {
            2 { return (T 'ekran-ust') }
            1 { return (T 'ekran-orta') }
            0 { return (T 'ekran-alt') }
        }
    }
    return (T 'ekran-n' @($Indeks))
}

# ---------------------------------------------------------------------------
# EKRAN TESPITI - arayuz kurulmadan ONCE calismali, satir sayisi buna bagli.
# Sadece sayilir ve indeksi ogrenilir; cihaz surulmez (o daemon'un isi).
# ---------------------------------------------------------------------------
try { $script:EkranSayisi = @(Get-TlLcdDeviceInfos).Count } catch { $script:EkranSayisi = 0 }
$script:EkranIndeksleri = @(Get-EkranIndeksleri -Sayi $script:EkranSayisi)
foreach ($ix in $script:EkranIndeksleri) {
    $script:EkranAdlari[[string]$ix] = Get-EkranAdi -Indeks $ix -Tumu $script:EkranIndeksleri
}

# ---------------------------------------------------------------------------
# Uygulama islemleri
# ---------------------------------------------------------------------------
$script:MinFan  = 20    # fanlarin altina inmedigi taban
$script:PumpMin = 40    # pompanin altina inmedigi taban - termal guvenlik

function Set-Hiz {
    <# Tek slider tum fanlari ve pompayi ayni oranda surer. #>
    param([int]$Yuzde)

    $sonuc = @()
    $fanSeviye = [Math]::Max($Yuzde, $script:MinFan)

    if ($script:TlFanlar.Count -gt 0) {
        foreach ($f in $script:TlFanlar) {
            Set-TLFanSpeed -Device $f.Dev -Port $f.Port -FanIndex $f.FanIndex -Percent $fanSeviye | Out-Null
            Start-Sleep -Milliseconds 60
        }
        $sonuc += (T 'sonuc-fan' @($fanSeviye))
    }

    if ($script:Ga2Dev) {
        $script:GA2_PUMP_MIN_PERCENT = $script:PumpMin
        $r = Set-GA2PumpSpeed -Device $script:Ga2Dev -Percent $Yuzde
        $sonuc += (T 'sonuc-pompa' @($r.Uygulanan))
    }

    return ($sonuc -join ', ')
}

function Set-Isik {
    <#
      Ayni rengi tum hedeflere uygular.
      Efekt modu yalnizca TL fanlarinda calisir; pompa ve bellek sabit renkte
      kalir (bellekte sadece "direct" mod var, cihazda efekt uretilemiyor).
    #>
    param([string]$Hex, [string]$Mod = 'Static', [int]$Parlaklik = 4, [int]$AioParlaklik = 2, [int]$Hiz = 2)

    $hedefler = @()
    $hatalar  = @()

    foreach ($f in $script:TlFanlar) {
        try {
            Set-TLFanLight -Device $f.Dev -Port $f.Port -FanIndex $f.FanIndex `
                           -Mode $Mod -Colors @($Hex) -Brightness $Parlaklik -Speed $Hiz | Out-Null
            Start-Sleep -Milliseconds 60
        }
        catch { $hatalar += (T 'hata-tl' @($_.Exception.Message)) }
    }
    if ($script:TlFanlar.Count -gt 0) { $hedefler += (T 'hedef-tl') }

    if ($script:Ga2Dev) {
        # Pompa basliginda "Tumu" kapsami bu cihazda calismiyor - Ic ve Dis ayri ayri
        foreach ($sc in @('Inner','Outer')) {
            try {
                Set-GA2PumpLight -Device $script:Ga2Dev -Color $Hex -Brightness $AioParlaklik -Scope $sc | Out-Null
                Start-Sleep -Milliseconds 80
            }
            catch { $hatalar += (T 'hata-pompa' @($sc, $_.Exception.Message)) }
        }
        $hedefler += (T 'hedef-pompa')

        try {
            Set-GA2FanLight -Device $script:Ga2Dev -Color $Hex -Brightness $AioParlaklik | Out-Null
            $hedefler += (T 'hedef-aio-fan')
        }
        catch { $hatalar += (T 'hata-aio-fan' @($_.Exception.Message)) }
    }

    # Bellek - SMBus, mutex zorunlu
    if ($script:SmbH -ne [IntPtr]::Zero) {
        try {
            Invoke-WithSmbusLock -TimeoutMs 6000 -Action {
                Set-SmbusPort -Handle $script:SmbH -Port $script:RamPort | Out-Null
                foreach ($a in $script:RamAdresleri) {
                    Set-CorsairDramColor -Handle $script:SmbH -Address $a -Color $Hex | Out-Null
                    Start-Sleep -Milliseconds 15
                }
            }
            $hedefler += (T 'hedef-bellek')
        }
        catch { $hatalar += (T 'hata-bellek' @($_.Exception.Message)) }
    }

    return [PSCustomObject]@{ Hedefler = $hedefler; Hatalar = $hatalar }
}

function Set-IsikKapali {
    $hatalar = @()

    foreach ($f in $script:TlFanlar) {
        try { Set-TLFanLight -Device $f.Dev -Port $f.Port -FanIndex $f.FanIndex -Off | Out-Null }
        catch { $hatalar += $_.Exception.Message }
        Start-Sleep -Milliseconds 60
    }

    if ($script:Ga2Dev) {
        foreach ($sc in @('Inner','Outer')) {
            try { Set-GA2PumpLight -Device $script:Ga2Dev -Scope $sc -Off | Out-Null } catch {}
            Start-Sleep -Milliseconds 80
        }
        try { Set-GA2FanLight -Device $script:Ga2Dev -Off | Out-Null } catch {}
    }

    # Bellekte "kapali" diye bir komut yok; siyah renk yaziliyor
    if ($script:SmbH -ne [IntPtr]::Zero) {
        try {
            Invoke-WithSmbusLock -TimeoutMs 6000 -Action {
                Set-SmbusPort -Handle $script:SmbH -Port $script:RamPort | Out-Null
                foreach ($a in $script:RamAdresleri) {
                    Set-CorsairDramColor -Handle $script:SmbH -Address $a -Color '000000' | Out-Null
                    Start-Sleep -Milliseconds 15
                }
            }
        }
        catch { $hatalar += (T 'hata-bellek' @($_.Exception.Message)) }
    }

    return $hatalar
}

function Get-CpuWatt {
    <#
      Watt'i UYKUSUZ hesaplar: enerji sayacinin bir onceki okumayla farkini
      gecen sureye boler. Arayuzu dondurmamak icin boyle - Get-AmdCpuPower
      400 ms uyudugu icin zamanlayici icinde kullanilamaz.
    #>
    if ($script:CpuH -eq [IntPtr]::Zero -or $null -eq $script:EnerjiBirimi) { return $null }

    $e = Get-AmdMsr -Handle $script:CpuH -Index $script:AMD_MSR_PKG_ENERGY
    $t = [DateTime]::UtcNow
    if ($null -eq $e) { return $null }

    $sonuc = $null
    if ($null -ne $script:OncekiEnerji) {
        $a = [uint64]($script:OncekiEnerji -band 0xFFFFFFFF)
        $b = [uint64]($e -band 0xFFFFFFFF)
        $fark = if ($b -ge $a) { $b - $a } else { (0x100000000 + $b) - $a }
        $sn = ($t - $script:OncekiZaman).TotalSeconds
        if ($sn -gt 0.05) {
            $w = ($fark * $script:EnerjiBirimi) / $sn
            if ($w -gt 0 -and $w -lt 500) { $sonuc = [math]::Round($w, 1) }
        }
    }

    $script:OncekiEnerji = $e
    $script:OncekiZaman  = $t
    return $sonuc
}

# ---------------------------------------------------------------------------
# Arayuz
# ---------------------------------------------------------------------------
$yaziTipi     = New-Object System.Drawing.Font('Segoe UI', 9)
$zeminRenk    = [System.Drawing.Color]::FromArgb(32, 34, 38)
$panelRenk    = [System.Drawing.Color]::FromArgb(44, 47, 52)
$yaziRenk     = [System.Drawing.Color]::FromArgb(226, 228, 232)
$soluk        = [System.Drawing.Color]::FromArgb(150, 154, 160)

# --- Ekran bolumunun yuksekligi satir sayisina gore degisir ---
# Ekran yoksa da BIR satirlik yer birakilir; oraya aciklama notu konur.
# Referans yerlesim 3 ekran icindi (yukseklik 216); asagidaki formuller o
# degerleri birebir uretir, yani 3 ekranli makinede gorunum DEGISMEZ.
$ekranSatirSayisi  = [Math]::Max($script:EkranIndeksleri.Count, 1)
$ekranAltY         = 22 + ($ekranSatirSayisi * 30) - 2      # 3 satir -> 110
$grpEkranYukseklik = $ekranAltY + 106                        # 3 satir -> 216
# Ekran bolumu buyuyup kuculdukce altindaki her sey ayni miktarda kayar.
$kayma = $grpEkranYukseklik - 216

$form = New-Object System.Windows.Forms.Form
$form.Text = T 'baslik'
# +30: alt bilgi satirinin altinda dil secici icin ayrilan serit.
$form.Size = New-Object System.Drawing.Size(460, (920 + $kayma))
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.BackColor = $zeminRenk
$form.ForeColor = $yaziRenk
$form.Font = $yaziTipi

function New-Grup {
    param([string]$Baslik, [int]$Y, [int]$Yukseklik)
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $Baslik
    $g.ForeColor = $soluk
    $g.Location = New-Object System.Drawing.Point(12, $Y)
    $g.Size = New-Object System.Drawing.Size(420, $Yukseklik)
    $form.Controls.Add($g)
    return $g
}

# ---------- HIZ ----------
$grpHiz = New-Grup -Baslik (T 'grp-sogutma') -Y 8 -Yukseklik 130

$lblHiz = New-Object System.Windows.Forms.Label
$lblHiz.Text = "%40"
$lblHiz.Font = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
$lblHiz.ForeColor = $yaziRenk
$lblHiz.Location = New-Object System.Drawing.Point(14, 22)
$lblHiz.Size = New-Object System.Drawing.Size(110, 40)
$grpHiz.Controls.Add($lblHiz)

$trkHiz = New-Object System.Windows.Forms.TrackBar
$trkHiz.Minimum = 0
$trkHiz.Maximum = 100
$trkHiz.TickFrequency = 10
$trkHiz.LargeChange = 10
$trkHiz.Value = 40
$trkHiz.Location = New-Object System.Drawing.Point(120, 24)
$trkHiz.Size = New-Object System.Drawing.Size(288, 45)
$grpHiz.Controls.Add($trkHiz)

$lblHizNot = New-Object System.Windows.Forms.Label
$lblHizNot.Text = T 'hiz-not' @($script:PumpMin)
$lblHizNot.ForeColor = $soluk
$lblHizNot.Location = New-Object System.Drawing.Point(16, 66)
$lblHizNot.Size = New-Object System.Drawing.Size(392, 18)
$grpHiz.Controls.Add($lblHizNot)

# Dugmelerin metin ANAHTARI saklanir, metnin kendisi degil: dil degisince
# Update-Dil bu listeyi gezip yeniden yaziyor.
$hizOnAyar = @(
    @{ Anahtar = 'onayar-sessiz';  Deger = 25 },
    @{ Anahtar = 'onayar-dengeli'; Deger = 45 },
    @{ Anahtar = 'onayar-serin';   Deger = 70 },
    @{ Anahtar = 'onayar-tam';     Deger = 100 }
)
$script:OnAyarDugmeleri = @()
$x = 16
foreach ($oa in $hizOnAyar) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = T $oa.Anahtar
    $b.Tag = $oa.Deger
    $script:OnAyarDugmeleri += [PSCustomObject]@{ Dugme = $b; Anahtar = $oa.Anahtar }
    $b.Location = New-Object System.Drawing.Point($x, 90)
    $b.Size = New-Object System.Drawing.Size(94, 28)
    $b.FlatStyle = 'Flat'
    $b.BackColor = $panelRenk
    $b.ForeColor = $yaziRenk
    $b.FlatAppearance.BorderColor = $zeminRenk
    $b.Add_Click({ $trkHiz.Value = [int]$this.Tag; Invoke-HizUygula }.GetNewClosure())
    $grpHiz.Controls.Add($b)
    $x += 100
}

# ---------- ISIK ----------
$grpIsik = New-Grup -Baslik (T 'grp-isik') -Y 146 -Yukseklik 178

$pnlRenk = New-Object System.Windows.Forms.Panel
$pnlRenk.Location = New-Object System.Drawing.Point(16, 26)
$pnlRenk.Size = New-Object System.Drawing.Size(56, 56)
$pnlRenk.BackColor = [System.Drawing.Color]::FromArgb(0, 160, 255)
$pnlRenk.BorderStyle = 'FixedSingle'
$grpIsik.Controls.Add($pnlRenk)

$btnRenk = New-Object System.Windows.Forms.Button
$btnRenk.Text = T 'renk-sec'
$btnRenk.Location = New-Object System.Drawing.Point(84, 26)
$btnRenk.Size = New-Object System.Drawing.Size(120, 26)
$btnRenk.FlatStyle = 'Flat'
$btnRenk.BackColor = $panelRenk
$btnRenk.ForeColor = $yaziRenk
$btnRenk.FlatAppearance.BorderColor = $zeminRenk
$grpIsik.Controls.Add($btnRenk)

$btnKapat = New-Object System.Windows.Forms.Button
$btnKapat.Text = T 'isik-kapat'
$btnKapat.Location = New-Object System.Drawing.Point(212, 26)
$btnKapat.Size = New-Object System.Drawing.Size(120, 26)
$btnKapat.FlatStyle = 'Flat'
$btnKapat.BackColor = $panelRenk
$btnKapat.ForeColor = $yaziRenk
$btnKapat.FlatAppearance.BorderColor = $zeminRenk
$grpIsik.Controls.Add($btnKapat)

$lblMod = New-Object System.Windows.Forms.Label
$lblMod.Text = T 'efekt'
$lblMod.ForeColor = $soluk
$lblMod.Location = New-Object System.Drawing.Point(84, 60)
$lblMod.Size = New-Object System.Drawing.Size(44, 20)
$grpIsik.Controls.Add($lblMod)

$cmbMod = New-Object System.Windows.Forms.ComboBox
$cmbMod.DropDownStyle = 'DropDownList'
$cmbMod.Location = New-Object System.Drawing.Point(128, 57)
$cmbMod.Size = New-Object System.Drawing.Size(204, 24)
$cmbMod.BackColor = $panelRenk
$cmbMod.ForeColor = $yaziRenk
$cmbMod.FlatStyle = 'Flat'
try { Get-TLModes | Sort-Object | ForEach-Object { [void]$cmbMod.Items.Add($_) } } catch {}
if ($cmbMod.Items.Contains('Static')) { $cmbMod.SelectedItem = 'Static' }
elseif ($cmbMod.Items.Count -gt 0)    { $cmbMod.SelectedIndex = 0 }
$grpIsik.Controls.Add($cmbMod)

# Hazir renkler
$hazirRenkler = @('FF0000','FF6A00','FFD800','00FF21','00FFFF','0094FF','4800FF','FF00DC','FFFFFF')
$x = 16
foreach ($hx in $hazirRenkler) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($x, 94)
    $p.Size = New-Object System.Drawing.Size(38, 26)
    $p.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#$hx")
    $p.BorderStyle = 'FixedSingle'
    $p.Cursor = [System.Windows.Forms.Cursors]::Hand
    $p.Tag = $hx
    $p.Add_Click({
        $pnlRenk.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#$($this.Tag)")
        Invoke-IsikUygula
    }.GetNewClosure())
    $grpIsik.Controls.Add($p)
    $x += 43
}

$lblIsikNot = New-Object System.Windows.Forms.Label
$lblIsikNot.Text = T 'isik-not'
$lblIsikNot.ForeColor = $soluk
$lblIsikNot.Location = New-Object System.Drawing.Point(16, 128)
$lblIsikNot.Size = New-Object System.Drawing.Size(392, 18)
$grpIsik.Controls.Add($lblIsikNot)

$btnUygula = New-Object System.Windows.Forms.Button
$btnUygula.Text = T 'renk-uygula'
$btnUygula.Location = New-Object System.Drawing.Point(16, 146)
$btnUygula.Size = New-Object System.Drawing.Size(392, 26)
$btnUygula.FlatStyle = 'Flat'
$btnUygula.BackColor = [System.Drawing.Color]::FromArgb(0, 110, 190)
$btnUygula.ForeColor = [System.Drawing.Color]::White
$btnUygula.FlatAppearance.BorderColor = $zeminRenk
$grpIsik.Controls.Add($btnUygula)

# ---------- EKRANLAR ----------
$grpEkran = New-Grup -Baslik (T 'grp-ekran') -Y 332 -Yukseklik $grpEkranYukseklik

# Satirlar bulunan ekran kadar, buyuk indeksten kucuge (uc ekranli
# makinede ust/orta/alt sirasi cikar - olculmus fiziksel eslesme).
$script:EkranKutulari = @{}
$script:EkranEtiketleri = @{}   # dil degisince yeniden yazilacak satir adlari
$script:EkranSecDugmeleri = @()
$satirY = 22
foreach ($ixSayi in $script:EkranIndeksleri) {
    $ix = [string]$ixSayi

    $lb = New-Object System.Windows.Forms.Label
    $lb.Text = $script:EkranAdlari[$ix]
    $script:EkranEtiketleri[$ix] = $lb
    $lb.ForeColor = $soluk
    # Etiket genisligi 62 -> 78: "Bottom fan" 62'ye SIGMIYORDU, "Bottom"
    # diye kirpiliyordu. Metin kutusu da ayni kadar saga kaydi; sagdaki
    # dugmeler (298 ve 362) yerinde kaldi.
    $lb.Location = New-Object System.Drawing.Point(16, ($satirY + 5))
    $lb.Size = New-Object System.Drawing.Size(78, 20)
    $grpEkran.Controls.Add($lb)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.ReadOnly = $true
    $tb.Location = New-Object System.Drawing.Point(98, $satirY)
    $tb.Size = New-Object System.Drawing.Size(194, 22)
    $tb.BackColor = $panelRenk
    $tb.ForeColor = $yaziRenk
    $tb.BorderStyle = 'FixedSingle'
    $tb.Text = T 'ekran-bos'
    $grpEkran.Controls.Add($tb)
    $script:EkranKutulari[$ix] = $tb

    $bs = New-Object System.Windows.Forms.Button
    $bs.Text = T 'ekran-sec'
    $bs.Tag = $ix
    $script:EkranSecDugmeleri += $bs
    $bs.Location = New-Object System.Drawing.Point(298, ($satirY - 1))
    $bs.Size = New-Object System.Drawing.Size(60, 24)
    $bs.FlatStyle = 'Flat'
    $bs.BackColor = $panelRenk
    $bs.ForeColor = $yaziRenk
    $bs.FlatAppearance.BorderColor = $zeminRenk
    $bs.Add_Click({ Invoke-EkranDosyaSec -Indeks ([string]$this.Tag) }.GetNewClosure())
    $grpEkran.Controls.Add($bs)

    $bt = New-Object System.Windows.Forms.Button
    $bt.Text = "X"
    $bt.Tag = $ix
    $bt.Location = New-Object System.Drawing.Point(362, ($satirY - 1))
    $bt.Size = New-Object System.Drawing.Size(30, 24)
    $bt.FlatStyle = 'Flat'
    $bt.BackColor = $panelRenk
    $bt.ForeColor = $yaziRenk
    $bt.FlatAppearance.BorderColor = $zeminRenk
    $bt.Add_Click({ Invoke-EkranDosyaTemizle -Indeks ([string]$this.Tag) }.GetNewClosure())
    $grpEkran.Controls.Add($bt)

    $satirY += 30
}

# Hic ekran yoksa satir alani bos kalmasin - sebebini yaz.
$script:LblEkranYok = $null
if ($script:EkranIndeksleri.Count -eq 0) {
    $lblEkranYok = New-Object System.Windows.Forms.Label
    $lblEkranYok.Text = T 'ekran-yok-not'
    $script:LblEkranYok = $lblEkranYok
    $lblEkranYok.ForeColor = $soluk
    $lblEkranYok.Location = New-Object System.Drawing.Point(16, 27)
    $lblEkranYok.Size = New-Object System.Drawing.Size(392, 20)
    $grpEkran.Controls.Add($lblEkranYok)
}

$lblParlaklik = New-Object System.Windows.Forms.Label
$lblParlaklik.Text = T 'parlaklik'
$lblParlaklik.ForeColor = $soluk
$lblParlaklik.Location = New-Object System.Drawing.Point(16, ($ekranAltY + 8))
$lblParlaklik.Size = New-Object System.Drawing.Size(72, 20)   # "Brightness:" 64'e sigmiyordu
$grpEkran.Controls.Add($lblParlaklik)

$trkParlaklik = New-Object System.Windows.Forms.TrackBar
$trkParlaklik.Minimum = 10
$trkParlaklik.Maximum = 100
$trkParlaklik.TickFrequency = 10
$trkParlaklik.LargeChange = 10
$trkParlaklik.Value = 100
$trkParlaklik.Location = New-Object System.Drawing.Point(92, $ekranAltY)
$trkParlaklik.Size = New-Object System.Drawing.Size(148, 45)   # bitis 240, dugme 250'de
$grpEkran.Controls.Add($trkParlaklik)

$btnEkranDurdur = New-Object System.Windows.Forms.Button
$btnEkranDurdur.Text = T 'ekran-durdur'
$btnEkranDurdur.Location = New-Object System.Drawing.Point(250, ($ekranAltY + 4))
$btnEkranDurdur.Size = New-Object System.Drawing.Size(158, 26)
$btnEkranDurdur.FlatStyle = 'Flat'
$btnEkranDurdur.BackColor = $panelRenk
$btnEkranDurdur.ForeColor = $yaziRenk
$btnEkranDurdur.FlatAppearance.BorderColor = $zeminRenk
$grpEkran.Controls.Add($btnEkranDurdur)

$btnEkranUygula = New-Object System.Windows.Forms.Button
$btnEkranUygula.Text = T 'ekran-uygula'
$btnEkranUygula.Location = New-Object System.Drawing.Point(16, ($ekranAltY + 40))
$btnEkranUygula.Size = New-Object System.Drawing.Size(392, 26)
$btnEkranUygula.FlatStyle = 'Flat'
$btnEkranUygula.BackColor = [System.Drawing.Color]::FromArgb(0, 110, 190)
$btnEkranUygula.ForeColor = [System.Drawing.Color]::White
$btnEkranUygula.FlatAppearance.BorderColor = $zeminRenk
$grpEkran.Controls.Add($btnEkranUygula)

$lblEkranDurum = New-Object System.Windows.Forms.Label
$lblEkranDurum.Location = New-Object System.Drawing.Point(16, ($ekranAltY + 70))
$lblEkranDurum.Size = New-Object System.Drawing.Size(392, 30)
$lblEkranDurum.ForeColor = $soluk
$lblEkranDurum.Text = T 'ekran-ipucu'
$grpEkran.Controls.Add($lblEkranDurum)

# ---------- BASLANGIC ----------
$grpBaslangic = New-Grup -Baslik (T 'grp-baslangic') -Y (560 + $kayma) -Yukseklik 74

$chkBasEkran = New-Object System.Windows.Forms.CheckBox
$chkBasEkran.Text = T 'bas-ekran'
$chkBasEkran.Location = New-Object System.Drawing.Point(16, 20)
$chkBasEkran.Size = New-Object System.Drawing.Size(190, 22)
$chkBasEkran.ForeColor = $yaziRenk
$grpBaslangic.Controls.Add($chkBasEkran)

$chkBasApp = New-Object System.Windows.Forms.CheckBox
$chkBasApp.Text = T 'bas-app'
$chkBasApp.Location = New-Object System.Drawing.Point(16, 44)
$chkBasApp.Size = New-Object System.Drawing.Size(190, 22)
$chkBasApp.ForeColor = $yaziRenk
$grpBaslangic.Controls.Add($chkBasApp)

$lblBasNot = New-Object System.Windows.Forms.Label
$lblBasNot.Location = New-Object System.Drawing.Point(212, 18)
$lblBasNot.Size = New-Object System.Drawing.Size(196, 50)
$lblBasNot.ForeColor = $soluk
$lblBasNot.Text = T 'bas-not'
$grpBaslangic.Controls.Add($lblBasNot)

# ---------- DURUM ----------
$grpDurum = New-Grup -Baslik (T 'grp-durum') -Y (642 + $kayma) -Yukseklik 150

$lblDurum = New-Object System.Windows.Forms.Label
$lblDurum.Location = New-Object System.Drawing.Point(16, 24)
$lblDurum.Size = New-Object System.Drawing.Size(392, 118)
$lblDurum.ForeColor = $yaziRenk
$lblDurum.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$lblDurum.Text = T 'durum-okunuyor'
$grpDurum.Controls.Add($lblDurum)

# ---------- ALT BILGI ----------
$lblAlt = New-Object System.Windows.Forms.Label
$lblAlt.Location = New-Object System.Drawing.Point(14, (800 + $kayma))
$lblAlt.Size = New-Object System.Drawing.Size(420, 34)
$lblAlt.ForeColor = $soluk
$lblAlt.Text = ""
$form.Controls.Add($lblAlt)

# ---------- DIL ----------
# En alt seride, saga yaslanmis. Kendi grup kutusu YOK: dil bir donanim
# ayari degil, uygulamanin kendi ayari - bolumler arasinda yer kaplamasin.
$lblDil = New-Object System.Windows.Forms.Label
$lblDil.Text = T 'dil-etiket'
$lblDil.ForeColor = $soluk
$lblDil.Location = New-Object System.Drawing.Point(238, (841 + $kayma))
$lblDil.Size = New-Object System.Drawing.Size(78, 20)   # "Language:" 64'e sigmiyordu
$lblDil.TextAlign = 'MiddleRight'
$form.Controls.Add($lblDil)

$cmbDil = New-Object System.Windows.Forms.ComboBox
$cmbDil.DropDownStyle = 'DropDownList'
$cmbDil.Location = New-Object System.Drawing.Point(320, (838 + $kayma))
$cmbDil.Size = New-Object System.Drawing.Size(112, 24)
$cmbDil.BackColor = $panelRenk
$cmbDil.ForeColor = $yaziRenk
$cmbDil.FlatStyle = 'Flat'
foreach ($d in Get-DilSecenekleri) { [void]$cmbDil.Items.Add($d.Ad) }
$script:DilKodlari = @(Get-DilSecenekleri | ForEach-Object { $_.Kod })
$cmbDil.SelectedIndex = [Math]::Max($script:DilKodlari.IndexOf((Get-Dil)), 0)
$form.Controls.Add($cmbDil)

function Set-AltBilgi {
    param([string]$Metin, [switch]$Hata)
    $lblAlt.ForeColor = if ($Hata) { [System.Drawing.Color]::FromArgb(255, 130, 130) } else { $soluk }
    $lblAlt.Text = $Metin
    $form.Refresh()
}

# ---------------------------------------------------------------------------
# Olay isleyicileri
# ---------------------------------------------------------------------------
function Invoke-HizUygula {
    $v = $trkHiz.Value
    Set-AltBilgi (T 'uygulaniyor')
    try {
        $r = Set-Hiz -Yuzde $v
        Set-AltBilgi (T 'hiz-uygulandi' @($r))
    }
    catch { Set-AltBilgi (T 'hiz-hata' @($_.Exception.Message)) -Hata }
}

function Invoke-IsikUygula {
    $c = $pnlRenk.BackColor
    $hex = '{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B
    $mod = if ($cmbMod.SelectedItem) { [string]$cmbMod.SelectedItem } else { 'Static' }

    Set-AltBilgi (T 'uygulaniyor')
    try {
        $r = Set-Isik -Hex $hex -Mod $mod
        if ($r.Hatalar.Count -gt 0) {
            Set-AltBilgi (T 'isik-sonuc-sorun' @($hex, ($r.Hedefler -join ', '), $r.Hatalar[0])) -Hata
        }
        else {
            Set-AltBilgi (T 'isik-sonuc' @($hex, ($r.Hedefler -join ', ')))
        }
    }
    catch { Set-AltBilgi (T 'isik-hata' @($_.Exception.Message)) -Hata }
}

# Slider surukleme bitince uygula - her piksel harekette cihaza yazmamak icin
$script:HizZamanlayici = New-Object System.Windows.Forms.Timer
$script:HizZamanlayici.Interval = 450
$script:HizZamanlayici.Add_Tick({
    $script:HizZamanlayici.Stop()
    Invoke-HizUygula
})

$trkHiz.Add_ValueChanged({
    $lblHiz.Text = "%$($trkHiz.Value)"
    $script:HizZamanlayici.Stop()
    $script:HizZamanlayici.Start()
})

$btnRenk.Add_Click({
    $d = New-Object System.Windows.Forms.ColorDialog
    $d.Color = $pnlRenk.BackColor
    $d.FullOpen = $true
    if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $pnlRenk.BackColor = $d.Color
        Invoke-IsikUygula
    }
})

$btnUygula.Add_Click({ Invoke-IsikUygula })

function Update-DonanimGorunumu {
    <#
      Bulunmayan donanimin bolumunu PASIFLESTIRIR ve sebebini basliga yazar.

      NEDEN GIZLEMEK YERINE PASIFLESTIRME: kullanici bolumun neden
      calismadigini GORMELI. Gizlenen bolum "bende neden yok?" sorusu
      dogurur; soluk ve sebebi yazili bolum dogurmaz.

      Bolum, ilgili donanimlardan EN AZ BIRI varsa acik kalir - orneginde
      AIO'su olmayip TL fani olan kullanici hiz kaydiricisini kullanabilmeli.
    #>
    $fanVar   = ($script:TlDevs.Count -gt 0) -and ($script:TlFanlar.Count -gt 0)
    $pompaVar = ($null -ne $script:Ga2Dev)
    # DIKKAT: bu "bellek modulu var" demek DEGIL - SMBus okumasi bu makinede
    # calismadigi icin modul varligi DOGRULANAMAZ. Sadece "yazma yolu acik".
    $ramVar   = ($script:SmbH -ne [IntPtr]::Zero)
    $ekranVar = ($script:EkranSayisi -gt 0)

    # ---------- Sogutma: fan VEYA pompa yeterli ----------
    if ($fanVar -or $pompaVar) {
        $grpHiz.Enabled = $true
        $grpHiz.Text =
            if ($fanVar -and $pompaVar) { T 'grp-sogutma' }
            elseif ($fanVar)            { T 'sogutma-pompa-yok' }
            else                        { T 'sogutma-fan-yok' }
    }
    else {
        $grpHiz.Enabled = $false
        $grpHiz.Text = T 'sogutma-hicbiri'
    }

    # ---------- Isik: fan, pompa veya bellek RGB'den biri yeterli ----------
    if ($fanVar -or $pompaVar -or $ramVar) {
        $grpIsik.Enabled = $true

        # "yok" listesi ile "yonetici gerekli" notu AYRI kurulur; ikisini tek
        # listede birlestirmek "bellek: yonetici gerekli yok" gibi bozuk
        # cumleler uretiyordu.
        $eksik = @()
        if (-not $fanVar)   { $eksik += (T 'eksik-fan') }
        if (-not $pompaVar) { $eksik += (T 'eksik-pompa') }
        if (-not $ramVar -and $script:Yetkili) { $eksik += (T 'eksik-bellek') }

        $parcalar = @()
        if ($eksik.Count -gt 0) { $parcalar += (T 'eksik-yok' @($eksik -join ', ')) }
        if (-not $ramVar -and -not $script:Yetkili) { $parcalar += (T 'bellek-yetki') }

        $grpIsik.Text =
            if ($parcalar.Count -eq 0) { T 'grp-isik' }
            else { T 'isik-ekli' @($parcalar -join '; ') }
    }
    else {
        $grpIsik.Enabled = $false
        $grpIsik.Text = T 'isik-hicbiri'
    }

    # ---------- Fan ekranlari ----------
    if ($ekranVar) {
        $grpEkran.Enabled = $true
        $grpEkran.Text = T 'ekran-sayili' @($script:EkranSayisi)
    }
    else {
        $grpEkran.Enabled = $false
        $grpEkran.Text = T 'ekran-hicbiri'
    }

    # Baslangic ve Durum bolumleri donanimdan BAGIMSIZ - hep acik kalir.
    return ($fanVar -or $pompaVar -or $ramVar -or $ekranVar)
}

function Update-EkranKutulari {
    <#
      Atamalari arayuzdeki kutulara yansitir. Yalnizca GERCEKTEN KURULMUS
      satirlar uzerinde doner: ayar dosyasinda artik takili olmayan bir
      ekranin atamasi kalmis olabilir, onun kutusu yoktur.
    #>
    foreach ($ix in @($script:EkranKutulari.Keys)) {
        $yol = $script:EkranAyari.Atamalar[$ix]
        $script:EkranKutulari[$ix].Text =
            if ([string]::IsNullOrWhiteSpace($yol)) { T 'ekran-bos' }
            else { [IO.Path]::GetFileName($yol) }
    }
}

function Update-Dil {
    <#
      Dil degisince acik penceredeki BUTUN metinleri yeniden yazar.

      NEDEN YENIDEN BASLATMA DEGIL: uygulama yonetici olarak calisiyor;
      kendini yeniden baslatmak ikinci bir UAC penceresi demek olurdu.
      Metinleri yerinde degistirmek hem daha hizli hem de kullanicinin
      ayarlarini (secili renk, kaydirici, atamalar) BOZMUYOR.

      Yeni bir metinli denetim eklendiginde BURAYA DA eklenmeli - unutulursa
      o denetim eski dilde takili kalir (tools/test-dil.ps1 bunu yakalar).
    #>
    $form.Text = T 'baslik'

    # Hiz
    $lblHizNot.Text = T 'hiz-not' @($script:PumpMin)
    foreach ($o in $script:OnAyarDugmeleri) { $o.Dugme.Text = T $o.Anahtar }

    # Isik
    $btnRenk.Text    = T 'renk-sec'
    $btnKapat.Text   = T 'isik-kapat'
    $lblMod.Text     = T 'efekt'
    $lblIsikNot.Text = T 'isik-not'
    $btnUygula.Text  = T 'renk-uygula'

    # Ekranlar - satir adlari da dile bagli (Ust/Orta/Alt fan)
    foreach ($ix in @($script:EkranEtiketleri.Keys)) {
        $script:EkranAdlari[$ix] = Get-EkranAdi -Indeks ([int]$ix) -Tumu $script:EkranIndeksleri
        $script:EkranEtiketleri[$ix].Text = $script:EkranAdlari[$ix]
    }
    foreach ($b in $script:EkranSecDugmeleri) { $b.Text = T 'ekran-sec' }
    if ($script:LblEkranYok) { $script:LblEkranYok.Text = T 'ekran-yok-not' }
    $lblParlaklik.Text   = T 'parlaklik'
    $btnEkranDurdur.Text = T 'ekran-durdur'
    $btnEkranUygula.Text = T 'ekran-uygula'

    # Baslangic
    $grpBaslangic.Text = T 'grp-baslangic'
    $chkBasEkran.Text  = T 'bas-ekran'
    $chkBasApp.Text    = T 'bas-app'
    $lblBasNot.Text    = T 'bas-not'

    # Durum + dil secici
    $grpDurum.Text = T 'grp-durum'
    $lblDil.Text   = T 'dil-etiket'

    # Grup basliklari donanim durumuna bagli - onlari o fonksiyon kurar
    $null = Update-DonanimGorunumu
    Update-EkranKutulari
    Update-Durum
}

function Invoke-EkranDosyaSec {
    <# Dosya secer ve KAYDEDER, ama ekranlara YOLLAMAZ.
       Gonderim "Ekranlara uygula" dugmesiyle olur - Isik bolumundeki
       "Rengi uygula" ile ayni mantik. #>
    param([string]$Indeks)

    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title = T 'dosya-sec-baslik' @($script:EkranAdlari[$Indeks])
    $d.Filter = T 'dosya-suzgec'
    $mevcut = $script:EkranAyari.Atamalar[$Indeks]
    if ($mevcut -and (Test-Path -LiteralPath $mevcut)) {
        $d.InitialDirectory = [IO.Path]::GetDirectoryName($mevcut)
    }

    if ($d.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    # Dosyayi burada bir kez cozup dogrula: bozuk/desteklenmeyen dosyayi
    # kullanici "uygula" dedikten sonra degil, HEMEN soyleyelim.
    try {
        $null = ConvertTo-TlLcdFrames -Path $d.FileName -Quality 40 -MaxFrames 1
    }
    catch {
        Set-AltBilgi (T 'dosya-acilamadi' @($_.Exception.Message)) -Hata
        return
    }

    $script:EkranAyari.Atamalar[$Indeks] = $d.FileName
    Export-EkranAyari
    Update-EkranKutulari
    Set-AltBilgi (T 'atandi' @($script:EkranAdlari[$Indeks], [IO.Path]::GetFileName($d.FileName)))
}

function Invoke-EkranDosyaTemizle {
    param([string]$Indeks)
    $script:EkranAyari.Atamalar.Remove($Indeks)
    Export-EkranAyari
    Update-EkranKutulari
    Set-AltBilgi (T 'temizlendi' @($script:EkranAdlari[$Indeks]))
}

$btnEkranUygula.Add_Click({
    try {
        if ($script:EkranAyari.Atamalar.Count -eq 0) {
            Set-AltBilgi (T 'once-gorsel-sec') -Hata
            return
        }
        Set-AltBilgi (T 'ekranlara-uygulaniyor')
        # Calisan daemon eski ayarla acildigi icin yeniden kurulmali;
        # kareler baslangicta bir kez kodlaniyor.
        Restart-LcdDaemon
        Set-AltBilgi (T 'ekranlara-uygulandi')
    }
    catch { Set-AltBilgi (T 'ekran-genel-hata' @($_.Exception.Message)) -Hata }
})

$btnEkranDurdur.Add_Click({
    try {
        Set-AltBilgi (T 'ekranlar-durduruluyor')
        Stop-LcdDaemon
        Set-AltBilgi (T 'ekranlar-durdu')
    }
    catch { Set-AltBilgi (T 'ekran-genel-hata' @($_.Exception.Message)) -Hata }
})

$trkParlaklik.Add_ValueChanged({
    # Ayarda tut; "Ekranlara uygula" ile yururluge girer.
    $script:EkranAyari.Parlaklik = $trkParlaklik.Value
})

# Kutulari acilista sistemin GERCEK durumundan dolduruyoruz. O sirada
# olay isleyicisinin tetiklenmemesi icin bu bayrak var - yoksa uygulama
# her acilista kaydi silip yeniden kurardi.
$script:BaslangicYukleniyor = $false

$chkBasEkran.Add_CheckedChanged({
    if ($script:BaslangicYukleniyor) { return }
    try {
        Set-BaslangicEkran -Etkin $chkBasEkran.Checked
        Set-AltBilgi $(if ($chkBasEkran.Checked) { T 'bas-ekran-acik' } else { T 'bas-ekran-kapali' })
    }
    catch {
        $script:BaslangicYukleniyor = $true
        $chkBasEkran.Checked = (Test-BaslangicEkran)
        $script:BaslangicYukleniyor = $false
        Set-AltBilgi (T 'bas-hata' @($_.Exception.Message)) -Hata
    }
})

$chkBasApp.Add_CheckedChanged({
    if ($script:BaslangicYukleniyor) { return }

    if ($chkBasApp.Checked -and -not $script:Yetkili) {
        $script:BaslangicYukleniyor = $true
        $chkBasApp.Checked = $false
        $script:BaslangicYukleniyor = $false
        Set-AltBilgi (T 'bas-app-yetki') -Hata
        return
    }

    try {
        Set-BaslangicUygulama -Etkin $chkBasApp.Checked
        Set-AltBilgi $(if ($chkBasApp.Checked) { T 'bas-app-acik' } else { T 'bas-app-kapali' })
    }
    catch {
        $script:BaslangicYukleniyor = $true
        $chkBasApp.Checked = (Test-BaslangicUygulama)
        $script:BaslangicYukleniyor = $false
        Set-AltBilgi (T 'gorev-hata' @($_.Exception.Message)) -Hata
    }
})

$btnKapat.Add_Click({
    Set-AltBilgi (T 'kapatiliyor')
    try {
        $h = Set-IsikKapali
        if ($h.Count -gt 0) { Set-AltBilgi (T 'isik-kapandi-sorun' @($h[0])) -Hata }
        else { Set-AltBilgi (T 'isik-kapandi') }
    }
    catch { Set-AltBilgi (T 'kapatilamadi' @($_.Exception.Message)) -Hata }
})

$cmbDil.Add_SelectedIndexChanged({
    $kod = $script:DilKodlari[$cmbDil.SelectedIndex]
    if ($kod -eq (Get-Dil)) { return }
    Set-Dil -Kod $kod
    Update-Dil
    Set-AltBilgi (T 'hazir')
})

# ---------------------------------------------------------------------------
# Durum zamanlayicisi
# ---------------------------------------------------------------------------
function Update-Durum {
    $satirlar = @()

    # CPU
    if ($script:CpuH -ne [IntPtr]::Zero) {
        try {
            $t = Get-AmdCpuTemperature -Handle $script:CpuH
            $w = Get-CpuWatt
            $ek = if ($null -ne $w) { "   {0,5:N1} W" -f $w } else { "" }
            if ($t.Ok) {
                $ccd = if ($t.Ccd.Count -gt 0) { "   die {0} C" -f $t.Ccd[0].TempC } else { "" }
                $satirlar += ("{0}{1,5:N1} C{2}{3}" -f (T 'et-cpu'), $t.Tctl, $ek, $ccd)
            }
        }
        catch { $satirlar += ((T 'et-cpu') + (T 'okunamadi')) }
    }
    else {
        $satirlar += ((T 'et-cpu') + (T 'yetki-yok-kisa'))
    }

    # GPU
    if ($script:Gpu) {
        try {
            $gt = Get-NvTemp -Gpu $script:Gpu
            $gf = Get-NvFans -Gpu $script:Gpu
            $gu = Get-NvUsage -Gpu $script:Gpu
            $rpm = if ($gf.Count -gt 0) { [int]$gf[0].Rpm } else { 0 }
            $yuk = if ($gu.ContainsKey('Gpu')) { "   %{0}" -f $gu['Gpu'] } else { "" }
            $fanMetin = if ($rpm -eq 0) { T 'gpu-fan-durdu' } else { "{0} RPM" -f $rpm }
            $satirlar += ("{0}{1,5:N0} C   {2}{3}" -f (T 'et-gpu'), $gt, $fanMetin, $yuk)
        }
        catch { $satirlar += ((T 'et-gpu') + (T 'okunamadi')) }
    }

    # Fanlar - her kontrolcu kendi envanterini bildirir, hepsi tek satirda
    # birlestirilir. Birden fazla kontrolcu varsa kacinci oldugu yazilir,
    # tek kontrolcude eskisi gibi sade kalir.
    if ($script:TlDevs.Count -gt 0) {
        $no = 0
        foreach ($dev in $script:TlDevs) {
            $no++
            $etiket = if ($script:TlDevs.Count -gt 1) { T 'et-fan-n' @($no) } else { T 'et-fan' }
            try {
                $f = (Get-TLFans -Device $dev).Fans | Where-Object { $_.Detected } | Sort-Object Port, FanIndex
                if ($f) {
                    $satirlar += ($etiket + (($f | ForEach-Object { "{0,5:N0}" -f $_.RPM }) -join ' ') + " RPM")
                }
            }
            catch { $satirlar += ($etiket + (T 'okunamadi')) }
        }
    }

    # Pompa
    if ($script:Ga2Dev) {
        try {
            $g = Get-GA2Status -Device $script:Ga2Dev
            if ($g) { $satirlar += ("{0}{1,5:N0} RPM" -f (T 'et-pompa'), $g.PumpRPM) }
        }
        catch { $satirlar += ((T 'et-pompa') + (T 'okunamadi')) }
    }

    # Bellek RGB durumu.
    # Modul SAYISI YAZILMAZ: SMBus okumasi calismadigi icin kac modul
    # oldugu DOGRULANAMAZ, uydurma sayi yazmak yerine ne yaptigimizi yaziyoruz.
    if ($script:SmbH -ne [IntPtr]::Zero) {
        $port = if ($script:RamPortBulundu) { T 'ram-port' @($script:RamPort) } else { T 'ram-port-sessiz' }
        $satirlar += (T 'bellek-durum' @($port))
    }

    $lblDurum.Text = ($satirlar -join "`r`n")

    # Ekran durumu - arka parcacigin bildirdigi degerler
    if (Test-LcdDaemon) {
        $ld = Get-LcdDurum
        if ($null -eq $ld) {
            $lblEkranDurum.Text = T 'ekran-durum' @(T 'ekd-basliyor')
        }
        elseif ($ld.Hata) {
            $lblEkranDurum.Text = T 'ekran-sorun' @($ld.Hata)
        }
        else {
            $ek  = if ($ld.Fps -gt 0) { "  {0:N1} fps" -f $ld.Fps } else { "" }
            $ek2 = if ($ld.Not) { "  ({0})" -f $ld.Not } else { "" }
            $lblEkranDurum.Text = (T 'ekran-durum' @(Get-EkranDurumMetni $ld)) + $ek + $ek2
        }
    }
    else {
        $lblEkranDurum.Text = T 'ekran-surec-yok'
    }
}

$script:DurumZamanlayici = New-Object System.Windows.Forms.Timer
$script:DurumZamanlayici.Interval = 2000
$script:DurumZamanlayici.Add_Tick({ try { Update-Durum } catch {} })

# ---------------------------------------------------------------------------
# Baslat
# ---------------------------------------------------------------------------
$form.Add_Shown({
    Import-EkranAyari
    Update-EkranKutulari
    if ($script:EkranAyari.Parlaklik -ge $trkParlaklik.Minimum -and
        $script:EkranAyari.Parlaklik -le $trkParlaklik.Maximum) {
        $trkParlaklik.Value = $script:EkranAyari.Parlaklik
    }

    # Baslangic kutulari: sistemde GERCEKTEN kayitli olana gore
    $script:BaslangicYukleniyor = $true
    try {
        $chkBasEkran.Checked = Test-BaslangicEkran
        $chkBasApp.Checked   = Test-BaslangicUygulama
    }
    catch { }
    $script:BaslangicYukleniyor = $false

    $sorunlar = Open-Devices
    $donanimVar = Update-DonanimGorunumu

    if ($sorunlar.Count -gt 0) { Set-AltBilgi ($sorunlar -join '  |  ') -Hata }
    elseif (-not $donanimVar) { Set-AltBilgi (T 'donanim-yok') -Hata }
    elseif (-not $script:Yetkili) { Set-AltBilgi (T 'yetki-yok') -Hata }
    else { Set-AltBilgi (T 'hazir') }

    # Slider'i mevcut fan hizina yaklastir (olculen model: RPM = 17.5*yuzde + 155)
    if ($script:TlFanlar.Count -gt 0) {
        $ortRpm = ($script:TlFanlar | Measure-Object RPM -Average).Average
        $tahmin = [int][Math]::Round(($ortRpm - 155) / 17.5)
        if ($tahmin -ge 0 -and $tahmin -le 100) {
            $script:HizZamanlayici.Stop()      # ilk ayarda cihaza yazma
            $trkHiz.Value = $tahmin
            $script:HizZamanlayici.Stop()
            $lblHiz.Text = "%$tahmin"
        }
    }

    Update-Durum
    $script:DurumZamanlayici.Start()
})

$form.Add_FormClosing({
    $script:DurumZamanlayici.Stop()
    $script:HizZamanlayici.Stop()
    # LCD daemon BILEREK durdurulmuyor: kullanici uygulama kapandiktan sonra
    # da ekranlarin donmesini istiyor. Durdurmak icin "Ekranlari durdur".
    Close-Devices
})

[void]$form.ShowDialog()



