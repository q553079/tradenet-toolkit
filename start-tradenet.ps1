[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "TradeNet.Common.ps1")

$config = Get-TradeNetConfig
$logContext = New-TradeNetLogContext -Config $config -Prefix "start"

try {
    Enter-TradeNetLock -Config $config
    Start-TradeNetStack `
        -Config $config `
        -LogContext $logContext `
        -OpenWireGuardGui:$config.OpenWireGuardGui `
        -OpenPingWindows:$config.OpenPingWindows | Out-Null

    Write-Host ""
    Write-Host "TradeNet 已启动。" -ForegroundColor Green
    Write-Host "主日志: $($logContext.MainLog)"
    Write-Host "udp2raw stdout: $($logContext.Udp2rawOutLog)"
    Write-Host "udp2raw stderr: $($logContext.Udp2rawErrLog)"
} catch {
    Write-TradeNetLog -Message ("启动失败: {0}" -f $_.Exception.Message) -Path $logContext.MainLog -Level "ERROR"
    Write-Host ""
    Write-Host "TradeNet 启动失败。" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "日志: $($logContext.MainLog)"
    exit 1
} finally {
    Exit-TradeNetLock
}
