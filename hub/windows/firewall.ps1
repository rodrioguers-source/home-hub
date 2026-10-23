# Lets phones on the home Wi-Fi reach the hub on TCP 8787, and the one-off secret transfer use 8787 or 8788.
# Private profile and local subnet only.
# Run in an admin PowerShell:  powershell -ExecutionPolicy Bypass -File hub\windows\firewall.ps1
$ErrorActionPreference = "Stop"
Get-NetFirewallRule -DisplayName "Home Hub*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName "Home Hub (8787-8788)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8787-8788 `
    -Profile Private -RemoteAddress LocalSubnet | Out-Null
Write-Host "Firewall rule added. Check the Wi-Fi network is set to Private:"
Get-NetConnectionProfile | Format-Table Name, InterfaceAlias, NetworkCategory
