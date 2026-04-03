$settings = [ordered]@{
    DeployUser                = "deploy"
    Port                      = 22
    DeployRoot                = "C:\deploy"
    AppRoot                   = "C:\apps\TradeNet"
    OpenSshInstallMode        = "portable"
    GrantAdministratorsGroup  = $false
    IncludePasswordInReport   = $true
    PauseOnSuccess            = $true
    DeployPassword            = ""
    PublicKeyPath             = ""
    PublicKey                 = ""
    DisablePasswordAuthentication = $false
}

function Read-Value {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [string]$DefaultValue
    )

    if ([string]::IsNullOrWhiteSpace($DefaultValue)) {
        $value = Read-Host $Prompt
    } else {
        $value = Read-Host ("{0} [{1}]" -f $Prompt, $DefaultValue)
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }

    return $value.Trim()
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [bool]$DefaultValue = $false
    )

    $suffix = if ($DefaultValue) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        $value = Read-Host ("{0} {1}" -f $Prompt, $suffix)
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $DefaultValue
        }

        switch ($value.Trim().ToLowerInvariant()) {
            "y" { return $true }
            "yes" { return $true }
            "n" { return $false }
            "no" { return $false }
            default { Write-Host "Please answer y/yes or n/no." -ForegroundColor Yellow }
        }
    }
}

function Read-Choice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [Parameter(Mandatory = $true)]
        [string[]]$AllowedValues,
        [Parameter(Mandatory = $true)]
        [string]$DefaultValue
    )

    while ($true) {
        $value = Read-Host ("{0} [{1}]" -f $Prompt, $DefaultValue)
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $DefaultValue
        }

        $trimmed = $value.Trim().ToLowerInvariant()
        if ($AllowedValues -contains $trimmed) {
            return $trimmed
        }

        Write-Host ("Allowed values: {0}" -f ($AllowedValues -join ", ")) -ForegroundColor Yellow
    }
}

function ConvertTo-PlainText {
    param(
        [Parameter(Mandatory = $true)]
        [Security.SecureString]$SecureString
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Read-PasswordPair {
    while ($true) {
        $password1 = Read-Host "Deploy user password" -AsSecureString
        $password2 = Read-Host "Confirm deploy user password" -AsSecureString

        $plain1 = ConvertTo-PlainText -SecureString $password1
        $plain2 = ConvertTo-PlainText -SecureString $password2

        if ([string]::IsNullOrWhiteSpace($plain1)) {
            Write-Host "Password cannot be empty." -ForegroundColor Yellow
            continue
        }

        if ($plain1 -ne $plain2) {
            Write-Host "Passwords do not match. Try again." -ForegroundColor Yellow
            continue
        }

        return $plain1
    }
}

function Collect-AuthenticationSettings {
    param(
        [System.Collections.IDictionary]$State
    )

    $hasPassword = -not [string]::IsNullOrWhiteSpace($State.DeployPassword)
    $hasKey = (-not [string]::IsNullOrWhiteSpace($State.PublicKeyPath)) -or (-not [string]::IsNullOrWhiteSpace($State.PublicKey))

    if ($hasPassword -and $hasKey) {
        $State.DisablePasswordAuthentication = $false
        return
    }

    if ($hasPassword -and -not $hasKey) {
        $State.DisablePasswordAuthentication = $false
        return
    }

    if (-not $hasPassword -and $hasKey) {
        $State.DisablePasswordAuthentication = $true
        return
    }

    Write-Host ""
    Write-Host "Authentication setup"
    Write-Host "  1. password"
    Write-Host "  2. publickey"
    Write-Host "  3. both"
    $authMode = Read-Choice -Prompt "Choose auth mode" -AllowedValues @("1", "2", "3") -DefaultValue "1"

    if ($authMode -in @("1", "3")) {
        $State.DeployPassword = Read-PasswordPair
    }

    if ($authMode -in @("2", "3")) {
        $keySource = Read-Choice -Prompt "Public key source: file or paste" -AllowedValues @("file", "paste") -DefaultValue "file"
        if ($keySource -eq "file") {
            while ($true) {
                $path = Read-Value -Prompt "Public key file path on target machine" -DefaultValue "C:\temp\id_ed25519.pub"
                if (Test-Path -LiteralPath $path) {
                    $State.PublicKeyPath = $path
                    break
                }

                Write-Host ("File not found: {0}" -f $path) -ForegroundColor Yellow
            }
        } else {
            while ($true) {
                $inlineKey = Read-Host "Paste the public key"
                if (-not [string]::IsNullOrWhiteSpace($inlineKey)) {
                    $State.PublicKey = $inlineKey.Trim()
                    break
                }

                Write-Host "Public key cannot be empty." -ForegroundColor Yellow
            }
        }
    }

    $State.DisablePasswordAuthentication = ($authMode -eq "2")
}

Write-Host ""
Write-Host "TradeNet Windows SSH target setup"
Write-Host "Press Enter to accept the default values."
Write-Host ""

$settings.DeployUser = Read-Value -Prompt "Deploy user" -DefaultValue $settings.DeployUser

while ($true) {
    $portValue = Read-Value -Prompt "SSH port" -DefaultValue ([string]$settings.Port)
    if ($portValue -match "^\d+$" -and [int]$portValue -ge 1 -and [int]$portValue -le 65535) {
        $settings.Port = [int]$portValue
        break
    }

    Write-Host "Port must be an integer between 1 and 65535." -ForegroundColor Yellow
}

$settings.DeployRoot = Read-Value -Prompt "Deploy root" -DefaultValue $settings.DeployRoot
$settings.AppRoot = Read-Value -Prompt "App root" -DefaultValue $settings.AppRoot
$settings.GrantAdministratorsGroup = Read-YesNo -Prompt "Add deploy user to Administrators group" -DefaultValue $settings.GrantAdministratorsGroup

Collect-AuthenticationSettings -State $settings

$parameters = @{}
foreach ($entry in $settings.GetEnumerator()) {
    switch ($entry.Key) {
        "GrantAdministratorsGroup" {
            if ([bool]$entry.Value) {
                $parameters[$entry.Key] = $true
            }
            continue
        }
        "IncludePasswordInReport" {
            if ([bool]$entry.Value) {
                $parameters[$entry.Key] = $true
            }
            continue
        }
        "PauseOnSuccess" {
            if ([bool]$entry.Value) {
                $parameters[$entry.Key] = $true
            }
            continue
        }
        "DisablePasswordAuthentication" {
            if ([bool]$entry.Value) {
                $parameters[$entry.Key] = $true
            }
            continue
        }
        default {
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
                $parameters[$entry.Key] = $entry.Value
            }
        }
    }
}

& (Join-Path $PSScriptRoot "Initialize-WindowsSshTarget.ps1") @parameters
