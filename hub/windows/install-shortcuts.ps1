# Puts two desktop shortcuts that run power-mode.ps1. Windows doesn't allow ":" in a file name, so the
# names use a dash. Run once:  powershell -ExecutionPolicy Bypass -File hub\windows\install-shortcuts.ps1
$ErrorActionPreference = "Stop"
$script = Join-Path $PSScriptRoot "power-mode.ps1"
$desktop = [Environment]::GetFolderPath("Desktop")
$shell = New-Object -ComObject WScript.Shell

foreach ($s in @(@{Name = "Laptop - hub mode (cool)"; Mode = "Hub"}, @{Name = "Laptop - performance mode"; Mode = "Performance"})) {
    $path = Join-Path $desktop "$($s.Name).lnk"
    $link = $shell.CreateShortcut($path)
    $link.TargetPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $link.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Mode $($s.Mode)"
    $link.WorkingDirectory = $PSScriptRoot
    $link.Description = "Set the processor limits on mains power to $($s.Mode) mode"
    $link.Save()
    Write-Host "Created $path"
}
