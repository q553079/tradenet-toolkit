[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $PSScriptRoot "TradeNet.Common.ps1")

$script:Config = Get-TradeNetConfig
$script:DashboardLogContext = New-TradeNetLogContext -Config $script:Config -Prefix "dashboard"
$script:IsBusy = $false
$script:FailureCount = 0
$script:LastRecoveryAt = [datetime]::MinValue
$script:LatestStatus = $null

function Set-ValueAppearance {
    param(
        [System.Windows.Forms.Label]$Label,
        [string]$Text,
        [ValidateSet("Normal", "Good", "Warn", "Bad")]
        [string]$Kind = "Normal"
    )

    $Label.Text = $Text
    $Label.ForeColor = switch ($Kind) {
        "Good" { [System.Drawing.Color]::FromArgb(22, 120, 28) }
        "Warn" { [System.Drawing.Color]::FromArgb(184, 120, 0) }
        "Bad" { [System.Drawing.Color]::FromArgb(180, 32, 32) }
        default { [System.Drawing.Color]::FromArgb(32, 32, 32) }
    }
}

function Show-TradeNetError {
    param([string]$Message)

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        "TradeNet",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Open-TradeNetFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Show-TradeNetError -Message ("文件不存在: {0}" -f $Path)
        return
    }

    Start-Process -FilePath "notepad.exe" -ArgumentList $Path | Out-Null
}

function Invoke-TradeNetUiAction {
    param(
        [string]$ActionName,
        [scriptblock]$Action
    )

    if ($script:IsBusy) {
        return
    }

    $script:IsBusy = $true
    $timer.Stop()
    $form.UseWaitCursor = $true
    $btnStart.Enabled = $false
    $btnStop.Enabled = $false
    $btnRefresh.Enabled = $false
    $btnBuildSplit.Enabled = $false
    Set-ValueAppearance -Label $lblAction -Text ("执行中: {0}" -f $ActionName) -Kind "Warn"

    try {
        Enter-TradeNetLock -Config $script:Config
        & $Action
        $script:FailureCount = 0
        Set-ValueAppearance -Label $lblAction -Text ("完成: {0}" -f $ActionName) -Kind "Good"
    } catch {
        Write-TradeNetLog -Message ("{0} 失败: {1}" -f $ActionName, $_.Exception.Message) -Path $script:DashboardLogContext.MainLog -Level "ERROR"
        Set-ValueAppearance -Label $lblAction -Text ("失败: {0}" -f $ActionName) -Kind "Bad"
        Show-TradeNetError -Message $_.Exception.Message
    } finally {
        Exit-TradeNetLock
        $script:IsBusy = $false
        $form.UseWaitCursor = $false
        $btnStart.Enabled = $true
        $btnStop.Enabled = $true
        $btnRefresh.Enabled = $true
        $btnBuildSplit.Enabled = $true
        Refresh-TradeNetDashboard
        $timer.Start()
    }
}

function Get-StatusReasonText {
    param([object[]]$Reasons)

    if (-not $Reasons -or $Reasons.Count -eq 0) {
        return "无"
    }

    return ($Reasons -join "；")
}

