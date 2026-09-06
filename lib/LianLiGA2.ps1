# LianLiGA2.ps1 - Lian Li Galahad II Trinity AIO (VID 0x0416 / PID 0x7373)
#
# Paket bicimi TL kontrolcusuyle ayni ailede:
#   Rapor ID 0x01, 64 bayt, 6 baytlik baslik
#   [0]=0x01 [1]=komut [2]=rsv [3]=pktHi [4]=pktLo [5]=veriUzunlugu [6..]=veri
#
# ANCAK KOMUT BAYTLARI FARKLI - TL'nin 0xA1/0xAA'si burada gecerli DEGIL:
#   0x81 HANDSHAKE      -> cevap: [0..1]=fan RPM (BE), [2..3]=pompa RPM (BE)
#   0x8A SET_PUMP_PWM   -> veri = [mbSync, yuzde 0-100]
#   0x8B SET_FAN_PWM    -> veri = [mbSync, yuzde 0-100]
#   0x83 SET_PUMP_LIGHT / 0x85 SET_FAN_LIGHT
#
# NOT: Bu cihazda sivi (coolant) sicaklik sensoru YOKTUR.

. (Join-Path $PSScriptRoot "HidCore.ps1")

$script:GA2_VID        = 0x0416
$script:GA2_PID        = 0x7373
$script:GA2_USAGE_PAGE = 0xFF1B

$script:GA2_REPORT_ID   = 0x01
$script:GA2_PACKET_SIZE = 64
$script:GA2_HEADER_LEN  = 6

$script:GA2_CMD_HANDSHAKE      = 0x81
$script:GA2_CMD_GET_FIRMWARE   = 0x86
$script:GA2_CMD_SET_PUMP_PWM   = 0x8A
$script:GA2_CMD_SET_FAN_PWM    = 0x8B
$script:GA2_CMD_SET_PUMP_LIGHT = 0x83
$script:GA2_CMD_SET_FAN_LIGHT  = 0x85

# Pompa basligi LED sayisi (kaynakta FAN_LED_COUNT = 24, pompa bolgesi de 24)
$script:GA2_LED_COUNT = 24

# Pompayi asla tamamen durdurmamak icin guvenlik tabani.
$script:GA2_PUMP_MIN_PERCENT = 40

function Get-GA2DeviceInfo {
    [LianLi.HidCore]::Find($script:GA2_VID, $script:GA2_PID, $script:GA2_USAGE_PAGE)
}

function New-GA2Packet {
    param([byte]$Command, [byte[]]$Data = @())
    $pkt = New-Object byte[] $script:GA2_PACKET_SIZE
    $pkt[0] = $script:GA2_REPORT_ID
    $pkt[1] = $Command
    $pkt[5] = [byte]$Data.Length
    if ($Data.Length -gt 0) {
        [Array]::Copy($Data, 0, $pkt, $script:GA2_HEADER_LEN, [Math]::Min($Data.Length, $script:GA2_PACKET_SIZE - $script:GA2_HEADER_LEN))
    }
    return $pkt
}

function Invoke-GA2Command {
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] [byte]$Command,
        [byte[]]$Data = @(),
        [switch]$ExpectResponse,
        [int]$TimeoutMs = 3000
    )
    $Device.Write((New-GA2Packet -Command $Command -Data $Data), 1000)
    if (-not $ExpectResponse) { return $null }

    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $kalan = [int]((($deadline) - (Get-Date)).TotalMilliseconds)
        if ($kalan -le 0) { break }
        $resp = $Device.Read($kalan)
        if ($null -eq $resp) { continue }
        if ($resp.Length -ge $script:GA2_HEADER_LEN -and $resp[1] -eq $Command) { return $resp }
    }
    return $null
}

function Get-GA2Status {
    <#
      Handshake (0x81). Sadece SORGULAR - pompa veya fan ayarini degistirmez.
      Doner: FanRPM, PumpRPM
    #>
    param([Parameter(Mandatory)] $Device)

    $resp = Invoke-GA2Command -Device $Device -Command $script:GA2_CMD_HANDSHAKE -ExpectResponse -TimeoutMs 3000
    if ($null -eq $resp) { return $null }

    $h = $script:GA2_HEADER_LEN
    if ($resp.Length -lt ($h + 4)) { return $null }

    # [int] cast'i sart: PowerShell'de -shl bir [byte] uzerinde 8 bit genisliginde calisir.
    $fanRpm  = ([int]$resp[$h]     -shl 8) -bor [int]$resp[$h + 1]
    $pumpRpm = ([int]$resp[$h + 2] -shl 8) -bor [int]$resp[$h + 3]

    return [PSCustomObject]@{
        FanRPM     = $fanRpm
        PumpRPM    = $pumpRpm
        RawDataLen = [int]$resp[5]
        Raw        = ($resp[0..([Math]::Min($resp.Length, 24) - 1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    }
}

function Set-GA2PumpSpeed {
    <#
      Pompa hizi. GUVENLIK: $GA2_PUMP_MIN_PERCENT altina inilmesine izin verilmez.
      -Force ile taban gecilebilir, ama CPU sogutmasi riske girer.
    #>
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] [ValidateRange(0,100)] [int]$Percent,
        [switch]$MotherboardSync,
        [switch]$Force
    )
    $uygulanan = $Percent
    if (-not $Force -and $uygulanan -lt $script:GA2_PUMP_MIN_PERCENT) {
        $uygulanan = $script:GA2_PUMP_MIN_PERCENT
    }
    $mb = [byte]([int][bool]$MotherboardSync)
    Invoke-GA2Command -Device $Device -Command $script:GA2_CMD_SET_PUMP_PWM -Data @($mb, [byte]$uygulanan) | Out-Null
    return [PSCustomObject]@{ Istenen = $Percent; Uygulanan = $uygulanan; Taban = $script:GA2_PUMP_MIN_PERCENT }
}

function Set-GA2FanSpeed {
    <# AIO radyator fan kanali. #>
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)] [ValidateRange(0,100)] [int]$Percent,
        [switch]$MotherboardSync
    )
    $mb = [byte]([int][bool]$MotherboardSync)
    Invoke-GA2Command -Device $Device -Command $script:GA2_CMD_SET_FAN_PWM -Data @($mb, [byte]$Percent) | Out-Null
    return [PSCustomObject]@{ Percent = $Percent }
}

