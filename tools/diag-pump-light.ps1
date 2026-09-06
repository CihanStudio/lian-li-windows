# diag-pump-light.ps1 - Pompa basligi isigi neden yanmiyor?
#
# Parlaklik / kapsam / kaynak kombinasyonlarini tek tek dener.
# HER ADIMDA POMPA BASLIGINA BAK ve hangi ADIM NUMARASINDA yandigini not al.
# Renk her adimda KIRMIZI'dir; yanan adimda kirmizi gormelisin.

param([int]$HoldSeconds = 6)

. (Join-Path $PSScriptRoot "..\lib\LianLiGA2.ps1")

$info = Get-GA2DeviceInfo
if ($null -eq $info) { Write-Host "AIO bulunamadi." -ForegroundColor Red; exit 1 }

# Adim matrisi: parlaklik ters olcekli mi, kapsam mi sorun, kaynak mi sorun?
$adimlar = @(
    @{ N=1;  Br=0; Scope='All';   Src=0; Aciklama='parlaklik 0 (ters olcekte en parlak olabilir)' },
    @{ N=2;  Br=1; Scope='All';   Src=0; Aciklama='parlaklik 1' },
    @{ N=3;  Br=2; Scope='All';   Src=0; Aciklama='parlaklik 2' },
    @{ N=4;  Br=3; Scope='All';   Src=0; Aciklama='parlaklik 3' },
    @{ N=5;  Br=4; Scope='All';   Src=0; Aciklama='parlaklik 4 (onceki denemem - sonuk kaldi)' },
    @{ N=6;  Br=0; Scope='Inner'; Src=0; Aciklama='kapsam Ic' },
    @{ N=7;  Br=0; Scope='Outer'; Src=0; Aciklama='kapsam Dis' },
    @{ N=8;  Br=0; Scope='All';   Src=1; Aciklama='kaynak = anakart' },
    @{ N=9;  Br=2; Scope='Inner'; Src=0; Aciklama='parlaklik 2 + kapsam Ic' }
)

$dev = $null
try {
    $dev = [LianLi.HidCore]::Open($info)
    Write-Host ""
    Write-Host "POMPA BASLIGINA BAK. Kirmizi yandigi ADIM NUMARASINI not al." -ForegroundColor Yellow
    Write-Host ("Her adim {0} saniye surer. Toplam ~{1} saniye." -f $HoldSeconds, ($HoldSeconds * $adimlar.Count)) -ForegroundColor DarkGray
    Write-Host ""

    foreach ($a in $adimlar) {
        Write-Host ("  ADIM {0}  ->  {1}" -f $a.N, $a.Aciklama) -ForegroundColor Cyan
        try {
            Set-GA2PumpLight -Device $dev -Color 'FF0000' `
                             -Brightness $a.Br -Scope $a.Scope -SourceByte $a.Src | Out-Null
        } catch {
            Write-Host ("     hata: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
        Start-Sleep -Seconds $HoldSeconds
    }

    Write-Host ""
    Write-Host "Test bitti. Hangi adimda yandi? (hicbirinde yanmadiysa bunu da soyle)" -ForegroundColor Yellow
}
catch { Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red; exit 3 }
finally { if ($null -ne $dev) { $dev.Dispose() } }
