# probe-ram.ps1 - Corsair Vengeance DDR5 RGB denetleyicilerini SORGULAR.
#
# YALNIZCA OKUMA. Hicbir yazma yapmaz.
# SPD (0x50-0x53) adreslerine zaten kutuphane seviyesinde yazma engeli var.

. (Join-Path $PSScriptRoot "..\lib\Smbus.ps1")

# Corsair DRAM register haritasi
$REG_STATUS         = 0x30
$REG_GET_DEVICE_INFO = 0x61
$REG_GET_CONFIG     = 0x63
$REG_BUSY_STATUS    = 0x41

$RGB_ADRESLERI = @(0x18, 0x19, 0x1A, 0x1B)

Write-Host "=== PawnIO / SMBus ===" -ForegroundColor Cyan
try { Write-Host ("  PawnIO surumu : {0}" -f (Get-PawnIOVersion)) -ForegroundColor Green }
catch { Write-Host ("  HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red; exit 1 }

$h = [IntPtr]::Zero
try {
    $h = Open-SmbusModule
    $id = Get-SmbusIdentity -Handle $h
    Write-Host ("  Denetleyici   : {0}  taban 0x{1:X4}" -f $id.Type, $id.IoBase) -ForegroundColor Green
}
catch {
    Write-Host ("  MODUL YUKLENEMEDI: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host "  Yonetici olarak calistirilmasi gerekiyor." -ForegroundColor Yellow
    exit 2
}

try {
    Invoke-WithSmbusLock -TimeoutMs 8000 -Action {
        Set-SmbusPort -Handle $h -Port 0 | Out-Null

        foreach ($adr in $RGB_ADRESLERI) {
            Write-Host ""
            Write-Host ("=== ADRES 0x{0:X2} ===" -f $adr) -ForegroundColor Cyan

            # Basit bayt okumalari
            foreach ($reg in @(@{R=$REG_STATUS;      N='STATUS      (0x30)'},
                               @{R=$REG_BUSY_STATUS; N='BUSY_STATUS (0x41)'})) {
                $v = Read-SmbusByte -Handle $h -Address $adr -Register $reg.R
                if ($null -ne $v) { Write-Host ("  {0} = 0x{1:X2}" -f $reg.N, $v) -ForegroundColor White }
                else              { Write-Host ("  {0} = okunamadi" -f $reg.N) -ForegroundColor DarkGray }
                Start-Sleep -Milliseconds 8
            }

            # Blok okumalar
            foreach ($reg in @(@{R=$REG_GET_DEVICE_INFO; N='DEVICE_INFO (0x61)'},
                               @{R=$REG_GET_CONFIG;      N='CONFIG      (0x63)'})) {
                $b = Read-SmbusBlock -Handle $h -Address $adr -Register $reg.R
                if ($null -ne $b -and $b.Count -gt 0) {
                    $hex = ($b | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                    Write-Host ("  {0} = {1} bayt: {2}" -f $reg.N, $b.Count, $hex) -ForegroundColor White
                } else {
                    Write-Host ("  {0} = okunamadi/bos" -f $reg.N) -ForegroundColor DarkGray
                }
                Start-Sleep -Milliseconds 15
            }
        }
    }
}
catch { Write-Host ("HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red }
finally {
    Close-PawnIOModule -Handle $h
    Write-Host ""
    Write-Host "PawnIO handle kapatildi." -ForegroundColor DarkGray
}
