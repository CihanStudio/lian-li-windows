# probe-smbus-raw.ps1 - ioctl_smbus_xfer GERCEKTE ne donduruyor?
#
# YONETICI YETKISI GEREKIR.  SALT OKUMA (sadece okuma yonu denenir).
#
# NEDEN: SPD hub'i (0x50) JEDEC geregi MR0=0x51 dondurmek ZORUNDA, ama biz 0x00
# aliyoruz. Yani okuma yolunda bizim tarafimizda bir hata var. Bu arac hicbir sey
# varsaymadan CIKIS TAMPONUNUN TAMAMINI basar; dogru hucre hangisiyse gorulur.
#
# Denenen degiskenler:
#   - cikis hucre sayisi (1 / 2 / 5 / 8)
#   - protokol (BYTE=1, BYTE_DATA=2, WORD_DATA=3)
#   - in[1] yonu (1 ve 0 - kaynakta 1=oku varsayiliyor, dogrulanir)

. (Join-Path $PSScriptRoot "..\lib\Smbus.ps1")

$HEDEF_ADRES = 0x50    # DDR5 SPD hub - MR0 SABIT 0x51 olmali
$HEDEF_REG   = 0x00

function Show-Xfer {
    param(
        [IntPtr]$Handle, [string]$Etiket,
        [int]$Address, [int]$Rw, [int]$Register, [int]$Protocol, [int]$OutCount
    )
    $in = @([uint64]$Address, [uint64]$Rw, [uint64]$Register, [uint64]$Protocol)
    $res = $null
    $hr = [PawnIO.Lib]::TryExecute($Handle, "ioctl_smbus_xfer", $in, $OutCount, [ref]$res)

    if ($hr -ne 0) {
        Write-Host ("  {0,-34} hr=0x{1:X8}" -f $Etiket, $hr) -ForegroundColor DarkGray
        return
    }

    $hucreler = @()
    for ($i = 0; $i -lt $res.Count; $i++) { $hucreler += ('[{0}]=0x{1:X16}' -f $i, $res[$i]) }
    $metin = if ($hucreler.Count -eq 0) { '(cikis yok)' } else { $hucreler -join '  ' }

    # 0x51 herhangi bir hucrenin herhangi bir baytinda goruntu verdi mi?
    $bulundu = $false
    foreach ($c in $res) {
        for ($b = 0; $b -lt 8; $b++) {
            if ((([uint64]$c -shr ($b * 8)) -band 0xFF) -eq 0x51) { $bulundu = $true }
        }
    }

    $renk = if ($bulundu) { 'Green' } else { 'White' }
    $not  = if ($bulundu) { '   <-- 0x51 GORULDU' } else { '' }
    Write-Host ("  {0,-34} n={1}  {2}{3}" -f $Etiket, $res.Count, $metin, $not) -ForegroundColor $renk
}

$h = [IntPtr]::Zero
try { $h = Open-SmbusModule }
catch { Write-Host ("Modul yuklenemedi: {0}" -f $_.Exception.Message) -ForegroundColor Red; exit 2 }

try {
    Invoke-WithSmbusLock -TimeoutMs 25000 -Action {

        $kim = Get-SmbusIdentity -Handle $h
        Write-Host ""
        Write-Host ("Denetleyici: {0}  IoBase=0x{1:X4}  PciId=0x{2:X8}" -f $kim.Type, $kim.IoBase, $kim.PciId) -ForegroundColor Cyan
        Write-Host ("Hedef: adres 0x{0:X2}, register 0x{1:X2}  (SPD5118 MR0, beklenen 0x51)" -f $HEDEF_ADRES, $HEDEF_REG) -ForegroundColor Cyan

        foreach ($port in @(0, 1)) {
            try { Set-SmbusPort -Handle $h -Port $port | Out-Null } catch { continue }
            Start-Sleep -Milliseconds 20

            Write-Host ""
            Write-Host ("--- Port {0} ---" -f $port) -ForegroundColor Yellow

            foreach ($proto in @(1, 2, 3)) {
                $pad = switch ($proto) { 1 { 'BYTE     ' } 2 { 'BYTE_DATA' } 3 { 'WORD_DATA' } }
                foreach ($oc in @(1, 2, 5, 8)) {
                    Show-Xfer -Handle $h -Etiket ("rw=1 {0} out={1}" -f $pad, $oc) `
                              -Address $HEDEF_ADRES -Rw 1 -Register $HEDEF_REG -Protocol $proto -OutCount $oc
                    Start-Sleep -Milliseconds 6
                }
            }

            # NOT: in[1]=0 (yazma yonu) BILEREK DENENMIYOR. Hedef 0x50 bir DDR5 SPD
            # hub'i; modul giris tamponunu sinir kontrolunden gecirmezse oraya cop
            # yazilabilir ve modul kalici bozulur. Teshis bu riske degmez.
        }

        try { Set-SmbusPort -Handle $h -Port 0 | Out-Null } catch {}
        Write-Host ""
    }
}
catch { Write-Host ("HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red }
finally { Close-PawnIOModule -Handle $h }
