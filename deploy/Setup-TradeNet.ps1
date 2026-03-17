param(
    [string]$ProfilePath = (Join-Path (Split-Path $PSScriptRoot -Parent) "TradeNet.Deployment.psd1"),
    [switch]$SkipServer,
    [switch]$SkipClient
)

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = "Stop"

if (-not $SkipServer) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Deploy-TradeNetServer.ps1") -ProfilePath $ProfilePath
    if ($LASTEXITCODE -ne 0) {
        throw "Deploy-TradeNetServer.ps1 failed."
    }
}

if (-not $SkipClient) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Install-TradeNetClient.ps1") -ProfilePath $ProfilePath
    if ($LASTEXITCODE -ne 0) {
        throw "Install-TradeNetClient.ps1 failed."
    }
}

Write-Host "TradeNet setup completed." -ForegroundColor Green
