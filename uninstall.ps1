#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Remove the PXE provisioning stack installed by install.ps1

.PARAMETER PxeRoot
    Install root. Default C:\PXE

.PARAMETER RemoveData
    Also delete the install root (ISOs, extracted trees, kickstarts, logs).
#>
[CmdletBinding()]
param(
    [string]$PxeRoot = 'C:\PXE',
    [switch]$RemoveData
)

$ErrorActionPreference = 'Continue'

function Ok($m) { Write-Host "    OK  $m" -ForegroundColor Green }

Write-Host "`n[1] Scheduled tasks" -ForegroundColor Cyan
foreach ($t in 'PXE-TFTP', 'PXE-Health') {
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
    Ok "removed $t"
}

Write-Host "`n[2] TFTP process" -ForegroundColor Cyan
Stop-Process -Name tftpd -Force -ErrorAction SilentlyContinue
Ok 'stopped tftpd'

Write-Host "`n[3] IIS site" -ForegroundColor Cyan
Import-Module WebAdministration -ErrorAction SilentlyContinue
if (Get-Website -Name 'PXE' -ErrorAction SilentlyContinue) {
    Stop-Website -Name 'PXE' -ErrorAction SilentlyContinue
    Remove-Website -Name 'PXE'
    Ok 'removed site PXE'
}
$def = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
if ($def) { Start-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue; Ok 're-enabled Default Web Site' }

Write-Host "`n[4] Firewall rules" -ForegroundColor Cyan
foreach ($n in 'PXE-TFTP-69', 'PXE-HTTP-80') {
    Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Ok "removed $n"
}

Write-Host "`n[5] DHCP scope" -ForegroundColor Cyan
try {
    $scope = Get-DhcpServerv4Scope -ErrorAction Stop | Where-Object { $_.Name -eq 'PXE-Provision' }
    foreach ($s in $scope) {
        Remove-DhcpServerv4Scope -ScopeId $s.ScopeId -Force -ErrorAction SilentlyContinue
        Ok "removed scope $($s.ScopeId)"
    }
} catch { Write-Host '    no DHCP server role or no matching scope' }

Write-Host "`n[6] Shortcuts" -ForegroundColor Cyan
foreach ($dir in @((Join-Path $env:PUBLIC 'Desktop'), (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'))) {
    Get-ChildItem $dir -Filter 'PXE Console.lnk' -ErrorAction SilentlyContinue | Remove-Item -Force
    Ok $dir
}

if ($RemoveData) {
    Write-Host "`n[7] Install root" -ForegroundColor Cyan
    if (Test-Path $PxeRoot) { Remove-Item $PxeRoot -Recurse -Force; Ok "deleted $PxeRoot" }
} else {
    Write-Host "`n    (kept $PxeRoot - pass -RemoveData to delete it)" -ForegroundColor Yellow
}

Write-Host "`nDone. Windows features (DHCP / IIS) were left installed." -ForegroundColor Cyan
