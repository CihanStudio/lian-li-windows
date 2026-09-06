# scan-smbus-bus.ps1 - Tum SMBus adres araligini tara (SALT OKUMA)
#
# YONETICI YETKISI GEREKIR.
#
# AMAC: "cihaz envanteri" gercek mi?
#   QUICK islemi cihaz ACK vermezse STATUS_NO_SUCH_DEVICE (0x800701B1) doner.
#   Eger 0x08-0x77 arasindaki HER adres basarili donuyorsa, ACK tespiti
#   anlamsizdir - o zaman eski envanter (0x18-0x1B, 0x48-0x4B, 0x50-0x53) da
#   uydurmadir. Sadece BELIRLI adresler donuyorsa tespit gercektir.
#
# Yazma yapilmaz: QUICH islemi okuma yonunde (rw=1) gonderilir.

. (Join-Path $PSScriptRoot "..\lib\Smbus.ps1")

function Test-SmbusAck {
    param([IntPtr]$Handle, [int]$Address)
    # QUICK, okuma yonu - veri fazi yok, sadece adres+ACK
    $in = @([uint64]$Address, [uint64]1, [uint64]0, [uint64]0)
    $res = $null
    $hr = [PawnIO.Lib]::TryExecute($Handle, "ioctl_smbus_xfer", $in, 1, [ref]$res)
    return $hr
}

$h = [IntPtr]::Zero
try { $h = Open-SmbusModule }
catch { Write-Host ("Modul yuklenemedi: {0}" -f $_.Exception.Message) -ForegroundColor Red; exit 2 }

try {
    Invoke-WithSmbusLock -TimeoutMs 40000 -Action {
        Set-SmbusPort -Handle $h -Port 0 | Out-Null

        Write-Host ""
        Write-Host "=== SMBus tam adres taramasi (port 0, QUICK) ===" -ForegroundColor Cyan
        Write-Host ""

        $ack = @()
        $yok = 0
        $hata = @{}

        foreach ($a in 0x08..0x77) {
            $hr = Test-SmbusAck -Handle $h -Address $a
            if ($hr -eq 0) { $ack += $a }
            elseif ($hr -eq 0x800701B1 -or $hr -eq -2147024463) { $yok++ }
            else {
                $k = '0x{0:X8}' -f $hr
                if (-not $hata.ContainsKey($k)) { $hata[$k] = 0 }
                $hata[$k]++
            }
            Start-Sleep -Milliseconds 4
        }

        $toplam = 0x77 - 0x08 + 1
        Write-Host ("  Taranan adres    : {0}" -f $toplam) -ForegroundColor DarkGray
        Write-Host ("  ACK veren        : {0}" -f $ack.Count) -ForegroundColor White
        Write-Host ("  Yanit yok        : {0}" -f $yok) -ForegroundColor DarkGray
        foreach ($k in $hata.Keys) { Write-Host ("  Diger hata {0} : {1}" -f $k, $hata[$k]) -ForegroundColor DarkGray }

        Write-Host ""
        if ($ack.Count -gt 0) {
            $liste = ($ack | ForEach-Object { '0x{0:X2}' -f $_ }) -join ' '
            Write-Host ("  ACK adresleri: {0}" -f $liste) -ForegroundColor Green
        }

        Write-Host ""
        Write-Host "=== YORUM ===" -ForegroundColor Cyan
        if ($ack.Count -ge ($toplam * 0.8)) {
            Write-Host "  Neredeyse HER adres ACK veriyor -> ACK tespiti ANLAMSIZ." -ForegroundColor Red
            Write-Host "  Eski cihaz envanteri gecersiz; bu otobuste gercekten kim var bilinmiyor." -ForegroundColor Red
        }
        elseif ($ack.Count -eq 0) {
            Write-Host "  Hicbir adres ACK vermiyor -> bu otobuste erisilebilir cihaz yok." -ForegroundColor Yellow
        }
        else {
            Write-Host "  Secici ACK -> tespit GERCEK. Yukaridaki adresler gercek cihazlar." -ForegroundColor Green
        }
        Write-Host ""
    }
}
catch { Write-Host ("HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red }
finally { Close-PawnIOModule -Handle $h }
