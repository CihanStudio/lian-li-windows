# diag-aio-fanlight.ps1
#
# Iki soruyu ayni anda cozer:
#   A) Pompa basliginda sorun parlaklik miydi, kapsam mi? (Adim 1-2)
#   B) Pompaya bagli fanlarin isiklari hangi parlaklikta yaniyor? (Adim 3-8)
#
# Renk her adimda YESIL - boylece onceki kirmizi durumdan ayirt edilir.
# ADIM NUMARALARINI takip et ve neyin yandigini not al.

param([int]$HoldSeconds = 6)

. (Join-Path $PSScriptRoot "..\lib\LianLiGA2.ps1")

$info = Get-GA2DeviceInfo
if ($null -eq $info) { Write-Host "AIO bulunamadi." -ForegroundColor Red; exit 1 }

$dev = $null
try {
    $dev = [LianLi.HidCore]::Open($info)

    Write-Host ""
    Write-Host "Renk bu testte YESIL. Adim numaralarini takip et." -ForegroundColor Yellow
    Write-Host ""

    # --- A) Pompa basligi: parlaklik mi kapsam mi? ---
    Write-Host "--- A) POMPA BASLIGI ---" -ForegroundColor Cyan
    Write-Host "  ADIM 1 -> pompa basligi: parlaklik 2, kapsam TUMU" -ForegroundColor Cyan
    Set-GA2PumpLight -Device $dev -Color '00FF00' -Brightness 2 -Scope 'All' | Out-Null
    Start-Sleep -Seconds $HoldSeconds

    Write-Host "  ADIM 2 -> pompa basligi: parlaklik 0, kapsam TUMU" -ForegroundColor Cyan
    Set-GA2PumpLight -Device $dev -Color '00FF00' -Brightness 0 -Scope 'All' | Out-Null
    Start-Sleep -Seconds $HoldSeconds

    # --- B) AIO fan isik kanali (komut 0x85) ---
    Write-Host ""
    Write-Host "--- B) POMPAYA BAGLI FANLARIN ISIKLARI (komut 0x85) ---" -ForegroundColor Cyan
    $n = 3
    foreach ($br in @(0, 1, 2, 3, 4)) {
        Write-Host ("  ADIM {0} -> AIO fan isigi: parlaklik {1}" -f $n, $br) -ForegroundColor Cyan
        try {
            Set-GA2FanLight -Device $dev -Color '00FF00' -Brightness $br | Out-Null
        } catch {
            Write-Host ("     hata: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
        Start-Sleep -Seconds $HoldSeconds
        $n++
    }

    Write-Host ("  ADIM {0} -> AIO fan isigi: parlaklik 2 + pompaya senkron" -f $n) -ForegroundColor Cyan
    Set-GA2FanLight -Device $dev -Color '00FF00' -Brightness 2 -SyncToPump | Out-Null
    Start-Sleep -Seconds $HoldSeconds

    Write-Host ""
    Write-Host "Test bitti. Soyle bana:" -ForegroundColor Yellow
    Write-Host "  1) Pompa basligi Adim 1 ve 2'de yesil yandi mi? Ikisinde de mi, birinde mi?" -ForegroundColor Yellow
    Write-Host "  2) Fanlarin isiklari hangi adimda yandi?" -ForegroundColor Yellow
}
catch { Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red; exit 3 }
finally { if ($null -ne $dev) { $dev.Dispose() } }
