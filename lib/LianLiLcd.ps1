# LianLiLcd.ps1 - Lian Li UNI FAN TL LCD ekranlari (VID 04FC / PID 7393).
#
# YONETICI YETKISI GEREKMEZ. Windows'un yerlesik HID yigini kullanilir.
#
# PROTOKOL (sgtaziz/lian-li-linux, crates/lianli-devices/src/tl_lcd.rs):
#   HID Output Report, Report ID 0x02, TAM 512 bayt.
#   11 baytlik baslik:
#     [0]      rapor kimligi (0x02)
#     [1]      komut
#     [2..5]   toplam veri boyu   (4 bayt, BUYUK endian)
#     [6..8]   paket numarasi     (3 bayt, BUYUK endian)
#     [9..10]  bu paketin yuku    (2 bayt, BUYUK endian)
#     [11..]   yuk (en fazla 501 bayt)
#   Buyuk resim 501 baytlik parcalara bolunup ardisik paketlerle gonderilir.
#   Ekran 400x400, JPEG, kalite 90, en fazla 30 fps.
#
# GUVENLIK - BILINCLI OLARAK UYGULANMAYAN KOMUTLAR:
#   0x47 WRITE_BOOT_AVI ve 0x48 WRITE_BOOT_JPG acilis goruntusunu KALICI
#   olarak degistirir; yanlis veri ekrani acilista kullanilamaz hale
#   getirebilir. Islevimiz icin gereksiz, o yuzden sarmalanmadi.
#   63 WRITE_SERIAL cihazin kalici seri numarasini degistirir - bizim
#   ihtiyacimiz yok, dokunmuyoruz.

. (Join-Path $PSScriptRoot "HidCore.ps1")

Add-Type -AssemblyName System.Drawing
# WebP/HEIF gibi GDI+'in bilmedigi bicimler icin Windows'un WIC kod cozucusu.
# Ek program/kodek KURULMAZ; isletim sisteminde zaten varsa kullanilir.
Add-Type -AssemblyName PresentationCore

$script:LCD_VID = 0x04FC
$script:LCD_PID = 0x7393
$script:LCD_USAGE_PAGE = 0xFF06

$script:LCD_REPORT_ID   = 0x02
$script:LCD_PACKET_SIZE = 512
$script:LCD_HEADER_LEN  = 11
$script:LCD_MAX_PAYLOAD = 501          # 512 - 11

$script:LCD_W = 400
$script:LCD_H = 400
$script:LCD_JPEG_QUALITY = 90
# Cihazin kabul ettigi ust sinir (ScreenInfo.max_payload). Bunun ustundeki
# JPEG'i gondermeye calismak yerine kaliteyi dusurup kuculturuz.
$script:LCD_MAX_IMAGE_BYTES = 65535

# Komutlar
$script:LCD_CMD_HANDSHAKE    = 60
$script:LCD_CMD_PRODUCT_INFO = 61
$script:LCD_CMD_READ_SERIAL  = 62
$script:LCD_CMD_CONTROL      = 64
$script:LCD_CMD_WRITE_JPG    = 0x41    # tek kare, her pakete ACK bekler
$script:LCD_CMD_SYNC_JPG     = 0x46    # akis, ACK beklemez

# LCD kontrol modlari
$script:LCD_MODE_SHOW_JPG  = 1
$script:LCD_MODE_SHOW_AVI  = 3
$script:LCD_MODE_APP_SYNC  = 4
$script:LCD_MODE_SETTING   = 5
$script:LCD_MODE_TEST      = 6

# ---------------------------------------------------------------------------
# Cihaz bulma / acma
# ---------------------------------------------------------------------------

function Get-TlLcdDeviceInfos {
    <# Sistemdeki tum TL LCD arayuzlerini dondurur (salt okuma, hicbir sey gondermez). #>
    [LianLi.HidCore]::Enumerate() | Where-Object {
        $_.Vid -eq $script:LCD_VID -and
        $_.Pid -eq $script:LCD_PID -and
        $_.UsagePage -eq $script:LCD_USAGE_PAGE -and
        $_.OutputLen -eq $script:LCD_PACKET_SIZE
    }
}

