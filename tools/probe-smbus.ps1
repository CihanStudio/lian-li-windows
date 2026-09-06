# probe-smbus.ps1 - SMBus denetleyicisini tanimlar ve cihaz adreslerini tarar.
#
# GUVENLIK: Bu script SMBus'a YALNIZCA OKUMA yapar (BYTE_DATA read).
# Hicbir adrese yazmaz. DDR5 SPD hub'larina yazmak modulu kalici bozabilecegi
# icin yazma islemleri bilincli olarak disarida birakilmistir.
#
# Tum SMBus erisimleri Access_SMBUS.HTP.Method mutex'i altinda yapilir.

param(
    [int[]]$Ports = @(0),
    [switch]$FullRange
)

. (Join-Path $PSScriptRoot "..\lib\PawnIO.ps1")

# SMBus protokol numaralari (Linux i2c_smbus standardi)
$PROTO_QUICK     = 0
$PROTO_BYTE      = 1
$PROTO_BYTE_DATA = 2

Write-Host "=== PawnIO ===" -ForegroundColor Cyan
try {
    Write-Host ("  Surum : {0}" -f (Get-PawnIOVersion)) -ForegroundColor Green
} catch {
    Write-Host ("  HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

$h = [IntPtr]::Zero
try {
    Write-Host "  SmbusPIIX4.bin yukleniyor..." -ForegroundColor DarkGray
    $h = Open-PawnIOModule -ModuleName "SmbusPIIX4.bin"
    Write-Host "  Modul yuklendi." -ForegroundColor Green
}
catch {
    Write-Host ("  MODUL YUKLENEMEDI: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host "  Olasi sebep: PawnIO surucusune erisim yonetici yetkisi istiyor olabilir." -ForegroundColor Yellow
    Write-Host "  Bu scripti yonetici PowerShell'de tekrar dene." -ForegroundColor Yellow
    exit 2
}

try {
    # --- Denetleyici kimligi ---
    Write-Host ""
    Write-Host "=== SMBUS DENETLEYICISI ===" -ForegroundColor Cyan
    try {
        $id = [PawnIO.Lib]::Execute($h, "ioctl_identity", @(), 3)
        if ($id.Count -ge 3) {
            Write-Host ("  Tur          : 0x{0:X}" -f $id[0]) -ForegroundColor White
            Write-Host ("  G/C taban    : 0x{0:X4}" -f $id[1]) -ForegroundColor White
            Write-Host ("  PCI kimlik   : 0x{0:X}" -f $id[2]) -ForegroundColor White
        } else {
            Write-Host ("  ioctl_identity {0} hucre dondu: {1}" -f $id.Count, ($id -join ', ')) -ForegroundColor Yellow
        }
    } catch {
        Write-Host ("  ioctl_identity hatasi: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }

    # --- Adres taramasi (SALT OKUMA) ---
    $adresler = if ($FullRange) { 0x08..0x77 } else { @(0x18..0x1F) + @(0x30..0x37) + @(0x50..0x57) + @(0x58..0x5F) }

    Write-Host ""
    Write-Host "=== ADRES TARAMASI (salt okuma) ===" -ForegroundColor Cyan
    Write-Host ("  Taranan adres sayisi: {0}" -f $adresler.Count) -ForegroundColor DarkGray

    Invoke-WithSmbusLock -TimeoutMs 8000 -Action {
        foreach ($port in $Ports) {
            # Port sec
            try {
                $prev = [PawnIO.Lib]::Execute($h, "ioctl_piix4_port_sel", @([uint64]$port), 1)
                Write-Host ("`n  --- Port {0} (onceki: {1}) ---" -f $port, $(if ($prev.Count -gt 0) { $prev[0] } else { '?' })) -ForegroundColor Cyan
            } catch {
                Write-Host ("`n  --- Port {0}: secilemedi ({1}) ---" -f $port, $_.Exception.Message) -ForegroundColor Yellow
                continue
            }

            $bulunan = @()
            foreach ($a in $adresler) {
                $in = @([uint64]$a, [uint64]1, [uint64]0, [uint64]$PROTO_BYTE_DATA)   # oku, komut 0x00
                $res = $null
                $hr = [PawnIO.Lib]::TryExecute($h, "ioctl_smbus_xfer", $in, 5, [ref]$res)
                if ($hr -eq 0) {
                    $deger = if ($res.Count -gt 0) { $res[0] } else { 0 }
                    $bulunan += [PSCustomObject]@{
                        Adres = ('0x{0:X2}' -f $a)
                        Veri  = ('0x{0:X2}' -f ($deger -band 0xFF))
                    }
                }
                Start-Sleep -Milliseconds 3
            }

            if ($bulunan.Count -eq 0) {
                Write-Host "    cihaz bulunamadi" -ForegroundColor DarkGray
            } else {
                Write-Host ("    {0} cihaz:" -f $bulunan.Count) -ForegroundColor Green
                $bulunan | Format-Table Adres, Veri -AutoSize | Out-String | Write-Host
            }
        }
    }
}
catch {
    Write-Host ("HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red
}
finally {
    Close-PawnIOModule -Handle $h
    Write-Host "PawnIO handle kapatildi." -ForegroundColor DarkGray
}