function Handle-AutoRestart {
    param([pscustomobject]$Status)

    if (-not $chkAutoRestart.Checked) {
        $script:FailureCount = 0
        Set-ValueAppearance -Label $lblAutoRestart -Text "自动重启: 已关闭" -Kind "Normal"
        return
    }

    if ($Status.ManualStopRequested) {
        $script:FailureCount = 0
        Set-ValueAppearance -Label $lblAutoRestart -Text "自动重启: 已暂停（手动停止保护）" -Kind "Warn"
        return
    }

    if (-not $Status.AutoRestartEligible) {
        $script:FailureCount = 0
        Set-ValueAppearance -Label $lblAutoRestart -Text ("自动重启: 监控中（阈值 {0} 次）" -f $script:Config.AutoRestartThreshold) -Kind "Good"
        return
    }

    $script:FailureCount += 1
    $cooldownRemaining = [math]::Ceiling(($script:LastRecoveryAt.AddSeconds($script:Config.AutoRestartCooldown) - (Get-Date)).TotalSeconds)
    if ($cooldownRemaining -gt 0) {
        Set-ValueAppearance -Label $lblAutoRestart -Text ("自动重启: 冷却中，剩余 {0}s" -f $cooldownRemaining) -Kind "Warn"
        return
    }

    if ($script:FailureCount -lt $script:Config.AutoRestartThreshold) {
        Set-ValueAppearance -Label $lblAutoRestart -Text ("自动重启: 异常计数 {0}/{1}" -f $script:FailureCount, $script:Config.AutoRestartThreshold) -Kind "Warn"
        return
    }

    $script:FailureCount = 0
    $script:LastRecoveryAt = Get-Date
    Write-TradeNetLog -Message ("检测到异常状态，执行自动恢复。原因: {0}" -f (Get-StatusReasonText -Reasons $Status.Reasons)) -Path $script:DashboardLogContext.MainLog -Level "WARN"

    Invoke-TradeNetUiAction -ActionName "自动恢复" -Action {
        $logContext = New-TradeNetLogContext -Config $script:Config -Prefix "autofix"
        Start-TradeNetStack `
            -Config $script:Config `
            -LogContext $logContext `
            -OpenWireGuardGui:$script:Config.OpenWireGuardGui `
            -OpenPingWindows:$script:Config.OpenPingWindows | Out-Null
    }
}

