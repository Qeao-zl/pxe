# Import-PxeIso.ps1 - expand ISO into PXE-bootable layout + regenerate GRUB menu
# Usage (run as Administrator on the PXE server):
#   .\Import-PxeIso.ps1 -Iso 'C:\PXE\iso\Kylin-Server-V10-SP3-...-arm64.iso'
#   .\Import-PxeIso.ps1 -Iso 'C:\PXE\iso\*.iso' -ServerIp 10.0.0.1
param(
    [Parameter(Mandatory = $true)][string[]]$Iso,
    [string]$PxeRoot = '',
    [string]$ServerIp = ''
)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$conf = @{}
$cfgPath = Join-Path $scriptDir 'pxe.config.psd1'
if (Test-Path $cfgPath) { try { $conf = Import-PowerShellDataFile -Path $cfgPath } catch { } }
if (-not $PxeRoot)  { $PxeRoot  = if ($conf.PxeRoot)  { $conf.PxeRoot }  else { $scriptDir } }
if (-not $ServerIp) { $ServerIp = if ($conf.ServerIp) { $conf.ServerIp } else { '10.0.0.1' } }

$ErrorActionPreference = 'Stop'
$tftpRoot = Join-Path $PxeRoot 'tftproot'
$wwwRoot  = Join-Path $PxeRoot 'www'
$grubDir  = Join-Path $tftpRoot 'grub'
$imgRoot  = Join-Path $tftpRoot 'images'
$osRoot   = Join-Path $wwwRoot  'os'
$cfgPath  = Join-Path $grubDir  'grub.cfg'

foreach ($d in @($grubDir, $imgRoot, $osRoot, (Join-Path $tftpRoot 'EFI\BOOT'))) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

function Get-Slug([string]$name) {
    $s = [IO.Path]::GetFileNameWithoutExtension($name).ToLowerInvariant()
    $s = $s -replace '\.iso$', ''
    $s = $s -replace '[^a-z0-9\.\-]+', '-'
    $s = $s -replace '-+', '-'
    return $s.Trim('-')
}

$entries = @()

