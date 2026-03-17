param(
    [switch]$StartupMode
)

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "TradeNet.Common.ps1")

$config = Get-TradeNetConfig
$logContext = New-TradeNetLogContext -Config $config -Prefix "agent"
$failureCount = 0
$lastRecoveryAt = [datetime]::MinValue
$lastStatusFingerprint = ""

function Get-StatusReasonText {
    param([object[]]$Reasons)

    if (-not $Reasons -or $Reasons.Count -eq 0) {
        return "无"
    }

    return ($Reasons -join "；")
}

function Write-AgentHeartbeat {
    param([pscustomobject]$Status)

    $fingerprint = "{0}|{1}|{2}|{3}" -f `
        $Status.Healthy, `
        $Status.ManualStopRequested, `
        $Status.WireGuardServiceState, `
        (Get-StatusReasonText -Reasons $Status.Reasons)

    if ($fingerprint -eq $script:lastStatusFingerprint) {
        return
    }

    $script:lastStatusFingerprint = $fingerprint

    if ($Status.ManualStopRequested) {
        Write-TradeNetLog -Message "后台守护检测到手动停止保护，暂停自动恢复。" -Path $logContext.MainLog -Level "WARN"
        return
    }

    if ($Status.Healthy) {
        Write-TradeNetLog -Message "后台守护检测到通道正常。" -Path $logContext.MainLog
        return
    }

    Write-TradeNetLog -Message ("后台守护检测到异常: {0}" -f (Get-StatusReasonText -Reasons $Status.Reasons)) -Path $logContext.MainLog -Level "WARN"
}

function Invoke-AgentRecovery {
    param(
        [string]$Reason,
        [switch]$IgnoreManualStop
    )

    Enter-TradeNetLock -Config $config
    try {
        if ($IgnoreManualStop) {
            Clear-TradeNetManualStopFlag -Config $config
        }

        $recoveryLog = New-TradeNetLogContext -Config $config -Prefix "agent-recovery"
        Start-TradeNetStack `
            -Config $config `
            -LogContext $recoveryLog `
            -OpenWireGuardGui:$false `
            -OpenPingWindows:$false | Out-Null

        $script:failureCount = 0
        $script:lastRecoveryAt = Get-Date
        Write-TradeNetLog -Message ("后台守护恢复完成: {0}" -f $Reason) -Path $logContext.MainLog
    } catch {
        $script:lastRecoveryAt = Get-Date
        Write-TradeNetLog -Message ("后台守护恢复失败: {0}" -f $_.Exception.Message) -Path $logContext.MainLog -Level "ERROR"
    } finally {
        Exit-TradeNetLock
    }
}

Write-TradeNetLog -Message ("启动 TradeNet 后台守护，StartupMode={0}" -f [bool]$StartupMode) -Path $logContext.MainLog

if ($StartupMode) {
    $startupStatus = Get-TradeNetRuntimeStatus -Config $config
    Write-AgentHeartbeat -Status $startupStatus

    if (-not $startupStatus.Healthy) {
        if ($startupStatus.ManualStopRequested -and -not $config.WatchdogIgnoreManualStopOnBoot) {
            Write-TradeNetLog -Message "开机守护尊重手动停止保护，本次不自动拉起。" -Path $logContext.MainLog -Level "WARN"
        } else {
            Invoke-AgentRecovery `
                -Reason ("开机自检: {0}" -f (Get-StatusReasonText -Reasons $startupStatus.Reasons)) `
                -IgnoreManualStop:$startupStatus.ManualStopRequested
        }
    }
}

while ($true) {
    $status = Get-TradeNetRuntimeStatus -Config $config
    Write-AgentHeartbeat -Status $status

    if ($status.ManualStopRequested) {
        $failureCount = 0
        Start-Sleep -Seconds $config.MonitorRefreshSeconds
        continue
    }

    if (-not $status.AutoRestartEligible) {
        $failureCount = 0
        Start-Sleep -Seconds $config.MonitorRefreshSeconds
        continue
    }

    $failureCount += 1
    $cooldownRemaining = [math]::Ceiling(($lastRecoveryAt.AddSeconds($config.AutoRestartCooldown) - (Get-Date)).TotalSeconds)

    if ($cooldownRemaining -gt 0) {
        Start-Sleep -Seconds $config.MonitorRefreshSeconds
        continue
    }

    if ($failureCount -ge [math]::Max(1, [int]$config.AutoRestartThreshold)) {
        Invoke-AgentRecovery -Reason (Get-StatusReasonText -Reasons $status.Reasons)
    }

    Start-Sleep -Seconds $config.MonitorRefreshSeconds
}