function Open-TlLcd {
    param([Parameter(Mandatory)]$Info)
    return [LianLi.HidCore]::Open($Info)
}

# ---------------------------------------------------------------------------
# Paket kurma / cozme
# ---------------------------------------------------------------------------

function New-TlLcdPacket {
    <#
      512 baytlik output report kurar.
      DIKKAT: tum sayi alanlari BUYUK endian. PowerShell'de kaydirmadan once
      [int] cast'i sart, yoksa bayt genisliginde kaydirma yapilir.
    #>
    param(
        [Parameter(Mandatory)][int]$Cmd,
        [int]$TotalSize = 0,
        [int]$PacketNum = 0,
        [byte[]]$Payload = @()
    )

    $pkt = New-Object 'byte[]' $script:LCD_PACKET_SIZE
    $pkt[0] = [byte]$script:LCD_REPORT_ID
    $pkt[1] = [byte]$Cmd

    $ts = [int]$TotalSize
    $pkt[2] = [byte](($ts -shr 24) -band 0xFF)
    $pkt[3] = [byte](($ts -shr 16) -band 0xFF)
    $pkt[4] = [byte](($ts -shr 8)  -band 0xFF)
    $pkt[5] = [byte]( $ts          -band 0xFF)

    $pn = [int]$PacketNum
    $pkt[6] = [byte](($pn -shr 16) -band 0xFF)
    $pkt[7] = [byte](($pn -shr 8)  -band 0xFF)
    $pkt[8] = [byte]( $pn          -band 0xFF)

    $len = [Math]::Min($Payload.Length, $script:LCD_MAX_PAYLOAD)
    $pkt[9]  = [byte](($len -shr 8) -band 0xFF)
    $pkt[10] = [byte]( $len         -band 0xFF)

    if ($len -gt 0) {
        [Array]::Copy($Payload, 0, $pkt, $script:LCD_HEADER_LEN, $len)
    }
    return $pkt
}

function Get-TlLcdPayloadLength {
    param([byte[]]$Packet)
    if ($null -eq $Packet -or $Packet.Length -lt $script:LCD_HEADER_LEN) { return 0 }
    return (([int]$Packet[9] -shl 8) -bor [int]$Packet[10])
}

function Get-TlLcdPayloadString {
    <# Yanit paketindeki yuku ASCII metne cevirir. #>
    param([byte[]]$Packet, [int]$MaxLen = 0)
    $len = Get-TlLcdPayloadLength -Packet $Packet
    if ($MaxLen -gt 0 -and $len -gt $MaxLen) { $len = $MaxLen }
    $son = $script:LCD_HEADER_LEN + $len
    if ($son -gt $Packet.Length) { $son = $Packet.Length }
    if ($son -le $script:LCD_HEADER_LEN) { return "" }
    $dilim = $Packet[$script:LCD_HEADER_LEN..($son - 1)]
    return ([Text.Encoding]::ASCII.GetString($dilim)).TrimEnd([char]0).Trim()
}

function Clear-TlLcdInput {
    <# Cihazdan gelmis ama okunmamis yanitlari bosaltir; yoksa sonraki
       komutun yaniti bir oncekinin yaniti sanilir. #>
    param([Parameter(Mandatory)]$Device, [int]$MaxTries = 8)
    for ($i = 0; $i -lt $MaxTries; $i++) {
        if ($null -eq $Device.Read(15)) { break }
    }
}

