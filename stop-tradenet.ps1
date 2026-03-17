[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "TradeNet.Common.ps1")

$config = Get-TradeNetConfig
$logContext = New-TradeNetLogContext -Config $config -Prefix "stop"

try {
    Enter-TradeNetLock -Config $config
    Stop-TradeNetStack -Config $config -LogPath $logContext.MainLog

    Write-Host ""
    Write-Host "TradeNet 已停止。" -ForegroundColor Yellow
    Write-Host "日志: $($logContext.MainLog)"
} catch {
    Write-TradeNetLog -Message ("停止失败: {0}" -f $_.Exception.Message) -Path $logContext.MainLog -Level "ERROR"
    Write-Host ""
    Write-Host "TradeNet 停止失败。" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "日志: $($logContext.MainLog)"
    exit 1
} finally {
    Exit-TradeNetLock
}
