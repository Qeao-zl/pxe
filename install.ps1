#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install a self-hosted PXE provisioning server on Windows Server 2016/2019/2022.

.DESCRIPTION
    Sets up DHCP + TFTP + HTTP on one box so bare-metal servers can network-boot
    and install RHEL-family (Kylin / openEuler / CentOS / Rocky ...) unattended.

    Components installed:
      * DHCP role  - scope + option 66/67 for PXE
      * IIS        - serves ISO trees over HTTP (inst.repo)
      * tftpd.exe  - small TFTP server compiled from src\TftpServer.cs, runs as a scheduled task
      * PXE-Health - boot-time self heal task
      * Desktop / Start Menu shortcut for the GUI console

.PARAMETER ServerIp
    Static IP of the provisioning NIC. Default 10.0.0.1

.PARAMETER ScopeId
    DHCP scope subnet. Default 10.0.0.0 (with /24)

.PARAMETER RangeStart / RangeEnd
    DHCP pool. Default <subnet>.100 - <subnet>.200

.PARAMETER PxeRoot
    Install root. Default C:\PXE

.PARAMETER NicAlias
    Name of the adapter that should carry ServerIp (e.g. "Ethernet2").
    Leave empty to let the health task pick one.

.EXAMPLE
    .\install.ps1 -ServerIp 10.0.0.1 -ScopeId 10.0.0.0 -NicAlias Ethernet2

.NOTES
    The provisioning NIC must be on an ISOLATED layer-2 segment.
    Running a DHCP server on an office LAN will fight the existing DHCP.
#>
[CmdletBinding()]
param(
    [string]$ServerIp   = '10.0.0.1',
    [int]   $Prefix     = 24,
    [string]$ScopeId    = '10.0.0.0',
    [string]$RangeStart = '',
    [string]$RangeEnd   = '',
    [string]$PxeRoot    = 'C:\PXE',
    [string]$NicAlias   = '',
    [switch]$SkipDhcp
)

$ErrorActionPreference = 'Stop'
$src = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

function Step($n, $msg) { Write-Host "`n[$n] $msg" -ForegroundColor Cyan }
function Ok($msg)        { Write-Host "    OK  $msg" -ForegroundColor Green }
function Warn($msg)      { Write-Host "    !!  $msg" -ForegroundColor Yellow }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script as Administrator.'
}

# ---------------------------------------------------------------- 1. layout
Step 1 'Create directory layout'
foreach ($d in @(
    $PxeRoot,
    (Join-Path $PxeRoot 'www'),
    (Join-Path $PxeRoot 'www\os'),
    (Join-Path $PxeRoot 'www\ks'),
    (Join-Path $PxeRoot 'tftproot'),
    (Join-Path $PxeRoot 'tftproot\grub'),
    (Join-Path $PxeRoot 'tftproot\images'),
    (Join-Path $PxeRoot 'tftproot\EFI\BOOT'),
    (Join-Path $PxeRoot 'iso'),
    (Join-Path $PxeRoot 'logs'),
    (Join-Path $PxeRoot 'work'),
    (Join-Path $PxeRoot 'tftpd'),
    (Join-Path $PxeRoot 'lib')
)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
Ok $PxeRoot

# ---------------------------------------------------------------- 2. files
Step 2 'Copy scripts'
$map = @{
    'lib\PxeLib.ps1'          = (Join-Path $PxeRoot 'lib\PxeLib.ps1')
    'lib\PxeHealth.ps1'       = (Join-Path $PxeRoot 'lib\PxeHealth.ps1')
    'PXEConsole.ps1'          = (Join-Path $PxeRoot 'PXEConsole.ps1')
    'Import-PxeIso.ps1'       = (Join-Path $PxeRoot 'Import-PxeIso.ps1')
}
foreach ($k in $map.Keys) {
    $from = Join-Path $src $k
    if (Test-Path $from) { Copy-Item $from $map[$k] -Force; Ok $k }
    else { Warn "missing source $k" }
}

$cfgText = @"
@{
    ServerIp = '$ServerIp'
    Prefix   = $Prefix
    ScopeId  = '$ScopeId'
    PxeRoot  = '$($PxeRoot -replace '\\','\\')'
    NicAlias = '$NicAlias'
}
"@
Set-Content -Path (Join-Path $PxeRoot 'pxe.config.psd1') -Value $cfgText -Encoding UTF8
Ok 'pxe.config.psd1'

$cmdText = @"
@echo off
start "" powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$PxeRoot\PXEConsole.ps1"
"@
Set-Content -Path (Join-Path $PxeRoot 'PXEConsole.cmd') -Value $cmdText -Encoding ASCII
Ok 'PXEConsole.cmd'

# ---------------------------------------------------------------- 3. tftp
Step 3 'Build the TFTP server'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'csc.exe not found (.NET Framework 4 missing?)' }