function Refresh-TradeNetDashboard {
    $status = Get-TradeNetRuntimeStatus -Config $script:Config
    $splitStatus = Get-TradeNetSplitRoutingStatus -Config $script:Config
    $script:LatestStatus = $status

    if ($status.ManualStopRequested) {
        Set-ValueAppearance -Label $lblOverall -Text "当前状态: 已手动停止" -Kind "Warn"
        Set-ValueAppearance -Label $lblSummary -Text "自动恢复已暂停，点击“启动”后会清除手动停止保护。" -Kind "Warn"
    } elseif ($status.Healthy) {
        Set-ValueAppearance -Label $lblOverall -Text "当前状态: 通道正常" -Kind "Good"
        Set-ValueAppearance -Label $lblSummary -Text "udp2raw、WireGuard 服务、本地监听和网关连通性都正常。" -Kind "Good"
    } else {
        Set-ValueAppearance -Label $lblOverall -Text "当前状态: 通道异常" -Kind "Bad"
        Set-ValueAppearance -Label $lblSummary -Text (Get-StatusReasonText -Reasons $status.Reasons) -Kind "Bad"
    }

    $lblLastRefresh.Text = "最近刷新: {0}" -f $status.Timestamp.ToString("yyyy-MM-dd HH:mm:ss")

    Set-ValueAppearance -Label $statusLabels["Route"] -Text ($(if ($status.RouteOk) { "OK" } else { "缺失" })) -Kind ($(if ($status.RouteOk) { "Good" } else { "Bad" }))
    Set-ValueAppearance -Label $statusLabels["Udp2raw"] -Text ($(if ($status.Udp2rawRunning) { "运行中 (PID: $($status.Udp2rawPidText))" } else { "未运行" })) -Kind ($(if ($status.Udp2rawRunning) { "Good" } else { "Bad" }))
    Set-ValueAppearance -Label $statusLabels["Listener"] -Text ($(if ($status.ListenerBound) { $script:Config.Udp2rawListen } else { "$($script:Config.Udp2rawListen) 未监听" })) -Kind ($(if ($status.ListenerBound) { "Good" } else { "Bad" }))
    Set-ValueAppearance -Label $statusLabels["WgService"] -Text $status.WireGuardServiceState -Kind ($(if ($status.WireGuardServiceState -eq "RUNNING") { "Good" } else { "Bad" }))
    Set-ValueAppearance -Label $statusLabels["WgCli"] -Text $status.WireGuardCliState -Kind ($(if ($status.WireGuardCliState -eq "CONNECTED") { "Good" } else { "Warn" }))
    Set-ValueAppearance -Label $statusLabels["GatewayPing"] -Text $status.GatewayPingText -Kind ($(if ($status.GatewayPingOk) { "Good" } else { "Bad" }))
    Set-ValueAppearance -Label $statusLabels["InternetPing"] -Text $status.InternetPingText -Kind ($(if ($status.InternetPingOk) { "Good" } else { "Warn" }))
    Set-ValueAppearance -Label $statusLabels["Handshake"] -Text ($(if ($status.HandshakeLine) { $status.HandshakeLine } else { "未检测到握手" })) -Kind ($(if ($status.HandshakeLine) { "Good" } else { "Warn" }))
    Set-ValueAppearance -Label $statusLabels["Transfer"] -Text ($(if ($status.TransferLine) { $status.TransferLine } else { "暂无流量信息" })) -Kind "Normal"
    Set-ValueAppearance -Label $statusLabels["Reasons"] -Text (Get-StatusReasonText -Reasons $status.Reasons) -Kind ($(if ($status.Healthy) { "Good" } else { "Warn" }))
    Set-ValueAppearance -Label $statusLabels["SplitRouting"] -Text $splitStatus.Summary -Kind ($(if ($splitStatus.ValidationPassed) { "Good" } elseif ($splitStatus.ProfileReady) { "Warn" } else { "Bad" }))

    $activeLogPath = Resolve-TradeNetActiveLogPath -Config $script:Config -FallbackPath $script:DashboardLogContext.MainLog
    Set-ValueAppearance -Label $statusLabels["LogPath"] -Text $activeLogPath -Kind "Normal"
    $txtLogs.Text = Get-TradeNetTailText -Path $activeLogPath -LineCount 80

    $splitGeneratedText = if ($splitStatus.GeneratedAt) { $splitStatus.GeneratedAt.ToString("yyyy-MM-dd HH:mm:ss") } else { "未生成" }
    Set-ValueAppearance -Label $lblSplit -Text ("分流配置: {0} | 最近校验: {1}" -f $splitStatus.Summary, $splitGeneratedText) -Kind ($(if ($splitStatus.ValidationPassed) { "Good" } elseif ($splitStatus.ProfileReady) { "Warn" } else { "Bad" }))

    $btnBuildSplit.Enabled = $splitStatus.ProfileReady -and $splitStatus.MihomoExists
    $btnOpenSplitProfile.Enabled = $splitStatus.ProfileExists
    $btnOpenSplitConfig.Enabled = $splitStatus.ConfigExists
    $btnOpenSplitDocs.Enabled = Test-Path -LiteralPath $splitStatus.DocsPath

    if (-not $script:IsBusy) {
        Handle-AutoRestart -Status $status
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "TradeNet Control Center"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(1040, 780)
$form.MinimumSize = New-Object System.Drawing.Size(980, 720)
$form.BackColor = [System.Drawing.Color]::FromArgb(247, 248, 250)
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9.5)

$mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
$mainLayout.Dock = "Fill"
$mainLayout.Padding = New-Object System.Windows.Forms.Padding(14)
$mainLayout.ColumnCount = 1
$mainLayout.RowCount = 3
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 138)))
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 320)))
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$form.Controls.Add($mainLayout)

$topCard = New-Object System.Windows.Forms.Panel
$topCard.Dock = "Fill"
$topCard.BackColor = [System.Drawing.Color]::White
$topCard.Padding = New-Object System.Windows.Forms.Padding(18, 16, 18, 14)
$mainLayout.Controls.Add($topCard, 0, 0)

