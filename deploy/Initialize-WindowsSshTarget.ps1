<#
.SYNOPSIS
Initializes a Windows deployment target for SSH-based deployments.

.DESCRIPTION
Installs and configures OpenSSH Server, opens the firewall port, creates or
updates a deployment user, configures authorized keys, and prepares common
deployment directories.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\deploy\Initialize-WindowsSshTarget.ps1 `
  -DeployUser deploy `
  -DeployPassword 'ChangeMe123!' `
  -PublicKeyPath 'C:\temp\id_ed25519.pub'

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\deploy\Initialize-WindowsSshTarget.ps1 `
  -DeployUser deploy `
  -PublicKey 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... deploy@controller' `
  -DisablePasswordAuthentication
#>
param(
    [string]$DeployUser = "deploy",
    [string]$DeployPassword,
    [string]$PublicKey,
    [string]$PublicKeyPath,
    [int]$Port = 22,
    [string]$DeployRoot = "C:\deploy",
    [string]$AppRoot = "C:\apps\TradeNet",
    [switch]$GrantAdministratorsGroup,
    [switch]$DisablePasswordAuthentication,
    [switch]$IncludePasswordInReport,
    [switch]$PauseOnSuccess,
    [ValidateSet("portable", "capability")]
    [string]$OpenSshInstallMode = "portable",
    [string]$OpenSshDownloadUrl = "https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip",
    [string]$OpenSshArchivePath = "C:\deploy\OpenSSH-Win64.zip",
    [string]$OpenSshInstallPath = "C:\Program Files\OpenSSH"
)

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$script:FailureLogPath = "C:\deploy\ssh-init.error.log"
$script:OriginalBoundParameters = @{}
foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    $script:OriginalBoundParameters[$entry.Key] = $entry.Value
}

function Start-ElevatedSelf {
    $argumentList = [System.Collections.Generic.List[string]]::new()
    $argumentList.Add("-NoProfile")
    $argumentList.Add("-ExecutionPolicy")
    $argumentList.Add("Bypass")
    $argumentList.Add("-File")
    $argumentList.Add(('"{0}"' -f $PSCommandPath))

    foreach ($entry in $script:OriginalBoundParameters.GetEnumerator()) {
        $argumentList.Add("-$($entry.Key)")

        if ($entry.Value -is [switch]) {
            continue
        }

        $escapedValue = $entry.Value.ToString().Replace('"', '\"')
        $argumentList.Add(('"{0}"' -f $escapedValue))
    }

    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argumentList | Out-Null
    exit 0
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Start-ElevatedSelf
    }
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

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
        $logDirectory = Split-Path -Parent $script:FailureLogPath
        if (-not [string]::IsNullOrWhiteSpace($logDirectory) -and -not (Test-Path -LiteralPath $logDirectory)) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }

        $content = @(
            ("Time: {0}" -f (Get-Date).ToString("s"))
            ("Message: {0}" -f $Message)
        ) -join [Environment]::NewLine
        $content | Set-Content -LiteralPath $script:FailureLogPath -Encoding UTF8
        Write-Host ""
        Write-Host ("Failure log: {0}" -f $script:FailureLogPath) -ForegroundColor Yellow
    } catch {
    }

    if ($Host.Name -eq "ConsoleHost") {
        Write-Host ""
        Read-Host "Press Enter to close" | Out-Null
    }
}

function Ensure-ServiceRunning {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [ValidateSet("Automatic", "Manual")]
        [string]$StartupType = "Manual"
    )

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        return
    }

    Set-Service -Name $Name -StartupType $StartupType
    if ($service.Status -ne "Running") {
        Start-Service -Name $Name
    }
}

function Get-PortablePayloadRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExtractRoot
    )

    $entries = @(Get-ChildItem -LiteralPath $ExtractRoot)
    if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) {
        return $entries[0].FullName
    }

    return $ExtractRoot
}

