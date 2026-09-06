# ram-color.ps1 - Corsair DDR5 belleklerin rengini ayarla (GUNCEL protokol).
#
# YONETICI YETKISI GEREKIR.
#
# KULLANIM
#   .\ram-color.ps1 -Color FF0000        Kirmizi
#   .\ram-color.ps1 -Color 00FF00        Yesil
#   .\ram-color.ps1 -Color 000000        Kapat
#   .\ram-color.ps1 -Color FF0000 -Addresses 0x18,0x19,0x1A,0x1B   Elle adres
#
# NOT: Bu makinede SMBus okuma calismadigi icin cihaz dogrulamasi yapilamiyor;
# adreslere KORLEMESINE yaziliyor. "hr=0" surucunun islemi kabul ettigini
# gosterir, isigin degistigini DEGIL. Gorsel dogrulamayi sen yapacaksin.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Color,
    [int[]]$Addresses,
    [int]$LedCount = 10
)

. (Join-Path $PSScriptRoot "..\lib\CorsairDram.ps1")

# Varsayilan hedefler: 4 DIMM'in RGB denetleyicileri (RGB adresi = SPD - 0x38).
#
# NEDEN TARAMA YOK:
#   Onceden burada QUICK ile ACK taramasi vardi. OLCULDU ki bu yontem bu
#   denetleyicilerde GUVENILMEZ: 0x19 ve 0x1B kimi taramada yanit veriyor,
#   kimi taramada vermiyor - ama BLOK YAZMA her iki durumda da calisiyor
#   (2. ve 4. modulun rengi degistigi gozle dogrulandi). Tarama sonucuna
#   guvenmek modullerin yarisini sessizce disarida birakiyordu.
#   Bu yuzden adresler sabit. Bir adreste cihaz yoksa denetleyici
#   NO_SUCH_DEVICE (0x800701B1) doner ve hicbir sey olmaz; 0x18-0x1B
#   araligi SPD/PMIC bolgesinin disindadir, yazmak guvenlidir.
$VarsayilanAdresler = @(0x18, 0x19, 0x1A, 0x1B)

$h = [IntPtr]::Zero
try { $h = Open-SmbusModule }
catch {
    Write-Host ("Modul yuklenemedi: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host "(0x80070005 = yonetici yetkisi yok)" -ForegroundColor DarkGray
    exit 2
}

try {
    Invoke-WithSmbusLock -TimeoutMs 25000 -Action {
        Set-SmbusPort -Handle $h -Port 0 | Out-Null

        $hedefler = $Addresses
        if (-not $hedefler -or $hedefler.Count -eq 0) { $hedefler = $VarsayilanAdresler }

        Write-Host ""
        Write-Host ("Renk #{0}, modul basina {1} LED" -f $Color.TrimStart('#').ToUpper(), $LedCount) -ForegroundColor Cyan
        Write-Host ""

        foreach ($a in $hedefler) {
            try {
                $r = Set-CorsairDramColor -Handle $h -Address $a -Color $Color -LedCount $LedCount
                $renk = if ($r.Ok) { 'Green' } else { 'Yellow' }
                $ek = if ($null -ne $r.Hr2) { ("  hr2=0x{0:X8}" -f $r.Hr2) } else { "" }
                Write-Host ("  0x{0:X2}  paket={1} bayt  hr1=0x{2:X8}{3}" -f $a, $r.PaketBoyu, $r.Hr1, $ek) -ForegroundColor $renk
            }
            catch {
                Write-Host ("  0x{0:X2}  HATA: {1}" -f $a, $_.Exception.Message) -ForegroundColor Red
            }
            Start-Sleep -Milliseconds 20
        }

        Write-Host ""
        Write-Host "Yazma tamamlandi. RAM'lere BAK: renk degisti mi?" -ForegroundColor Cyan
        Write-Host ""
    }
}
catch { Write-Host ("HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red }
finally { Close-PawnIOModule -Handle $h }
