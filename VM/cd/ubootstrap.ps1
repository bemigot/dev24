#Requires -Version 5.1
<#
    ubootstrap.ps1 - user bootstrap for a bare Windows dev machine.

    Installs Python (and nothing else) so check-req.py and the rest of the
    toolchain setup can run. Self-contained: no repo, no Git - a developer can
    fetch this single file over HTTP and run it, or run it from the MAINTCD
    control disc. Idempotent: a no-op when a real Python is already on PATH.

        powershell -ExecutionPolicy Bypass -File .\ubootstrap.ps1

    If you DOWNLOADED this file (browser / HTTP), Windows tags it with the
    Mark-of-the-Web, so it won't run even under RemoteSigned until you clear it:
        Unblock-File .\ubootstrap.ps1
    The `-ExecutionPolicy Bypass -File` form above runs it regardless.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The Microsoft Store ships 0-byte "App execution alias" stubs for python.exe /
# python3.exe that bounce the user to the Store instead of running Python.
# Remove them so the real interpreter wins. (Only the 0-byte stubs - never a
# real python.exe that happens to live here.)
function Disable-StorePythonAliases {
    $dir = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    foreach ($name in 'python.exe', 'python3.exe') {
        $stub = Join-Path $dir $name
        if (Test-Path $stub) {
            try {
                if ((Get-Item $stub -Force).Length -eq 0) {
                    Remove-Item $stub -Force
                    Write-Host "  removed Store alias stub: $name"
                }
            } catch {
                Write-Warning "  could not remove ${stub}: $($_.Exception.Message)"
            }
        }
    }
}

# True when `py` or `python` runs a real interpreter (a trivial import proves it,
# and distinguishes it from the Store stub which can't import anything).
function Test-RealPython {
    foreach ($exe in 'py', 'python') {
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
        try {
            $v = & $exe -c "import json,sys; print(sys.version.split()[0])" 2>$null
            if ($LASTEXITCODE -eq 0 -and $v) {
                Write-Host "  found working Python via '$exe': $v"
                return $true
            }
        } catch { }
    }
    return $false
}

Write-Host "== ubootstrap: ensure Python =="

# Drop the stubs first so the probe below can't trip the Store redirect.
Disable-StorePythonAliases

if (Test-RealPython) {
    Write-Host "Python already present and working - nothing to do."
    exit 0
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Error "winget (App Installer) not found. Install 'App Installer' from the Microsoft Store, then re-run."
    exit 1
}

# 9NQ7512CXL7T = Python install manager 26.1 (Microsoft Store).
Write-Host "Installing Python via winget (9NQ7512CXL7T) ..."
winget install --id 9NQ7512CXL7T `
    --accept-package-agreements --accept-source-agreements --disable-interactivity
$rc = $LASTEXITCODE

# NOTE: do NOT remove the WindowsApps python.exe/python3.exe aliases after this -
# the Python Install Manager creates its OWN aliases there, and deleting them is
# exactly what breaks `python`/`python3` (only `py` survives). The pre-install
# pass above already cleared the Store redirect stubs.

if ($rc -ne 0) {
    Write-Error "winget install returned $rc."
    exit $rc
}

Write-Host ""
Write-Host "Done. Open a NEW terminal so PATH refreshes, then check:  py --version"