$lblOverall = New-Object System.Windows.Forms.Label
$lblOverall.Location = New-Object System.Drawing.Point(16, 14)
$lblOverall.Size = New-Object System.Drawing.Size(400, 32)
$lblOverall.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 16, [System.Drawing.FontStyle]::Bold)
$topCard.Controls.Add($lblOverall)

$lblSummary = New-Object System.Windows.Forms.Label
$lblSummary.Location = New-Object System.Drawing.Point(18, 50)
$lblSummary.Size = New-Object System.Drawing.Size(560, 22)
$topCard.Controls.Add($lblSummary)

$lblLastRefresh = New-Object System.Windows.Forms.Label
$lblLastRefresh.Location = New-Object System.Drawing.Point(18, 78)
$lblLastRefresh.Size = New-Object System.Drawing.Size(320, 22)
$lblLastRefresh.ForeColor = [System.Drawing.Color]::FromArgb(96, 96, 96)
$topCard.Controls.Add($lblLastRefresh)

$rightPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$rightPanel.Dock = "Right"
$rightPanel.Width = 470
$rightPanel.FlowDirection = "TopDown"
$rightPanel.WrapContents = $false
$topCard.Controls.Add($rightPanel)

$chkAutoRestart = New-Object System.Windows.Forms.CheckBox
$chkAutoRestart.Text = "启用断线自动重启"
$chkAutoRestart.AutoSize = $true
$chkAutoRestart.Checked = [bool]$script:Config.AutoRestartEnabled
$rightPanel.Controls.Add($chkAutoRestart)

$lblAutoRestart = New-Object System.Windows.Forms.Label
$lblAutoRestart.Size = New-Object System.Drawing.Size(360, 24)
$rightPanel.Controls.Add($lblAutoRestart)

$lblAction = New-Object System.Windows.Forms.Label
$lblAction.Size = New-Object System.Drawing.Size(360, 24)
$rightPanel.Controls.Add($lblAction)

$lblSplit = New-Object System.Windows.Forms.Label
$lblSplit.Size = New-Object System.Drawing.Size(440, 38)
$lblSplit.MaximumSize = New-Object System.Drawing.Size(440, 0)
$rightPanel.Controls.Add($lblSplit)

$buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonPanel.AutoSize = $true
$buttonPanel.WrapContents = $true
$buttonPanel.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
$rightPanel.Controls.Add($buttonPanel)

function New-ActionButton {
    param([string]$Text)

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Size = New-Object System.Drawing.Size(110, 34)
    $button.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 8)
    return $button
}

$btnStart = New-ActionButton -Text "启动"
$btnStop = New-ActionButton -Text "停止"
$btnRefresh = New-ActionButton -Text "刷新"
$btnOpenWireGuard = New-ActionButton -Text "打开 WireGuard"
$btnOpenLogs = New-ActionButton -Text "日志目录"
$btnOpenCurrentLog = New-ActionButton -Text "当前日志"
$btnBuildSplit = New-ActionButton -Text "构建分流"
$btnOpenSplitProfile = New-ActionButton -Text "分流Profile"
$btnOpenSplitConfig = New-ActionButton -Text "分流YAML"
$btnOpenSplitDocs = New-ActionButton -Text "分流说明"

$buttonPanel.Controls.AddRange(@($btnStart, $btnStop, $btnRefresh, $btnOpenWireGuard, $btnOpenLogs, $btnOpenCurrentLog, $btnBuildSplit, $btnOpenSplitProfile, $btnOpenSplitConfig, $btnOpenSplitDocs))

$bodyLayout = New-Object System.Windows.Forms.TableLayoutPanel
$bodyLayout.Dock = "Fill"
$bodyLayout.ColumnCount = 2
$bodyLayout.RowCount = 1
$bodyLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 68)))
$bodyLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 32)))
$mainLayout.Controls.Add($bodyLayout, 0, 1)

