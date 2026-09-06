# LianLiTL.ps1 - Lian Li UNI FAN TL kontrolcusu (VID 0x0416 / PID 0x7372)
#
# Protokol (acik kaynak tersine muhendislik calismalarindan alinmistir):
#   Arayuz      : UsagePage 0xFF1B, 64 bayt In/Out
#   Rapor ID    : 0x01
#   Paket       : 64 bayt, 6 baytlik baslik
#                 [0]=0x01  [1]=komut  [2]=rezerve  [3]=pktNoHi  [4]=pktNoLo  [5]=veriUzunlugu
#                 [6..]=veri
#   0xA1 HANDSHAKE  -> fan envanteri + RPM. Durum DEGISTIRMEZ, sadece sorgular.
#   0xAA SET_SPEED  -> veri = [ (port<<4)|fanIndex , duty(0-255) ]
#   0xA3 SET_LIGHT  -> RGB (Faz 1'in ikinci adiminda)
#
#   4 port (0-3), her portta zincirlenmis birden fazla fan olabilir.
#   TL fan basina 20 LED.

. (Join-Path $PSScriptRoot "HidCore.ps1")

$script:TL_VID         = 0x0416
$script:TL_PID         = 0x7372
$script:TL_USAGE_PAGE  = 0xFF1B

$script:TL_REPORT_ID   = 0x01
$script:TL_PACKET_SIZE = 64
$script:TL_HEADER_LEN  = 6

$script:TL_CMD_HANDSHAKE = 0xA1
$script:TL_CMD_SET_SPEED = 0xAA
$script:TL_CMD_SET_LIGHT = 0xA3

function Get-TLDeviceInfos {
    <#
      Sistemdeki TUM TL kontrolcu arayuzlerini dondurur (salt okuma, hicbir
      sey gonderilmez).

      NEDEN COGUL: bir kontrolcu 4 port x 16 fan tasiyor; bu siniri asan
      kullanicilar ikinci bir kontrolcu takiyor. Tek cihaz varsayimi o
      kullanicida ikinci kontrolcuyu SESSIZCE gormezden gelirdi.

      FILTRE NOTU: kontrolcu birden fazla HID arayuzu sunuyor (olculdu:
      protokol arayuzu UsagePage 0xFF1B / 64 bayt, ayrica UsagePage 0x0001
      olan bir klavye arayuzu). UsagePage + OutputLen ikilisi protokol
      arayuzunu tek basina secer; boylece ayni cihaz iki kez sayilmaz.
    #>
    [LianLi.HidCore]::Enumerate() | Where-Object {
        $_.Vid -eq $script:TL_VID -and
        $_.Pid -eq $script:TL_PID -and
        $_.UsagePage -eq $script:TL_USAGE_PAGE -and
        $_.OutputLen -eq $script:TL_PACKET_SIZE
    }
}

function Get-TLDeviceInfo {
    <#
      Ilk kontrolcuyu dondurur; yoksa $null.
      Tek cihazla calisan tools/ betikleri icin korunuyor - birden fazla
      kontrolcuyu yonetmesi gereken kod Get-TLDeviceInfos kullanmali.
    #>
    @(Get-TLDeviceInfos) | Select-Object -First 1
}

function New-TLPacket {
    param([byte]$Command, [byte[]]$Data = @())

    $pkt = New-Object byte[] $script:TL_PACKET_SIZE
    $pkt[0] = $script:TL_REPORT_ID
    $pkt[1] = $Command
    $pkt[2] = 0x00
    $pkt[3] = 0x00
    $pkt[4] = 0x00
    $pkt[5] = [byte]$Data.Length
    if ($Data.Length -gt 0) {
        [Array]::Copy($Data, 0, $pkt, $script:TL_HEADER_LEN, [Math]::Min($Data.Length, $script:TL_PACKET_SIZE - $script:TL_HEADER_LEN))
    }
    return $pkt
}

function Invoke-TLCommand {
    <#  Paketi gonderir; -ExpectResponse verilirse cevabi okur. #>
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] [byte]$Command,
        [byte[]]$Data = @(),
        [switch]$ExpectResponse,
        [int]$TimeoutMs = 3000
    )

    $pkt = New-TLPacket -Command $Command -Data $Data
    $Device.Write($pkt, 1000)
    if (-not $ExpectResponse) { return $null }

    # Cihaz bazen alakasiz bir rapor gonderebilir; dogru komutun cevabini bekleyelim.
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $kalan = [int]((($deadline) - (Get-Date)).TotalMilliseconds)
        if ($kalan -le 0) { break }
        $resp = $Device.Read($kalan)
        if ($null -eq $resp) { continue }
        if ($resp.Length -ge $script:TL_HEADER_LEN -and $resp[1] -eq $Command) { return $resp }
    }
    return $null
}

