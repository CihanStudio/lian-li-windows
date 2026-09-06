# scan-smbus-aux.ps1 - TUM SMBus portlarinda (0-4) tam adres taramasi
#
# YONETICI YETKISI GEREKIR.
#
# NEDEN BU IKINCI TARAMA VAR:
#   Onceki tarama (scan-smbus-ports.ps1) port 0-3 arasini taradi. PawnIO
#   SmbusPIIX4 modulunun KAYNAGINDAN dogrulandi ki gecerli port araligi
#   0-4'tur, yani BES port var ve PORT 4 HIC TARANMADI.
#
#   Modul kaynagindaki eslesme (piix4_port_sel):
#     addresses[] = [0x0B00, 0x0B20]
#     port_to_reg[] = [0b00, 0b00, 0b01, 0b10, 0b11]
#     Port 0 -> birincil taban 0x0B00, coklayici 0
#     Port 1 -> IKINCIL TABAN 0x0B20 (ASF denetleyicisi) - coklayici degismez
#     Port 2 -> birincil taban, coklayici 1
#     Port 3 -> birincil taban, coklayici 2
#     Port 4 -> birincil taban, coklayici 3   <-- DENENMEDI
#
#   Yani "denenmemis ikinci taban 0x0B20" aslinda port 1 olarak ZATEN
#   taranmisti (orada 0x15 vardi). Gercek bosluk port 4.
#
# IKINCI YENILIK: YAZMA YONUNDE QUICK taramasi.
#   Onceki tarama sadece OKUMA yonunde QUICK yapti. SMBus'ta bazi cihazlar
#   okuma yonunde adres baytina ACK vermez ama yazma yonunde verir; Linux'un
#   i2cdetect araci da bu yuzden cogu adres icin yazma yonunu kullanir.
#
# GUVENLIK:
#   - Okuma yonunde tarama tum araligi kapsar (tamamen zararsiz).
#   - Yazma yonunde QUICK sadece adres baytini surer, VERI BAYTI YOKTUR,
#     dolayisiyla hicbir register degistiremez. Yine de 0x48-0x57 (DDR5
#     PMIC + SPD hub) araligi bilincli olarak ATLANIR: o bolgede risk
#     almanin karsiligi yok, aradigimiz RGB denetleyicileri 0x18-0x1F ve
#     0x58-0x5F araliklarinda.
#   - Hicbir yerde veri yazilmaz.

. (Join-Path $PSScriptRoot "..\lib\Smbus.ps1")

# Yazma yonunde denenmeyecek adresler - ustteki GUVENLIK notuna bak
$YazmaTaramasiYasak = @()
$YazmaTaramasiYasak += 0x48..0x57

function Test-SmbusAck {
    param([IntPtr]$Handle, [int]$Address, [int]$Rw)
    $in = @([uint64]$Address, [uint64]$Rw, [uint64]0, [uint64]0)   # QUICK
    $res = $null
    return [PawnIO.Lib]::TryExecute($Handle, "ioctl_smbus_xfer", $in, 1, [ref]$res)
}

function Format-AdresListesi {
    param([int[]]$Adresler)
    if (@($Adresler).Count -eq 0) { return "-" }
    return (($Adresler | ForEach-Object { '0x{0:X2}' -f $_ }) -join ' ')
}

$h = [IntPtr]::Zero
try { $h = Open-SmbusModule }
catch {
    Write-Host ("Modul yuklenemedi: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host "(0x80070005 = yonetici yetkisi yok)" -ForegroundColor DarkGray
    exit 2
}

try {
    Invoke-WithSmbusLock -TimeoutMs 300000 -Action {

        Write-Host ""
        Write-Host "=== SMBus tam tarama: port 0-4, iki yon ===" -ForegroundColor Cyan
        Write-Host ""

        $okuma = @{}
        $yazma = @{}
        $taban  = @{}

        foreach ($port in 0..4) {
            try { $null = Set-SmbusPort -Handle $h -Port $port }
            catch {
                Write-Host ("  Port {0}: secilemedi ({1})" -f $port, $_.Exception.Message) -ForegroundColor DarkGray
                continue
            }
            Start-Sleep -Milliseconds 40

            # Hangi taban aktif? 0x0B00 = birincil, 0x0B20 = ikincil (ASF)
            $b = 0
            try { $b = [int](Get-SmbusIdentity -Handle $h).IoBase } catch {}
            $taban[$port] = $b

            $ackOku = @()
            $ackYaz = @()
            foreach ($a in 0x08..0x77) {
                if ((Test-SmbusAck -Handle $h -Address $a -Rw 1) -eq 0) { $ackOku += $a }
                Start-Sleep -Milliseconds 2

                if ($YazmaTaramasiYasak -notcontains $a) {
                    if ((Test-SmbusAck -Handle $h -Address $a -Rw 0) -eq 0) { $ackYaz += $a }
                    Start-Sleep -Milliseconds 2
                }
            }

            $okuma[$port] = $ackOku
            $yazma[$port] = $ackYaz

            $renk = if (@($ackOku).Count -gt 0 -or @($ackYaz).Count -gt 0) { 'Green' } else { 'DarkGray' }
            Write-Host ("  Port {0}  (taban 0x{1:X4})" -f $port, $b) -ForegroundColor $renk
            Write-Host ("      okuma yonu : {0}" -f (Format-AdresListesi $ackOku))
            Write-Host ("      yazma yonu : {0}" -f (Format-AdresListesi $ackYaz))
        }

        # Varsayilan duruma don
        try { $null = Set-SmbusPort -Handle $h -Port 0 } catch {}

        # ---- Yorum ----
        Write-Host ""
        Write-Host "=== YORUM ===" -ForegroundColor Cyan

        # Aranan: eksik iki modulun RGB adresleri. Corsair DDR5 denetleyicileri
        # OpenRGB'de 0x18-0x1F ve 0x58-0x5F araliklarinda taraniyor.
        $aranan = @(0x19, 0x1B, 0x51, 0x53) + (0x58..0x5F)
        $bulunan = @()

        foreach ($port in 0..4) {
            foreach ($yon in @('okuma', 'yazma')) {
                $liste = if ($yon -eq 'okuma') { @($okuma[$port]) } else { @($yazma[$port]) }
                foreach ($a in $liste) {
                    if ($aranan -contains $a) {
                        $bulunan += ("port {0} / 0x{1:X2} ({2} yonu)" -f $port, $a, $yon)
                    }
                }
            }
        }

        if ($bulunan.Count -gt 0) {
            Write-Host "  YENI ADRES BULUNDU:" -ForegroundColor Green
            foreach ($x in $bulunan) { Write-Host ("    {0}" -f $x) -ForegroundColor Green }
        }
        else {
            Write-Host "  Bes portun hicbirinde eksik modullere ait adres yok." -ForegroundColor Yellow
            Write-Host "  -> Kalan 2 DIMM'in RGB denetleyicisi SMBus'a hic baglanmiyor." -ForegroundColor Yellow
        }
        Write-Host ""
    }
}
catch { Write-Host ("HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red }
finally { Close-PawnIOModule -Handle $h }
