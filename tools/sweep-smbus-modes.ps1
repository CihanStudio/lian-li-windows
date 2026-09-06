# sweep-smbus-modes.ps1 - Okuma kanalini acan bir kombinasyon var mi?
#
# Port (0-4) x protokol (BYTE / BYTE_DATA / WORD_DATA) taramasi.
# Basari olcutu: 0xA0-0xA3 register'larinin FARKLI degerler dondurmesi
# (hepsi ayni ise yine yanki demektir) veya dogrudan 0xBA gorulmesi.
#
# SALT OKUMA.

param([int]$Address = 0x18)

. (Join-Path $PSScriptRoot "..\lib\Smbus.ps1")

$protokoller = @(
    @{ P = 1; Ad = 'BYTE     ' },
    @{ P = 2; Ad = 'BYTE_DATA' },
    @{ P = 3; Ad = 'WORD_DATA' }
)

function Read-Generic {
    param([IntPtr]$H, [int]$Adr, [int]$Reg, [int]$Proto)
    $in = @([uint64]$Adr, [uint64]1, [uint64]$Reg, [uint64]$Proto)
    $res = $null
    $hr = [PawnIO.Lib]::TryExecute($H, "ioctl_smbus_xfer", $in, 5, [ref]$res)
    if ($hr -ne 0 -or $res.Count -lt 1) { return $null }
    return [uint64]$res[0]
}

$h = [IntPtr]::Zero
try { $h = Open-SmbusModule }
catch { Write-Host ("Modul yuklenemedi: {0}" -f $_.Exception.Message) -ForegroundColor Red; exit 2 }

try {
    Invoke-WithSmbusLock -TimeoutMs 25000 -Action {
        Write-Host ""
        Write-Host ("Adres 0x{0:X2} - port x protokol taramasi" -f $Address) -ForegroundColor Cyan
        Write-Host ""

        foreach ($port in 0..4) {
            try { Set-SmbusPort -Handle $h -Port $port | Out-Null }
            catch { Write-Host ("  Port {0}: secilemedi" -f $port) -ForegroundColor DarkGray; continue }
            Start-Sleep -Milliseconds 20

            foreach ($pr in $protokoller) {
                $degerler = @()
                foreach ($reg in @(0xA0, 0xA1, 0xA2, 0xA3)) {
                    $v = Read-Generic -H $h -Adr $Address -Reg $reg -Proto $pr.P
                    $degerler += $v
                    Start-Sleep -Milliseconds 6
                }

                $gecerli = @($degerler | Where-Object { $null -ne $_ })
                if ($gecerli.Count -eq 0) {
                    Write-Host ("  Port {0}  {1}  -> hepsi basarisiz" -f $port, $pr.Ad) -ForegroundColor DarkGray
                    continue
                }

                $hex = ($degerler | ForEach-Object { if ($null -eq $_) { '--' } else { '{0:X2}' -f ($_ -band 0xFF) } }) -join ' '
                $benzersiz = @($gecerli | ForEach-Object { $_ -band 0xFF } | Sort-Object -Unique)
                $baIcerir = ($benzersiz -contains 0xBA)

                $renk = if ($baIcerir) { 'Green' } elseif ($benzersiz.Count -gt 1) { 'Yellow' } else { 'DarkGray' }
                $not = if ($baIcerir) { '  <-- 0xBA GORULDU' }
                       elseif ($benzersiz.Count -gt 1) { '  <-- degerler farkli, gercek okuma olabilir' }
                       else { '  (hepsi ayni - yanki)' }

                Write-Host ("  Port {0}  {1}  -> {2}{3}" -f $port, $pr.Ad, $hex, $not) -ForegroundColor $renk
            }
        }
        # Port 0'a geri don
        try { Set-SmbusPort -Handle $h -Port 0 | Out-Null } catch {}
    }
}
catch { Write-Host ("HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red }
finally { Close-PawnIOModule -Handle $h }