$statusGroup = New-Object System.Windows.Forms.GroupBox
$statusGroup.Text = "实时状态"
$statusGroup.Dock = "Fill"
$statusGroup.BackColor = [System.Drawing.Color]::White
$bodyLayout.Controls.Add($statusGroup, 0, 0)

$statusTable = New-Object System.Windows.Forms.TableLayoutPanel
$statusTable.Dock = "Fill"
$statusTable.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 12)
$statusTable.ColumnCount = 2
$statusTable.RowCount = 12
$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 150)))
$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$statusGroup.Controls.Add($statusTable)

$statusLabels = @{}

function Add-StatusRow {
    param(
        [string]$Key,
        [string]$Title,
        [int]$RowIndex
    )

    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = $Title
    $nameLabel.AutoSize = $true
    $nameLabel.Margin = New-Object System.Windows.Forms.Padding(0, 6, 8, 6)
    $nameLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9.5, [System.Drawing.FontStyle]::Bold)

    $valueLabel = New-Object System.Windows.Forms.Label
    $valueLabel.AutoSize = $true
    $valueLabel.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
    $valueLabel.MaximumSize = New-Object System.Drawing.Size(520, 0)

    $statusTable.Controls.Add($nameLabel, 0, $RowIndex)
    $statusTable.Controls.Add($valueLabel, 1, $RowIndex)
    $statusLabels[$Key] = $valueLabel
}

Add-StatusRow -Key "Route" -Title "VPS 路由" -RowIndex 0
Add-StatusRow -Key "Udp2raw" -Title "udp2raw" -RowIndex 1
Add-StatusRow -Key "Listener" -Title "本地监听" -RowIndex 2
Add-StatusRow -Key "WgService" -Title "WireGuard 服务" -RowIndex 3
Add-StatusRow -Key "WgCli" -Title "WireGuard CLI" -RowIndex 4
Add-StatusRow -Key "GatewayPing" -Title "WG 网关延迟" -RowIndex 5
Add-StatusRow -Key "InternetPing" -Title "公网延迟" -RowIndex 6
Add-StatusRow -Key "Handshake" -Title "最近握手" -RowIndex 7
Add-StatusRow -Key "Transfer" -Title "流量" -RowIndex 8
Add-StatusRow -Key "Reasons" -Title "异常原因" -RowIndex 9
Add-StatusRow -Key "SplitRouting" -Title "分流模式" -RowIndex 10
Add-StatusRow -Key "LogPath" -Title "当前日志" -RowIndex 11

$opsGroup = New-Object System.Windows.Forms.GroupBox
$opsGroup.Text = "说明"
$opsGroup.Dock = "Fill"
$opsGroup.BackColor = [System.Drawing.Color]::White
$bodyLayout.Controls.Add($opsGroup, 1, 0)

$opsText = New-Object System.Windows.Forms.TextBox
$opsText.Dock = "Fill"
$opsText.Multiline = $true
$opsText.ReadOnly = $true
$opsText.BorderStyle = "None"
$opsText.BackColor = [System.Drawing.Color]::White
$opsText.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9.5)
$opsText.Text = @"
1. “启动”会清除手动停止保护，并重新拉起 udp2raw + WireGuard 服务。
2. “停止”会中断当前通道，并写入手动停止保护，防止自动重启立刻把它拉起。
3. 自动重启只有在连续多次检测到异常后才会触发，并带冷却时间，避免抖动时频繁重启。
4. “构建分流”会基于 TradeNet.SplitRouting.psd1 生成并校验 Mihomo YAML，但不会立即切换当前流量。
5. 分流模式切换前，不要让当前全局 WireGuard 服务和 Mihomo TUN 同时接管业务流量。
6. 仪表盘关闭后不会自动执行恢复；如果你需要后台守护，可以继续使用控制台版 Monitor。
"@
$opsGroup.Controls.Add($opsText)

