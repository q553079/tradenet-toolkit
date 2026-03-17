param(
    [switch]$Replace,
    [switch]$StartNow
)

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "TradeNet.Common.ps1")

$config = Get-TradeNetConfig
$status = Register-TradeNetWatchdogTask -Config $config -Replace:$Replace -StartNow:$StartNow

Write-Host "TradeNet 开机守护已注册。" -ForegroundColor Green
Write-Host "任务名: $($status.TaskName)"
Write-Host "状态: $($status.Summary)"