function Invoke-TlLcdCommand {
    <# Komut gonderir, istege bagli olarak tek yanit okur. Yanit yoksa $null. #>
    param(
        [Parameter(Mandatory)]$Device,
        [Parameter(Mandatory)][int]$Cmd,
        [byte[]]$Payload = @(),
        [switch]$ReadResponse,
        [int]$TimeoutMs = 400
    )
    $pkt = New-TlLcdPacket -Cmd $Cmd -TotalSize $Payload.Length -PacketNum 0 -Payload $Payload
    $Device.Write($pkt, 1000)
    if ($ReadResponse) { return $Device.Read($TimeoutMs) }
    return $null
}

# ---------------------------------------------------------------------------
# Bilgi okuma
# ---------------------------------------------------------------------------

function Get-TlLcdIdentity {
    <#
      Seri numarasi + port + indeks dondurur. Uc ekrani birbirinden
      ayirmanin tek yolu bu (HID yollari her takista degisebilir).
      NOT: Seri numarasi YAZILMAZ. Fabrika degeri "TL_LCDV0.1" gibi
      ortak bir metinse ekranlar seriyle ayirt edilemez; o durumda
      port/indeks ikilisi kullanilir.
    #>
    param([Parameter(Mandatory)]$Device)
    Clear-TlLcdInput -Device $Device
    $r = Invoke-TlLcdCommand -Device $Device -Cmd $script:LCD_CMD_READ_SERIAL -ReadResponse -TimeoutMs 3000
    if ($null -eq $r) { return $null }

    $h = $script:LCD_HEADER_LEN
    return [PSCustomObject]@{
        Seri   = Get-TlLcdPayloadString -Packet $r -MaxLen 32
        Port   = if ($r.Length -gt ($h + 32)) { [int]$r[$h + 32] } else { 0 }
        Indeks = if ($r.Length -gt ($h + 33)) { [int]$r[$h + 33] } else { 0 }
    }
}

function Get-TlLcdHandshake {
    <# Cihazin su anki modu ve kare sayaci. #>
    param([Parameter(Mandatory)]$Device)
    Clear-TlLcdInput -Device $Device
    $r = Invoke-TlLcdCommand -Device $Device -Cmd $script:LCD_CMD_HANDSHAKE -ReadResponse -TimeoutMs 3000
    if ($null -eq $r) { return $null }

    $h = $script:LCD_HEADER_LEN
    return [PSCustomObject]@{
        Mod      = if ($r.Length -gt $h)       { [int]$r[$h] } else { 0 }
        KareNo   = if ($r.Length -gt ($h + 2)) { (([int]$r[$h + 1] -shl 8) -bor [int]$r[$h + 2]) } else { 0 }
    }
}

function Get-TlLcdFirmware {
    <# Yazilim surumu. Cihaz IKI yanit gonderir (surum + tarih); ikincisi de
       okunmalidir, yoksa sonraki komutta senkron kayar. #>
    param([Parameter(Mandatory)]$Device)
    Clear-TlLcdInput -Device $Device
    $r1 = Invoke-TlLcdCommand -Device $Device -Cmd $script:LCD_CMD_PRODUCT_INFO -ReadResponse -TimeoutMs 3000
    if ($null -eq $r1) { return $null }
    $surum = Get-TlLcdPayloadString -Packet $r1

    $tarih = ""
    $r2 = $Device.Read(1000)
    if ($null -ne $r2) { $tarih = Get-TlLcdPayloadString -Packet $r2 }

    return [PSCustomObject]@{ Surum = $surum; Tarih = $tarih }
}

# ---------------------------------------------------------------------------
# Ayarlar
# ---------------------------------------------------------------------------

