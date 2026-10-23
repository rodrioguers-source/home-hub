# Updates the hub from a zip made on the Mac with `git archive` (see hub\README.md, "Updating the hub").
# Keeps .venv. Settings, presets, paired phones, logs and secrets live in %APPDATA%\HomeHub and Credential Manager,
# so they aren't touched.
# Run in PowerShell:  powershell -ExecutionPolicy Bypass -File D:\home-hub\hub\windows\update.ps1 E:\home-hub.zip
param([Parameter(Mandatory = $true)][string]$Zip)
$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$python = Join-Path $repo ".venv\Scripts\python.exe"
if (-not (Test-Path $python)) { throw "No .venv at $repo\.venv. Run this copy of update.ps1 from the installed hub, not from the new zip." }
$Zip = (Resolve-Path -LiteralPath $Zip).Path

$stage = Join-Path ([IO.Path]::GetTempPath()) ("home-hub-update-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
try {
    Expand-Archive -LiteralPath $Zip -DestinationPath $stage
    $root = $stage
    if (-not (Test-Path (Join-Path $root "hub\__main__.py"))) {
        $inner = Get-ChildItem -LiteralPath $stage -Directory | Where-Object { Test-Path (Join-Path $_.FullName "hub\__main__.py") } | Select-Object -First 1
        if (-not $inner) { throw "$Zip doesn't look like the home hub: there's no hub\__main__.py inside." }
        $root = $inner.FullName
    }

    $task = Get-ScheduledTask -TaskName "Home Hub" -ErrorAction SilentlyContinue
    if ($task) {
        Write-Host "Stopping the Home Hub task..."
        Stop-ScheduledTask -TaskName "Home Hub"
        Start-Sleep -Seconds 2
    }

    Write-Host "Copying the new files into $repo ..."
    # /MIR also removes files that were deleted from the repo; /XD leaves .venv (and Python's caches) alone.
    robocopy $root $repo /MIR /XD .venv .git __pycache__ /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying the files failed (robocopy exit code $LASTEXITCODE)." }

    Write-Host "Updating Python packages..."
    & $python -m pip install --disable-pip-version-check -q -r (Join-Path $repo "hub\requirements.txt")
    if ($LASTEXITCODE -ne 0) { throw "pip install -r hub\requirements.txt failed. The files are updated; fix pip, then start the task." }
    & $python -m pip show -q pyremoteplay *> $null
    if ($LASTEXITCODE -eq 0) {
        & $python -m pip install --disable-pip-version-check -q -r (Join-Path $repo "hub\requirements-ps5-windows.txt")
        if ($LASTEXITCODE -ne 0) { throw "pip install -r hub\requirements-ps5-windows.txt failed." }
    }

    if ($task) {
        Start-ScheduledTask -TaskName "Home Hub"
        Write-Host "Updated and restarted the Home Hub task. Logs: $env:APPDATA\HomeHub\hub.log"
    } else {
        Write-Host "Updated. There's no Home Hub task yet: see step 7 in hub\README.md."
    }
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
