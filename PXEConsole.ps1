# PXEConsole.ps1 - PXE 装机控制台（WinForms）
# 启动：双击桌面「PXE 装机控制台」或运行 C:\PXE\PXEConsole.cmd
param([switch]$DryRun, [string]$Screenshot)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $PSScriptRoot 'lib\PxeLib.ps1')

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'PXE 装机控制台'
$form.ClientSize      = New-Object System.Drawing.Size(990, 690)
$form.StartPosition   = 'CenterScreen'
$form.Font            = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.MinimumSize     = New-Object System.Drawing.Size(960, 660)

function New-Label($parent, $text, $x, $y, $w = 100, $h = 22) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.TextAlign = 'MiddleLeft'
    $l.BackColor = [System.Drawing.Color]::Transparent
    $parent.Controls.Add($l)
    return $l
}

function New-Text($parent, $x, $y, $w, $text = '', $h = 25) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y)
    $t.Size = New-Object System.Drawing.Size($w, $h)
    $t.Text = $text
    $parent.Controls.Add($t)
    return $t
}

# ================= 页签 =================
$tabs           = New-Object System.Windows.Forms.TabControl
$tabs.Dock      = 'Top'
$tabs.Height    = 420

$tabSys  = New-Object System.Windows.Forms.TabPage; $tabSys.Text  = '  系统与网络  '
$tabAcc  = New-Object System.Windows.Forms.TabPage; $tabAcc.Text  = '  账号  '
$tabDisk = New-Object System.Windows.Forms.TabPage; $tabDisk.Text = '  分区  '
$tabPkg  = New-Object System.Windows.Forms.TabPage; $tabPkg.Text  = '  软件包  '
$tabs.TabPages.AddRange(@($tabSys, $tabAcc, $tabDisk, $tabPkg))
foreach ($tp in $tabs.TabPages) { $tp.BackColor = [System.Drawing.Color]::White }

# ---------------- 系统与网络 ----------------
[void](New-Label $tabSys '目标架构' 24 28 90)
$cbArch = New-Object System.Windows.Forms.ComboBox
$cbArch.Location = New-Object System.Drawing.Point(130, 25)
$cbArch.Size = New-Object System.Drawing.Size(250, 25)
$cbArch.DropDownStyle = 'DropDownList'
[void]$cbArch.Items.AddRange(@('ARM64 (aarch64 / 鲲鹏 · 飞腾)', 'x64 (x86_64)'))
$cbArch.SelectedIndex = 0
$tabSys.Controls.Add($cbArch)

[void](New-Label $tabSys '操作系统镜像' 24 68 90)
$cbOs = New-Object System.Windows.Forms.ComboBox
$cbOs.Location = New-Object System.Drawing.Point(130, 65)
$cbOs.Size = New-Object System.Drawing.Size(820, 25)
$cbOs.DropDownStyle = 'DropDownList'
$tabSys.Controls.Add($cbOs)

$lblOsInfo = New-Label $tabSys '' 132 94 810
$lblOsInfo.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$lblOsInfo.ForeColor = [System.Drawing.Color]::DimGray
$lblOsInfo.AutoEllipsis = $true

$gbNet = New-Object System.Windows.Forms.GroupBox
$gbNet.Text = '网络配置'
$gbNet.Location = New-Object System.Drawing.Point(24, 128)
$gbNet.Size = New-Object System.Drawing.Size(926, 120)
$tabSys.Controls.Add($gbNet)

$rbDhcp = New-Object System.Windows.Forms.RadioButton
$rbDhcp.Text = 'DHCP 自动获取'; $rbDhcp.Location = New-Object System.Drawing.Point(20, 26)
$rbDhcp.AutoSize = $true; $rbDhcp.Checked = $true
$gbNet.Controls.Add($rbDhcp)

$rbStatic = New-Object System.Windows.Forms.RadioButton
$rbStatic.Text = '静态 IP'; $rbStatic.Location = New-Object System.Drawing.Point(190, 26)
$rbStatic.AutoSize = $true
$gbNet.Controls.Add($rbStatic)

[void](New-Label $gbNet 'IP 地址' 20 70 62)
$tbIp = New-Text $gbNet 92 67 150
$tbIp.Enabled = $false
[void](New-Label $gbNet '子网掩码' 262 70 68)
$tbMask = New-Text $gbNet 338 67 140 '255.255.255.0'
$tbMask.Enabled = $false
[void](New-Label $gbNet '网关' 498 70 40)
$tbGw = New-Text $gbNet 545 67 120 '10.0.0.1'
$tbGw.Enabled = $false
[void](New-Label $gbNet 'DNS' 685 70 36)
$tbDns = New-Text $gbNet 728 67 120 '10.0.0.1'
$tbDns.Enabled = $false