function Install-PortableOpenSshServer {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DownloadUrl,
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,
        [Parameter(Mandatory = $true)]
        [string]$InstallPath
    )

    $existingService = Get-Service -Name sshd -ErrorAction SilentlyContinue
    $existingInstallScript = Join-Path $InstallPath "install-sshd.ps1"
    if ($existingService -and (Test-Path -LiteralPath $existingInstallScript)) {
        Write-Host ("Portable OpenSSH is already present at {0}." -f $InstallPath)
        return
    }

    Ensure-Directory -Path (Split-Path -Parent $ArchivePath)
    if (Test-Path -LiteralPath $ArchivePath) {
        Write-Host ("Using existing OpenSSH archive: {0}" -f $ArchivePath)
    } else {
        if ([string]::IsNullOrWhiteSpace($DownloadUrl)) {
            throw "OpenSshDownloadUrl is required when OpenSshArchivePath does not already exist."
        }

        Write-Host ("Downloading portable OpenSSH from {0}" -f $DownloadUrl)
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $ArchivePath
    }

    $extractRoot = Join-Path $env:TEMP ("openssh-portable-" + [guid]::NewGuid().ToString("N"))
    Ensure-Directory -Path $extractRoot
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extractRoot -Force

    $payloadRoot = Get-PortablePayloadRoot -ExtractRoot $extractRoot
    Ensure-Directory -Path $InstallPath
    Copy-Item -Path (Join-Path $payloadRoot "*") -Destination $InstallPath -Recurse -Force

    $installScript = Join-Path $InstallPath "install-sshd.ps1"
    if (-not (Test-Path -LiteralPath $installScript)) {
        throw "Portable OpenSSH install script not found after extraction: $installScript"
    }

    Write-Host "Running portable OpenSSH installer..."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript
    if ($LASTEXITCODE -ne 0) {
        throw "install-sshd.ps1 failed with exit code $LASTEXITCODE"
    }

    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function Ensure-OpenSshServerCapability {
    $capabilityName = "OpenSSH.Server~~~~0.0.1.0"
    Write-Host "Checking OpenSSH Server capability..."
    $capability = Get-WindowsCapability -Online -Name $capabilityName
    if ($capability.State -ne "Installed") {
        Write-Host "OpenSSH Server is not installed. Starting Windows servicing components..."
        Ensure-ServiceRunning -Name "wuauserv" -StartupType Manual
        Ensure-ServiceRunning -Name "bits" -StartupType Manual
        Ensure-ServiceRunning -Name "TrustedInstaller" -StartupType Manual
        Write-Host "Installing OpenSSH Server. This can take several minutes on some machines..."
        Add-WindowsCapability -Online -Name $capabilityName | Out-Null
        $capability = Get-WindowsCapability -Online -Name $capabilityName
        if ($capability.State -ne "Installed") {
            throw "OpenSSH Server capability install did not complete successfully."
        }
    }
    Write-Host "OpenSSH Server capability is installed."
}

