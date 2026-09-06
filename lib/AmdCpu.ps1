# AmdCpu.ps1 - AMD Ryzen sicaklik / guc okumasi (PawnIO AMDFamily17 modulu).
#
# YONETICI YETKISI GEREKIR.
#
# Bu makinedeki islemci: Ryzen 7 9700X = Family 0x1A, Model 0x44 (Zen 5, Granite Ridge).
# AMDFamily17 modulu 17h/19h/1Ah ailelerini kapsiyor; SMN adres haritasi aileye gore
# degisiyor, bu yuzden ADAY ADRESLER denenip MAKUL SONUC veren secilir (asagiya bak).
#
# Modulun disa actigi fonksiyonlar (binary'den okundu):
#   ioctl_read_smn   in[0]=adres            -> out[0]=32-bit deger
#   ioctl_read_msr   in[0]=msr indeksi      -> out[0]=64-bit deger
#   ioctl_write_msr  (KULLANILMIYOR - salt okuma politikasi)
#
# SALT OKUMA: bu dosya hicbir yazma islemi yapmaz. MSR/SMN yazmak islemciyi
# kararsizlastirabilir veya kalici ayar bozabilir; bilincli olarak sarilmadi.

. (Join-Path $PSScriptRoot "PawnIO.ps1")

# --- SMN adresleri ---
# Tctl/Tdie ham register'i. 17h'den 1Ah'e kadar ayni adreste duruyor.
$script:AMD_SMN_THM_CUR_TMP = 0x00059800
$script:AMD_TEMP_OFFSET_FLAG = 0x80000     # set ise olculen deger 49 derece kaydirilmis

# CCD (cekirdek kompleksi) sicaklik dizisinin baslangici - aileye gore degisiyor.
# Hangisinin dogru oldugu OLCUMLE secilir: makul aralikta (0-125 C) deger veren.
$script:AMD_CCD_ADAYLAR = @(
    @{ Ad = 'Zen4/Zen5 (0x59B08)'; Adres = 0x00059B08 },
    @{ Ad = 'Zen3 (0x59954)';      Adres = 0x00059954 },
    @{ Ad = 'Zen2 (0x59954)';      Adres = 0x00059954 }
)

# --- MSR indeksleri ---
# DIKKAT: 'L' soneki SART. PowerShell 0xC0010299 sabitini Int32 olarak ayristirir
# ve deger isaret bitini astigi icin NEGATIF (-1073675623) olur; [uint32]'e cevrimi
# de patlar. 'L' ile Int64 olarak ayristirilir ve dogru pozitif deger elde edilir.
$script:AMD_MSR_RAPL_PWR_UNIT   = [uint32]0xC0010299L   # birim tanimlari
$script:AMD_MSR_CORE_ENERGY     = [uint32]0xC001029AL   # cekirdek basi enerji sayaci
$script:AMD_MSR_PKG_ENERGY      = [uint32]0xC001029BL   # paket enerji sayaci
$script:AMD_MSR_PSTATE_0        = [uint32]0xC0010064L   # P0 tanimi (taban carpan)

function Open-AmdCpuModule {
    Open-PawnIOModule -ModuleName "AMDFamily17.bin"
}

function Get-AmdSmn {
    <# Tek bir SMN register'i okur. Basarisizsa $null. #>
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [Parameter(Mandatory)][uint32]$Address
    )
    $res = $null
    $hr = [PawnIO.Lib]::TryExecute($Handle, "ioctl_read_smn", @([uint64]$Address), 1, [ref]$res)
    if ($hr -ne 0 -or $res.Count -lt 1) { return $null }
    return [uint32]([uint64]$res[0] -band 0xFFFFFFFF)
}

function Get-AmdMsr {
    <# Tek bir MSR okur. Basarisizsa $null. #>
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [Parameter(Mandatory)][uint32]$Index
    )
    $res = $null
    $hr = [PawnIO.Lib]::TryExecute($Handle, "ioctl_read_msr", @([uint64]$Index), 1, [ref]$res)
    if ($hr -ne 0 -or $res.Count -lt 1) { return $null }
    return [uint64]$res[0]
}

function ConvertFrom-AmdTctlRaw {
    <#
      THM_TCON_CUR_TMP ham degerini santigrada cevirir.
        bit 31..21 : sicaklik, 1/8 derece adimli
        bit 19     : "range" bayragi - set ise 49 derece cikarilir
    #>
    param([Parameter(Mandatory)][uint32]$Raw)

    $adim = [int](($Raw -shr 21) -band 0x7FF)
    $c = $adim / 8.0
    if (($Raw -band $script:AMD_TEMP_OFFSET_FLAG) -ne 0) { $c -= 49.0 }
    return [math]::Round($c, 1)
}

