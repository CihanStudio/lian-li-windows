# Smbus.ps1 - PawnIO SmbusPIIX4 modulu uzerinden SMBus erisimi.
#
# YONETICI YETKISI GEREKIR (pawnio_open aksi halde 0x80070005 doner).
#
# Paket duzeni (modul kaynagindan dogrulandi):
#   in[0] = adres, in[1] = 1:oku / 0:yaz, in[2] = komut, in[3] = protokol
#   in[4..] = veri; BLOCK icin bayt dizisi little-endian paketlenir ve
#             ILK BAYT UZUNLUKTUR: [uzunluk, d0, d1, ...]
#   BLOCK okumada cikis da ayni sekilde paketlidir: out_data[0] = uzunluk.
#
# ---------------------------------------------------------------------------
# GUVENLIK KORUMASI
#   Bu dosya, YAZMA islemlerini belirli adres araliklarinda KALICI olarak
#   reddeder. DDR5'te SPD hub'ina (0x50-0x57) veya PMIC'e (0x48-0x4F) yanlis
#   yazmak bellek modulunu kalici olarak bozabilir. RGB denetleyicileri
#   ayri adreslerdedir (0x18-0x1B), oraya yazmak guvenlidir.
#   Bu koruma bilincli olarak parametreyle kapatilamaz.
# ---------------------------------------------------------------------------

. (Join-Path $PSScriptRoot "PawnIO.ps1")

$script:SMB_QUICK     = 0
$script:SMB_BYTE      = 1
$script:SMB_BYTE_DATA = 2
$script:SMB_WORD_DATA = 3
$script:SMB_BLOCK_DATA = 5

# Yazmanin yasak oldugu adresler
$script:SMB_WRITE_YASAK = @()
$script:SMB_WRITE_YASAK += 0x48..0x4F   # DDR5 PMIC
$script:SMB_WRITE_YASAK += 0x50..0x57   # DDR5 SPD hub

function Assert-SmbusWriteAllowed {
    param([int]$Address)
    if ($script:SMB_WRITE_YASAK -contains $Address) {
        throw ("GUVENLIK: 0x{0:X2} adresine yazma engellendi. Bu adres DDR5 SPD/PMIC bolgesinde; yanlis yazma bellek modulunu kalici bozabilir." -f $Address)
    }
}

function Open-SmbusModule {
    Open-PawnIOModule -ModuleName "SmbusPIIX4.bin"
}

function Get-SmbusIdentity {
    param([Parameter(Mandatory)][IntPtr]$Handle)
    $r = [PawnIO.Lib]::Execute($Handle, "ioctl_identity", @(), 3)
    $tur = ""
    if ($r.Count -ge 1) {
        # Tur alani ASCII olarak paketli ("PIIX4")
        $v = [uint64]$r[0]
        for ($i = 0; $i -lt 8; $i++) {
            $b = [int](($v -shr ($i * 8)) -band 0xFF)
            if ($b -ge 32 -and $b -lt 127) { $tur += [char]$b }
        }
    }
    return [PSCustomObject]@{
        Type    = $tur
        IoBase  = if ($r.Count -ge 2) { [uint64]$r[1] } else { 0 }
        PciId   = if ($r.Count -ge 3) { [uint64]$r[2] } else { 0 }
    }
}

function Set-SmbusPort {
    param([Parameter(Mandatory)][IntPtr]$Handle, [Parameter(Mandatory)][int]$Port)
    $r = [PawnIO.Lib]::Execute($Handle, "ioctl_piix4_port_sel", @([uint64]$Port), 1)
    return $(if ($r.Count -gt 0) { [int]$r[0] } else { -1 })
}

# --- bayt dizisi <-> 64-bit hucre paketleme (little-endian) ---
function ConvertTo-SmbusCells {
    param([byte[]]$Bytes)
    $hucreSayisi = [Math]::Ceiling($Bytes.Length / 8.0)
    if ($hucreSayisi -lt 1) { $hucreSayisi = 1 }
    $cells = New-Object 'UInt64[]' $hucreSayisi
    for ($i = 0; $i -lt $Bytes.Length; $i++) {
        $c = [int][Math]::Floor($i / 8)
        $shift = ($i % 8) * 8
        $cells[$c] = $cells[$c] -bor ([uint64]$Bytes[$i] -shl $shift)
    }
    return $cells
}

function ConvertFrom-SmbusCells {
    param([UInt64[]]$Cells, [int]$ByteCount)
    $out = New-Object 'byte[]' $ByteCount
    for ($i = 0; $i -lt $ByteCount; $i++) {
        $c = [int][Math]::Floor($i / 8)
        if ($c -ge $Cells.Length) { break }
        $shift = ($i % 8) * 8
        $out[$i] = [byte](([uint64]$Cells[$c] -shr $shift) -band 0xFF)
    }
    return $out
}

function Read-SmbusByteRaw {
    <# Tek bir BYTE_DATA islemi. Ham sonuc - yankı duzeltmesi YOK. #>
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [Parameter(Mandatory)][int]$Address,
        [Parameter(Mandatory)][int]$Register
    )
    $in = @([uint64]$Address, [uint64]1, [uint64]$Register, [uint64]$script:SMB_BYTE_DATA)
    $res = $null
    $hr = [PawnIO.Lib]::TryExecute($Handle, "ioctl_smbus_xfer", $in, 5, [ref]$res)
    if ($hr -ne 0 -or $res.Count -lt 1) { return $null }
    return [byte]([uint64]$res[0] -band 0xFF)
}