$rbStatic.add_CheckedChanged({
    $on = $rbStatic.Checked
    $tbIp.Enabled = $on; $tbMask.Enabled = $on; $tbGw.Enabled = $on; $tbDns.Enabled = $on
})

[void](New-Label $tabSys '时区' 24 272 90)
$cbTz = New-Object System.Windows.Forms.ComboBox
$cbTz.Location = New-Object System.Drawing.Point(130, 269)
$cbTz.Size = New-Object System.Drawing.Size(250, 25)
$cbTz.DropDownStyle = 'DropDownList'
[void]$cbTz.Items.AddRange(@('Asia/Shanghai', 'Asia/Hong_Kong', 'UTC', 'Asia/Singapore'))
$cbTz.SelectedIndex = 0
$tabSys.Controls.Add($cbTz)

[void](New-Label $tabSys '语言' 430 272 50)
$cbLang = New-Object System.Windows.Forms.ComboBox
$cbLang.Location = New-Object System.Drawing.Point(490, 269)
$cbLang.Size = New-Object System.Drawing.Size(260, 25)
$cbLang.DropDownStyle = 'DropDownList'
[void]$cbLang.Items.AddRange(@('zh_CN.UTF-8', 'en_US.UTF-8'))
$cbLang.SelectedIndex = 0
$tabSys.Controls.Add($cbLang)

# ---------------- 账号 ----------------
[void](New-Label $tabAcc 'root 密码' 24 32 90)
$tbRootPw = New-Text $tabAcc 130 29 280
$tbRootPw.UseSystemPasswordChar = $true

[void](New-Label $tabAcc '确认密码' 24 72 90)
$tbRootPw2 = New-Text $tabAcc 130 69 280
$tbRootPw2.UseSystemPasswordChar = $true

$chkUser = New-Object System.Windows.Forms.CheckBox
$chkUser.Text = '同时创建一个普通管理员账号'
$chkUser.Location = New-Object System.Drawing.Point(24, 115)
$chkUser.AutoSize = $true
$chkUser.BackColor = [System.Drawing.Color]::Transparent
$tabAcc.Controls.Add($chkUser)

[void](New-Label $tabAcc '用户名' 40 155 60)
$tbUser = New-Text $tabAcc 130 152 280 'ops'
$tbUser.Enabled = $false

[void](New-Label $tabAcc '密码' 40 195 60)
$tbUserPw = New-Text $tabAcc 130 192 280
$tbUserPw.UseSystemPasswordChar = $true; $tbUserPw.Enabled = $false

$chkSudo = New-Object System.Windows.Forms.CheckBox
$chkSudo.Text = '加入 wheel 组（可 sudo）'
$chkSudo.Location = New-Object System.Drawing.Point(130, 232)
$chkSudo.AutoSize = $true; $chkSudo.Checked = $true; $chkSudo.Enabled = $false
$chkSudo.BackColor = [System.Drawing.Color]::Transparent
$tabAcc.Controls.Add($chkSudo)

$chkUser.add_CheckedChanged({
    $on = $chkUser.Checked
    $tbUser.Enabled = $on; $tbUserPw.Enabled = $on; $chkSudo.Enabled = $on
})

$lblHint = New-Label $tabAcc '密码以 anaconda --plaintext 方式写入 ks，装完请及时修改。ks 文件在 C:\PXE\www\ks。' 24 285 860 40
$lblHint.ForeColor = [System.Drawing.Color]::DimGray

# ---------------- 分区 ----------------
$rbAutoDisk = New-Object System.Windows.Forms.RadioButton
$rbAutoDisk.Text = '按容量自动识别系统盘'
$rbAutoDisk.Location = New-Object System.Drawing.Point(24, 24)
$rbAutoDisk.AutoSize = $true; $rbAutoDisk.Checked = $true
$rbAutoDisk.BackColor = [System.Drawing.Color]::Transparent
$tabDisk.Controls.Add($rbAutoDisk)

[void](New-Label $tabDisk '容量白名单(GB)' 44 58 105)
$tbRules = New-Text $tabDisk 155 55 120 '480, 960'