# --- RGB ---
# Mod baytlari TL ile ayni tabloyu kullaniyor gorunuyor; kaynak kodda
# "eslenemezse Static'e dus" durumunda 3 yaziliyor, bu da TL'deki Static=3
# ile ortusuyor. Sabit renk icin 3 kullaniyoruz.
$script:GA2_MODE_STATIC = 3

function Set-GA2PumpLight {
    <#
      Pompa basligi isigi (komut 0x83, 19 baytlik payload).
        [0]=kapsam (0=Ic, 1=Dis, 2=Tumu)
        [1]=mod  [2]=parlaklik 0-4  [3]=hiz 0-4
        [4..15]=R,G,B x 4
        [16]=yon  [17]=kapali bayragi  [18]=kaynak (0=cihaz MCU, 1=anakart)
    #>
    param(
        [Parameter(Mandatory)] $Device,
        [string]$Color = 'FF0000',
        [ValidateRange(0,8)] [int]$Brightness = 0,
        [ValidateRange(0,4)] [int]$Speed = 2,
        [ValidateSet('Inner','Outer','All')] [string]$Scope = 'All',
        [int]$ModeByte = -1,
        [ValidateRange(0,1)] [int]$SourceByte = 0,   # 0 = cihazin MCU'su, 1 = anakart
        [switch]$Off
    )

    $kapsam = switch ($Scope) { 'Inner' { 0 } 'Outer' { 1 } default { 2 } }
    $mod = if ($ModeByte -ge 0) { $ModeByte } else { $script:GA2_MODE_STATIC }

    $h = $Color.TrimStart('#')
    if ($h.Length -ne 6) { throw "Colour must be 6 hex digits: '$Color'" }
    $r = [byte][Convert]::ToInt32($h.Substring(0,2),16)
    $g = [byte][Convert]::ToInt32($h.Substring(2,2),16)
    $b = [byte][Convert]::ToInt32($h.Substring(4,2),16)

    $payload = New-Object byte[] 19
    $payload[0] = [byte]$kapsam
    $payload[1] = [byte]$mod
    $payload[2] = [byte]$Brightness
    $payload[3] = [byte]$Speed
    $payload[4] = $r; $payload[5] = $g; $payload[6] = $b
    $payload[16] = 0                                # yon
    $payload[17] = [byte]([int][bool]$Off)
    $payload[18] = [byte]$SourceByte

    Invoke-GA2Command -Device $Device -Command $script:GA2_CMD_SET_PUMP_LIGHT -Data $payload | Out-Null
    return [PSCustomObject]@{
        Zone = 'PumpHead'; Scope = $Scope; Color = $Color; Off = [bool]$Off
        Brightness = $Brightness; ModeByte = $mod; Source = $SourceByte
    }
}

function Set-GA2FanLight {
    <#
      AIO fan kanali isigi (komut 0x85, 20 baytlik payload).
        [0]=mod  [1]=parlaklik  [2]=hiz
        [3..14]=R,G,B x 4
        [15]=yon  [16]=kapali  [17]=kaynak  [18]=pompaya senkron  [19]=LED sayisi
      NOT: Bu sistemde AIO fan kanali bos oldugu icin gorsel etkisi yoktur;
      fan takilirsa diye destekleniyor.
    #>
    param(
        [Parameter(Mandatory)] $Device,
        [string]$Color = 'FF0000',
        [ValidateRange(0,4)] [int]$Brightness = 4,
        [ValidateRange(0,4)] [int]$Speed = 2,
        [int]$ModeByte = -1,
        [switch]$SyncToPump,
        [switch]$Off
    )

    $mod = if ($ModeByte -ge 0) { $ModeByte } else { $script:GA2_MODE_STATIC }
    $h = $Color.TrimStart('#')
    if ($h.Length -ne 6) { throw "Colour must be 6 hex digits: '$Color'" }
    $r = [byte][Convert]::ToInt32($h.Substring(0,2),16)
    $g = [byte][Convert]::ToInt32($h.Substring(2,2),16)
    $b = [byte][Convert]::ToInt32($h.Substring(4,2),16)

    $payload = New-Object byte[] 20
    $payload[0] = [byte]$mod
    $payload[1] = [byte]$Brightness
    $payload[2] = [byte]$Speed
    $payload[3] = $r; $payload[4] = $g; $payload[5] = $b
    $payload[15] = 0
    $payload[16] = [byte]([int][bool]$Off)
    $payload[17] = 0
    $payload[18] = [byte]([int][bool]$SyncToPump)
    $payload[19] = [byte]$script:GA2_LED_COUNT

    Invoke-GA2Command -Device $Device -Command $script:GA2_CMD_SET_FAN_LIGHT -Data $payload | Out-Null
    return [PSCustomObject]@{ Zone = 'AioFans'; Color = $Color; Off = [bool]$Off }
}
