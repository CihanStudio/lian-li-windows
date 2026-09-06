# Dil.ps1 - Arayuz metinleri: Ingilizce + Turkce
#
# TASARIM KARARLARI
#
# 1) VARSAYILAN DIL ISLETIM SISTEMINDEN GELIR. Windows dili Turkce ise arayuz
#    Turkce acilir, degilse Ingilizce. Boylece yabanci kullanici hicbir sey
#    yapmadan anlayacagi bir pencere gorur; kullanici secim yaparsa secimi
#    diske yazilir ve bir daha sorulmaz.
#
# 2) KUTUPHANELER (lib/*.ps1) CEVIRILMEZ - hepsi Ingilizce. Oradaki metinler
#    istisna mesajlari, yani teshis ciktisi; projenin teknik dili (README,
#    protokol notlari, kod yorumlari disindaki her sey) zaten Ingilizce.
#    Her kutuphaneye dil bagimliligi eklemek, `tools/` betiklerini ve
#    daemon'u da dil dosyasina bagimli hale getirirdi - kazancina degmez.
#    Kullaniciya donen kutuphane hatalari CEVIRILMIS bir cumlenin icine
#    gomulur ("Bu dosya acilamadi: <ingilizce sebep>").
#
# 3) LcdDaemon METIN DEGIL KOD YAZAR. Daemon ayri bir surec ve Windows
#    acilisinda arayuzden once baslayabiliyor; kendi dilini bilmesine gerek
#    yok. Durum dosyasina 'akis'/'ekran-yok' gibi KOD yazar, ceviriyi okuyan
#    taraf yapar. Boylece kullanici dili degistirdiginde daemon'u yeniden
#    baslatmak gerekmez.
#
# YENI METIN EKLERKEN: iki dili de doldur. Eksik anahtar sessizce bos
# donmez, koseli parantez icinde anahtarin kendisini dondurur - testte
# hemen goze batsin diye (bkz. tools/test-dil.ps1).

$script:DilKok     = Split-Path $PSScriptRoot -Parent
$script:DilDosyasi = Join-Path $script:DilKok "dil.txt"
$script:Dil        = $null

function Get-SistemDili {
    <# Windows arayuz dili Turkce ise 'tr', degilse 'en'. #>
    try {
        $k = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
        if ($k -eq 'tr') { return 'tr' }
    }
    catch { }
    return 'en'
}

function Get-Dil {
    if ($script:Dil) { return $script:Dil }

    # Diskteki secim > sistem dili
    try {
        if (Test-Path -LiteralPath $script:DilDosyasi) {
            $d = (Get-Content -LiteralPath $script:DilDosyasi -Raw -ErrorAction Stop).Trim().ToLowerInvariant()
            if ($d -eq 'tr' -or $d -eq 'en') { $script:Dil = $d; return $script:Dil }
        }
    }
    catch { }   # okunamayan ayar dosyasi uygulamayi engellememeli

    $script:Dil = Get-SistemDili
    return $script:Dil
}

function Set-Dil {
    param([Parameter(Mandatory)][ValidateSet('tr','en')][string]$Kod)
    $script:Dil = $Kod
    try { Set-Content -LiteralPath $script:DilDosyasi -Value $Kod -Encoding ASCII }
    catch { }   # yazamamak dili degistirmeyi engellemesin, sadece kalici olmaz
}

function Get-DilSecenekleri {
    # Her dilin adi KENDI DILINDE yazilir: menuyu goren kisi kendi dilini
    # tanisin diye (Ingilizce arayuzde "Turkce" degil "Turkce" gorunur).
    return @(
        [PSCustomObject]@{ Kod = 'en'; Ad = 'English' }
        [PSCustomObject]@{ Kod = 'tr'; Ad = 'Turkce'  }
    )
}

function T {
    <#
      Metin arar. -Arg verilirse -f ile bicimlendirir.
      Bulunamayan anahtar [koseli parantez] icinde doner - sessiz bos metin
      hatayi gizlerdi.
    #>
    param(
        [Parameter(Mandatory)][string]$Anahtar,
        [object[]]$Arg
    )
    $satir = $script:Metinler[$Anahtar]
    if ($null -eq $satir) { return "[$Anahtar]" }

    $dil = Get-Dil
    $m = $satir[$dil]
    if ($null -eq $m) { $m = $satir['en'] }
    if ($null -eq $m) { return "[$Anahtar]" }

    if ($Arg -and $Arg.Count -gt 0) { return ($m -f $Arg) }
    return $m
}

