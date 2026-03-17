[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "TradeNet.Common.ps1")

$config = Get-TradeNetConfig
$monitorLog = New-TradeNetLogContext -Config $config -Prefix "monitor"
$failureCount = 0
$lastRecoveryAt = [datetime]::MinValue

function Write-MonitorBanner {
    Clear-Host
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host "     TradeNet Console Watch    " -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Status {
    param([pscustomobject]$Status)

    Write-MonitorBanner

    if ($Status.ManualStopRequested) {
        Write-Host "状态: 已手动停止" -ForegroundColor Yellow
    } elseif ($Status.Healthy) {
        Write-Host "状态: 通道正常" -ForegroundColor Green
    } else {
        Write-Host "状态: 通道异常" -ForegroundColor Red
    }

    Write-Host ("时间: {0}" -f $Status.Timestamp.ToString("yyyy-MM-dd HH:mm:ss"))
    Write-Host ""

    Write-Host "VPS 路由: " -NoNewline
    Write-Host ($(if ($Status.RouteOk) { "OK" } else { "缺失" })) -ForegroundColor $(if ($Status.RouteOk) { "Green" } else { "Red" })

    Write-Host "udp2raw: " -NoNewline
    Write-Host ($(if ($Status.Udp2rawRunning) { "运行中 PID=$($Status.Udp2rawPidText)" } else { "未运行" })) -ForegroundColor $(if ($Status.Udp2rawRunning) { "Green" } else { "Red" })

    Write-Host "本地监听: " -NoNewline
    Write-Host ($(if ($Status.ListenerBound) { $config.Udp2rawListen } else { "$($config.Udp2rawListen) 未监听" })) -ForegroundColor $(if ($Status.ListenerBound) { "Green" } else { "Red" })

    Write-Host "WireGuard 服务: " -NoNewline
    Write-Host $Status.WireGuardServiceState -ForegroundColor $(if ($Status.WireGuardServiceState -eq "RUNNING") { "Green" } else { "Red" })

    Write-Host "WireGuard CLI: " -NoNewline
    Write-Host $Status.WireGuardCliState -ForegroundColor $(if ($Status.WireGuardCliState -eq "CONNECTED") { "Green" } else { "Yellow" })

    Write-Host ("WG 网关延迟: {0}" -f $Status.GatewayPingText)
    Write-Host ("公网延迟: {0}" -f $Status.InternetPingText)
    Write-Host ("最近握手: {0}" -f ($(if ($Status.HandshakeLine) { $Status.HandshakeLine } else { "未检测到握手" })))
    Write-Host ("流量: {0}" -f ($(if ($Status.TransferLine) { $Status.TransferLine } else { "暂无流量信息" })))
    Write-Host ""

    if ($Status.Reasons.Count -gt 0) {
        Write-Host ("异常原因: {0}" -f ($Status.Reasons -join "；")) -ForegroundColor Yellow
    } else {
        Write-Host "异常原因: 无" -ForegroundColor Green
    }

    if ($config.AutoRestartEnabled) {
        Write-Host ("自动重启: 已启用，阈值 {0} 次，冷却 {1}s" -f $config.AutoRestartThreshold, $config.AutoRestartCooldown) -ForegroundColor Cyan
    } else {
        Write-Host "自动重启: 已关闭" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "按 Q 退出监控" -ForegroundColor DarkGray
}

Write-TradeNetLog -Message "打开控制台 Monitor。" -Path $monitorLog.MainLog

while ($true) {
    if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Q) {
            break
        }
    }

    $status = Get-TradeNetRuntimeStatus -Config $config
    Show-Status -Status $status

    if ($config.AutoRestartEnabled -and $status.AutoRestartEligible -and -not $status.ManualStopRequested) {
        $failureCount += 1
        $cooldownRemaining = [math]::Ceiling(($lastRecoveryAt.AddSeconds($config.AutoRestartCooldown) - (Get-Date)).TotalSeconds)

        if ($cooldownRemaining -gt 0) {
            Write-Host ("自动重启冷却中，剩余 {0}s" -f $cooldownRemaining) -ForegroundColor Yellow
        } elseif ($failureCount -ge $config.AutoRestartThreshold) {
            Write-TradeNetLog -Message ("Monitor 检测到异常，开始自动恢复。原因: {0}" -f ($status.Reasons -join "；")) -Path $monitorLog.MainLog -Level "WARN"

            try {
                Enter-TradeNetLock -Config $config
                $logContext = New-TradeNetLogContext -Config $config -Prefix "autofix"
                Start-TradeNetStack `
                    -Config $config `
                    -LogContext $logContext `
                    -OpenWireGuardGui:$config.OpenWireGuardGui `
                    -OpenPingWindows:$config.OpenPingWindows | Out-Null

                $failureCount = 0
                $lastRecoveryAt = Get-Date
                Write-TradeNetLog -Message "Monitor 自动恢复完成。" -Path $monitorLog.MainLog
            } catch {
                $lastRecoveryAt = Get-Date
                Write-TradeNetLog -Message ("Monitor 自动恢复失败: {0}" -f $_.Exception.Message) -Path $monitorLog.MainLog -Level "ERROR"
            } finally {
                Exit-TradeNetLock
            }
        } else {
            Write-Host ("自动重启异常计数: {0}/{1}" -f $failureCount, $config.AutoRestartThreshold) -ForegroundColor Yellow
        }
    } else {
        $failureCount = 0
    }

    Start-Sleep -Seconds $config.MonitorRefreshSeconds
}
