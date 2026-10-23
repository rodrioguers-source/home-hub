# Registers "Home Hub" in Task Scheduler: starts at your logon, restarts if it stops, never times out.
# Run in PowerShell (no admin needed):  powershell -ExecutionPolicy Bypass -File hub\windows\install-task.ps1
$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$python = Join-Path $repo ".venv\Scripts\pythonw.exe"
if (-not (Test-Path $python)) { throw "No .venv found at $repo\.venv. Create it first (see hub\README.md)." }
$user = "$env:USERDOMAIN\$env:USERNAME"

$action = New-ScheduledTaskAction -Execute $python -Argument "-m hub" -WorkingDirectory $repo
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
# Interactive: the token lives in your Credential Manager and toasts need your desktop session.
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName "Home Hub" -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "TV, lights, PS5, scenes, washer and the phone app (LAN only)." -Force | Out-Null
Write-Host "Registered the 'Home Hub' task. Start it now with:  Start-ScheduledTask -TaskName 'Home Hub'"