$logGroup = New-Object System.Windows.Forms.GroupBox
$logGroup.Text = "最近日志"
$logGroup.Dock = "Fill"
$logGroup.BackColor = [System.Drawing.Color]::White
$mainLayout.Controls.Add($logGroup, 0, 2)

$txtLogs = New-Object System.Windows.Forms.TextBox
$txtLogs.Dock = "Fill"
$txtLogs.Multiline = $true
$txtLogs.ReadOnly = $true
$txtLogs.ScrollBars = "Vertical"
$txtLogs.Font = New-Object System.Drawing.Font("Consolas", 10)
$logGroup.Controls.Add($txtLogs)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [int]($script:Config.MonitorRefreshSeconds * 1000)
$timer.Add_Tick({
    if (-not $script:IsBusy) {
        Refresh-TradeNetDashboard
    }
})

$btnRefresh.Add_Click({
    Refresh-TradeNetDashboard
})

$btnStart.Add_Click({
    Invoke-TradeNetUiAction -ActionName "启动" -Action {
        $logContext = New-TradeNetLogContext -Config $script:Config -Prefix "start"
        Start-TradeNetStack `
            -Config $script:Config `
            -LogContext $logContext `
            -OpenWireGuardGui:$script:Config.OpenWireGuardGui `
            -OpenPingWindows:$script:Config.OpenPingWindows | Out-Null
    }
})

$btnStop.Add_Click({
    $result = [System.Windows.Forms.MessageBox]::Show(
        "停止会断开当前通道。确认继续？",
        "TradeNet",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    Invoke-TradeNetUiAction -ActionName "停止" -Action {
        $logContext = New-TradeNetLogContext -Config $script:Config -Prefix "stop"
        Stop-TradeNetStack -Config $script:Config -LogPath $logContext.MainLog
    }
})

$btnOpenWireGuard.Add_Click({
    if (Test-Path -LiteralPath $script:Config.WireGuardGui) {
        Start-Process -FilePath $script:Config.WireGuardGui | Out-Null
    } else {
        Show-TradeNetError -Message ("未找到 WireGuard GUI: {0}" -f $script:Config.WireGuardGui)
    }
})

$btnOpenLogs.Add_Click({
    Ensure-TradeNetDirectory -Path $script:Config.LogDir
    Start-Process -FilePath "explorer.exe" -ArgumentList $script:Config.LogDir | Out-Null
})

$btnOpenCurrentLog.Add_Click({
    $activeLogPath = Resolve-TradeNetActiveLogPath -Config $script:Config -FallbackPath $script:DashboardLogContext.MainLog
    Open-TradeNetFile -Path $activeLogPath
})

$btnBuildSplit.Add_Click({
    Invoke-TradeNetUiAction -ActionName "构建分流配置" -Action {
        $output = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Config.ScriptRoot "Build-TradeNetMihomoConfig.ps1") 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw $(if ($output) { $output } else { "Build-TradeNetMihomoConfig.ps1 failed." })
        }

        if ($output) {
            Write-TradeNetLog -Message $output -Path $script:DashboardLogContext.MainLog -NoConsole
        }
    }
})

$btnOpenSplitProfile.Add_Click({
    Open-TradeNetFile -Path $script:Config.SplitRoutingProfilePath
})

$btnOpenSplitConfig.Add_Click({
    $splitStatus = Get-TradeNetSplitRoutingStatus -Config $script:Config
    Open-TradeNetFile -Path $splitStatus.ConfigPath
})

$btnOpenSplitDocs.Add_Click({
    Open-TradeNetFile -Path $script:Config.SplitRoutingDocsPath
})

$form.Add_Shown({
    Write-TradeNetLog -Message "打开 TradeNet Dashboard。" -Path $script:DashboardLogContext.MainLog
    Refresh-TradeNetDashboard
    $timer.Start()
})

$form.Add_FormClosing({
    $timer.Stop()
})

[void]$form.ShowDialog()
