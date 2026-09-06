# set-aio-light.ps1 - AIO isiklarini TEK SEFERDE ayarlar (adim takibi yok).
#
# Pompa basliginin Ic ve Dis bolgelerini AYRI AYRI ayarlar; bu cihazda
# "Tumu" kapsami calismiyor (olculdu: kapsam Tumu -> sonuk, kapsam Ic -> yaniyor).
# Ayrica pompaya bagli fanlarin isik kanalini (0x85) da ayarlar.

param(
    [string]$Color = 'FF0000',
    [ValidateRange(0,8)] [int]$Brightness = 2,
    [switch]$FansSyncToPump,
    [switch]$Off
)

. (Join-Path $PSScriptRoot "..\lib\LianLiGA2.ps1")

$info = Get-GA2DeviceInfo
if ($null -eq $info) { Write-Host "AIO bulunamadi." -ForegroundColor Red; exit 1 }

$dev = $null
try {
    $dev = [LianLi.HidCore]::Open($info)
    $renkStr = '#' + $Color.TrimStart('#')

    # --- Pompa basligi: Ic ve Dis bolgeler ayri ayri ---
    foreach ($scope in @('Inner','Outer')) {
        try {
            if ($Off) { Set-GA2PumpLight -Device $dev -Scope $scope -Off | Out-Null }
            else      { Set-GA2PumpLight -Device $dev -Color $Color -Brightness $Brightness -Scope $scope | Out-Null }
            Write-Host ("  pompa basligi / {0,-5} -> {1}" -f $scope, $(if ($Off) { 'kapali' } else { $renkStr })) -ForegroundColor Green
        } catch {
            Write-Host ("  pompa basligi / {0,-5} -> hata: {1}" -f $scope, $_.Exception.Message) -ForegroundColor Red
        }
        Start-Sleep -Milliseconds 150
    }

    # --- Pompaya bagli fanlarin isiklari ---
    try {
        if ($Off) {
            Set-GA2FanLight -Device $dev -Off | Out-Null
        } else {
            if ($FansSyncToPump) { Set-GA2FanLight -Device $dev -Color $Color -Brightness $Brightness -SyncToPump | Out-Null }
            else                 { Set-GA2FanLight -Device $dev -Color $Color -Brightness $Brightness | Out-Null }
        }
        $ek = if ($FansSyncToPump) { ' (pompaya senkron)' } else { '' }
        Write-Host ("  AIO fan isiklari        -> {0}{1}" -f $(if ($Off) { 'kapali' } else { $renkStr }), $ek) -ForegroundColor Green
    } catch {
        Write-Host ("  AIO fan isiklari        -> hata: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}
catch { Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red; exit 3 }
finally { if ($null -ne $dev) { $dev.Dispose() } }
