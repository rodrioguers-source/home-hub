# On mains power: closing the lid does nothing, and the laptop never sleeps or hibernates.
# Battery behaviour is left alone. Run in PowerShell:  powershell -ExecutionPolicy Bypass -File hub\windows\power.ps1
$ErrorActionPreference = "Stop"
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /setactive SCHEME_CURRENT
Write-Host "Done. Current lid action on AC (0 = do nothing):"
powercfg /query SCHEME_CURRENT SUB_BUTTONS LIDACTION | Select-String "Current AC"
