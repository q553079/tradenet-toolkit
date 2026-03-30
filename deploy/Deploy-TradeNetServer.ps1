param(
    [string]$ProfilePath = (Join-Path (Split-Path $PSScriptRoot -Parent) "TradeNet.Deployment.psd1")
)

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Ensure-Paramiko {
    $found = py -c "import importlib.util; print(bool(importlib.util.find_spec('paramiko')))" 2>$null
    if ($found.Trim() -ne "True") {
        py -m pip install --user paramiko | Out-Null
    }
}

if (-not (Test-Path -LiteralPath $ProfilePath)) {
    throw "Deployment profile not found: $ProfilePath"
}

$profile = Import-PowerShellDataFile -Path $ProfilePath
$repoRoot = Split-Path $PSScriptRoot -Parent
$artifactDir = Join-Path $repoRoot "artifacts"
if (-not (Test-Path -LiteralPath $artifactDir)) {
    New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
}

$jobPath = Join-Path $artifactDir "deploy-job.json"
$stdoutPath = Join-Path $artifactDir "server-install.stdout.log"
$stderrPath = Join-Path $artifactDir "server-install.stderr.log"
$installerPath = Join-Path $PSScriptRoot "server\install-tradenet-server.sh"
$pythonPath = Join-Path $PSScriptRoot "server\deploy_tradenet_server.py"

$environment = [ordered]@{
    TRADENET_PUBLIC_ENDPOINT        = $profile.Server.PublicEndpoint
    TRADENET_PUBLIC_INTERFACE       = $profile.Server.PublicInterface
    TRADENET_WG_IFACE               = $profile.Server.WireGuardInterface
    TRADENET_WG_SUBNET              = $profile.Server.WireGuardSubnet
    TRADENET_SERVER_ADDRESS         = $profile.Server.ServerAddress
    TRADENET_CLIENT_ADDRESS         = $profile.Server.ClientAddress
    TRADENET_CLIENT_ALLOWED_IP      = $profile.Server.ClientAllowedIp
    TRADENET_WG_LISTEN_PORT         = [string]$profile.Server.WireGuardListenPort
    TRADENET_WG_MTU                 = [string]$profile.Server.WireGuardMtu
    TRADENET_CLIENT_LISTEN_PORT     = [string]$profile.Server.ClientListenPort
    TRADENET_CLIENT_DNS             = $profile.Server.ClientDns
    TRADENET_CLIENT_ALLOWED_ROUTES  = ($profile.Server.ClientAllowedRoutes -join ",")
    TRADENET_PERSISTENT_KEEPALIVE   = [string]$profile.Server.PersistentKeepalive
    TRADENET_UDP2RAW_BINARY_PATH    = $profile.Server.Udp2rawBinaryPath
    TRADENET_UDP2RAW_DOWNLOAD_URL   = $profile.Server.Udp2rawDownloadUrl
    TRADENET_UDP2RAW_PASSWORD       = $profile.Server.Udp2rawPassword
    TRADENET_UDP2RAW_LISTEN_PORT    = [string]$profile.Server.Udp2rawListenPort
    TRADENET_UDP2RAW_MODE           = $profile.Server.Udp2rawMode
    TRADENET_CLIENT_WG_HOST         = $profile.Server.ClientWireGuardHost
    TRADENET_CLIENT_WG_PORT         = [string]$profile.Server.ClientWireGuardPort
    TRADENET_MANAGE_FIREWALL        = if ([bool]$profile.Server.Deployment.ManageFirewall) { "true" } else { "false" }
    TRADENET_FIREWALL_BACKEND       = $profile.Server.Deployment.FirewallBackend
    TRADENET_RESET_FIREWALL         = if ([bool]$profile.Server.Deployment.ResetFirewall) { "true" } else { "false" }
    TRADENET_SSH_PORT               = [string]$profile.Server.Deployment.SshPort
    TRADENET_MANAGE_SYSCTL          = if ([bool]$profile.Server.Deployment.ManageSysctl) { "true" } else { "false" }
    TRADENET_APPLY_GATEWAY_TUNING   = if ([bool]$profile.Server.Deployment.ApplyGatewayTuning) { "true" } else { "false" }
    TRADENET_VERIFY_AFTER_INSTALL   = if ([bool]$profile.Server.Deployment.VerifyAfterInstall) { "true" } else { "false" }
}

$job = [ordered]@{
    server = [ordered]@{
        host         = $profile.Server.Host
        port         = [int]$profile.Server.Port
        user         = $profile.Server.User
        password     = $profile.Server.Password
        artifact_dir = "/opt/tradenet/artifacts"
        environment  = $environment
    }
    local  = [ordered]@{
        installer_path      = $installerPath
        artifact_dir        = $artifactDir
        remote_stdout_path  = $stdoutPath
        remote_stderr_path  = $stderrPath
    }
}

$job | ConvertTo-Json -Depth 6 | Set-Content -Path $jobPath -Encoding UTF8

Ensure-Paramiko
& py $pythonPath $jobPath
if ($LASTEXITCODE -ne 0) {
    throw "Deploy-TradeNetServer failed. See $stdoutPath and $stderrPath"
}

Write-Host "Server deployment completed." -ForegroundColor Green
Write-Host "Artifacts: $artifactDir"