[void](New-Label $tabDisk '容差(%)' 292 58 60)
$numTol = New-Object System.Windows.Forms.NumericUpDown
$numTol.Location = New-Object System.Drawing.Point(356, 55)
$numTol.Size = New-Object System.Drawing.Size(60, 25)
$numTol.Minimum = 1; $numTol.Maximum = 30; $numTol.Value = 8
$tabDisk.Controls.Add($numTol)

[void](New-Label $tabDisk '多块命中时' 440 58 82)
$cbMulti = New-Object System.Windows.Forms.ComboBox
$cbMulti.Location = New-Object System.Drawing.Point(526, 55)
$cbMulti.Size = New-Object System.Drawing.Size(140, 25)
$cbMulti.DropDownStyle = 'DropDownList'
[void]$cbMulti.Items.AddRange(@('中止安装', '选最小的', '选最大的'))
$cbMulti.SelectedIndex = 0
$tabDisk.Controls.Add($cbMulti)

$lblDetectHint = New-Label $tabDisk '装机时 %pre 扫 /sys/block 实测容量，白名单之外的盘一律排除' 44 86 620
$lblDetectHint.ForeColor = [System.Drawing.Color]::DimGray
$lblDetectHint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)

$rbFixedDisk = New-Object System.Windows.Forms.RadioButton
$rbFixedDisk.Text = '指定磁盘'
$rbFixedDisk.Location = New-Object System.Drawing.Point(24, 116)
$rbFixedDisk.AutoSize = $true
$rbFixedDisk.BackColor = [System.Drawing.Color]::Transparent
$tabDisk.Controls.Add($rbFixedDisk)

$tbDisk = New-Text $tabDisk 155 113 150 '/dev/sda'
$tbDisk.Enabled = $false

$rbAutoDisk.add_CheckedChanged({
    $on = $rbAutoDisk.Checked
    $tbRules.Enabled = $on; $numTol.Enabled = $on; $cbMulti.Enabled = $on
    $tbDisk.Enabled = -not $on
})

$gbPart = New-Object System.Windows.Forms.GroupBox
$gbPart.Text = '分区方案'
$gbPart.Location = New-Object System.Drawing.Point(24, 148)
$gbPart.Size = New-Object System.Drawing.Size(926, 58)
$tabDisk.Controls.Add($gbPart)

$rbAuto = New-Object System.Windows.Forms.RadioButton
$rbAuto.Text = '自动分区（EFI + boot + swap + /）'
$rbAuto.Location = New-Object System.Drawing.Point(15, 22)
$rbAuto.AutoSize = $true; $rbAuto.Checked = $true
$gbPart.Controls.Add($rbAuto)

$rbManual = New-Object System.Windows.Forms.RadioButton
$rbManual.Text = '自定义分区'
$rbManual.Location = New-Object System.Drawing.Point(300, 22)
$rbManual.AutoSize = $true
$gbPart.Controls.Add($rbManual)

[void](New-Label $gbPart 'swap(GB)' 430 22 62)
$numSwap = New-Object System.Windows.Forms.NumericUpDown
$numSwap.Location = New-Object System.Drawing.Point(496, 19)
$numSwap.Size = New-Object System.Drawing.Size(60, 25)
$numSwap.Minimum = 0; $numSwap.Maximum = 256; $numSwap.Value = 4
$gbPart.Controls.Add($numSwap)

$chkClear = New-Object System.Windows.Forms.CheckBox
$chkClear.Text = '安装前清空磁盘'
$chkClear.Location = New-Object System.Drawing.Point(600, 22)
$chkClear.AutoSize = $true; $chkClear.Checked = $true
$chkClear.BackColor = [System.Drawing.Color]::Transparent
$gbPart.Controls.Add($chkClear)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(24, 214)
$grid.Size = New-Object System.Drawing.Size(926, 148)
$grid.AllowUserToAddRows = $false
$grid.RowHeadersVisible = $false
$grid.AutoSizeColumnsMode = 'Fill'
$grid.EditMode = 'EditOnEnter'
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.Enabled = $false
$tabDisk.Controls.Add($grid)

$dt = New-Object System.Data.DataTable
[void]$dt.Columns.Add('挂载点', [string])
[void]$dt.Columns.Add('大小MB', [int])
[void]$dt.Columns.Add('文件系统', [string])
[void]$dt.Columns.Add('用剩余空间', [bool])
foreach ($row in @(
    @('/boot/efi', 600, 'efi', $false),
    @('/boot', 1024, 'xfs', $false),
    @('swap', 4096, 'swap', $false),
    @('/', 0, 'xfs', $true))) {
    $r = $dt.NewRow()
    $r['挂载点'] = $row[0]; $r['大小MB'] = $row[1]; $r['文件系统'] = $row[2]; $r['用剩余空间'] = $row[3]
    [void]$dt.Rows.Add($r)
}
$grid.DataSource = $dt

