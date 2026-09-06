# scan-smbus-ports.ps1 - TUM SMBus portlarinda tam adres taramasi (SALT OKUMA)
#
# YONETICI YETKISI GEREKIR.
#
# NEDEN: 4 DIMM takili ama port 0'da sadece 2'si gorunuyor
#   (SPD 0x50/0x52, RGB 0x18/0x1A). Renk yazmasi bu ikisinde CALISTI.
#   Kalan iki modul (RGB 0x19/0x1B beklenirdi) port 0'da ACK vermiyor.
#   AMD FCH SMBus'inda coklayici (port secici) var; diger modullerin baska
#   portta olup olmadigini bu tarama gosterir.
#
# Yazma yapilmaz: sadece QUICK islemi, okuma yonunde.

. (Join-Path $PSScriptRoot "..\lib\Smbus.ps1")

function Test-SmbusAck {
    param([IntPtr]$Handle, [int]$Address)
    $in = @([uint64]$Address, [uint64]1, [uint64]0, [uint64]0)   # QUICK, oku
    $res = $null
    return [PawnIO.Lib]::TryExecute($Handle, "ioctl_smbus_xfer", $in, 1, [ref]$res)
}

$h = [IntPtr]::Zero
try { $h = Open-SmbusModule }
catch {
    Write-Host ("Modul yuklenemedi: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host "(0x80070005 = yonetici yetkisi yok)" -ForegroundColor DarkGray
    exit 2
}

try {
    Invoke-WithSmbusLock -TimeoutMs 120000 -Action {

        Write-Host ""
        Write-Host "=== SMBus port x adres taramasi ===" -ForegroundColor Cyan
        Write-Host "  (0x08-0x77, QUICK islemi, salt okuma)" -ForegroundColor DarkGray
        Write-Host ""

        $tumBulgular = @{}

        foreach ($port in 0..3) {
            try {
                $r = Set-SmbusPort -Handle $h -Port $port
            }
            catch {
                Write-Host ("  Port {0}: secilemedi ({1})" -f $port, $_.Exception.Message) -ForegroundColor DarkGray
                continue
            }
            Start-Sleep -Milliseconds 30

            $ack = @()
            foreach ($a in 0x08..0x77) {
                if ((Test-SmbusAck -Handle $h -Address $a) -eq 0) { $ack += $a }
                Start-Sleep -Milliseconds 3
            }

            $tumBulgular[$port] = $ack

            if ($ack.Count -eq 0) {
                Write-Host ("  Port {0} : cihaz yok" -f $port) -ForegroundColor DarkGray
            }
            elseif ($ack.Count -gt 90) {
                # Neredeyse her adres yanit veriyorsa tespit anlamsizdir
                Write-Host ("  Port {0} : {1} adres ACK verdi - GUVENILMEZ (hepsi yanit veriyor)" -f $port, $ack.Count) -ForegroundColor Red
            }
            else {
                $liste = ($ack | ForEach-Object { '0x{0:X2}' -f $_ }) -join ' '
                Write-Host ("  Port {0} : {1}" -f $port, $liste) -ForegroundColor Green
            }
        }

        # Port 0'a geri don - varsayilan durum
        try { Set-SmbusPort -Handle $h -Port 0 | Out-Null } catch {}

        # ---- Yorum ----
        Write-Host ""
        Write-Host "=== YORUM ===" -ForegroundColor Cyan

        $p0 = @($tumBulgular[0])
        $digerPortlar = @()
        foreach ($k in $tumBulgular.Keys) {
            if ($k -ne 0 -and @($tumBulgular[$k]).Count -gt 0) { $digerPortlar += $k }
        }

        # Aranan: 0x19 / 0x1B (eksik iki modulun RGB adresleri)
        $eksikBulundu = @()
        foreach ($k in $tumBulgular.Keys) {
            foreach ($a in @($tumBulgular[$k])) {
                if ($a -eq 0x19 -or $a -eq 0x1B) { $eksikBulundu += ("port {0} / 0x{1:X2}" -f $k, $a) }
            }
        }

        if ($eksikBulundu.Count -gt 0) {
            Write-Host ("  Eksik moduller BULUNDU: {0}" -f ($eksikBulundu -join ', ')) -ForegroundColor Green
            Write-Host "  -> ram-color.ps1 o portta calistirilirsa 4 modul de boyanabilir." -ForegroundColor Green
        }
        elseif ($digerPortlar.Count -eq 0) {
            Write-Host "  Baska portta hicbir cihaz yok." -ForegroundColor Yellow
            Write-Host "  -> Kalan 2 modulun RGB denetleyicisi SMBus'tan erisilemiyor." -ForegroundColor Yellow
            Write-Host "     Muhtemel sebep: ayni kanaldaki ikinci DIMM'in hub'i BIOS tarafindan" -ForegroundColor DarkGray
            Write-Host "     gizlenmis ya da farkli bir yan bant uzerinde." -ForegroundColor DarkGray
        }
        else {
            Write-Host ("  Baska portlarda cihaz var ({0}) ama 0x19/0x1B yok." -f ($digerPortlar -join ', ')) -ForegroundColor Yellow
        }
        Write-Host ""
    }
}
catch { Write-Host ("HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red }
finally { Close-PawnIOModule -Handle $h }