function Get-TLFans {
    <#
      Handshake (0xA1) gonderip fan envanterini dondurur.
      Bu komut sadece SORGULAR - fan hizini, rengini veya baska hicbir ayari degistirmez.
      Doner: her fan icin Port / FanIndex / RPM / Detected
    #>
    param([Parameter(Mandatory)] $Device)

    $resp = Invoke-TLCommand -Device $Device -Command $script:TL_CMD_HANDSHAKE -ExpectResponse -TimeoutMs 3000
    if ($null -eq $resp) { return $null }

    $dataLen = [int]$resp[5]
    $fanSayisi = [Math]::Floor($dataLen / 3)
    $fanlar = @()

    for ($i = 0; $i -lt $fanSayisi; $i++) {
        $off = $script:TL_HEADER_LEN + ($i * 3)
        if (($off + 2) -ge $resp.Length) { break }

        # DIKKAT: PowerShell'de -shl/-shr [byte] uzerinde 8 bit genisliginde calisir,
        # yani [byte]3 -shl 8 sonucu 0 verir. RPM'in ust baytini kaybetmemek icin
        # kaydirmadan once mutlaka [int]'e cevir.
        $info = [int]$resp[$off]
        $rpmHi = [int]$resp[$off + 1]
        $rpmLo = [int]$resp[$off + 2]

        $fanlar += [PSCustomObject]@{
            Port      = ($info -shr 4) -band 0x03
            FanIndex  = $info -band 0x0F
            Detected  = (($info -band 0x80) -ne 0)
            Upgrading = (($info -band 0x40) -ne 0)
            RPM       = ($rpmHi -shl 8) -bor $rpmLo
            InfoByte  = ('0x{0:X2}' -f $info)
        }
    }

    return [PSCustomObject]@{
        RawDataLen = $dataLen
        Fans       = $fanlar
        Raw        = ($resp[0..([Math]::Min($resp.Length, 32) - 1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    }
}

function Set-TLFanDuty {
    <#
      Ham duty baytini gonderir (olcek yorumlanmaz).
      Protokol arastirmasi / kalibrasyon icin.
    #>
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] [ValidateRange(0,3)]   [int]$Port,
        [Parameter(Mandatory)] [ValidateRange(0,15)]  [int]$FanIndex,
        [Parameter(Mandatory)] [ValidateRange(0,255)] [int]$Duty
    )

    $addr = [byte](($Port -shl 4) -bor ($FanIndex -band 0x0F))
    Invoke-TLCommand -Device $Device -Command $script:TL_CMD_SET_SPEED -Data @($addr, [byte]$Duty) | Out-Null
    return [PSCustomObject]@{ Port = $Port; FanIndex = $FanIndex; Duty = $Duty }
}

# TL RGB mod tablosu (protokoldeki mod baytlari)
$script:TL_MODES = [ordered]@{
    'Rainbow'         = 1
    'RainbowMorph'    = 2
    'Static'          = 3      # sabit renk
    'Breathing'       = 4
    'Runway'          = 5
    'Meteor'          = 6
    'ColorCycle'      = 7
    'Staggered'       = 8
    'Tide'            = 9
    'Mixing'          = 10
    'Voice'           = 11
    'Door'            = 12
    'Render'          = 13
    'Ripple'          = 14
    'Reflect'         = 15
    'TailChasing'     = 16
    'Paint'           = 17
    'PingPong'        = 18
    'Stack'           = 19
    'CoverCycle'      = 20
    'Wave'            = 21
    'Racing'          = 22
    'Lottery'         = 23
    'Intertwine'      = 24
    'MeteorShower'    = 25
    'Collide'         = 26
    'ElectricCurrent' = 27
    'Kaleidoscope'    = 28
}

$script:TL_DIRECTIONS = [ordered]@{
    'Clockwise' = 0; 'CounterClockwise' = 1; 'Up' = 2; 'Down' = 3; 'Spread' = 4; 'Gather' = 5
}

function ConvertFrom-HexColor {
    <# "FF0000" veya "#FF0000" -> @(R,G,B) #>
    param([Parameter(Mandatory)][string]$Hex)
    $h = $Hex.TrimStart('#')
    if ($h.Length -ne 6) { throw "Colour must be 6 hex digits (e.g. FF0000): '$Hex'" }
    return @(
        [byte][Convert]::ToInt32($h.Substring(0,2), 16),
        [byte][Convert]::ToInt32($h.Substring(2,2), 16),
        [byte][Convert]::ToInt32($h.Substring(4,2), 16)
    )
}

function Set-TLFanLight {
    <#
      Bir fanin isigini ayarlar (komut 0xA3, 20 baytlik payload).

        [0]     = (port<<4) | sync
        [1]     = (port<<4) | fanIndex
        [2]     = mod bayti
        [3]     = parlaklik 0-4
        [4]     = hiz 0-4
        [5..16] = R,G,B x 4 renk
        [17]    = yon 0-5
        [18]    = kapali bayragi (1 = isik kapali)
        [19]    = kullanilan renk sayisi
    #>
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] [ValidateRange(0,3)]  [int]$Port,
        [Parameter(Mandatory)] [ValidateRange(0,15)] [int]$FanIndex,
        [string]$Mode = 'Static',
        [string[]]$Colors = @('FF0000'),
        [ValidateRange(0,4)] [int]$Brightness = 4,
        [ValidateRange(0,4)] [int]$Speed = 2,
        [string]$Direction = 'Clockwise',
        [switch]$Off,
        [switch]$SyncWithMotherboard
    )

    if (-not $script:TL_MODES.Contains($Mode)) {
        throw "Unknown mode '$Mode'. Valid modes: $(($script:TL_MODES.Keys) -join ', ')"
    }
    if (-not $script:TL_DIRECTIONS.Contains($Direction)) {
        throw "Unknown direction '$Direction'. Valid directions: $(($script:TL_DIRECTIONS.Keys) -join ', ')"
    }

    $payload = New-Object byte[] 20
    $payload[0] = [byte](($Port -shl 4) -bor ([int][bool]$SyncWithMotherboard))
    $payload[1] = [byte](($Port -shl 4) -bor ($FanIndex -band 0x0F))
    $payload[2] = [byte]$script:TL_MODES[$Mode]
    $payload[3] = [byte]$Brightness
    $payload[4] = [byte]$Speed

    $renkSayisi = [Math]::Min($Colors.Count, 4)
    for ($i = 0; $i -lt $renkSayisi; $i++) {
        $rgb = ConvertFrom-HexColor -Hex $Colors[$i]
        # DIKKAT: bu degiskeni '$off' diye adlandirma - PowerShell degisken adlarinda
        # buyuk/kucuk harf ayrimi yapmaz ve '$Off' switch parametresini ezer.
        $renkOfs = 5 + ($i * 3)
        $payload[$renkOfs]     = $rgb[0]   # R
        $payload[$renkOfs + 1] = $rgb[1]   # G
        $payload[$renkOfs + 2] = $rgb[2]   # B
    }

    $payload[17] = [byte]$script:TL_DIRECTIONS[$Direction]
    $payload[18] = [byte]([int][bool]$Off)
    $payload[19] = [byte]$renkSayisi

    Invoke-TLCommand -Device $Device -Command $script:TL_CMD_SET_LIGHT -Data $payload | Out-Null
    return [PSCustomObject]@{
        Port = $Port; FanIndex = $FanIndex; Mode = $Mode; ModeByte = $payload[2]
        Colors = ($Colors | Select-Object -First 4); Brightness = $Brightness; Off = [bool]$Off
    }
}

function Get-TLModes { $script:TL_MODES.Keys }

function Set-TLFanSpeed {
    <#
      Tek bir fanin hizini yuzde olarak ayarlar. Port 0-3, Percent 0-100.

      OLCEK NOTU: Referans implementasyonda duty 0-255 PWM olarak belgelenmis,
      ancak bu donanimda (TL_Series_ControllerV0.62) olculen davranis 0-100
      olceginde: 100 ustu tum degerler ayni maksimum RPM'i veriyor.
      Bu yuzden yuzde dogrudan duty olarak gonderiliyor.
    #>
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] [ValidateRange(0,3)]   [int]$Port,
        [Parameter(Mandatory)] [ValidateRange(0,15)]  [int]$FanIndex,
        [Parameter(Mandatory)] [ValidateRange(0,100)] [int]$Percent
    )

    $r = Set-TLFanDuty -Device $Device -Port $Port -FanIndex $FanIndex -Duty $Percent
    return [PSCustomObject]@{ Port = $Port; FanIndex = $FanIndex; Percent = $Percent; Duty = $r.Duty }
}
