# probe-spd.ps1 - DDR5 SPD hub okumasi + SMBUS OKUMA KANALI TESTI
#
# YONETICI YETKISI GEREKIR.  SALT OKUMA - hicbir yazma yapilmaz.
#
# NEDEN ONEMLI:
#   RAM RGB denetleyicisi (0x18-0x1B) okumaya "yanki" donduruyordu. Bunun iki
#   olasi sebebi vardi:
#     (a) SMBus okuma yolumuz bastan bozuk  -> hicbir adresten gercek veri gelmez
#     (b) 0x18-0x1B'de gercek bir cihaz yok -> baska adresler duzgun okunur
#   SPD hub'i (0x50-0x53) JEDEC SPD5118 standardi geregi SABIT bir imza tutar:
#     MR0 = 0x51, MR1 = 0x18   (birlikte "5118")
#   Bu imza dogru geliyorsa okuma yolu SAGLAM demektir ve (b) dogrulanir.
#
# Ayrica calisirsa bedava bir sensor kazaniyoruz: her DIMM'in kendi sicakligi.

. (Join-Path $PSScriptRoot "..\lib\Smbus.ps1")

$SPD_MR_TYPE = 0x00     # MR0/MR1 = 0x51 / 0x18
$SPD_MR_TEMP = 0x31     # MR49/MR50, 16 bit little-endian

function Read-SpdWord {
    <# WORD_DATA okuma (little-endian). Basarisizsa $null. #>
    param([IntPtr]$Handle, [int]$Address, [int]$Register)
    $in = @([uint64]$Address, [uint64]1, [uint64]$Register, [uint64]3)
    $res = $null
    $hr = [PawnIO.Lib]::TryExecute($Handle, "ioctl_smbus_xfer", $in, 5, [ref]$res)
    if ($hr -ne 0 -or $res.Count -lt 1) { return $null }
    return [int]([uint64]$res[0] -band 0xFFFF)
}

function ConvertFrom-Spd5Temp {
    <# SPD5118: bit 12..2 isaretli, adim 0.25 C. #>
    param([int]$Raw)
    $v = ($Raw -shr 2) -band 0x7FF
    if ($v -ge 0x400) { $v -= 0x800 }
    return [math]::Round($v * 0.25, 2)
}

$h = [IntPtr]::Zero
try { $h = Open-SmbusModule }
catch { Write-Host ("Modul yuklenemedi: {0}" -f $_.Exception.Message) -ForegroundColor Red; exit 2 }

try {
    Invoke-WithSmbusLock -TimeoutMs 20000 -Action {
        Set-SmbusPort -Handle $h -Port 0 | Out-Null

        Write-Host ""
        Write-Host "=== DDR5 SPD hub (0x50-0x53) ===" -ForegroundColor Cyan
        Write-Host ""

        $saglam = $false

        foreach ($adr in 0x50..0x53) {
            # --- imza: MR0 ve MR1 AYRI AYRI, bayt bayt ---
            $mr0 = Read-SmbusByteRaw -Handle $h -Address $adr -Register 0x00
            Start-Sleep -Milliseconds 5
            $mr1 = Read-SmbusByteRaw -Handle $h -Address $adr -Register 0x01
            Start-Sleep -Milliseconds 5

            $f = { param($v) if ($null -eq $v) { '--' } else { '{0:X2}' -f $v } }

            if ($null -eq $mr0 -and $null -eq $mr1) {
                Write-Host ("  0x{0:X2}  cihaz yok / yanit yok" -f $adr) -ForegroundColor DarkGray
                continue
            }

            $imzaTamam = ($mr0 -eq 0x51 -and $mr1 -eq 0x18)
            if ($imzaTamam) { $saglam = $true }

            $durum = if ($imzaTamam) { "SPD5118 imzasi DOGRU" }
                     elseif ($mr0 -eq $mr1) { "iki register ayni -> YANKI" }
                     else { "imza tutmadi" }
            $renk = if ($imzaTamam) { 'Green' } else { 'Yellow' }

            Write-Host ("  0x{0:X2}  MR0={1} MR1={2}  (beklenen 51 18)  {3}" -f `
                        $adr, (& $f $mr0), (& $f $mr1), $durum) -ForegroundColor $renk

            # --- sicaklik ---
            $w = Read-SpdWord -Handle $h -Address $adr -Register $SPD_MR_TEMP
            if ($null -ne $w) {
                $c = ConvertFrom-Spd5Temp -Raw $w
                $makul = ($c -gt 0 -and $c -lt 110)
                $not = if ($makul) { "" } else { "  (makul degil)" }
                Write-Host ("        sicaklik ham=0x{0:X4} -> {1} C{2}" -f $w, $c, $not) `
                           -ForegroundColor $(if ($makul) { 'Green' } else { 'DarkGray' })
            }
            Start-Sleep -Milliseconds 8
        }

        Write-Host ""
        Write-Host "=== SONUC ===" -ForegroundColor Cyan
        if ($saglam) {
            Write-Host "  SMBus OKUMA YOLU SAGLAM. SPD hub'i dogru imzayi donduruyor." -ForegroundColor Green
            Write-Host "  -> Demek ki 0x18-0x1B'deki 'yanki', bizim hatamiz degil:" -ForegroundColor Green
            Write-Host "     o adreslerde gercekte okunabilir bir RGB denetleyicisi YOK." -ForegroundColor Green
        } else {
            Write-Host "  SPD imzasi hicbir adreste dogrulanmadi." -ForegroundColor Yellow
            Write-Host "  -> Okuma yolunun kendisi bozuk olabilir; RAM RGB sonucu kesin degil." -ForegroundColor Yellow
        }
        Write-Host ""
    }
}
catch { Write-Host ("HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red }
finally { Close-PawnIOModule -Handle $h }