foreach ($pattern in $Iso) {
    $files = Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue
    if (-not $files) { Write-Warning "not found: $pattern"; continue }

    foreach ($f in $files) {
        $slug = Get-Slug $f.Name
        Write-Host "`n===== $($f.Name)  ->  $slug ====="

        $mounted = $false
        try {
            $img = Mount-DiskImage -ImagePath $f.FullName -PassThru -ErrorAction Stop
            $mounted = $true
            $drive = ($img | Get-Volume).DriveLetter
            if (-not $drive) { throw 'mounted but no drive letter' }
            $src = "${drive}:"

            # ---------- detect family ----------
            $isAnaconda = Test-Path (Join-Path $src 'images\pxeboot\vmlinuz')
            $isCasper   = (Test-Path (Join-Path $src 'casper\vmlinuz')) -or (Test-Path (Join-Path $src 'casper\vmlinuz.efi'))
            $isUbuntuServer = Test-Path (Join-Path $src 'install\vmlinuz')

            $fam = if ($isAnaconda) { 'anaconda' } elseif ($isCasper) { 'casper' } elseif ($isUbuntuServer) { 'ubuntu-server' } else { 'unknown' }
            if ($fam -eq 'unknown') { throw 'unrecognized ISO layout (no images/pxeboot, casper or install dir)' }

            # ---------- copy whole ISO tree to HTTP root ----------
            $osPath = Join-Path $osRoot $slug
            if (Test-Path $osPath) { Remove-Item $osPath -Recurse -Force }
            New-Item -ItemType Directory -Path $osPath -Force | Out-Null
            Write-Host "  copying to $osPath ..."
            $rc = Start-Process robocopy -ArgumentList "`"$src`" `"$osPath`" /E /NFL /NDL /NJH /NJS /NP /MT:8" -Wait -PassThru -WindowStyle Hidden
            if ($rc.ExitCode -ge 8) { throw "robocopy failed: $($rc.ExitCode)" }

            # ---------- kernel / initrd into TFTP root ----------
            $imgDir = Join-Path $imgRoot $slug
            New-Item -ItemType Directory -Path $imgDir -Force | Out-Null

            if ($isAnaconda) {
                $kernelSrc = Join-Path $src 'images\pxeboot\vmlinuz'
                $initrdSrc = Join-Path $src 'images\pxeboot\initrd.img'
            } elseif ($isCasper) {
                if (Test-Path (Join-Path $src 'casper\vmlinuz')) {
                    $kernelSrc = Join-Path $src 'casper\vmlinuz'
                } else {
                    $kernelSrc = Join-Path $src 'casper\vmlinuz.efi'
                }
                $initrdSrc = Join-Path $src 'casper\initrd'
            } else {
                $kernelSrc = Join-Path $src 'install\vmlinuz'
                $initrdSrc = Join-Path $src 'install\initrd'
            }

            Copy-Item $kernelSrc (Join-Path $imgDir 'vmlinuz') -Force
            Copy-Item $initrdSrc (Join-Path $imgDir 'initrd.img') -Force
            Write-Host "  kernel: $([int]((Get-Item (Join-Path $imgDir 'vmlinuz')).Length / 1MB)) MB"

            # ---------- GRUB EFI loaders per arch ----------
            $efiBoot = Join-Path $src 'EFI\BOOT'
            $arch = 'unknown'
            # 优先用发行版自带的 grubaa64.efi（内嵌 prefix /EFI/BOOT），BOOTAA64.EFI 通常是 shim
            $realGrub = Join-Path $efiBoot 'grubaa64.efi'
            $shim     = Join-Path $efiBoot 'BOOTAA64.EFI'
            if (Test-Path $realGrub) {
                Copy-Item $realGrub (Join-Path $tftpRoot 'grubaa64.efi') -Force
                $arch = 'arm64'
                if (Test-Path $shim) { Copy-Item $shim (Join-Path $tftpRoot 'shimaa64.efi') -Force }
            } elseif (Test-Path $shim) {
                Copy-Item $shim (Join-Path $tftpRoot 'grubaa64.efi') -Force
                $arch = 'arm64'
            }
            $realGrubX64 = Join-Path $efiBoot 'grubx64.efi'
            $shimX64     = Join-Path $efiBoot 'BOOTX64.EFI'
            if (Test-Path $realGrubX64) {
                Copy-Item $realGrubX64 (Join-Path $tftpRoot 'grubx64.efi') -Force
                if ($arch -eq 'unknown') { $arch = 'x64' }
                if (Test-Path $shimX64) { Copy-Item $shimX64 (Join-Path $tftpRoot 'shimx64.efi') -Force }
            } elseif (Test-Path $shimX64) {
                Copy-Item $shimX64 (Join-Path $tftpRoot 'grubx64.efi') -Force
                if ($arch -eq 'unknown') { $arch = 'x64' }
            }
            # mirror the ISO EFI dir so grub internal prefix (/EFI/...) resolves over TFTP
            if (Test-Path (Join-Path $src 'EFI')) {
                robocopy (Join-Path $src 'EFI') (Join-Path $tftpRoot 'EFI') /E /NFL /NDL /NJH /NJS /NP | Out-Null
            }

            # ---------- menu entry ----------
            $httpBase  = "http://$ServerIp/os/$slug"
            $label     = $f.Name -replace '\.iso$', ''
            $kernelPath = "/images/$slug/vmlinuz"
            $initrdPath = "/images/$slug/initrd.img"

            if ($fam -eq 'anaconda') {
                $entry = @"
menuentry '$label' --class linux {
    linuxefi $kernelPath inst.repo=$httpBase/ ip=dhcp rd.neednet=1 inst.lang=zh_CN.UTF-8 console=tty0
    initrdefi $initrdPath
}

"@
            } elseif ($fam -eq 'casper') {
                $entry = @"
menuentry '$label' --class linux {
    linuxefi $kernelPath boot=casper ip=dhcp url=$httpBase/ --- quiet splash
    initrdefi $initrdPath
}

"@
            } else {
                $entry = @"
menuentry '$label' --class linux {
    linuxefi $kernelPath autoinstall ip=dhcp ds=nocloud-net;s=$httpBase/ ---
    initrdefi $initrdPath
}

"@
            }

            $entries += [pscustomobject]@{ Name = $label; Slug = $slug; Entry = $entry; Arch = $arch; Family = $fam }
            Write-Host "  OK ($arch / $fam)"
        }
        catch {
            Write-Warning "  $($f.Name) failed: $($_.Exception.Message)"
        }
        finally {
            if ($mounted) { Dismount-DiskImage -ImagePath $f.FullName -ErrorAction SilentlyContinue | Out-Null }
        }
    }
}