function Read-SmbusByte {
    <#
      BYTE_DATA okuma - YANKI DUZELTMELI.

      OLCULEN DAVRANIS: bu denetleyicide tek bir okuma, BIR ONCEKI islemin
      veri baytini donduruyor (islem tamamlanmadan veri register'i okunuyor).
      Kanit: 0xB0'a 0x5A yazip 0xB1'i okuyunca 0x5A geliyordu.

      Bu yuzden ayni register iki kez okunur ve IKINCI sonuc dondurulur:
      ikinci okuma, birinci okumanin verisini - yani gercek icerigi - verir.
      -Raw ile duzeltme atlanabilir (teshis icin).
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [Parameter(Mandatory)][int]$Address,
        [Parameter(Mandatory)][int]$Register,
        [switch]$Raw,
        [int]$SettleMs = 3
    )

    $ilk = Read-SmbusByteRaw -Handle $Handle -Address $Address -Register $Register
    if ($Raw) { return $ilk }
    if ($null -eq $ilk) { return $null }

    Start-Sleep -Milliseconds $SettleMs
    return Read-SmbusByteRaw -Handle $Handle -Address $Address -Register $Register
}

function Write-SmbusByte {
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [Parameter(Mandatory)][int]$Address,
        [Parameter(Mandatory)][int]$Register,
        [Parameter(Mandatory)][byte]$Value
    )
    Assert-SmbusWriteAllowed -Address $Address
    # Cikis tamponu comert tutuluyor: modul beklenenden fazla hucre yazarsa
    # ERROR_INSUFFICIENT_BUFFER (0x8007007A) donuyor.
    $in = @([uint64]$Address, [uint64]0, [uint64]$Register, [uint64]$script:SMB_BYTE_DATA, [uint64]$Value)
    $res = $null
    return [PawnIO.Lib]::TryExecute($Handle, "ioctl_smbus_xfer", $in, 5, [ref]$res)
}

# BLOCK islemlerinde modul in[4]'ten itibaren SABIT 33 bayt okur/yazar
# (I2C_SMBUS_BLOCK_MAX + 1). 33 bayt = 5 hucre, bu yuzden:
#   giris  = 4 baslik + 5 veri  = 9 hucre (eksikse ERROR_INSUFFICIENT_BUFFER)
#   cikis  = 5 hucre
$script:SMB_BLOCK_CELLS   = 5
$script:SMB_BLOCK_IN_SIZE = 9

function Read-SmbusBlock {
    <# BLOCK_DATA okuma. Doner: byte[] veya $null. #>
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [Parameter(Mandatory)][int]$Address,
        [Parameter(Mandatory)][int]$Register
    )
    $in = New-Object 'UInt64[]' $script:SMB_BLOCK_IN_SIZE
    $in[0] = [uint64]$Address
    $in[1] = [uint64]1
    $in[2] = [uint64]$Register
    $in[3] = [uint64]$script:SMB_BLOCK_DATA

    $res = $null
    $hr = [PawnIO.Lib]::TryExecute($Handle, "ioctl_smbus_xfer", $in, $script:SMB_BLOCK_CELLS, [ref]$res)
    if ($hr -ne 0 -or $res.Count -lt 1) { return $null }

    $ham = ConvertFrom-SmbusCells -Cells $res -ByteCount 33
    $uzunluk = [int]$ham[0]
    if ($uzunluk -lt 1 -or $uzunluk -gt 32) { return $null }
    return $ham[1..$uzunluk]
}

function Write-SmbusBlock {
    <# BLOCK_DATA yazma. En fazla 32 bayt. Doner: HRESULT (0 = basarili). #>
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [Parameter(Mandatory)][int]$Address,
        [Parameter(Mandatory)][int]$Register,
        [Parameter(Mandatory)][byte[]]$Data
    )
    Assert-SmbusWriteAllowed -Address $Address
    if ($Data.Length -gt 32) { throw "BLOCK write is limited to 32 bytes (given: $($Data.Length))." }

    # in_data = [uzunluk, d0, d1, ...] - 33 bayta sifirla doldurulur
    $paket = New-Object 'byte[]' 33
    $paket[0] = [byte]$Data.Length
    [Array]::Copy($Data, 0, $paket, 1, $Data.Length)

    $veriHucreleri = ConvertTo-SmbusCells -Bytes $paket    # tam 5 hucre
    $in = New-Object 'UInt64[]' $script:SMB_BLOCK_IN_SIZE
    $in[0] = [uint64]$Address
    $in[1] = [uint64]0
    $in[2] = [uint64]$Register
    $in[3] = [uint64]$script:SMB_BLOCK_DATA
    [Array]::Copy($veriHucreleri, 0, $in, 4, $veriHucreleri.Length)

    $res = $null
    return [PawnIO.Lib]::TryExecute($Handle, "ioctl_smbus_xfer", $in, $script:SMB_BLOCK_CELLS, [ref]$res)
}