$csSrc = Join-Path $src 'src\TftpServer.cs'
if (-not (Test-Path $csSrc)) { throw "missing src\TftpServer.cs" }
$exe = Join-Path $PxeRoot 'tftpd\tftpd.exe'
& $csc /nologo /optimize+ /target:exe "/out:$exe" $csSrc | Out-Null
if (-not (Test-Path $exe)) { throw 'compilation failed' }
Ok $exe

# ---------------------------------------------------------------- 4. features
Step 4 'Install Windows features'
$feat = @('Web-Server', 'Web-Mgmt-Tools', 'TFTP-Client')
if (-not $SkipDhcp) { $feat += 'DHCP' }
$r = Install-WindowsFeature -Name $feat -IncludeManagementTools
Ok ("installed: " + (($r.FeatureResult | Where-Object { $_.Success } | ForEach-Object { $_.Name }) -join ', '))

# ---------------------------------------------------------------- 5. firewall
Step 5 'Firewall rules'
foreach ($r in @(
    @{ n = 'PXE-TFTP-69'; p = 'UDP'; port = 69 },
    @{ n = 'PXE-HTTP-80'; p = 'TCP'; port = 80 })) {
    if (Get-NetFirewallRule -DisplayName $r.n -ErrorAction SilentlyContinue) {
        Ok "$($r.n) exists"
    } else {
        New-NetFirewallRule -DisplayName $r.n -Direction Inbound -Protocol $r.p -LocalPort $r.port -Action Allow -Profile Any | Out-Null
        Ok $r.n
    }
}

# ---------------------------------------------------------------- 6. tasks
Step 6 'Scheduled tasks'
foreach ($t in 'PXE-TFTP', 'PXE-Health') {
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
}

$act = New-ScheduledTaskAction -Execute $exe -Argument (Join-Path $PxeRoot 'tftproot')
$trg = New-ScheduledTaskTrigger -AtStartup
$prn = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName 'PXE-TFTP' -Action $act -Trigger $trg -Principal $prn -Settings $set | Out-Null
Ok 'PXE-TFTP'

$act2 = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $PxeRoot 'lib\PxeHealth.ps1'))
$trg2 = New-ScheduledTaskTrigger -AtStartup
$trg2.Delay = 'PT30S'
$set2 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'PXE-Health' -Action $act2 -Trigger $trg2 -Principal $prn -Settings $set2 | Out-Null
Ok 'PXE-Health'

Start-ScheduledTask -TaskName 'PXE-TFTP'
Start-Sleep -Seconds 3
if (Get-Process tftpd -ErrorAction SilentlyContinue) { Ok 'tftpd running' } else { Warn 'tftpd not running yet' }

# ---------------------------------------------------------------- 7. IIS
Step 7 'IIS site'
Import-Module WebAdministration -ErrorAction Stop
$wwwRoot = Join-Path $PxeRoot 'www'