function Set-TlLcdSettings {
    <#
      Parlaklik (0-100) ve donus (0/90/180/270) uygular.
      Kontrol yuku 11 bayt: [0]=mod, [4]=parlaklik, [5]=fps, [6]=donus.
    #>
    param(
        [Parameter(Mandatory)]$Device,
        [ValidateRange(0, 100)][int]$Brightness = 50,
        [ValidateSet(0, 90, 180, 270)][int]$Rotation = 0,
        [int]$Mode = $script:LCD_MODE_SETTING
    )
    $donus = switch ($Rotation) { 90 { 1 } 180 { 2 } 270 { 3 } default { 0 } }

    $p = New-Object 'byte[]' 11
    $p[0] = [byte]$Mode
    $p[4] = [byte]$Brightness
    $p[5] = 30                      # fps - cihazin ust siniri
    $p[6] = [byte]$donus

    Clear-TlLcdInput -Device $Device
    $null = Invoke-TlLcdCommand -Device $Device -Cmd $script:LCD_CMD_CONTROL -Payload $p -ReadResponse -TimeoutMs 500
}

# ---------------------------------------------------------------------------
# Goruntu gonderme
# ---------------------------------------------------------------------------

function ConvertTo-TlLcdJpeg {
    <#
      Herhangi bir goruntu dosyasini 400x400 JPEG bayt dizisine cevirir.

      Ekran YUVARLAK (fan gobegi), o yuzden goruntu esnetilmez: kisa kenara
      gore olceklenip ORTADAN KIRPILIR (kapak/cover davranisi).

      Sonuc cihazin sinirindan (65535 bayt) buyukse kalite kademeli
      dusurulur - buyuk paketi gondermek yerine kucult.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Quality = $script:LCD_JPEG_QUALITY
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "Image not found: $Path" }

    $kaynak = (Open-TlLcdGoruntu -Path $Path).Goruntu
    try {
        $hedef = New-Object Drawing.Bitmap($script:LCD_W, $script:LCD_H)
        try {
            $g = [Drawing.Graphics]::FromImage($hedef)
            try {
                $g.InterpolationMode  = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.PixelOffsetMode    = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $g.SmoothingMode      = [Drawing.Drawing2D.SmoothingMode]::HighQuality
                $g.Clear([Drawing.Color]::Black)

                # Kapak kirpmasi: kaynaktan en buyuk kareyi ortadan al
                $kenar = [Math]::Min($kaynak.Width, $kaynak.Height)
                $sx = [int](($kaynak.Width  - $kenar) / 2)
                $sy = [int](($kaynak.Height - $kenar) / 2)
                $kaynakDik = New-Object Drawing.Rectangle($sx, $sy, $kenar, $kenar)
                $hedefDik  = New-Object Drawing.Rectangle(0, 0, $script:LCD_W, $script:LCD_H)
                $g.DrawImage($kaynak, $hedefDik, $kaynakDik, [Drawing.GraphicsUnit]::Pixel)
            }
            finally { $g.Dispose() }

            return ConvertTo-TlLcdJpegBytes -Bitmap $hedef -Quality $Quality
        }
        finally { $hedef.Dispose() }
    }
    finally { $kaynak.Dispose() }
}

function ConvertTo-TlLcdJpegBytes {
    <# Bir Bitmap'i JPEG bayt dizisine cevirir, boyut sinirina sigdirir. #>
    param(
        [Parameter(Mandatory)][Drawing.Bitmap]$Bitmap,
        [int]$Quality = $script:LCD_JPEG_QUALITY
    )

    $kodlayici = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                 Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
    if ($null -eq $kodlayici) { throw "No JPEG encoder available." }

    $kalite = $Quality
    while ($true) {
        $ep = New-Object Drawing.Imaging.EncoderParameters(1)
        try {
            $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter(
                [Drawing.Imaging.Encoder]::Quality, [int64]$kalite)

            $ms = New-Object IO.MemoryStream
            try {
                $Bitmap.Save($ms, $kodlayici, $ep)
                $baytlar = $ms.ToArray()
            }
            finally { $ms.Dispose() }
        }
        finally { $ep.Dispose() }

        if ($baytlar.Length -le $script:LCD_MAX_IMAGE_BYTES -or $kalite -le 30) {
            if ($baytlar.Length -gt $script:LCD_MAX_IMAGE_BYTES) {
                throw ("Goruntu kalite 30'da bile cok buyuk ({0} bayt, sinir {1})." -f $baytlar.Length, $script:LCD_MAX_IMAGE_BYTES)
            }
            return $baytlar
        }
        $kalite -= 10
    }
}

