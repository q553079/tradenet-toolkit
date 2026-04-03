param(
    [string]$DnsServersCsv = "8.8.8.8,223.5.5.5",
    [string]$BackupPath = "C:\deploy\dns-backup.json"
)

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$script:FailureLogPath = "C:\deploy\retry-init.error.log"

function Get-DnsServers {
    $servers = $DnsServersCsv -split '\s*,\s*' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (-not $servers -or $servers.Count -eq 0) {
        throw "DnsServersCsv must contain at least one DNS server."
    }

    return $servers
}

function Start-ElevatedSelf {
    $argumentList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f $PSCommandPath),
        "-DnsServersCsv", ('"{0}"' -f $DnsServersCsv),
        "-BackupPath", ('"{0}"' -f $BackupPath)
    )

    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argumentList | Out-Null
    exit 0
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Start-ElevatedSelf
    }
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-FailureAndPause {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    try {
        Ensure-Directory -Path (Split-Path -Parent $script:FailureLogPath)
        @(
            ("Time: {0}" -f (Get-Date).ToString("s"))
            ("Message: {0}" -f $Message)
        ) -join [Environment]::NewLine | Set-Content -LiteralPath $script:FailureLogPath -Encoding UTF8
        Write-Host ""
        Write-Host ("Failure log: {0}" -f $script:FailureLogPath) -ForegroundColor Yellow
    } catch {
    }

    if ($Host.Name -eq "ConsoleHost") {
        Write-Host ""
        Read-Host "Press Enter to close" | Out-Null
    }
}

function Get-PrimaryInterface {
    $candidates = Get-NetIPConfiguration | Where-Object {
        $_.NetAdapter.Status -eq "Up" -and $_.IPv4DefaultGateway -and $_.IPv4Address
    }

    $decorated = foreach ($candidate in $candidates) {
        $metric = [int]::MaxValue
        $ipInterface = Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $candidate.InterfaceIndex -ErrorAction SilentlyContinue
        if ($ipInterface -and $null -ne $ipInterface.InterfaceMetric) {
            $metric = [int]$ipInterface.InterfaceMetric
        }

        [pscustomobject]@{
            Metric    = $metric
            Candidate = $candidate
        }
    }

    $selected = $decorated |
        Sort-Object @{Expression = { $_.Metric }; Ascending = $true }, @{Expression = { $_.Candidate.InterfaceIndex }; Ascending = $true } |
        Select-Object -First 1

    if (-not $selected) {
        throw "No active IPv4 interface with a default gateway was found."
    }

    return $selected.Candidate
}

function Try-VerifyResolution {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$DnsServers
    )

    foreach ($server in $DnsServers) {
        try {
            Write-Host ("Verifying name resolution via {0}..." -f $server)
            Resolve-DnsName download.windowsupdate.com -Server $server -QuickTimeout -ErrorAction Stop |
                Select-Object -First 5 Name, Type, IPAddress, NameHost |
                Format-Table -AutoSize
            return
        } catch {
            Write-Host ("DNS verification via {0} failed: {1}" -f $server, $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    Write-Host "All DNS verification attempts timed out. Continuing anyway..." -ForegroundColor Yellow
}

try {
    Assert-Administrator

    $dnsServers = Get-DnsServers
    $primary = Get-PrimaryInterface
    $currentDns = (Get-DnsClientServerAddress -InterfaceIndex $primary.InterfaceIndex -AddressFamily IPv4).ServerAddresses
    Ensure-Directory -Path (Split-Path -Parent $BackupPath)

    $backup = [ordered]@{
        interface_alias = $primary.InterfaceAlias
        interface_index = $primary.InterfaceIndex
        previous_dns    = @($currentDns)
        backup_time     = (Get-Date).ToString("s")
    }
    $backup | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $BackupPath -Encoding UTF8

    Write-Host ""
    Write-Host ("Primary interface: {0} (Index {1})" -f $primary.InterfaceAlias, $primary.InterfaceIndex)
    Write-Host ("Previous DNS: {0}" -f (($currentDns | Where-Object { $_ }) -join ", "))
    Write-Host ("Switching DNS to: {0}" -f ($dnsServers -join ", "))

    Set-DnsClientServerAddress -InterfaceIndex $primary.InterfaceIndex -ServerAddresses $dnsServers
    Clear-DnsClientCache
    ipconfig /flushdns | Out-Null

    Try-VerifyResolution -DnsServers $dnsServers

    Write-Host ""
    Write-Host "Starting TradeNet SSH target initialization..."
    & (Join-Path $PSScriptRoot "Initialize-WindowsSshTarget-OneClick.ps1")
} catch {
    $message = $_.Exception.Message
    Write-Host ""
    Write-Host "Retry initialization failed." -ForegroundColor Red
    Write-Host $message -ForegroundColor Red
    Write-FailureAndPause -Message $message
    exit 1
}
