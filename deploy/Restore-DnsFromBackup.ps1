param(
    [string]$BackupPath = "C:\deploy\dns-backup.json"
)

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Start-ElevatedSelf {
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f $PSCommandPath),
        "-BackupPath", ('"{0}"' -f $BackupPath)
    ) | Out-Null
    exit 0
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Start-ElevatedSelf
    }
}

Assert-Administrator

if (-not (Test-Path -LiteralPath $BackupPath)) {
    throw "Backup file not found: $BackupPath"
}

$backup = Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json
Set-DnsClientServerAddress -InterfaceIndex $backup.interface_index -ServerAddresses $backup.previous_dns
Clear-DnsClientCache
ipconfig /flushdns | Out-Null

Write-Host ""
Write-Host ("Restored DNS for {0} (Index {1}) to: {2}" -f $backup.interface_alias, $backup.interface_index, (($backup.previous_dns | Where-Object { $_ }) -join ", "))