function Send-TlLcdImageData {
    <#
      JPEG verisini 501 baytlik paketler halinde gonderir.

      -Streaming verildiginde ACK BEKLENMEZ (komut 0x46, video/sensor akisi
      icin). Verilmediginde her paket icin ACK okunur (komut 0x41, tek kare).
      ACK okumak yavas ama tek karede guvenli olan bu.
    #>
    param(
        [Parameter(Mandatory)]$Device,
        [Parameter(Mandatory)][byte[]]$Jpeg,
        [switch]$Streaming
    )

    $cmd = if ($Streaming) { $script:LCD_CMD_SYNC_JPG } else { $script:LCD_CMD_WRITE_JPG }
    $toplam = $Jpeg.Length
    $ofset = 0
    $paketNo = 0

    if (-not $Streaming) { Clear-TlLcdInput -Device $Device }

    while ($ofset -lt $toplam) {
        $uzunluk = [Math]::Min($toplam - $ofset, $script:LCD_MAX_PAYLOAD)
        $parca = New-Object 'byte[]' $uzunluk
        [Array]::Copy($Jpeg, $ofset, $parca, 0, $uzunluk)

        $pkt = New-TlLcdPacket -Cmd $cmd -TotalSize $toplam -PacketNum $paketNo -Payload $parca
        $Device.Write($pkt, 1000)

        if (-not $Streaming) {
            $ack = $Device.Read(400)
            if ($null -ne $ack -and $ack.Length -gt 1 -and $ack[1] -ne $cmd) {
                throw ("ACK uyusmadi: beklenen 0x{0:X2}, gelen 0x{1:X2} (paket {2})" -f $cmd, $ack[1], $paketNo)
            }
        }

        $ofset += $uzunluk
        $paketNo++
    }

    return $paketNo
}