# ---------------------------------------------------------------------------
# METINLER
#
# Bastaki/sondaki BOSLUKLAR KASITLI: GroupBox basliklari cerceve cizgisinden
# ayrilsin diye " Cooling " seklinde yaziliyor.
# Durum panelindeki etiketler (cpu/gpu/fan/pompa) tek aralikli yazi tipiyle
# alt alta hizalandigi icin HEPSI 7 KARAKTERE tamamlanmis olmali.
# ---------------------------------------------------------------------------
$script:Metinler = @{

    # ---- Pencere ve bolum basliklari ----
    'baslik'            = @{ en = 'Cooling & Light';  tr = 'Sogutma ve Isik' }
    'grp-sogutma'       = @{ en = ' Cooling ';        tr = ' Sogutma ' }
    'grp-isik'          = @{ en = ' Light ';          tr = ' Isik ' }
    'grp-ekran'         = @{ en = ' Fan screens ';    tr = ' Fan ekranlari ' }
    'grp-baslangic'     = @{ en = ' Start with Windows '; tr = ' Windows ile baslangic ' }
    'grp-durum'         = @{ en = ' Status ';         tr = ' Durum ' }

    # ---- Bolum basligi ekleri (donanim yoksa) ----
    'sogutma-pompa-yok' = @{ en = ' Cooling  (no AIO pump) ';   tr = ' Sogutma  (AIO pompasi yok) ' }
    'sogutma-fan-yok'   = @{ en = ' Cooling  (no TL fans) ';    tr = ' Sogutma  (TL fan yok) ' }
    'sogutma-hicbiri'   = @{ en = ' Cooling  -  no fan or pump found '; tr = ' Sogutma  -  fan/pompa bulunamadi ' }
    'isik-ekli'         = @{ en = ' Light  ({0}) ';             tr = ' Isik  ({0}) ' }
    'isik-hicbiri'      = @{ en = ' Light  -  no RGB hardware found '; tr = ' Isik  -  RGB donanimi bulunamadi ' }
    'ekran-sayili'      = @{ en = ' Fan screens  ({0} screens) '; tr = ' Fan ekranlari  ({0} ekran) ' }
    'ekran-hicbiri'     = @{ en = ' Fan screens  -  no LCD screen found '; tr = ' Fan ekranlari  -  LCD ekran bulunamadi ' }
    'eksik-fan'         = @{ en = 'TL fans';  tr = 'TL fan' }
    'eksik-pompa'       = @{ en = 'pump';     tr = 'pompa' }
    'eksik-bellek'      = @{ en = 'memory';   tr = 'bellek' }
    'eksik-yok'         = @{ en = 'no {0}';   tr = '{0} yok' }
    'bellek-yetki'      = @{ en = 'memory needs administrator'; tr = 'bellek icin yonetici gerekli' }

    # ---- Hiz ----
    'hiz-not'           = @{ en = 'All fans and the pump move together. The pump never drops below {0}%.'
                             tr = 'Tum fanlar ve pompa birlikte hareket eder. Pompa %{0} altina inmez.' }
    'onayar-sessiz'     = @{ en = 'Quiet';    tr = 'Sessiz' }
    'onayar-dengeli'    = @{ en = 'Balanced'; tr = 'Dengeli' }
    'onayar-serin'      = @{ en = 'Cool';     tr = 'Serin' }
    'onayar-tam'        = @{ en = 'Max';      tr = 'Tam' }

    # ---- Isik ----
    'renk-sec'          = @{ en = 'Pick colour...'; tr = 'Renk sec...' }
    'isik-kapat'        = @{ en = 'Lights off';     tr = 'Isiklari kapat' }
    'efekt'             = @{ en = 'Effect:';        tr = 'Efekt:' }
    'isik-not'          = @{ en = 'Effects run on TL fans only; the pump and memory stay a solid colour.'
                             tr = 'Efekt yalnizca TL fanlarinda calisir; pompa ve bellek sabit renkte kalir.' }
    'renk-uygula'       = @{ en = 'Apply colour';   tr = 'Rengi uygula' }

    # ---- Ekranlar ----
    'ekran-bos'         = @{ en = '(empty)'; tr = '(bos)' }
    'ekran-sec'         = @{ en = 'Pick...'; tr = 'Sec...' }
    'ekran-yok-not'     = @{ en = 'No fans with LCD screens found.'; tr = 'LCD ekranli fan bulunamadi.' }
    'parlaklik'         = @{ en = 'Brightness:'; tr = 'Parlaklik:' }
    'ekran-durdur'      = @{ en = 'Stop screens';     tr = 'Ekranlari durdur' }
    'ekran-uygula'      = @{ en = 'Apply to screens'; tr = 'Ekranlara uygula' }
    'ekran-ipucu'       = @{ en = 'GIFs animate; jpg/png/bmp/webp are printed once and stay on the device.'
                             tr = 'GIF hareketli oynar; jpg/png/bmp/webp sabit basilir ve cihazda kalir.' }
    'ekran-ust'         = @{ en = 'Top fan';    tr = 'Ust fan' }
    'ekran-orta'        = @{ en = 'Middle fan'; tr = 'Orta fan' }
    'ekran-alt'         = @{ en = 'Bottom fan'; tr = 'Alt fan' }
    'ekran-n'           = @{ en = 'Screen {0}'; tr = 'Ekran {0}' }
    'dosya-sec-baslik'  = @{ en = 'Pick an image for {0}'; tr = '{0} icin gorsel sec' }
    'dosya-suzgec'      = @{ en = 'Images|*.gif;*.jpg;*.jpeg;*.png;*.bmp;*.webp;*.tif;*.tiff|Animated (GIF)|*.gif|All files|*.*'
                             tr = 'Gorseller|*.gif;*.jpg;*.jpeg;*.png;*.bmp;*.webp;*.tif;*.tiff|Hareketli (GIF)|*.gif|Tum dosyalar|*.*' }

    # ---- Baslangic ----
    'bas-ekran'         = @{ en = 'Screens (background process)'; tr = 'Ekranlar (arka surec)' }
    'bas-app'           = @{ en = 'This app'; tr = 'Bu uygulama' }
    'bas-not'           = @{ en = 'Independent of each other. The app starts as a scheduled task, so no UAC prompt.'
                             tr = 'Ikisi de bagimsiz. Uygulama zamanlanmis gorevle acilir, UAC sormaz.' }
    'kisayol-aciklama'  = @{ en = 'Background process feeding the fan LCD screens'
                             tr = 'Fan LCD ekranlarini besleyen arka surec' }

    # ---- Dil secici ----
    'dil-etiket'        = @{ en = 'Language:'; tr = 'Dil:' }

    # ---- Durum paneli (7 karaktere hizali etiketler) ----
    'durum-okunuyor'    = @{ en = 'reading...'; tr = 'okunuyor...' }
    'et-cpu'            = @{ en = 'CPU    '; tr = 'CPU    ' }
    'et-gpu'            = @{ en = 'GPU    '; tr = 'GPU    ' }
    'et-fan'            = @{ en = 'Fans   '; tr = 'Fanlar ' }
    'et-fan-n'          = @{ en = 'Fan {0}  '; tr = 'Fan {0}  ' }
    'et-pompa'          = @{ en = 'Pump   '; tr = 'Pompa  ' }
    'okunamadi'         = @{ en = 'read failed';        tr = 'okunamadi' }
    'yetki-yok-kisa'    = @{ en = 'no administrator rights'; tr = 'yonetici yetkisi yok' }
    'gpu-fan-durdu'     = @{ en = 'fan stopped'; tr = 'fan durdu' }
    'bellek-durum'      = @{ en = 'Memory RGB on - {0}, writing to every slot'
                             tr = 'Bellek RGB acik - {0}, tum yuvalara yaziliyor' }
    'ram-port'          = @{ en = 'port {0}'; tr = 'port {0}' }
    'ram-port-sessiz'   = @{ en = 'port 0 (probe got no answer)'; tr = 'port 0 (yoklama yanitsiz)' }

    # ---- Ekran durumu (daemon kodlarinin cevirisi) ----
    'ekd-basliyor'      = @{ en = 'starting...';           tr = 'basliyor...' }
    'ekd-ayar-yok'      = @{ en = 'no settings file';      tr = 'ayar dosyasi yok' }
    'ekd-ekran-yok'     = @{ en = 'no screens found';      tr = 'ekran bulunamadi' }
    'ekd-kodlaniyor'    = @{ en = 'encoding frames';       tr = 'kareler kodlaniyor' }
    'ekd-sabit'         = @{ en = '{0} static image(s) printed'; tr = '{0} sabit goruntu basildi' }
    'ekd-atama-yok'     = @{ en = 'no files assigned';     tr = 'atanmis dosya yok' }
    'ekd-akis'          = @{ en = '{0} animated, {1} static screen(s)'; tr = '{0} hareketli, {1} sabit ekran' }
    'ekd-durduruldu'    = @{ en = 'stopped';               tr = 'durduruldu' }
    'ekd-hata'          = @{ en = 'error';                 tr = 'hata' }
    'ekran-durum'       = @{ en = 'Screens: {0}';          tr = 'Ekranlar: {0}' }
    'ekran-sorun'       = @{ en = 'Screen problem: {0}';   tr = 'Ekran sorunu: {0}' }
    'ekran-surec-yok'   = @{ en = 'Screens: background process not running (static images stay put).'
                             tr = 'Ekranlar: arka surec calismiyor (sabit goruntuler yerinde kalir).' }

    # ---- Alt bilgi / islem mesajlari ----
    'uygulaniyor'       = @{ en = 'Applying...'; tr = 'Uygulaniyor...' }
    'hiz-uygulandi'     = @{ en = 'Speed applied: {0}';        tr = 'Hiz uygulandi: {0}' }
    'hiz-hata'          = @{ en = 'Could not apply speed: {0}'; tr = 'Hiz uygulanamadi: {0}' }
    'sonuc-fan'         = @{ en = 'fans {0}%'; tr = 'fan %{0}' }
    'sonuc-pompa'       = @{ en = 'pump {0}%'; tr = 'pompa %{0}' }
    'hedef-tl'          = @{ en = 'TL fans';   tr = 'TL fanlari' }
    'hedef-pompa'       = @{ en = 'pump head'; tr = 'pompa basligi' }
    'hedef-aio-fan'     = @{ en = 'AIO fans';  tr = 'AIO fanlari' }
    'hedef-bellek'      = @{ en = 'memory';    tr = 'bellek' }
    'isik-sonuc-sorun'  = @{ en = '#{0} -> {1}   |  problem: {2}'; tr = '#{0} -> {1}   |  sorun: {2}' }
    'isik-sonuc'        = @{ en = '#{0} applied -> {1}';           tr = '#{0} uygulandi -> {1}' }
    'isik-hata'         = @{ en = 'Could not apply light: {0}';    tr = 'Isik uygulanamadi: {0}' }
    'kapatiliyor'       = @{ en = 'Turning off...'; tr = 'Kapatiliyor...' }
    'isik-kapandi'      = @{ en = 'Lights off.';    tr = 'Isiklar kapatildi.' }
    'isik-kapandi-sorun'= @{ en = 'Lights off, one problem: {0}';  tr = 'Isiklar kapatildi, bir sorun: {0}' }
    'kapatilamadi'      = @{ en = 'Could not turn off: {0}';       tr = 'Kapatilamadi: {0}' }
    'dosya-acilamadi'   = @{ en = 'This file could not be opened: {0}'; tr = 'Bu dosya acilamadi: {0}' }
    'atandi'            = @{ en = "{0} -> {1}   (send it with 'Apply to screens')"
                             tr = "{0} -> {1}   ('Ekranlara uygula' ile gonder)" }
    'temizlendi'        = @{ en = '{0} cleared. What is on the screen stays until you apply.'
                             tr = '{0} temizlendi. Ekrandaki goruntu uygulanana kadar degismez.' }
    'once-gorsel-sec'   = @{ en = 'Pick an image for at least one fan first.'; tr = 'Once en az bir fana gorsel sec.' }
    'ekranlara-uygulaniyor' = @{ en = 'Applying to screens...'; tr = 'Ekranlara uygulaniyor...' }
    'ekranlara-uygulandi'   = @{ en = 'Applied. Frames are being encoded, this takes a few seconds.'
                                 tr = 'Ekranlara uygulandi. Kareler kodlaniyor, birkac saniye surer.' }
    'ekran-genel-hata'  = @{ en = 'Screens: {0}'; tr = 'Ekranlar: {0}' }
    'ekranlar-durduruluyor' = @{ en = 'Stopping screens...'; tr = 'Ekranlar durduruluyor...' }
    'ekranlar-durdu'    = @{ en = 'Screens stopped. Animations freeze on the last frame.'
                             tr = 'Ekranlar durdu. Hareketli goruntu son karede kalir.' }
    'bas-ekran-acik'    = @{ en = 'Screens will now start with Windows.'; tr = 'Ekranlar artik Windows ile birlikte baslayacak.' }
    'bas-ekran-kapali'  = @{ en = 'Screens will no longer start automatically.'; tr = 'Ekranlarin otomatik baslamasi kapatildi.' }
    'bas-hata'          = @{ en = 'Could not change the startup setting: {0}'; tr = 'Baslangic ayarlanamadi: {0}' }
    'bas-app-yetki'     = @{ en = 'For this, open the app as administrator.'; tr = 'Bunun icin uygulamayi yonetici olarak acmalisin.' }
    'bas-app-acik'      = @{ en = 'The app will start with Windows (no UAC prompt).'; tr = 'Uygulama Windows ile birlikte acilacak (UAC sormayacak).' }
    'bas-app-kapali'    = @{ en = 'The app will no longer start automatically.'; tr = 'Uygulamanin otomatik baslamasi kapatildi.' }
    'gorev-hata'        = @{ en = 'Could not create the scheduled task: {0}'; tr = 'Gorev olusturulamadi: {0}' }

    # ---- Acilis ----
    'hazir'             = @{ en = 'Ready.'; tr = 'Hazir.' }
    'donanim-yok'       = @{ en = 'No supported hardware found - see the compatibility list in the README.'
                             tr = 'Desteklenen donanim bulunamadi - README uyumluluk listesine bak.' }
    'yetki-yok'         = @{ en = 'No administrator rights: CPU temperature and memory RGB are off.'
                             tr = 'Yonetici yetkisi yok: CPU sicakligi ve bellek RGB kapali.' }
    'ac-tl'             = @{ en = 'TL controller {0}: {1}'; tr = 'TL kontrolcu {0}: {1}' }
    'ac-aio'            = @{ en = 'AIO: {0}';        tr = 'AIO: {0}' }
    'ac-gpu'            = @{ en = 'GPU: {0}';        tr = 'GPU: {0}' }
    'ac-cpu'            = @{ en = 'CPU sensor: {0}'; tr = 'CPU sensoru: {0}' }
    'ac-bellek'         = @{ en = 'Memory RGB: {0}'; tr = 'Bellek RGB: {0}' }
    'hata-tl'           = @{ en = 'TL: {0}';          tr = 'TL: {0}' }
    'hata-pompa'        = @{ en = 'Pump/{0}: {1}';    tr = 'Pompa/{0}: {1}' }
    'hata-aio-fan'      = @{ en = 'AIO fan light: {0}'; tr = 'AIO fan isigi: {0}' }
    'hata-bellek'       = @{ en = 'Memory: {0}';      tr = 'Bellek: {0}' }

    # ---- Beklenmeyen hata penceresi ----
    'catik-baslik'      = @{ en = 'Cooling - error'; tr = 'Sogutma - hata' }
    'catik-govde'       = @{ en = "Unexpected error:`r`n`r`n{0}`r`n`r`nLocation:`r`n{1}"
                             tr = "Beklenmeyen hata:`r`n`r`n{0}`r`n`r`nKonum:`r`n{1}" }
}