# ---------- rebuild grub.cfg ----------
# Prefer PxeLib: it rebuilds the menu from disk and keeps the AUTO / kickstart
# entries (and the default index) that the console sets up.
$menuDone = $false
$libPath = Join-Path $PxeRoot 'lib\PxeLib.ps1'
if (Test-Path $libPath) {
    try {
        $__savedIp   = $ServerIp
        $__savedRoot = $PxeRoot
        . $libPath
        $menu = Update-GrubMenu
        $ServerIp = $__savedIp
        $PxeRoot  = $__savedRoot
        Write-Host "menu rebuilt by PxeLib: $($menu.Path)  entries=$($menu.Count)  default=#$($menu.Default + 1)"
        $menuDone = $true
    } catch {
        Write-Warning "PxeLib menu rebuild failed, falling back: $($_.Exception.Message)"
    }
}

if (-not $menuDone) {
    $header = @'
set default=0
set timeout=60
set gfxmode=auto
terminal_output console
insmod all_video

'@

    $body = ($entries | ForEach-Object { $_.Entry }) -join "`n"
    $footer = @"

menuentry '--- reboot ---' {
    reboot
}
"@

    $cfg = $header + $body + $footer
    Set-Content -Path $cfgPath -Value $cfg -Encoding ASCII
    Copy-Item $cfgPath (Join-Path $tftpRoot 'EFI\BOOT\grub.cfg') -Force
    Copy-Item $cfgPath (Join-Path $tftpRoot 'grub.cfg') -Force
}

# ---------- 补齐 IIS 的 MIME 映射（.treeinfo/.zst/.discinfo 等默认 404）----------
try {
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $exts = Get-ChildItem $wwwRoot -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { [IO.Path]::GetExtension($_.Name) } |
            Where-Object { $_ -and $_ -ne '.config' } | Sort-Object -Unique
    foreach ($e in $exts) {
        $mime = switch ($e) {
            '.xml'      { 'text/xml' }
            '.html'     { 'text/html' }
            '.txt'      { 'text/plain' }
            '.treeinfo' { 'text/plain' }
            '.discinfo' { 'text/plain' }
            '.zst'      { 'application/zstd' }
            '.gz'       { 'application/gzip' }
            '.bz2'      { 'application/x-bzip2' }
            '.xz'       { 'application/x-xz' }
            '.rpm'      { 'application/x-rpm' }
            default     { 'application/octet-stream' }
        }
        try {
            Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/staticContent' -Name '.' -Value @{ fileExtension = $e; mimeType = $mime } -ErrorAction Stop
        } catch { }
    }
} catch { Write-Warning "MIME 映射补充失败: $($_.Exception.Message)" }

Write-Host "`n===== done ====="
Write-Host "menu : $cfgPath"
Write-Host "http : http://$ServerIp/os/"
$entries | Format-Table Name, Slug, Arch, Family -AutoSize | Out-String | Write-Host
