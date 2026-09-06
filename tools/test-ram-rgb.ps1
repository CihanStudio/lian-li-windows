# test-ram-rgb.ps1 - Corsair Vengeance DDR5 RGB yazma denemesi.
#
# Hedef adresler 0x18-0x1B (DIMM basina bir adet, uretici-ozel cihaz).
# PMIC (0x48-0x4B) ve SPD (0x50-0x53) adreslerine yazma kutuphane
# seviyesinde ENGELLI - bu script onlara dokunamaz.
#
# Protokol dogrulanmis degil; bu yuzden tek bir yaklasim denenir ve
# sonuc gozle kontrol edilir.

param(
    [string]$Color = 'FF0000',
    [int]$LedCount = 10,
    [ValidateSet('Block','Bytes')] [string]$Method = 'Block',
    [int[]]$Addresses = @(0x18, 0x19, 0x1A, 0x1B)
)

. (Join-Path $PSScriptRoot "..\lib\Smbus.ps1")

$REG_COLOR_BLOCK_1 = 0x31
$REG_COLOR_BLOCK_2 = 0x32

$h = $Color.TrimStart('#')
if ($h.Length -ne 6) { Write-Host "Renk 6 haneli hex olmali." -ForegroundColor Red; exit 1 }
$R = [byte][Convert]::ToInt32($h.Substring(0,2),16)
$G = [byte][Convert]::ToInt32($h.Substring(2,2),16)
$B = [byte][Convert]::ToInt32($h.Substring(4,2),16)

# LED basina R,G,B
$renkVerisi = New-Object 'byte[]' ($LedCount * 3)
for ($i = 0; $i -lt $LedCount; $i++) {
    $renkVerisi[$i*3]     = $R
    $renkVerisi[$i*3 + 1] = $G
    $renkVerisi[$i*3 + 2] = $B
}

$hnd = [IntPtr]::Zero
try { $hnd = Open-SmbusModule }
catch { Write-Host ("Modul yuklenemedi: {0}" -f $_.Exception.Message) -ForegroundColor Red; exit 2 }

try {
    Write-Host ""
    Write-Host ("Renk #{0}{1}{2}, {3} LED, yontem: {4}" -f $R.ToString('X2'), $G.ToString('X2'), $B.ToString('X2'), $LedCount, $Method) -ForegroundColor Cyan
    Write-Host ""

    Invoke-WithSmbusLock -TimeoutMs 10000 -Action {
        Set-SmbusPort -Handle $hnd -Port 0 | Out-Null

        foreach ($adr in $Addresses) {
            Write-Host ("  0x{0:X2} : " -f $adr) -NoNewline -ForegroundColor White

            try {
                if ($Method -eq 'Block') {
                    $blok1 = if ($renkVerisi.Length -gt 32) { $renkVerisi[0..31] } else { $renkVerisi }
                    $hr1 = Write-SmbusBlock -Handle $hnd -Address $adr -Register $REG_COLOR_BLOCK_1 -Data $blok1
                    $mesaj = ("blok1({0}b) hr=0x{1:X8}" -f $blok1.Length, $hr1)

                    if ($renkVerisi.Length -gt 32) {
                        $blok2 = $renkVerisi[32..($renkVerisi.Length - 1)]
                        $hr2 = Write-SmbusBlock -Handle $hnd -Address $adr -Register $REG_COLOR_BLOCK_2 -Data $blok2
                        $mesaj += ("  blok2({0}b) hr=0x{1:X8}" -f $blok2.Length, $hr2)
                    }
                    Write-Host $mesaj -ForegroundColor $(if ($hr1 -eq 0) { 'Green' } else { 'Yellow' })
                }
                else {
                    # Bayt bayt: her LED icin ardisik register'lara R,G,B
                    $basari = 0; $hata = 0
                    for ($i = 0; $i -lt $renkVerisi.Length; $i++) {
                        $hr = Write-SmbusByte -Handle $hnd -Address $adr -Register ($REG_COLOR_BLOCK_1 + $i) -Value $renkVerisi[$i]
                        if ($hr -eq 0) { $basari++ } else { $hata++ }
                        Start-Sleep -Milliseconds 3
                    }
                    Write-Host ("{0} basarili / {1} hatali bayt yazimi" -f $basari, $hata) -ForegroundColor $(if ($hata -eq 0) { 'Green' } else { 'Yellow' })
                }
            }
            catch {
                Write-Host ("hata: {0}" -f $_.Exception.Message) -ForegroundColor Red
            }
            Start-Sleep -Milliseconds 40
        }
    }

    Write-Host ""
    Write-Host "Yazma tamam. RAM'lere bak." -ForegroundColor Yellow
}
catch { Write-Host ("HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red }
finally { Close-PawnIOModule -Handle $hnd }