$btnAddRow = New-Object System.Windows.Forms.Button
$btnAddRow.Text = '添加分区'; $btnAddRow.Location = New-Object System.Drawing.Point(24, 370)
$btnAddRow.Size = New-Object System.Drawing.Size(100, 28); $btnAddRow.Enabled = $false
$tabDisk.Controls.Add($btnAddRow)
$btnAddRow.add_Click({
    $r = $dt.NewRow(); $r['挂载点'] = '/data'; $r['大小MB'] = 10240; $r['文件系统'] = 'xfs'; $r['用剩余空间'] = $false
    [void]$dt.Rows.Add($r)
})

$btnDelRow = New-Object System.Windows.Forms.Button
$btnDelRow.Text = '删除选中'; $btnDelRow.Location = New-Object System.Drawing.Point(134, 370)
$btnDelRow.Size = New-Object System.Drawing.Size(100, 28); $btnDelRow.Enabled = $false
$tabDisk.Controls.Add($btnDelRow)
$btnDelRow.add_Click({
    if ($grid.CurrentRow) { $grid.Rows.Remove($grid.CurrentRow) }
})

$rbManual.add_CheckedChanged({
    $on = $rbManual.Checked
    $grid.Enabled = $on; $btnAddRow.Enabled = $on; $btnDelRow.Enabled = $on
    $numSwap.Enabled = -not $on
})

# ---------------- 软件包 ----------------
$rbMin = New-Object System.Windows.Forms.RadioButton
$rbMin.Text = '最小化安装（无图形界面）'
$rbMin.Location = New-Object System.Drawing.Point(24, 22)
$rbMin.AutoSize = $true; $rbMin.Checked = $true
$rbMin.BackColor = [System.Drawing.Color]::Transparent
$tabPkg.Controls.Add($rbMin)

$rbGui = New-Object System.Windows.Forms.RadioButton
$rbGui.Text = '服务器带图形界面'
$rbGui.Location = New-Object System.Drawing.Point(24, 56)
$rbGui.AutoSize = $true
$rbGui.BackColor = [System.Drawing.Color]::Transparent
$tabPkg.Controls.Add($rbGui)

$rbCust = New-Object System.Windows.Forms.RadioButton
$rbCust.Text = '自定义软件包（一行一个，@ 开头表示组）'
$rbCust.Location = New-Object System.Drawing.Point(24, 90)
$rbCust.AutoSize = $true
$rbCust.BackColor = [System.Drawing.Color]::Transparent
$tabPkg.Controls.Add($rbCust)

$tbPkg = New-Object System.Windows.Forms.TextBox
$tbPkg.Location = New-Object System.Drawing.Point(24, 120)
$tbPkg.Size = New-Object System.Drawing.Size(926, 270)
$tbPkg.Multiline = $true; $tbPkg.ScrollBars = 'Vertical'; $tbPkg.Enabled = $false
$tbPkg.Font = New-Object System.Drawing.Font('Consolas', 9)
$tbPkg.Text = "vim`r`ntar`r`nnet-tools`r`nchrony"
$tabPkg.Controls.Add($tbPkg)

$rbCust.add_CheckedChanged({ $tbPkg.Enabled = $rbCust.Checked })

# ================= 底部 =================
$bottomBar = New-Object System.Windows.Forms.Panel
$bottomBar.Dock = 'Bottom'
$bottomBar.Height = 40

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(8, 10)
$lblStatus.Size = New-Object System.Drawing.Size(520, 20)
$lblStatus.Font = New-Object System.Drawing.Font('Consolas', 9)
$lblStatus.BackColor = [System.Drawing.Color]::Transparent
$bottomBar.Controls.Add($lblStatus)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新状态'; $btnRefresh.Size = New-Object System.Drawing.Size(84, 28)
$btnRefresh.Location = New-Object System.Drawing.Point(540, 6)
$bottomBar.Controls.Add($btnRefresh)

$btnKsDir = New-Object System.Windows.Forms.Button
$btnKsDir.Text = '打开 ks 目录'; $btnKsDir.Size = New-Object System.Drawing.Size(100, 28)
$btnKsDir.Location = New-Object System.Drawing.Point(630, 6)
$bottomBar.Controls.Add($btnKsDir)
$btnKsDir.add_Click({ Start-Process explorer.exe 'C:\PXE\www\ks' })

