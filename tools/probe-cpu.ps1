# probe-cpu.ps1 - CPU sicaklik/guc okumasi calisiyor mu?
#
# YONETICI YETKISI GEREKIR.  SALT OKUMA.
#
# Ham degerleri de basar; boylece formul dogru mu, adres dogru mu gorulebilir.

. (Join-Path $PSScriptRoot "..\lib\AmdCpu.ps1")

Write-Host ""
Write-Host "=== CPU (PawnIO / AMDFamily17) ===" -ForegroundColor Cyan

try { Write-Host ("  PawnIO surumu : {0}" -f (Get-PawnIOVersion)) -ForegroundColor DarkGray }
catch { Write-Host ("  PawnIO surumu okunamadi: {0}" -f $_.Exception.Message) -ForegroundColor Red; exit 2 }

$cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1)
Write-Host ("  Islemci       : {0}" -f $cpu.Name.Trim()) -ForegroundColor DarkGray
Write-Host ("  Kimlik        : {0}" -f $cpu.Description) -ForegroundColor DarkGray

$h = [IntPtr]::Zero
try { $h = Open-AmdCpuModule }
catch {
    Write-Host ("  MODUL YUKLENEMEDI: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host "  (0x80070005 = yonetici degil.  Baska kod = bu islemci ailesi desteklenmiyor.)" -ForegroundColor DarkGray
    exit 3
}

try {
    # ---- Tctl ----
    Write-Host ""
    Write-Host "  -- Sicaklik --" -ForegroundColor White
    $ham = Get-AmdSmn -Handle $h -Address 0x00059800
    if ($null -eq $ham) {
        Write-Host "  SMN 0x00059800 okunamadi." -ForegroundColor Red
    } else {
        $adim = [int](($ham -shr 21) -band 0x7FF)
        $ofsetli = (($ham -band 0x80000) -ne 0)
        Write-Host ("  SMN 0x59800 ham : 0x{0:X8}   (adim={1}, ofset bayragi={2})" -f $ham, $adim, $ofsetli) -ForegroundColor DarkGray
        Write-Host ("  Tctl            : {0} C" -f (ConvertFrom-AmdTctlRaw -Raw $ham)) -ForegroundColor Green
    }

    # ---- CCD aday taramasi (ham) ----
    Write-Host ""
    Write-Host "  -- CCD aday adresleri (ham tarama) --" -ForegroundColor White
    foreach ($aday in @(0x00059B08, 0x00059954, 0x00059800)) {
        for ($i = 0; $i -lt 2; $i++) {
            $adr = [uint32]($aday + ($i * 4))
            $v = Get-AmdSmn -Handle $h -Address $adr
            if ($null -eq $v) {
                Write-Host ("    0x{0:X5}  okunamadi" -f $adr) -ForegroundColor DarkGray
                continue
            }
            $c = ConvertFrom-AmdCcdRaw -Raw $v
            $yorum = if ($null -eq $c) { "makul degil" } else { "{0} C  <-- GECERLI" -f $c }
            $renk  = if ($null -eq $c) { 'DarkGray' } else { 'Green' }
            Write-Host ("    0x{0:X5}  ham=0x{1:X8}  {2}" -f $adr, $v, $yorum) -ForegroundColor $renk
        }
    }

    # ---- Kutuphane fonksiyonunun toplu sonucu ----
    Write-Host ""
    Write-Host "  -- Get-AmdCpuTemperature --" -ForegroundColor White
    $t = Get-AmdCpuTemperature -Handle $h
    if ($t.Ok) {
        Write-Host ("    Tctl   : {0} C" -f $t.Tctl) -ForegroundColor Green
        if ($t.Ccd.Count -gt 0) {
            Write-Host ("    Kaynak : {0}" -f $t.Source) -ForegroundColor DarkGray
            foreach ($c in $t.Ccd) { Write-Host ("    CCD{0}   : {1} C" -f $c.Index, $c.TempC) -ForegroundColor Green }
        } else {
            Write-Host "    CCD    : bulunamadi (Tctl kullanilacak)" -ForegroundColor Yellow
        }
    } else {
        Write-Host ("    HATA: {0}" -f $t.Hata) -ForegroundColor Red
    }

    # ---- Guc ----
    Write-Host ""
    Write-Host "  -- Guc (RAPL) --" -ForegroundColor White
    $birim = Get-AmdRaplUnits -Handle $h
    if ($null -eq $birim) {
        Write-Host "    RAPL birim MSR'i okunamadi (0xC0010299)." -ForegroundColor Yellow
    } else {
        Write-Host ("    Enerji birimi : {0} J  (ham 0x{1:X})" -f $birim.EnergyUnitJ, $birim.Raw) -ForegroundColor DarkGray
        $w = Get-AmdCpuPower -Handle $h -SampleMs 500
        if ($null -eq $w) { Write-Host "    Paket gucu    : okunamadi" -ForegroundColor Yellow }
        else             { Write-Host ("    Paket gucu    : {0} W" -f $w) -ForegroundColor Green }
    }

    # ---- SVI telemetri taramasi (cekirdek/SoC voltaji) ----
    # Adres aileye gore kayiyor; 0x5A000 civari taranip MAKUL voltaj veren
    # ofset aranir. VID -> Volt donusumu: 1.55 - VID * 0.00625
    Write-Host ""
    Write-Host "  -- SVI telemetri taramasi (voltaj adayi) --" -ForegroundColor White
    $bulundu = $false
    for ($ofs = 0; $ofs -le 0x20; $ofs += 4) {
        $adr = [uint32](0x0005A000 + $ofs)
        $v = Get-AmdSmn -Handle $h -Address $adr
        if ($null -eq $v -or $v -eq 0) { continue }

        $vid = [int](($v -shr 16) -band 0xFF)
        $volt = 1.55 - ($vid * 0.00625)
        $makul = ($volt -gt 0.40 -and $volt -lt 1.60 -and $vid -ne 0)
        if ($makul) {
            $bulundu = $true
            Write-Host ("    0x{0:X5}  ham=0x{1:X8}  VID={2}  -> {3} V  <-- makul" -f `
                        $adr, $v, $vid, [math]::Round($volt, 4)) -ForegroundColor Green
        } else {
            Write-Host ("    0x{0:X5}  ham=0x{1:X8}" -f $adr, $v) -ForegroundColor DarkGray
        }
    }
    if (-not $bulundu) { Write-Host "    Makul voltaj adayi bulunamadi." -ForegroundColor Yellow }
}
finally { Close-PawnIOModule -Handle $h }

Write-Host ""
