# probe-nv.ps1 - NVAPI SALT OKUMA testi.
# Fan hizi DEGISTIRMEZ; sadece fonksiyon ID'lerini cozer, sicaklik ve fan durumu okur.

. (Join-Path $PSScriptRoot "..\lib\NvApi.ps1")

Write-Host "=== 1) FONKSIYON ID COZUMLEME ===" -ForegroundColor Cyan
$probe = Get-NvProbe
foreach ($k in $probe.Keys) {
    $ok = $probe[$k]
    $renk = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0,-28} {1}" -f $k, $(if ($ok) { 'cozuldu' } else { 'COZULEMEDI' })) -ForegroundColor $renk
}

if (-not $probe['Initialize']) {
    Write-Host "nvapi64.dll temel fonksiyonu cozemedi, devam edilemiyor." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== 2) GPU LISTESI ===" -ForegroundColor Cyan
try {
    $gpus = Get-NvGpus
} catch {
    Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}
Write-Host ("  {0} NVIDIA GPU bulundu." -f $gpus.Count) -ForegroundColor White

$i = 0
foreach ($g in $gpus) {
    Write-Host ""
    Write-Host ("=== GPU #{0} ===" -f $i) -ForegroundColor Cyan

    $t = Get-NvTemp -Gpu $g
    if ($t -ge 0) { Write-Host ("  Sicaklik : {0} C" -f $t) -ForegroundColor White }
    else          { Write-Host  "  Sicaklik : okunamadi" -ForegroundColor Yellow }

    $fans = Get-NvFans -Gpu $g
    if ($fans.Count -eq 0) {
        Write-Host "  Fanlar   : ClientFanCoolers durumu okunamadi" -ForegroundColor Yellow
    } else {
        Write-Host ("  Fanlar   : {0} adet" -f $fans.Count) -ForegroundColor White
        foreach ($f in $fans) {
            Write-Host ("    id={0}  {1,5} RPM  seviye %{2}  (izin verilen %{3}-%{4})" -f $f.Id, $f.Rpm, $f.Level, $f.Min, $f.Max) -ForegroundColor White
        }
    }
    $i++
}
Write-Host ""