$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text = '生成 ks 并应用到 PXE'
$btnApply.Size = New-Object System.Drawing.Size(190, 28)
$btnApply.Location = New-Object System.Drawing.Point(740, 6)
$btnApply.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnApply.ForeColor = [System.Drawing.Color]::White
$btnApply.FlatStyle = 'Flat'
$bottomBar.Controls.Add($btnApply)

$log = New-Object System.Windows.Forms.TextBox
$log.Dock = 'Fill'
$log.Multiline = $true; $log.ScrollBars = 'Vertical'; $log.ReadOnly = $true
$log.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$log.BackColor = [System.Drawing.Color]::WhiteSmoke
$log.BorderStyle = 'FixedSingle'

$form.Controls.Add($log)
$form.Controls.Add($bottomBar)
$form.Controls.Add($tabs)

function Write-Log([string]$msg) {
    $log.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $msg`r`n")
}

function Update-Status {
    try {
        $s = Get-PxeStatus
        $lblStatus.Text = "DHCP=$($s.Dhcp)  IIS=$($s.Iis)  Site=$($s.Site)  TFTP=$($s.Tftp)"
        $lblStatus.ForeColor = if ($s.Dhcp -eq 'Running' -and $s.Site -eq 'Started' -and $s.Tftp -like 'running*') {
            [System.Drawing.Color]::DarkGreen
        } else { [System.Drawing.Color]::Firebrick }
    } catch { $lblStatus.Text = "状态读取失败: $($_.Exception.Message)" }
}

function Update-OsList {
    $arch = if ($cbArch.SelectedIndex -eq 0) { 'arm64' } else { 'x64' }
    $cbOs.Items.Clear()
    $script:osMap = @{}
    foreach ($o in (Get-PxeOsList)) {
        if ((Get-ArchNorm $o.Arch) -ne $arch) { continue }
        $txt = "$($o.Name) [$($o.Version)]"
        [void]$cbOs.Items.Add($txt)
        $script:osMap[$txt] = $o
    }
    if ($cbOs.Items.Count -gt 0) { $cbOs.SelectedIndex = 0 } else {
        [void]$cbOs.Items.Add("（没有 $arch 架构的镜像，请先导入）")
        $cbOs.SelectedIndex = 0
    }
}

$cbOs.add_SelectedIndexChanged({
    $txt = [string]$cbOs.SelectedItem
    if ($script:osMap -and $script:osMap.ContainsKey($txt)) {
        $o = $script:osMap[$txt]
        $lblOsInfo.Text = "$($o.HttpBase)   [$($o.Type)]   $($o.Family)"
    } else { $lblOsInfo.Text = '' }
})

$btnRefresh.add_Click({ Update-Status })

