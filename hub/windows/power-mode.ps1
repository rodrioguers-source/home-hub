# Switches the processor limits on mains power between a cool, quiet hub mode and full performance.
# Only these three settings change, on the active power plan; battery values are left alone.
#   powershell -ExecutionPolicy Bypass -File hub\windows\power-mode.ps1 -Mode Hub
#   powershell -ExecutionPolicy Bypass -File hub\windows\power-mode.ps1 -Mode Performance
param(
    [Parameter(Mandatory = $true)][ValidateSet("Hub", "Performance")][string]$Mode,
    [switch]$Elevated
)
$ErrorActionPreference = "Stop"

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-Mode", $Mode, "-Elevated")
    exit
}

if ($Mode -eq "Hub") {
    powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 50
    powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5
    powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE 0
} else {
    powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100
    powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE 2
}
powercfg /setactive SCHEME_CURRENT

Write-Host "$Mode mode is on. Values on mains power now (hex: 0x32 = 50, 0x64 = 100, 0x05 = 5; boost 0 = off, 2 = aggressive):"
foreach ($setting in "PROCTHROTTLEMAX", "PROCTHROTTLEMIN", "PERFBOOSTMODE") {
    $line = powercfg /query SCHEME_CURRENT SUB_PROCESSOR $setting | Select-String "Current AC"
    Write-Host ("  {0}: {1}" -f $setting, ($line -replace ".*:\s*", ""))
}
if ($Elevated) { Read-Host "Press Enter to close" | Out-Null }
