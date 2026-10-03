[CmdletBinding()]
param(
    [string]$UpstreamAdapterName = 'Meta',
    [string]$WifiAdapterName = 'WLAN',
    [ValidateSet('2.4GHz', '5GHz', 'Auto', 'Keep')][string]$Band = '2.4GHz'
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Use Windows PowerShell 5.1 (powershell.exe) for WinRT tethering.'
}

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$adapters = @(Get-NetAdapter -Name $UpstreamAdapterName -ErrorAction Stop)
if ($adapters.Count -ne 1 -or $adapters[0].Status -ne 'Up') {
    throw 'Expected one active upstream adapter. Enable Clash TUN first, or choose your physical adapter.'
}
$wifiAdapters = @(Get-NetAdapter -Name $WifiAdapterName -ErrorAction Stop)
if ($wifiAdapters.Count -ne 1 -or $wifiAdapters[0].AdminStatus -ne 'Up') {
    throw 'Expected one enabled Wi-Fi adapter. Check the adapter name and enable Wi-Fi.'
}
$profiles = [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]::GetConnectionProfiles()
$selected = @($profiles | Where-Object { $_.NetworkAdapter.NetworkAdapterId -eq [guid]$adapters[0].InterfaceGuid })
if ($selected.Count -ne 1) { throw 'Expected one connection profile for the upstream adapter.' }
$wifiProfile = $profiles | Where-Object { $_.NetworkAdapter.NetworkAdapterId -eq [guid]$wifiAdapters[0].InterfaceGuid } | Select-Object -First 1
$managerType = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
if ($wifiProfile) {
    $manager = $managerType::CreateFromConnectionProfile($selected[0], $wifiProfile.NetworkAdapter)
} else {
    $manager = $managerType::CreateFromConnectionProfile($selected[0])
}
$resultType = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
$operationTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetGenericArguments().Count -eq 1 -and
    $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1
$actionTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and -not $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
} | Select-Object -First 1
function Wait-TetherOperation($Operation) {
    $task = $operationTaskMethod.MakeGenericMethod($resultType).Invoke($null, @($Operation))
    if (-not $task.Wait(20000)) { throw 'Tethering timed out. Check hotspot state before retrying.' }
    if ($task.Result.Status.ToString() -ne 'Success') {
        throw ('Tethering failed: ' + $task.Result.Status + ' ' + $task.Result.AdditionalErrorMessage)
    }
}
function Wait-TetherAction($Operation) {
    $task = $actionTaskMethod.Invoke($null, @($Operation))
    if (-not $task.Wait(20000)) { throw 'Hotspot configuration timed out.' }
}

$oldConfiguration = $manager.GetCurrentAccessPointConfiguration()
$oldBand = $oldConfiguration.Band
$wasOn = $manager.TetheringOperationalState.ToString() -eq 'On'
$bandChanged = $false
try {
    if ($wasOn) { Wait-TetherOperation ($manager.StopTetheringAsync()) }
    if ($Band -ne 'Keep') {
        $configuration = $manager.GetCurrentAccessPointConfiguration()
        $bandType = [Windows.Networking.NetworkOperators.TetheringWiFiBand,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
        $configuration.Band = switch ($Band) {
            '2.4GHz' { $bandType::TwoPointFourGigahertz }
            '5GHz' { $bandType::FiveGigahertz }
            'Auto' { $bandType::Auto }
        }
        Wait-TetherAction ($manager.ConfigureAccessPointAsync($configuration))
        $bandChanged = $true
    }
    Wait-TetherOperation ($manager.StartTetheringAsync())
    [pscustomobject]@{
        Upstream = $adapters[0].Name
        Band = $manager.GetCurrentAccessPointConfiguration().Band.ToString()
        Hotspot = $manager.TetheringOperationalState.ToString()
        Note = 'Reconnect the phone and verify internet access. No automatic switching task is installed.'
    }
} catch {
    if ($bandChanged) {
        try {
            $restoreConfiguration = $manager.GetCurrentAccessPointConfiguration()
            $restoreConfiguration.Band = $oldBand
            Wait-TetherAction ($manager.ConfigureAccessPointAsync($restoreConfiguration))
        } catch { Write-Warning 'Could not restore the previous hotspot band.' }
    }
    throw
}
