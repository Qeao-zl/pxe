# PxeLib.ps1 - core logic for PXE install console (ASCII only, no GUI deps)
# Dot-source this file:  . .\lib\PxeLib.ps1
# Install root and network settings come from <root>\pxe.config.psd1 written by install.ps1

$script:Root = 'C:\PXE'
$__cfgPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'pxe.config.psd1'
if (Test-Path $__cfgPath) {
    try {
        $__conf = Import-PowerShellDataFile -Path $__cfgPath
        if ($__conf.PxeRoot)  { $script:Root = $__conf.PxeRoot }
        $script:ServerIp = if ($__conf.ServerIp) { $__conf.ServerIp } else { '10.0.0.1' }
        $script:ScopeId  = if ($__conf.ScopeId)  { $__conf.ScopeId }  else { '10.0.0.0' }
    } catch { }
}
if (-not $script:ServerIp) { $script:ServerIp = '10.0.0.1' }
if (-not $script:ScopeId)  { $script:ScopeId  = '10.0.0.0' }

$script:PxeRoot   = $script:Root
$script:WwwRoot   = Join-Path $script:Root 'www'
$script:TftpRoot  = Join-Path $script:Root 'tftproot'
$script:KsRoot    = Join-Path $script:Root 'www\ks'

function Initialize-PxePaths {
    foreach ($d in @($script:KsRoot, (Join-Path $script:TftpRoot 'grub'), (Join-Path $script:TftpRoot 'EFI\BOOT'))) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    try {
        $cur = Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/staticContent' -Name '.' -ErrorAction Stop
        if (-not ($cur.Collection | Where-Object { $_.fileExtension -eq '.ks' })) {
            Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/staticContent' -Name '.' -Value @{ fileExtension = '.ks'; mimeType = 'text/plain' } -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Get-PxeOsList {
    param([string]$WwwRoot = $script:WwwRoot)

    $osDir = Join-Path $WwwRoot 'os'
    if (-not (Test-Path $osDir)) { return @() }

    Get-ChildItem $osDir -Directory | ForEach-Object {
        $name = $_.Name; $arch = 'unknown'; $family = ''; $ver = ''
        $ti = Join-Path $_.FullName '.treeinfo'
        if (Test-Path $ti) {
            $t = Get-Content $ti -Raw
            if ($t -match '(?m)^name\s*=\s*(.+)$')    { $name   = $Matches[1].Trim() }
            if ($t -match '(?m)^arch\s*=\s*(.+)$')    { $arch   = $Matches[1].Trim() }
            if ($t -match '(?m)^family\s*=\s*(.+)$')  { $family = $Matches[1].Trim() }
            if ($t -match '(?m)^version\s*=\s*(.+)$') { $ver    = $Matches[1].Trim() }
        }
        $type = if (Test-Path (Join-Path $_.FullName 'images\pxeboot\vmlinuz')) { 'anaconda' }
                elseif (Test-Path (Join-Path $_.FullName 'casper'))            { 'casper' }
                else                                                           { 'unknown' }

        [pscustomobject]@{
            Slug     = $_.Name
            Name     = $name
            Arch     = $arch
            Family   = $family
            Version  = $ver
            Type     = $type
            HttpBase = "http://$($script:ServerIp)/os/$($_.Name)/"
        }
    }
}

function Get-ArchNorm([string]$arch) {
    switch -Regex ($arch) {
        'aarch64|arm64' { 'arm64' }
        'x86_64|amd64|x64' { 'x64' }
        default { 'unknown' }
    }
}

# ---------- partitioning helpers ----------

function Get-PartLines {
    param([string]$DiskToken, [string]$PartMode, [array]$Parts, [int]$SwapGB)

    $lines = New-Object System.Collections.ArrayList
    if ($PartMode -eq 'manual') {
        foreach ($p in $Parts) {
            if (-not $p.Mount) { continue }
            $line = if ($p.Mount -eq 'swap') { 'part swap' } else { "part $($p.Mount)" }
            if ($p.Mount -eq '/boot/efi') { $line += ' --fstype=efi' }
            elseif ($p.Mount -ne 'swap' -and $p.Fstype) { $line += " --fstype=$($p.Fstype)" }
            if ($p.Grow) { $line += ' --size=1 --grow' } else { $line += " --size=$([int]$p.SizeMB)" }
            $line += " --ondisk=$DiskToken"
            [void]$lines.Add($line)
        }
    } else {
        [void]$lines.Add("part /boot/efi --fstype=efi --size=600 --ondisk=$DiskToken")
        [void]$lines.Add("part /boot --fstype=xfs --size=1024 --ondisk=$DiskToken")
        if ($SwapGB -gt 0) { [void]$lines.Add("part swap --size=$([int]($SwapGB * 1024)) --ondisk=$DiskToken") }
        [void]$lines.Add("part / --fstype=xfs --size=1 --grow --ondisk=$DiskToken")
    }
    return ($lines -join "`n")
}

# bash %pre that detects the system disk by capacity, then writes the partition block
$script:DiskDetectTemplate = @'
out=/tmp/pxe-part.ks
rules="__RULES__"
tol=__TOL__
policy="__POLICY__"
: > "$out"
count=0
cands=""
first=""
minsz=""
maxsz=""
mindisk=""
maxdisk=""
for d in /sys/block/*; do
    n=${d##*/}
    case "$n" in loop*|ram*|zram*|sr*|dm-*|md*|nbd*) continue ;; esac
    r=$(cat "$d/removable" 2>/dev/null || echo 0)
    [ "$r" = "1" ] && continue
    sz=$(cat "$d/size" 2>/dev/null || echo 0)
    [ "$sz" -le 0 ] && continue
    gb=$(( sz * 512 / 1000000000 ))
    ok=0
    for x in $rules; do
        lo=$(( x * (100 - tol) / 100 ))
        hi=$(( x * (100 + tol) / 100 ))
        if [ "$gb" -ge "$lo" ] && [ "$gb" -le "$hi" ]; then ok=1; fi
    done
    if [ "$ok" = "1" ]; then
        count=$((count + 1))
        cands="$cands $n:${gb}G"
        if [ -z "$first" ]; then first="$n"; fi
        if [ -z "$minsz" ] || [ "$gb" -lt "$minsz" ]; then minsz=$gb; mindisk=$n; fi
        if [ -z "$maxsz" ] || [ "$gb" -gt "$maxsz" ]; then maxsz=$gb; maxdisk=$n; fi
    fi