function Ensure-OpenSshServer {
    param(
        [ValidateSet("portable", "capability")]
        [string]$InstallMode,
        [string]$DownloadUrl,
        [string]$ArchivePath,
        [string]$InstallPath
    )

    switch ($InstallMode) {
        "portable" {
            Install-PortableOpenSshServer `
                -DownloadUrl $DownloadUrl `
                -ArchivePath $ArchivePath `
                -InstallPath $InstallPath
        }
        "capability" {
            Ensure-OpenSshServerCapability
        }
        default {
            throw "Unsupported OpenSSH install mode: $InstallMode"
        }
    }
}

function Ensure-SshdService {
    Set-Service -Name sshd -StartupType Automatic
    $service = Get-Service -Name sshd
    if ($service.Status -ne "Running") {
        Start-Service -Name sshd
    }
}

function Ensure-FirewallRule {
    param(
        [Parameter(Mandatory = $true)]
        [int]$LocalPort
    )

    $ruleName = "TradeNet-OpenSSH-$LocalPort"
    $existing = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule `
            -Name $ruleName `
            -DisplayName "OpenSSH Server ($LocalPort)" `
            -Enabled True `
            -Direction Inbound `
            -Protocol TCP `
            -Action Allow `
            -LocalPort $LocalPort | Out-Null
        return
    }

    Set-NetFirewallRule -Name $ruleName -Enabled True -Direction Inbound -Action Allow | Out-Null
    $filter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $existing
    if ($filter.LocalPort -ne "$LocalPort") {
        Remove-NetFirewallRule -Name $ruleName | Out-Null
        New-NetFirewallRule `
            -Name $ruleName `
            -DisplayName "OpenSSH Server ($LocalPort)" `
            -Enabled True `
            -Direction Inbound `
            -Protocol TCP `
            -Action Allow `
            -LocalPort $LocalPort | Out-Null
    }
}

function Ensure-DeployUser {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserName,
        [string]$Password,
        [switch]$GrantAdmin
    )

    $user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if (-not $user) {
        if ([string]::IsNullOrWhiteSpace($Password)) {
            throw "DeployPassword is required when creating a new user."
        }

        $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
        New-LocalUser `
            -Name $UserName `
            -Password $securePassword `
            -PasswordNeverExpires `
            -UserMayNotChangePassword `
            -AccountNeverExpires | Out-Null
        $user = Get-LocalUser -Name $UserName
    } elseif (-not [string]::IsNullOrWhiteSpace($Password)) {
        $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
        $user | Set-LocalUser -Password $securePassword
    }

    if ($GrantAdmin) {
        $alreadyMember = Get-LocalGroupMember -Group "Administrators" -Member $UserName -ErrorAction SilentlyContinue
        if (-not $alreadyMember) {
            Add-LocalGroupMember -Group "Administrators" -Member $UserName
        }
    }
}

function Read-PublicKeyValue {
    param(
        [string]$InlineValue,
        [string]$PathValue
    )

    if (-not [string]::IsNullOrWhiteSpace($InlineValue)) {
        return $InlineValue.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($PathValue)) {
        if (-not (Test-Path -LiteralPath $PathValue)) {
            throw "PublicKeyPath not found: $PathValue"
        }

        return (Get-Content -LiteralPath $PathValue -Raw).Trim()
    }

    return $null
}

function Set-AuthorizedKeyForUser {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserName,
        [Parameter(Mandatory = $true)]
        [string]$KeyValue,
        [switch]$UseAdministratorsFile
    )

    if ($UseAdministratorsFile) {
        $sshRoot = Join-Path $env:ProgramData "ssh"
        Ensure-Directory -Path $sshRoot
        $authorizedKeysPath = Join-Path $sshRoot "administrators_authorized_keys"
        $principal = "Administrators"
        $grantSpec = "Administrators:(F)"
    } else {
        $userRoot = Join-Path $env:SystemDrive ("Users\{0}" -f $UserName)
        $sshRoot = Join-Path $userRoot ".ssh"
        Ensure-Directory -Path $sshRoot
        $authorizedKeysPath = Join-Path $sshRoot "authorized_keys"
        $principal = "$env:COMPUTERNAME\$UserName"
        $grantSpec = "${principal}:(F)"
    }

    if (Test-Path -LiteralPath $authorizedKeysPath) {
        $existing = (Get-Content -LiteralPath $authorizedKeysPath -Raw).Trim()
        $keys = @()
        if (-not [string]::IsNullOrWhiteSpace($existing)) {
            $keys = $existing -split "(`r`n|`n|`r)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }

        if ($keys -contains $KeyValue) {
            $shouldWrite = $false
        } else {
            $keys += $KeyValue
            $shouldWrite = $true
        }
    } else {
        $keys = @($KeyValue)
        $shouldWrite = $true
    }

    if ($shouldWrite) {
        ($keys -join [Environment]::NewLine) | Set-Content -LiteralPath $authorizedKeysPath -Encoding ascii
    }

    & icacls $sshRoot /inheritance:r /grant:r $grantSpec /grant:r "SYSTEM:(F)" | Out-Null
    & icacls $authorizedKeysPath /inheritance:r /grant:r $grantSpec /grant:r "SYSTEM:(F)" | Out-Null
}

function Set-SshdConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Lines,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $pattern = "^\s*#?\s*{0}\b.*$" -f [regex]::Escape($Key)
    $replacement = "{0} {1}" -f $Key, $Value
    $updated = $false
    $result = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $Lines) {
        if (-not $updated -and $line -match $pattern) {
            $result.Add($replacement)
            $updated = $true
            continue
        }

        $result.Add($line)
    }

    if (-not $updated) {
        $result.Add($replacement)
    }

    return $result.ToArray()
}