function ConvertFrom-AmdCcdRaw {
    <#
      CCD sicaklik register'i: bit 11..0, 1/8 derece adimli, 305 derece ofsetli.
      Makul olmayan sonuc (0'in altinda / 125 ustu) $null doner - bos CCD yuvasi.
    #>
    param([Parameter(Mandatory)][uint32]$Raw)

    if ($Raw -eq 0) { return $null }
    $c = (($Raw -band 0xFFF) / 8.0) - 305.0
    if ($c -le 0 -or $c -ge 125) { return $null }
    return [math]::Round($c, 1)
}

function Get-AmdCpuTemperature {
    <#
      CPU sicakligini dondurur.
        Tctl   : islemcinin fan kontrolu icin urettigi deger (ofsetli olabilir)
        CCD    : gercek silikon sicakliklari (varsa) - Tdie'ye en yakin olan bu
        Source : CCD bulunduysa hangi aday adresin tuttugu
    #>
    param([Parameter(Mandatory)][IntPtr]$Handle)

    $ham = Get-AmdSmn -Handle $Handle -Address $script:AMD_SMN_THM_CUR_TMP
    if ($null -eq $ham) {
        return [PSCustomObject]@{ Ok = $false; Hata = "SMN 0x59800 okunamadi"; Tctl = $null; Ccd = @(); Raw = $null }
    }

    $tctl = ConvertFrom-AmdTctlRaw -Raw $ham

    # CCD dizisini bul: makul deger veren ilk aday adres kazanir.
    $ccdler = @()
    $kaynak = $null
    foreach ($aday in $script:AMD_CCD_ADAYLAR) {
        $bulunan = @()
        for ($i = 0; $i -lt 2; $i++) {   # 9700X tek CCD; yine de 2 yuva taranir
            $adr = [uint32]($aday.Adres + ($i * 4))
            $v = Get-AmdSmn -Handle $Handle -Address $adr
            if ($null -eq $v) { continue }
            $c = ConvertFrom-AmdCcdRaw -Raw $v
            if ($null -ne $c) { $bulunan += [PSCustomObject]@{ Index = $i; TempC = $c; Raw = $v } }
        }
        if ($bulunan.Count -gt 0) { $ccdler = $bulunan; $kaynak = $aday.Ad; break }
    }

    return [PSCustomObject]@{
        Ok     = $true
        Tctl   = $tctl
        Ccd    = $ccdler
        Source = $kaynak
        Raw    = $ham
    }
}

function Get-AmdRaplUnits {
    <# RAPL birim MSR'ini cozer. energyUnit = 1 / 2^bit(12..8) joule. #>
    param([Parameter(Mandatory)][IntPtr]$Handle)

    $v = Get-AmdMsr -Handle $Handle -Index $script:AMD_MSR_RAPL_PWR_UNIT
    if ($null -eq $v) { return $null }

    $enerjiBit = [int](($v -shr 8) -band 0x1F)
    return [PSCustomObject]@{
        EnergyUnitJ = [math]::Pow(0.5, $enerjiBit)
        Raw         = $v
    }
}

function Get-AmdCpuPower {
    <#
      Paket gucunu (watt) olcer: enerji sayacinin iki okuma arasindaki farki
      gecen sureye bolunur. Sayac 32 bitlik ve tasabilir - tasma duzeltilir.
      SampleMs cok kisa olursa gurultu artar; 300 ms altina inme.
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [ValidateRange(100, 5000)][int]$SampleMs = 400
    )

    $birim = Get-AmdRaplUnits -Handle $Handle
    if ($null -eq $birim) { return $null }

    $e1 = Get-AmdMsr -Handle $Handle -Index $script:AMD_MSR_PKG_ENERGY
    if ($null -eq $e1) { return $null }
    $t1 = [System.Diagnostics.Stopwatch]::StartNew()

    Start-Sleep -Milliseconds $SampleMs

    $e2 = Get-AmdMsr -Handle $Handle -Index $script:AMD_MSR_PKG_ENERGY
    $t1.Stop()
    if ($null -eq $e2) { return $null }

    $a = [uint64]($e1 -band 0xFFFFFFFF)
    $b = [uint64]($e2 -band 0xFFFFFFFF)
    $fark = if ($b -ge $a) { $b - $a } else { (0x100000000 + $b) - $a }

    $saniye = $t1.Elapsed.TotalSeconds
    if ($saniye -le 0) { return $null }

    $watt = ($fark * $birim.EnergyUnitJ) / $saniye
    if ($watt -le 0 -or $watt -gt 500) { return $null }   # makul disi = sayac desteklenmiyor
    return [math]::Round($watt, 1)
}
