# CorsairDram.ps1 - Corsair DDR5 RGB bellek denetleyicisi (GUNCEL protokol).
#
# YONETICI YETKISI GEREKIR (SMBus -> PawnIO).
#
# ---------------------------------------------------------------------------
# ESKI PROTOKOLU TEKRAR DENEME
#   Once "Vengeance Pro" (DDR4 nesli) protokolu denendi: 0xA4/0xA5/0xA6 mod
#   register'lari, 0xB0/0xB1/0xB2 ayri R/G/B baytlari. Bu DDR5 modullerinde
#   HICBIR ETKISI YOK - denendi, isik degismedi. O yol kaldirildi; geri
#   getirilmesin.
#
#   Guncel protokol (OpenRGB CorsairDRAMController):
#     - Renk verisi TEK BIR 32 BAYTLIK BLOK YAZMASI ile gonderilir
#     - Hedef register: 0x31 (renk tamponu blok 1)
#     - Paket: [LED sayisi][R,G,B]x N[CRC-8]
#     - "Direct" modda cihaza AYRICA mod anlatmak GEREKMIYOR: kaynakta
#       SetEffect() direct modda hemen return ediyor, yani tek yazma yeterli.
# ---------------------------------------------------------------------------
#
# OKUMA YOK
#   OpenRGB cihazi 0x43/0x44 register'larini OKUYARAK dogruluyor ve efekt
#   modunda CRC'yi cihazdan geri okuyup karsilastiriyor. Bu makinede SMBus
#   OKUMA CALISMIYOR (bkz. tools/scan-smbus-bus.ps1 + probe-spd.ps1), bu yuzden:
#     - cihaz dogrulamasi YAPILAMAZ, adresler korlemesine kullanilir
#     - CRC geri okumali "efekt" yolu KULLANILAMAZ, sadece direct mod calisir
#   Bu bilincli bir sinirlama; basarisizlik sessiz olur, uydurma rapor verilmez.

. (Join-Path $PSScriptRoot "Smbus.ps1")

# --- Register haritasi (OpenRGB CorsairDRAMController.h) ---
$script:CDRAM_REG_COLOR_BLOCK_1 = 0x31
$script:CDRAM_REG_COLOR_BLOCK_2 = 0x32

# Corsair Vengeance RGB DDR5: modul basina 10 LED (OpenRGB cihaz tablosu)
$script:CDRAM_LED_COUNT_VENGEANCE_DDR5 = 10

# DDR5'te RGB denetleyicisinin adresi = SPD adresi - 0x38
#   SPD 0x50 -> RGB 0x18,  SPD 0x52 -> RGB 0x1A
$script:CDRAM_SPD_TO_RGB_OFFSET = 0x38

function Get-CorsairDramCrc8 {
    <#
      CRC-8: polinom 0x07, baslangic 0x00, yansitma yok, son XOR yok.
      (CRC++ kutuphanesindeki CRC::CRC_8() tanimi.)
    #>
    param([Parameter(Mandatory)][byte[]]$Data)

    $crc = 0
    foreach ($b in $Data) {
        $crc = $crc -bxor [int]$b
        for ($i = 0; $i -lt 8; $i++) {
            if (($crc -band 0x80) -ne 0) { $crc = (($crc -shl 1) -bxor 0x07) -band 0xFF }
            else                         { $crc =  ($crc -shl 1) -band 0xFF }
        }
    }
    return [byte]$crc
}

function ConvertFrom-HexColor {
    <# "FF8000" / "#FF8000" -> [byte[]] R,G,B #>
    param([Parameter(Mandatory)][string]$Hex)

    $h = $Hex.TrimStart('#').Trim()
    if ($h.Length -ne 6) { throw "Colour must be 6 hex digits (e.g. FF8000), given: '$Hex'" }
    return @(
        [Convert]::ToByte($h.Substring(0,2), 16),
        [Convert]::ToByte($h.Substring(2,2), 16),
        [Convert]::ToByte($h.Substring(4,2), 16)
    )
}

function New-CorsairDramDirectPacket {
    <#
      Direct mod paketini kurar.
        [0]          = LED sayisi
        [1 .. 3N]    = LED basina R,G,B
        [3N+1]       = onceki tum baytlarin CRC-8'i
      10 LED icin toplam TAM 32 BAYT olur - tek blok yazmasina sigar.
    #>
    param(
        [Parameter(Mandatory)][byte[][]]$LedColors   # her eleman: R,G,B
    )

    $n = $LedColors.Count
    $boyut = ($n * 3) + 2
    $paket = New-Object 'byte[]' $boyut
    $paket[0] = [byte]$n

    for ($i = 0; $i -lt $n; $i++) {
        $ofs = ($i * 3) + 1
        $paket[$ofs + 0] = $LedColors[$i][0]
        $paket[$ofs + 1] = $LedColors[$i][1]
        $paket[$ofs + 2] = $LedColors[$i][2]
    }

    $paket[$boyut - 1] = Get-CorsairDramCrc8 -Data $paket[0..($boyut - 2)]
    return $paket
}

function Set-CorsairDramColor {
    <#
      Bir bellek modulunun tum LED'lerini tek renge boyar (direct mod).

      Doner: PSCustomObject { Ok, Hr1, Hr2, PaketBoyu }
      Hr degerleri SMBus islem sonucudur; 0 = surucu seviyesinde basarili.
      DIKKAT: hr=0 "isik degisti" DEMEK DEGILDIR - geri okuma olmadigi icin
      gorsel dogrulama kullaniciya birakilir.
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [Parameter(Mandatory)][int]$Address,
        [Parameter(Mandatory)][string]$Color,
        [int]$LedCount = $script:CDRAM_LED_COUNT_VENGEANCE_DDR5
    )

    $rgb = ConvertFrom-HexColor -Hex $Color
    $renkler = @()
    for ($i = 0; $i -lt $LedCount; $i++) { $renkler += ,$rgb }

    $paket = New-CorsairDramDirectPacket -LedColors $renkler

    # Ilk blok: SABIT 32 bayt (kaynakta da uzunluk 32 olarak veriliyor)
    $ilkUzunluk = [Math]::Min(32, $paket.Length)
    $hr1 = Write-SmbusBlock -Handle $Handle -Address $Address `
                            -Register $script:CDRAM_REG_COLOR_BLOCK_1 `
                            -Data $paket[0..($ilkUzunluk - 1)]

    # Paket 32 bayti asiyorsa kalani ikinci bloga (10 LED'de asmaz)
    $hr2 = $null
    if ($hr1 -eq 0 -and $paket.Length -gt 32) {
        Start-Sleep -Milliseconds 5
        $hr2 = Write-SmbusBlock -Handle $Handle -Address $Address `
                                -Register $script:CDRAM_REG_COLOR_BLOCK_2 `
                                -Data $paket[32..($paket.Length - 1)]
    }

    return [PSCustomObject]@{
        Ok        = ($hr1 -eq 0 -and ($null -eq $hr2 -or $hr2 -eq 0))
        Hr1       = $hr1
        Hr2       = $hr2
        PaketBoyu = $paket.Length
    }
}

function Get-CorsairDramRgbAddress {
    <# SPD adresinden RGB denetleyici adresini turetir (DDR5: -0x38). #>
    param([Parameter(Mandatory)][int]$SpdAddress)
    return ($SpdAddress - $script:CDRAM_SPD_TO_RGB_OFFSET)
}