function Get-SshdConfigLines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,
        [Parameter(Mandatory = $true)]
        [string]$DefaultConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        if (-not (Test-Path -LiteralPath $DefaultConfigPath)) {
            throw "Neither sshd_config nor sshd_config_default exists."
        }

        Copy-Item -LiteralPath $DefaultConfigPath -Destination $ConfigPath -Force
    }

    $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) {
        if (-not (Test-Path -LiteralPath $DefaultConfigPath)) {
            throw "sshd_config is empty and sshd_config_default was not found: $DefaultConfigPath"
        }

        Copy-Item -LiteralPath $DefaultConfigPath -Destination $ConfigPath -Force
        $raw = Get-Content -LiteralPath $ConfigPath -Raw
    }

    $normalized = $raw -replace "`r`n", "`n"
    $lines = @($normalized -split "`n")
    if ($lines.Count -eq 0) {
        throw "sshd_config is empty after loading: $ConfigPath"
    }

    return $lines
}

function Configure-Sshd {
    param(
        [Parameter(Mandatory = $true)]
        [int]$SshPort,
        [Parameter(Mandatory = $true)]
        [bool]$EnablePasswordAuthentication,
        [string]$OpenSshInstallPath
    )

    $configPath = Join-Path $env:ProgramData "ssh\sshd_config"
    $defaultConfigCandidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($OpenSshInstallPath)) {
        $defaultConfigCandidates.Add((Join-Path $OpenSshInstallPath "sshd_config_default"))
    }

    $programFilesDefaultConfigPath = Join-Path $env:ProgramFiles "OpenSSH\sshd_config_default"
    if (-not ($defaultConfigCandidates -contains $programFilesDefaultConfigPath)) {
        $defaultConfigCandidates.Add($programFilesDefaultConfigPath)
    }

    $defaultConfigPath = $defaultConfigCandidates |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1

    if (-not $defaultConfigPath) {
        $defaultConfigPath = $defaultConfigCandidates[0]
    }

    $lines = Get-SshdConfigLines -ConfigPath $configPath -DefaultConfigPath $defaultConfigPath

    $updates = [ordered]@{
        Port                   = [string]$SshPort
        PubkeyAuthentication   = "yes"
        PasswordAuthentication = if ($EnablePasswordAuthentication) { "yes" } else { "no" }
    }

    $updatedLines = [System.Collections.Generic.List[string]]::new()
    $applied = @{}
    foreach ($key in $updates.Keys) {
        $applied[$key] = $false
    }

    foreach ($line in $lines) {
        $replaced = $false
        foreach ($key in $updates.Keys) {
            $pattern = "^\s*#?\s*{0}\b.*$" -f [regex]::Escape($key)
            if (-not $applied[$key] -and $line -match $pattern) {
                $updatedLines.Add(("{0} {1}" -f $key, $updates[$key]))
                $applied[$key] = $true
                $replaced = $true
                break
            }
        }

        if (-not $replaced) {
            $updatedLines.Add($line)
        }
    }

    foreach ($key in $updates.Keys) {
        if (-not $applied[$key]) {
            $updatedLines.Add(("{0} {1}" -f $key, $updates[$key]))
        }
    }

    $updatedLines | Set-Content -LiteralPath $configPath -Encoding ascii

    Restart-Service -Name sshd
}

