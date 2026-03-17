[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "TradeNet.Common.ps1")

$config = Get-TradeNetConfig
Unregister-TradeNetWatchdogTask -Config $config

Write-Host "TradeNet 开机守护已移除。" -ForegroundColor Yellow