done
echo "PXE disk scan: rules=[$rules]GB tol=${tol}% count=$count candidates=$cands"
if [ "$count" = "0" ]; then
    echo "PXE-FATAL: no disk matches capacity rules [$rules]GB +-${tol}%. Refusing to install." >&2
    exit 1
fi
DISK="$first"
if [ "$count" != "1" ]; then
    case "$policy" in
        min) DISK="$mindisk" ;;
        max) DISK="$maxdisk" ;;
        *)   echo "PXE-FATAL: multiple candidate disks:$cands  (policy=abort). Set multi-disk policy to min/max." >&2
             exit 1 ;;
    esac
fi
echo "PXE disk scan: selected $DISK"
cat > "$out" <<EOF
ignoredisk --only-use=$DISK
zerombr
clearpart --all --initlabel --drives=$DISK
__PARTLINES__
EOF
'@

function New-KickstartText {
    param([hashtable]$Config)

    $sb = New-Object System.Text.StringBuilder
    $add = { param($s) [void]$sb.AppendLine($s) }

    $os       = $Config.Os
    $arch     = Get-ArchNorm $Config.Arch
    $hostnameArg = if ($Config.Hostname) { " --hostname=$($Config.Hostname)" } else { '' }
    $diskMode = if ($Config.DiskSelect) { $Config.DiskSelect } else { 'auto' }

    & $add "### PXE_OS=$($os.Slug)"
    & $add "### PXE_ARCH=$arch"
    & $add "### PXE_LABEL=$($Config.Label)"
    & $add "### generated by PXE console $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    & $add "### disk-select=$diskMode part-mode=$($Config.PartMode)"
    & $add ''
    & $add "lang $($Config.Locale)"
    & $add "keyboard --vckeymap=us --xlayouts='us'"
    & $add "timezone $($Config.Timezone) --utc"
    & $add "url --url=`"$($os.HttpBase)`""
    & $add ''
    & $add "rootpw --plaintext $($Config.RootPassword)"
    if ($Config.CreateUser) {
        $groups = if ($Config.UserSudo) { '--groups=wheel' } else { '' }
        & $add "user --name=$($Config.UserName) $groups --plaintext --password=$($Config.UserPassword)"
    }
    & $add ''

    if ($Config.NetMode -eq 'static') {
        & $add "network --bootproto=static --device=link --activate$hostnameArg --ip=$($Config.Ip) --netmask=$($Config.Netmask) --gateway=$($Config.Gateway) --nameserver=$($Config.Dns)"
    } else {
        & $add "network --bootproto=dhcp --device=link --activate$hostnameArg"
    }
    & $add ''

    # ---- disk selection & partitioning ----
    if ($diskMode -eq 'auto') {
        $rules = if ($Config.SizeRules) { $Config.SizeRules } else { '480 960' }
        $tol   = if ($Config.SizeTolerance) { [int]$Config.SizeTolerance } else { 8 }
        $pol   = if ($Config.MultiPolicy) { $Config.MultiPolicy } else { 'abort' }

        $partBlock = Get-PartLines -DiskToken '$DISK' -PartMode $Config.PartMode -Parts $Config.Parts -SwapGB $Config.SwapGB
        $bash = $script:DiskDetectTemplate.Replace('__RULES__', $rules).Replace('__TOL__', [string]$tol).Replace('__POLICY__', $pol).Replace('__PARTLINES__', $partBlock)

        & $add '%pre --interpreter=/bin/bash --log=/tmp/pxe-disk.log'
        foreach ($ln in ($bash -split "`r?`n")) { & $add $ln }
        & $add '%end'
        & $add ''
        & $add '# partition block generated by the %pre above; must stay after it'
        & $add '%include /tmp/pxe-part.ks'
        & $add ''
    } else {
        $diskName = ($Config.Disk -replace '^/dev/', '')
        & $add "ignoredisk --only-use=$diskName"
        & $add 'zerombr'
        if ($Config.ClearDisk) { & $add 'clearpart --all --initlabel' }
        & $add (Get-PartLines -DiskToken $diskName -PartMode $Config.PartMode -Parts $Config.Parts -SwapGB $Config.SwapGB)
        & $add ''
    }

    if ($arch -eq 'x64') {
        & $add "bootloader --location=mbr --timeout=5"
    } else {
        & $add "bootloader --timeout=5"
    }
    & $add ''

    & $add 'selinux --enforcing'
    & $add 'firewall --enabled --service=ssh'
    & $add 'services --enabled=sshd,chronyd'
    if ($Config.PkgMode -eq 'minimal') { & $add 'skipx' }
    & $add 'reboot'
    & $add 'firstboot --disable'
    & $add ''

    & $add '%packages --ignoremissing'
    switch ($Config.PkgMode) {
        'minimal' { & $add '@^minimal-environment' }
        'gui'     { & $add '@^graphical-server-environment' }
        'custom'  {
            foreach ($ln in ($Config.Packages -split "`r?`n")) {
                if ($ln.Trim()) { & $add $ln.Trim() }
            }
        }
    }
    & $add '%end'
    & $add ''

    # %post：把本地系统的 EFI 引导项顶到第一位，防止重启后又回 PXE 反复重装
    & $add '%post --log=/root/pxe-post.log'
    & $add 'if command -v efibootmgr >/dev/null 2>&1; then'
    & $add '    entry=$(efibootmgr 2>/dev/null | grep -i -E "kylin|openeuler|centos|red ?hat|fedora|ubuntu" | head -n1 | sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p")'
    & $add '    if [ -n "$entry" ]; then'
    & $add '        rest=$(efibootmgr 2>/dev/null | sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p" | grep -v "^${entry}$" | tr "\n" "," | sed "s/,$//")'
    & $add '        efibootmgr -o "${entry},${rest}" >/dev/null 2>&1 && echo "PXE: boot order -> local disk first ($entry)"'
    & $add '    fi'
    & $add 'fi'
    & $add '%end'
    & $add ''

    return $sb.ToString()
}

function New-KickstartFile {
    param([hashtable]$Config, [string]$FileName)

    Initialize-PxePaths
    if (-not $FileName) {
        $FileName = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $Config.Os.Slug + '.ks'
    }
    if ($FileName -notmatch '\.ks$') { $FileName += '.ks' }
    $path = Join-Path $script:KsRoot $FileName
    $text = New-KickstartText -Config $Config
    Set-Content -Path $path -Value $text -Encoding ASCII
    return $path
}

function Get-KickstartMeta {
    param([string]$Path)
    $t = Get-Content $Path -Raw
    $os = ''; $arch = ''; $label = ''
    if ($t -match '(?m)^### PXE_OS=(.+)$')    { $os = $Matches[1].Trim() }
    if ($t -match '(?m)^### PXE_ARCH=(.+)$')  { $arch = $Matches[1].Trim() }
    if ($t -match '(?m)^### PXE_LABEL=(.+)$') { $label = $Matches[1].Trim() }
    if (-not $label) { $label = [IO.Path]::GetFileNameWithoutExtension($Path) }
    [pscustomobject]@{ Path = $Path; File = [IO.Path]::GetFileName($Path); OsSlug = $os; Arch = $arch; Label = $label }
}

function Update-GrubMenu {
    param([string]$DefaultKs = '')

    Initialize-PxePaths
    $osList = @(Get-PxeOsList)
    $entries = New-Object System.Collections.ArrayList

    foreach ($os in $osList) {
        $label = "$($os.Name) [$($os.Version)]"
        $e = @"
menuentry '$label' --class linux {
    linuxefi /images/$($os.Slug)/vmlinuz inst.repo=$($os.HttpBase) ip=dhcp rd.neednet=1 inst.lang=zh_CN.UTF-8 console=tty0
    initrdefi /images/$($os.Slug)/initrd.img
}

"@
        [void]$entries.Add([pscustomobject]@{ Label = $label; Text = $e; IsAuto = $false; KsFile = '' })
    }

    $ksFiles = @(Get-ChildItem $script:KsRoot -Filter *.ks -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($k in $ksFiles) {
        $meta = Get-KickstartMeta -Path $k.FullName
        $os = $osList | Where-Object { $_.Slug -eq $meta.OsSlug } | Select-Object -First 1
        if (-not $os) { continue }
        $label = ">> AUTO: $($meta.Label)"
        $e = @"
menuentry '$label' --class linux --id 'ks-$($meta.File)' {
    linuxefi /images/$($os.Slug)/vmlinuz inst.repo=$($os.HttpBase) inst.ks=http://$($script:ServerIp)/ks/$($meta.File) ip=dhcp rd.neednet=1 inst.lang=zh_CN.UTF-8 console=tty0
    initrdefi /images/$($os.Slug)/initrd.img
}

"@
        [void]$entries.Add([pscustomobject]@{ Label = $label; Text = $e; IsAuto = $true; KsFile = $meta.File })
    }

    $defaultIndex = 0
    if ($DefaultKs) {
        $dn = [IO.Path]::GetFileName($DefaultKs)
        for ($i = 0; $i -lt $entries.Count; $i++) {
            if ($entries[$i].IsAuto -and $entries[$i].KsFile -eq $dn) { $defaultIndex = $i; break }
        }
    }

    $header = @"
set default=$defaultIndex
set timeout=8
set gfxmode=auto
terminal_output console
insmod all_video

"@
    $body = ($entries | ForEach-Object { $_.Text }) -join "`n"
    $footer = @"
menuentry '--- reboot ---' {
    reboot
}
"@

    $cfg = $header + $body + "`n" + $footer
    $cfgPath = Join-Path $script:TftpRoot 'grub\grub.cfg'
    Set-Content -Path $cfgPath -Value $cfg -Encoding ASCII
    Copy-Item $cfgPath (Join-Path $script:TftpRoot 'EFI\BOOT\grub.cfg') -Force
    Copy-Item $cfgPath (Join-Path $script:TftpRoot 'grub.cfg') -Force

    [pscustomobject]@{ Path = $cfgPath; Count = $entries.Count; Default = $defaultIndex }
}