function Get-ActiveIpv4Info {
    $items = [System.Collections.Generic.List[object]]::new()
    $configs = Get-NetIPConfiguration | Where-Object {
        $_.NetAdapter.Status -eq "Up" -and $_.IPv4Address
    }

    foreach ($config in $configs) {
        foreach ($address in $config.IPv4Address) {
            if ($address.IPAddress -like "127.*" -or $address.IPAddress -like "169.254.*") {
                continue
            }

            $gateway = if ($config.IPv4DefaultGateway) {
                $config.IPv4DefaultGateway.NextHop
            } else {
                "-"
            }

            $items.Add([pscustomobject]@{
                Address        = $address.IPAddress
                InterfaceAlias = $config.InterfaceAlias
                Gateway        = $gateway
            })
        }
    }

    if ($items.Count -eq 0) {
        $items.Add([pscustomobject]@{
            Address        = "No active IPv4 address detected"
            InterfaceAlias = ""
            Gateway        = ""
        })
    }

    return $items.ToArray()
}

function Get-ActiveIpv4Summary {
    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($info in (Get-ActiveIpv4Info)) {
        if ($info.Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
            $items.Add($info.Address)
            continue
        }

        $items.Add(("{0} ({1}, gateway {2})" -f $info.Address, $info.InterfaceAlias, $info.Gateway))
    }

    return $items.ToArray()
}

function Get-OsSummary {
    $os = Get-CimInstance Win32_OperatingSystem
    return ("{0} {1} (build {2}, {3})" -f $os.Caption, $os.Version, $os.BuildNumber, $os.OSArchitecture)
}

function Get-PublicIpv4 {
    $endpoints = @(
        "https://api.ipify.org?format=text",
        "https://ifconfig.me/ip",
        "https://ipv4.icanhazip.com"
    )

    foreach ($endpoint in $endpoints) {
        try {
            $value = (Invoke-RestMethod -Uri $endpoint -Method Get -TimeoutSec 5).ToString().Trim()
            if ($value -match '^\d{1,3}(\.\d{1,3}){3}$') {
                return $value
            }
        } catch {
        }
    }

    return $null
}

function Get-SshHostKeyFingerprints {
    param(
        [string]$OpenSshInstallPath
    )

    $sshKeygenCandidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($OpenSshInstallPath)) {
        $sshKeygenCandidates.Add((Join-Path $OpenSshInstallPath "ssh-keygen.exe"))
    }

    $programFilesSshKeygenPath = Join-Path $env:ProgramFiles "OpenSSH\ssh-keygen.exe"
    if (-not ($sshKeygenCandidates -contains $programFilesSshKeygenPath)) {
        $sshKeygenCandidates.Add($programFilesSshKeygenPath)
    }

    $sshKeygenCommand = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if ($sshKeygenCommand -and -not [string]::IsNullOrWhiteSpace($sshKeygenCommand.Source) -and -not ($sshKeygenCandidates -contains $sshKeygenCommand.Source)) {
        $sshKeygenCandidates.Add($sshKeygenCommand.Source)
    }

    $sshKeygenPath = $sshKeygenCandidates |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1

    if (-not (Test-Path -LiteralPath $sshKeygenPath)) {
        return @("Unavailable: ssh-keygen.exe not found")
    }

    $keyPaths = @(
        (Join-Path $env:ProgramData "ssh\ssh_host_ed25519_key.pub"),
        (Join-Path $env:ProgramData "ssh\ssh_host_ecdsa_key.pub"),
        (Join-Path $env:ProgramData "ssh\ssh_host_rsa_key.pub")
    ) | Where-Object { Test-Path -LiteralPath $_ }

    if ($keyPaths.Count -eq 0) {
        return @("Unavailable: no ssh host public keys found")
    }

    $fingerprints = [System.Collections.Generic.List[string]]::new()
    foreach ($keyPath in $keyPaths) {
        try {
            $output = & $sshKeygenPath -lf $keyPath 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($output)) {
                $fingerprints.Add(($output | Select-Object -First 1).Trim())
            }
        } catch {
        }
    }

    if ($fingerprints.Count -eq 0) {
        $fingerprints.Add("Unavailable: fingerprint generation failed")
    }

    return $fingerprints.ToArray()
}