function New-ConfigFromUi {
    $arch = if ($cbArch.SelectedIndex -eq 0) { 'arm64' } else { 'x64' }
    $txt = [string]$cbOs.SelectedItem
    if (-not ($script:osMap.ContainsKey($txt))) { throw '请选择一个有效的操作系统镜像' }
    $os = $script:osMap[$txt]

    if (-not $tbRootPw.Text) { throw 'root 密码不能为空（在「账号」页签填写）' }
    if ($tbRootPw.Text -ne $tbRootPw2.Text) { throw '两次输入的 root 密码不一致' }

    $parts = @()
    if ($rbManual.Checked) {
        foreach ($row in $dt.Rows) {
            if ($row.RowState -eq 'Deleted') { continue }
            $m = [string]$row['挂载点']
            if (-not $m) { continue }
            if ($m -ne 'swap' -and -not $m.StartsWith('/')) { throw "分区挂载点必须以 / 开头: $m" }
            $parts += @{
                Mount  = $m
                SizeMB = [int]$row['大小MB']
                Fstype = [string]$row['文件系统']
                Grow   = [bool]$row['用剩余空间']
            }
        }
        if ($parts.Count -eq 0) { throw '自定义分区至少要有一行' }
        if (-not ($parts | Where-Object { $_.Mount -eq '/' })) { throw '自定义分区缺少根分区 /' }
    }

    $cfg = @{
        Os            = $os
        Arch          = $arch
        Label         = "$([IO.Path]::GetFileNameWithoutExtension($os.Slug))-$([datetime]::Now.ToString('MMdd-HHmm'))"
        Hostname      = ''
        Locale        = [string]$cbLang.SelectedItem
        Timezone      = [string]$cbTz.SelectedItem
        RootPassword  = $tbRootPw.Text
        CreateUser    = [bool]$chkUser.Checked
        UserName      = $tbUser.Text.Trim()
        UserPassword  = $tbUserPw.Text
        UserSudo      = [bool]$chkSudo.Checked
        NetMode       = if ($rbStatic.Checked) { 'static' } else { 'dhcp' }
        Ip            = $tbIp.Text.Trim()
        Netmask       = $tbMask.Text.Trim()
        Gateway       = $tbGw.Text.Trim()
        Dns           = $tbDns.Text.Trim()
        DiskSelect    = if ($rbAutoDisk.Checked) { 'auto' } else { 'fixed' }
        Disk          = $tbDisk.Text.Trim()
        ClearDisk     = [bool]$chkClear.Checked
        SizeRules     = (($tbRules.Text -replace ',', ' ') -replace '\s+', ' ').Trim()
        SizeTolerance = [int]$numTol.Value
        MultiPolicy   = switch ($cbMulti.SelectedIndex) { 0 { 'abort' } 1 { 'min' } 2 { 'max' } }
        PartMode      = if ($rbManual.Checked) { 'manual' } else { 'auto' }
        Parts         = $parts
        PkgMode       = if ($rbCust.Checked) { 'custom' } elseif ($rbGui.Checked) { 'gui' } else { 'minimal' }
        Packages      = $tbPkg.Text
        SwapGB        = [int]$numSwap.Value
    }

    if ($cfg.DiskSelect -eq 'auto') {
        if ($cfg.SizeRules -notmatch '^\d+(\s+\d+)*$') { throw '容量白名单格式不对，应形如 480 960' }
    } elseif (-not $cfg.Disk) {
        throw '指定磁盘时磁盘名不能为空'
    }
    if ($cfg.CreateUser) {
        if (-not $cfg.UserName) { throw '指定了普通用户但用户名为空' }
        if (-not $cfg.UserPassword) { throw '指定了普通用户但密码为空' }
    }
    if ($cfg.NetMode -eq 'static') {
        if ($cfg.Ip -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw '静态 IP 格式不对' }
        if ($cfg.Netmask -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw '子网掩码格式不对' }
    }
    return $cfg
}

$btnApply.add_Click({
    try {
        if (-not $isAdmin) { throw '需要以管理员身份运行' }
        $cfg = New-ConfigFromUi
        $file = New-KickstartFile -Config $cfg
        Write-Log "已生成 kickstart: $file"

        $menu = Update-GrubMenu -DefaultKs (Split-Path $file -Leaf)
        Write-Log "GRUB 菜单已更新: 共 $($menu.Count) 项，默认第 $($menu.Default + 1) 项"

        $nbp = Set-PxeBootArch -Arch $cfg.Arch
        Write-Log "DHCP 引导文件已设为: $nbp"

        Update-Status
        [void][System.Windows.Forms.MessageBox]::Show(
            "生成成功！`n`nks 文件: $file`n菜单默认项: 第 $($menu.Default + 1) 项`n引导文件: $nbp`n`n客户端 PXE 启动后 8 秒自动进入该项并全自动安装，无需任何操作。",
            'PXE 装机控制台', 'OK', 'Information')
    } catch {
        Write-Log "错误: $($_.Exception.Message)"
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '出错了', 'OK', 'Warning')
    }
})

Initialize-PxePaths
Update-OsList
Update-Status
$cbArch.add_SelectedIndexChanged({ Update-OsList; Update-Status })

if ($DryRun) {
    Write-Output "DryRun OK: form built, os=$($cbOs.Items.Count), status=$($lblStatus.Text)"
    $form.Dispose()
    return
}

if ($Screenshot) {
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(-4000, -4000)
    $form.ShowInTaskbar = $false
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 600
    $dir = Split-Path $Screenshot -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
    $i = 0
    foreach ($tp in $tabs.TabPages) {
        $tabs.SelectedTab = $tp
        $form.PerformLayout()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 400
        $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $out = [IO.Path]::Combine($dir, ("tab{0}.png" -f $i))
        $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Write-Output "saved $out"
        $i++
    }
    $form.Close()
    $form.Dispose()
    return
}

if (-not $isAdmin) {
    [void][System.Windows.Forms.MessageBox]::Show('请右键「以管理员身份运行」本工具，否则无法修改 DHCP 和菜单。', '权限不足', 'OK', 'Warning')
}

[void]$form.ShowDialog()