function ConvertFrom-WicBitmap {
    <# WPF/WIC goruntusunu System.Drawing.Bitmap'e cevirir. #>
    param([Parameter(Mandatory)]$Kaynak)

    $conv = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap
    $conv.BeginInit()
    $conv.Source = $Kaynak
    $conv.DestinationFormat = [System.Windows.Media.PixelFormats]::Bgra32
    $conv.EndInit()

    $w = $conv.PixelWidth
    $h = $conv.PixelHeight
    $stride = $w * 4
    $tampon = New-Object 'byte[]' ($stride * $h)
    $conv.CopyPixels($tampon, $stride, 0)

    $bmp = New-Object Drawing.Bitmap($w, $h, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $kilit = $bmp.LockBits(
        (New-Object Drawing.Rectangle(0, 0, $w, $h)),
        [Drawing.Imaging.ImageLockMode]::WriteOnly,
        [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try { [Runtime.InteropServices.Marshal]::Copy($tampon, 0, $kilit.Scan0, $tampon.Length) }
    finally { $bmp.UnlockBits($kilit) }
    return $bmp
}

function Open-TlLcdGoruntu {
    <#
      Dosyayi goruntuye acar. Once GDI+ denenir (jpg/png/bmp/gif/tiff);
      basarisiz olursa Windows'un WIC kod cozucusune dusulur - WebP,
      HEIF, JPEG XL gibi bicimler bu yoldan aciliyor.

      Doner: @{ Goruntu = <Image veya Bitmap>; Wic = $true/$false }
      Cagiran Goruntu'yu Dispose etmelidir.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $tam = (Resolve-Path -LiteralPath $Path).Path
    try {
        return @{ Goruntu = [Drawing.Image]::FromFile($tam); Wic = $false }
    }
    catch {
        # GDI+ bilmedigi bicimde "Bellek yetersiz" gibi alakasiz hata verir;
        # bu yuzden hata metnine bakmadan dogrudan WIC'e dusuyoruz.
        try {
            $dec = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
                (New-Object Uri($tam)), 'None', 'OnLoad')
            return @{ Goruntu = (ConvertFrom-WicBitmap -Kaynak $dec.Frames[0]); Wic = $true }
        }
        catch {
            throw ("Goruntu acilamadi ({0}): {1}" -f [IO.Path]::GetFileName($tam), $_.Exception.Message)
        }
    }
}

function ConvertTo-TlLcdFrameJpeg {
    <# Acik bir Image'in su anki karesini 400x400 JPEG'e cevirir (ortadan kirpar). #>
    param(
        [Parameter(Mandatory)][Drawing.Image]$Image,
        [int]$Quality = $script:LCD_JPEG_QUALITY
    )
    $hedef = New-Object Drawing.Bitmap($script:LCD_W, $script:LCD_H)
    try {
        $g = [Drawing.Graphics]::FromImage($hedef)
        try {
            $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode   = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.Clear([Drawing.Color]::Black)

            $kenar = [Math]::Min($Image.Width, $Image.Height)
            $sx = [int](($Image.Width  - $kenar) / 2)
            $sy = [int](($Image.Height - $kenar) / 2)
            $g.DrawImage($Image,
                (New-Object Drawing.Rectangle(0, 0, $script:LCD_W, $script:LCD_H)),
                (New-Object Drawing.Rectangle($sx, $sy, $kenar, $kenar)),
                [Drawing.GraphicsUnit]::Pixel)
        }
        finally { $g.Dispose() }
        return ConvertTo-TlLcdJpegBytes -Bitmap $hedef -Quality $Quality
    }
    finally { $hedef.Dispose() }
}

function ConvertFrom-TlLcdGif {
    <#
      GIF'i onceden kodlanmis JPEG karelere cevirir.

      NEDEN ONCEDEN: oynatma sirasinda kare kodlamak PowerShell'de cok yavas
      ve kare hizini dusurur. Kareler bir kez bellege alinir, oynatma
      dongusu sadece HID'e yazar.

      Kare gecikmesi GIF'in kendi 0x5100 (PropertyTagFrameDelay) alanindan
      okunur; birim 1/100 saniyedir. 0 gelen kareler (bazi uretici
      araclarinda olur) 100 ms sayilir - tarayicilarin yaptigi da budur.

      Animasyonda kalite bilincli olarak dusuk tutulur: her kare 501 baytlik
      paketlere bolunuyor, kucuk kare = az paket = yuksek kare hizi.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxFrames = 240,
        [int]$Quality = 75
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "GIF not found: $Path" }

    $img = [Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Path).Path)
    try {
        $fd = New-Object Drawing.Imaging.FrameDimension($img.FrameDimensionsList[0])
        $sayi = $img.GetFrameCount($fd)
        if ($sayi -gt $MaxFrames) { $sayi = $MaxFrames }

        # Gecikme dizisi - kare basina 4 bayt, kucuk endian, 1/100 sn
        $gecikmeler = $null
        try { $gecikmeler = $img.GetPropertyItem(0x5100).Value } catch { }

        $kareler = @()
        for ($i = 0; $i -lt $sayi; $i++) {
            $null = $img.SelectActiveFrame($fd, $i)

            $ms = 100
            if ($null -ne $gecikmeler -and $gecikmeler.Length -ge (($i + 1) * 4)) {
                $cs = [BitConverter]::ToInt32($gecikmeler, $i * 4)
                if ($cs -gt 0) { $ms = $cs * 10 }
            }

            $kareler += [PSCustomObject]@{
                Jpeg      = ConvertTo-TlLcdFrameJpeg -Image $img -Quality $Quality
                GecikmeMs = $ms
            }
        }
        return $kareler
    }
    finally { $img.Dispose() }
}