function New-ConnectionReport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserName,
        [Parameter(Mandatory = $true)]
        [int]$SshPort,
        [Parameter(Mandatory = $true)]
        [string]$DeployDirectory,
        [Parameter(Mandatory = $true)]
        [string]$ApplicationDirectory,
        [Parameter(Mandatory = $true)]
        [bool]$PasswordEnabled,
        [Parameter(Mandatory = $true)]
        [bool]$PublicKeyConfigured,
        [Parameter(Mandatory = $true)]
        [string]$OpenSshMode,
        [string]$OpenSshInstallPath,
        [string]$PasswordToShow
    )

    $authMode = if ($PublicKeyConfigured -and $PasswordEnabled) {
        "password + publickey"
    } elseif ($PublicKeyConfigured) {
        "publickey only"
    } elseif ($PasswordEnabled) {
        "password only"
    } else {
        "unknown"
    }

    $ipInfo = Get-ActiveIpv4Info
    $ipLines = Get-ActiveIpv4Summary
    $publicIpv4 = Get-PublicIpv4
    $osSummary = Get-OsSummary
    $fingerprints = Get-SshHostKeyFingerprints -OpenSshInstallPath $OpenSshInstallPath
    $connectionExamples = [System.Collections.Generic.List[string]]::new()
    foreach ($info in $ipInfo) {
        if ($info.Address -match '^\d{1,3}(\.\d{1,3}){3}$') {
            if ($SshPort -eq 22) {
                $connectionExamples.Add(("ssh {0}@{1}" -f $UserName, $info.Address))
            } else {
                $connectionExamples.Add(("ssh -p {0} {1}@{2}" -f $SshPort, $UserName, $info.Address))
            }
        }
    }

    $publicConnectionExample = $null
    if ($publicIpv4) {
        if ($SshPort -eq 22) {
            $publicConnectionExample = "ssh {0}@{1}" -f $UserName, $publicIpv4
        } else {
            $publicConnectionExample = "ssh -p {0} {1}@{2}" -f $SshPort, $UserName, $publicIpv4
        }
    }

    if ($connectionExamples.Count -eq 0) {
        if ($SshPort -eq 22) {
            $connectionExamples.Add(("ssh {0}@<target-ip>" -f $UserName))
        } else {
            $connectionExamples.Add(("ssh -p {0} {1}@<target-ip>" -f $SshPort, $UserName))
        }
    }

    $service = Get-Service -Name sshd
    $listening = Test-NetConnection -ComputerName "127.0.0.1" -Port $SshPort -WarningAction SilentlyContinue

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("=== TradeNet SSH Target Info ===")
    $lines.Add(("Generated At: {0}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")))
    $lines.Add(("HostName: {0}" -f $env:COMPUTERNAME))
    $lines.Add(("OS: {0}" -f $osSummary))
    $lines.Add(("User: {0}" -f $UserName))
    $lines.Add(("SSH Port: {0}" -f $SshPort))
    $lines.Add(("OpenSSH Install Mode: {0}" -f $OpenSshMode))
    $lines.Add(("Auth Mode: {0}" -f $authMode))
    if (-not [string]::IsNullOrWhiteSpace($PasswordToShow)) {
        $lines.Add(("Password: {0}" -f $PasswordToShow))
    }
    $lines.Add(("Public IPv4: {0}" -f $(if ($publicIpv4) { $publicIpv4 } else { "Unavailable" })))
    $lines.Add(("Deploy Root: {0}" -f $DeployDirectory))
    $lines.Add(("App Root: {0}" -f $ApplicationDirectory))
    $lines.Add(("sshd Service: {0}" -f $service.Status))
    $lines.Add(("Port Reachable On Host: {0}" -f $listening.TcpTestSucceeded))
    $lines.Add("IPv4:")
    foreach ($line in $ipLines) {
        $lines.Add(("  - {0}" -f $line))
    }
    $lines.Add("SSH Examples:")
    foreach ($example in ($connectionExamples | Select-Object -Unique)) {
        $lines.Add(("  - {0}" -f $example))
    }
    if ($publicConnectionExample) {
        $lines.Add(("Public SSH Example: {0}" -f $publicConnectionExample))
    }
    $lines.Add("SSH Host Key Fingerprints:")
    foreach ($fingerprint in $fingerprints) {
        $lines.Add(("  - {0}" -f $fingerprint))
    }
    $lines.Add("Notes:")
    if (-not [string]::IsNullOrWhiteSpace($PasswordToShow)) {
        $lines.Add("  - Password is stored in plaintext in this output and in the saved report file.")
    } else {
        $lines.Add("  - Password and private key are not printed by this script.")
    }
    $lines.Add("  - If the machine is behind NAT, also send the router-mapped public port if it is not 22.")
    $lines.Add("  - If Public IPv4 is unavailable, send the router public IP or DDNS host manually for internet deployment.")

    return ($lines -join [Environment]::NewLine)
}

