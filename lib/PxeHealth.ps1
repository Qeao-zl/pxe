# PxeHealth.ps1 - boot-time self heal for the PXE stack
# Runs from Task Scheduler (SYSTEM) at startup. Settings come from <root>\pxe.config.psd1
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
$log  = Join-Path $root 'logs\health.log'

$conf = @{}
$cfgPath = Join-Path $root 'pxe.config.psd1'
if (Test-Path $cfgPath) {
    try { $conf = Import-PowerShellDataFile -Path $cfgPath } catch { }
}
$ServerIp = if ($conf.ServerIp) { $conf.ServerIp } else { '10.0.0.1' }
$Prefix   = if ($conf.Prefix)   { [int]$conf.Prefix } else { 24 }
$NicAlias = if ($conf.NicAlias) { $conf.NicAlias } else { '' }

function Write-H([string]$m) {
    try { Add-Content -Path $log -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch { }
}

Write-H '--- health check start ---'

# 1. keep the provisioning NIC address
try {
    $has = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $ServerIp }
    if ($has) {
        Write-H "IP $ServerIp present on $($has.InterfaceAlias)"
        $nic = $has.InterfaceAlias
    } else {
        if ($NicAlias) { $nic = $NicAlias }
        else {
            $cand = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
                $_.Status -eq 'Up' -and $_.Virtual -eq $false
            } | Select-Object -First 1
            $nic = if ($cand) { $cand.Name } else { '' }
        }
        if ($nic) {
            Get-NetIPAddress -InterfaceAlias $nic -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -like '169.254.*' } |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceAlias $nic -IPAddress $ServerIp -PrefixLength $Prefix -ErrorAction Stop | Out-Null
            Write-H "added IP $ServerIp on $nic"
        } else { Write-H 'no usable NIC found for provisioning IP' }
    }
    if ($nic) { Set-NetConnectionProfile -InterfaceAlias $nic -NetworkCategory Private -ErrorAction SilentlyContinue }
} catch { Write-H "IP step failed: $($_.Exception.Message)" }

# 2. core services
foreach ($svc in 'DHCPServer', 'W3SVC', 'WinRM') {
    try {
        $s = Get-Service $svc -ErrorAction SilentlyContinue
        if (-not $s) { Write-H "service $svc missing"; continue }
        if ($s.Status -ne 'Running') { Start-Service $svc -ErrorAction Stop; Write-H "started $svc" }
    } catch { Write-H "service $svc failed: $($_.Exception.Message)" }
}

# 3. IIS sites
try {
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $site = Get-Website -Name 'PXE' -ErrorAction SilentlyContinue
    if ($site -and $site.State -ne 'Started') { Start-Website -Name 'PXE'; Write-H 'started site PXE' }
    $def = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
    if ($def -and $def.State -eq 'Started') { Stop-Website -Name 'Default Web Site'; Write-H 'stopped Default Web Site (port 80 conflict)' }
} catch { Write-H "iis step failed: $($_.Exception.Message)" }

# 4. TFTP process
try {
    if (-not (Get-Process tftpd -ErrorAction SilentlyContinue)) {
        Start-ScheduledTask -TaskName 'PXE-TFTP' -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        if (Get-Process tftpd -ErrorAction SilentlyContinue) { Write-H 'started tftpd' } else { Write-H 'tftpd still down' }
    } else { Write-H 'tftpd already running' }
} catch { Write-H "tftp step failed: $($_.Exception.Message)" }

# 5. firewall rules
try {
    foreach ($r in @(
        @{ n = 'PXE-TFTP-69'; p = 'UDP'; port = 69 },
        @{ n = 'PXE-HTTP-80'; p = 'TCP'; port = 80 })) {
        if (-not (Get-NetFirewallRule -DisplayName $r.n -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $r.n -Direction Inbound -Protocol $r.p -LocalPort $r.port -Action Allow -Profile Any | Out-Null
            Write-H "added firewall rule $($r.n)"
        }
    }
} catch { Write-H "firewall step failed: $($_.Exception.Message)" }

Write-H '--- health check done ---'