function ConvertTo-TlLcdFrames {
    <#
      HERHANGI bir goruntu dosyasini gonderime hazir karelere cevirir.
      Hem hareketli (GIF) hem sabit (jpg/png/bmp/webp/...) dosyalari kabul eder.

      Doner:
        Kareler     : @( @{Jpeg=byte[]; GecikmeMs=int} , ... )
        Animasyonlu : birden fazla kare varsa $true
        Not         : kullaniciya gosterilecek uyari (yoksa $null)

      SINIR: Animasyon yalnizca GIF'ten cikarilir. Hareketli WebP'de ilk kare
      alinir - WIC'in verdigi kareler kismi/disposal tabanli oldugu icin
      dogru birlestirilmeden oynatilirsa bozuk goruntu cikar.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Quality = 75,
        [int]$MaxFrames = 240
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }

    $ac = Open-TlLcdGoruntu -Path $Path
    $img = $ac.Goruntu
    $not = $null
    try {
        # Cok kareli mi? (GDI+ ile acilan GIF'lerde zaman boyutu olur)
        $kareSayisi = 1
        $fd = $null
        if (-not $ac.Wic) {
            try {
                $fd = New-Object Drawing.Imaging.FrameDimension($img.FrameDimensionsList[0])
                $kareSayisi = $img.GetFrameCount($fd)
            }
            catch { $kareSayisi = 1 }
        }
        else {
            $not = "WebP/HEIF: only the first frame was used."
        }

        if ($kareSayisi -le 1) {
            return [PSCustomObject]@{
                Kareler     = @([PSCustomObject]@{
                                  Jpeg = (ConvertTo-TlLcdFrameJpeg -Image $img -Quality $Quality)
                                  GecikmeMs = 100 })
                Animasyonlu = $false
                Not         = $not
            }
        }

        if ($kareSayisi -gt $MaxFrames) {
            $kareSayisi = $MaxFrames
            $not = "Animation too long: only the first $MaxFrames frames were used."
        }

        $gecikmeler = $null
        try { $gecikmeler = $img.GetPropertyItem(0x5100).Value } catch { }

        $kareler = @()
        for ($i = 0; $i -lt $kareSayisi; $i++) {
            $null = $img.SelectActiveFrame($fd, $i)
            $ms = 100
            if ($null -ne $gecikmeler -and $gecikmeler.Length -ge (($i + 1) * 4)) {
                $cs = [BitConverter]::ToInt32($gecikmeler, $i * 4)
                if ($cs -gt 0) { $ms = $cs * 10 }
            }
            $kareler += [PSCustomObject]@{
                Jpeg      = ConvertTo-TlLcdFrameJpeg -Image $img -Quality $Quality
                GecikmeMs = $ms
            }
        }

        return [PSCustomObject]@{ Kareler = $kareler; Animasyonlu = $true; Not = $not }
    }
    finally { $img.Dispose() }
}

function Send-TlLcdFrame {
    <# Tek bir kareyi akis modunda gonderir (ACK beklemez - hizli). #>
    param(
        [Parameter(Mandatory)]$Device,
        [Parameter(Mandatory)][byte[]]$Jpeg
    )
    return Send-TlLcdImageData -Device $Device -Jpeg $Jpeg -Streaming
}

function Send-TlLcdImage {
    <#
      Bir goruntu dosyasini ekrana KALICI olarak basar:
      once JPEG parcalari, sonra "ShowJpg" moduna gecis.
    #>
    param(
        [Parameter(Mandatory)]$Device,
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(0, 100)][int]$Brightness = 100,
        [ValidateSet(0, 90, 180, 270)][int]$Rotation = 0
    )

    $jpeg = ConvertTo-TlLcdJpeg -Path $Path
    $paket = Send-TlLcdImageData -Device $Device -Jpeg $jpeg
    Set-TlLcdSettings -Device $Device -Brightness $Brightness -Rotation $Rotation -Mode $script:LCD_MODE_SHOW_JPG

    return [PSCustomObject]@{
        JpegBayt  = $jpeg.Length
        PaketSayi = $paket
    }
}