try {
    Assert-Administrator

    $publicKeyValue = Read-PublicKeyValue -InlineValue $PublicKey -PathValue $PublicKeyPath
    if ($DisablePasswordAuthentication -and [string]::IsNullOrWhiteSpace($publicKeyValue)) {
        throw "A public key is required when DisablePasswordAuthentication is set."
    }

    Write-Host ""
    Write-Host ("Step 1/6: OpenSSH install ({0})" -f $OpenSshInstallMode)
    Ensure-OpenSshServer `
        -InstallMode $OpenSshInstallMode `
        -DownloadUrl $OpenSshDownloadUrl `
        -ArchivePath $OpenSshArchivePath `
        -InstallPath $OpenSshInstallPath
    Write-Host "Step 2/6: sshd service"
    Ensure-SshdService
    Write-Host "Step 3/6: firewall rule"
    Ensure-FirewallRule -LocalPort $Port
    Write-Host "Step 4/6: deploy user"
    Ensure-DeployUser -UserName $DeployUser -Password $DeployPassword -GrantAdmin:$GrantAdministratorsGroup

    if (-not [string]::IsNullOrWhiteSpace($publicKeyValue)) {
        Write-Host "Step 5/6: authorized_keys"
        Set-AuthorizedKeyForUser `
            -UserName $DeployUser `
            -KeyValue $publicKeyValue `
            -UseAdministratorsFile:$GrantAdministratorsGroup
    }

    Write-Host "Step 6/6: directories and sshd config"
    Ensure-Directory -Path $DeployRoot
    Ensure-Directory -Path $AppRoot
    Configure-Sshd `
        -SshPort $Port `
        -EnablePasswordAuthentication:(-not $DisablePasswordAuthentication) `
        -OpenSshInstallPath $OpenSshInstallPath
    $report = New-ConnectionReport `
        -UserName $DeployUser `
        -SshPort $Port `
        -DeployDirectory $DeployRoot `
        -ApplicationDirectory $AppRoot `
        -PasswordEnabled:(-not $DisablePasswordAuthentication) `
        -PublicKeyConfigured:(-not [string]::IsNullOrWhiteSpace($publicKeyValue)) `
        -OpenSshMode $OpenSshInstallMode `
        -OpenSshInstallPath $OpenSshInstallPath `
        -PasswordToShow:$(if ($IncludePasswordInReport -and -not [string]::IsNullOrWhiteSpace($DeployPassword)) { $DeployPassword } else { $null })
    $reportPath = Join-Path $DeployRoot "ssh-target-info.txt"
    $report | Set-Content -LiteralPath $reportPath -Encoding UTF8

    Write-Host ""
    Write-Host "Windows SSH target is ready." -ForegroundColor Green
    Write-Host "Copy the block below and send it back:"
    Write-Host ""
    Write-Host $report
    Write-Host ""
    Write-Host "Saved to: $reportPath"
    if ($PauseOnSuccess -and $Host.Name -eq "ConsoleHost") {
        Write-Host ""
        Read-Host "Press Enter to close" | Out-Null
    }
} catch {
    $message = $_.Exception.Message
    Write-Host ""
    Write-Host "Initialization failed." -ForegroundColor Red
    Write-Host $message -ForegroundColor Red
    Write-FailureAndPause -Message $message
    exit 1
}