function Set-PxeBootArch {
    param([ValidateSet('arm64', 'x64')][string]$Arch)
    $nbp = if ($Arch -eq 'arm64') { 'grubaa64.efi' } else { 'grubx64.efi' }
    if (-not (Test-Path (Join-Path $script:TftpRoot $nbp))) {
        throw "boot file missing: $nbp"
    }
    Set-DhcpServerv4OptionValue -ScopeId $script:ScopeId -OptionId 67 -Value $nbp -ErrorAction Stop
    return $nbp
}

function Get-PxeStatus {
    $tftp = Get-Process tftpd -ErrorAction SilentlyContinue
    $dhcp = Get-Service DHCPServer -ErrorAction SilentlyContinue
    $iis  = Get-Service W3SVC -ErrorAction SilentlyContinue
    $site = Get-Website -Name 'PXE' -ErrorAction SilentlyContinue
    $boot = ''
    try { $boot = (Get-DhcpServerv4OptionValue -ScopeId $script:ScopeId -OptionId 67 -ErrorAction SilentlyContinue).Value } catch { }

    [pscustomobject]@{
        Dhcp     = if ($dhcp) { $dhcp.Status } else { 'missing' }
        Iis      = if ($iis) { $iis.Status } else { 'missing' }
        Site     = if ($site) { $site.State } else { 'missing' }
        Tftp     = if ($tftp) { "running(pid=$($tftp.Id))" } else { 'stopped' }
        BootFile = if ($boot -is [array]) { $boot -join ',' } else { [string]$boot }
    }
}
