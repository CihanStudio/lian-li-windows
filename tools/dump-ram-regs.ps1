# dump-ram-regs.ps1 - 0x18-0x1B adreslerinin register haritasini cikarir.
#
# YALNIZCA OKUMA. Amac: bu adreslerde gercek bir cihaz mi var, yoksa her
# register'da ayni sabit degeri mi donduruyorlar? Gercek bir denetleyicide
# register'lar arasinda FARKLI degerler gorulmelidir.

param([int[]]$Addresses = @(0x18, 0x19), [int]$MaxReg = 0x7F)

. (Join-Path $PSScriptRoot "..\lib\Smbus.ps1")

$h = [IntPtr]::Zero
try { $h = Open-SmbusModule }
catch { Write-Host ("Modul yuklenemedi: {0}" -f $_.Exception.Message) -ForegroundColor Red; exit 2 }

try {
    Invoke-WithSmbusLock -TimeoutMs 15000 -Action {
        Set-SmbusPort -Handle $h -Port 0 | Out-Null

        foreach ($adr in $Addresses) {
            Write-Host ""
            Write-Host ("=== ADRES 0x{0:X2} - register dokumu ===" -f $adr) -ForegroundColor Cyan

            $degerler = @{}
            $okunan = 0
            for ($reg = 0; $reg -le $MaxReg; $reg++) {
                $v = Read-SmbusByte -Handle $h -Address $adr -Register $reg
                if ($null -ne $v) { $degerler[$reg] = $v; $okunan++ }
                Start-Sleep -Milliseconds 4
            }

            Write-Host ("  Okunabilen register sayisi: {0}/{1}" -f $okunan, ($MaxReg + 1)) -ForegroundColor DarkGray

            if ($okunan -eq 0) { Write-Host "  hicbir register okunamadi" -ForegroundColor Yellow; continue }

            # 16'sarli grid
            for ($satir = 0; $satir -le ($MaxReg -shr 4); $satir++) {
                $line = ("  {0:X2}: " -f ($satir * 16))
                for ($s = 0; $s -lt 16; $s++) {
                    $reg = $satir * 16 + $s
                    if ($reg -gt $MaxReg) { break }
                    if ($degerler.ContainsKey($reg)) { $line += ('{0:X2} ' -f $degerler[$reg]) }
                    else { $line += '-- ' }
                }
                Write-Host $line -ForegroundColor White
            }

            # Benzersiz deger analizi - kritik gosterge
            $benzersiz = $degerler.Values | Sort-Object -Unique
            Write-Host ("  Benzersiz deger sayisi: {0}  ->  {1}" -f $benzersiz.Count,
                        (($benzersiz | ForEach-Object { '0x{0:X2}' -f $_ }) -join ' ')) -ForegroundColor Yellow
            if ($benzersiz.Count -le 1) {
                Write-Host "  UYARI: tum register'lar ayni degeri donduruyor - burada gercek bir denetleyici olmayabilir." -ForegroundColor Red
            } else {
                Write-Host "  Register'lar farkli degerler donduruyor - gercek bir cihaz var." -ForegroundColor Green
            }
        }
    }
}
catch { Write-Host ("HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red }
finally { Close-PawnIOModule -Handle $h }