if (Get-Website -Name 'PXE' -ErrorAction SilentlyContinue) {
    Stop-Website -Name 'PXE' -ErrorAction SilentlyContinue
    Set-ItemProperty 'IIS:\Sites\PXE' -Name physicalPath -Value $wwwRoot
} else {
    New-Website -Name 'PXE' -PhysicalPath $wwwRoot -Port 80 -Force | Out-Null
}
$def = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
if ($def) {
    Set-ItemProperty 'IIS:\Sites\Default Web Site' -Name serverAutoStart -Value $false
    Stop-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
}
Set-ItemProperty 'IIS:\Sites\PXE' -Name serverAutoStart -Value $true
Set-WebConfigurationProperty -PSPath 'IIS:\Sites\PXE' -Filter '/system.webServer/directoryBrowse' -Name enabled -Value $true
try {
    Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/staticContent' -Name '.' `
        -Value @{ fileExtension = '.ks'; mimeType = 'text/plain' } -ErrorAction SilentlyContinue
} catch { }
Start-Website -Name 'PXE'
Ok 'site PXE started on port 80'

# ---------------------------------------------------------------- 8. DHCP
if (-not $SkipDhcp) {
    Step 8 'DHCP scope'
    try { Add-DhcpServerSecurityGroup -ErrorAction SilentlyContinue } catch { }

    $parts = $ScopeId.Split('.')
    if ($RangeStart -eq '') { $RangeStart = "$($parts[0]).$($parts[1]).$($parts[2]).100" }
    if ($RangeEnd   -eq '') { $RangeEnd   = "$($parts[0]).$($parts[1]).$($parts[2]).200" }

    $scope = Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue
    if (-not $scope) {
        Add-DhcpServerv4Scope -Name 'PXE-Provision' -StartRange $RangeStart -EndRange $RangeEnd `
            -SubnetMask 255.255.255.0 -LeaseDuration ([TimeSpan]::FromHours(1)) -State Active | Out-Null
        Ok "scope $ScopeId created ($RangeStart-$RangeEnd)"
    } else {
        Ok "scope $ScopeId already exists"
    }

    Set-DhcpServerv4OptionValue -ScopeId $ScopeId -Router $ServerIp -DnsServer $ServerIp -ErrorAction SilentlyContinue
    Set-DhcpServerv4OptionValue -ScopeId $ScopeId -OptionId 66 -Value $ServerIp -ErrorAction SilentlyContinue
    Set-DhcpServerv4OptionValue -ScopeId $ScopeId -OptionId 67 -Value 'grubaa64.efi' -ErrorAction SilentlyContinue
    Ok "options 66=$ServerIp 67=grubaa64.efi"

    Start-Service DHCPServer -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 9. shortcuts
Step 9 'Shortcuts'
$ws = New-Object -ComObject WScript.Shell
$folders = @(
    (Join-Path $env:PUBLIC 'Desktop'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
)
foreach ($dir in $folders) {
    try {
        $lnk = Join-Path $dir 'PXE Console.lnk'
        $sc = $ws.CreateShortcut($lnk)
        $sc.TargetPath = Join-Path $PxeRoot 'PXEConsole.cmd'
        $sc.WorkingDirectory = $PxeRoot
        $sc.Description = 'PXE provisioning console'
        $sc.IconLocation = 'C:\Windows\System32\shell32.dll,21'
        $sc.Save()
        Ok $lnk
    } catch { Warn "shortcut failed in $dir" }
}

# ---------------------------------------------------------------- 10. status
Step 10 'Status'
Get-Service DHCPServer, W3SVC -ErrorAction SilentlyContinue | Select-Object Name, Status | Format-Table -AutoSize | Out-String | Write-Host
Get-Website | Select-Object Name, State | Format-Table -AutoSize | Out-String | Write-Host

Write-Host @"

============================================================
Installed.

Next steps:
  1. Make sure the provisioning NIC has $ServerIp and is plugged
     into an ISOLATED switch together with the target servers.
  2. Copy your Linux ISOs into  $PxeRoot\iso
  3. Import them:
        cd $PxeRoot
        .\Import-PxeIso.ps1 -Iso "$PxeRoot\iso\*.iso"
  4. Open "PXE Console" on the desktop, fill in the form and press
     "build ks and apply".
  5. Boot the target server with PXE - it installs unattended.
============================================================
"@ -ForegroundColor Cyan
