# windows-env1.ps1  - setup a "typical" Windows dev env
# p24core(windows-DX) 2a7607e4 2026-06-02 Python DX w.i.p. - scripts/tmp-env1.ps1

# Provisions a machine to resemble the principal E2E dev's setup,
# so check-prerequisites.ps1 can be re-run against a realistic environment:
#   - Java JDK 21 (Eclipse Temurin, LTS)
#   - Node.js 22 (LTS)
#   - native PostgreSQL 17 (full: server + psql + pgAdmin) on :5432
#   - Docker Desktop
#   - Python 3.12 via the py.exe launcher (NO Pixi)
#   - env.bat pinning PYTHON_BIN=py -3.12 + matching DB creds
#
# This deliberately creates the native-PG-on-5432 state that check-prerequisites.ps1
# step 5b warns about and offers to stop/disable. Run as Administrator.

$ErrorActionPreference = 'Stop'

# Admin gate: print the elevation command instead of dying on a #Requires statement.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "This script must run as Administrator (it installs a PostgreSQL service, Docker Desktop, edits PATH)." -ForegroundColor Yellow
    Write-Host "Relaunch elevated with:" -ForegroundColor Yellow
    Write-Host "  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-File','$PSCommandPath'"
    exit 1
}
$RepoRoot   = Split-Path -Parent $PSScriptRoot   # scripts/ -> repo root
$PgPassword = 'postgres'   # matches sample.env defaults (DATASOURCES_DEFAULT_PASSWORD)

Write-Host "=== 1/6  Java JDK 21 (Temurin) ===" -ForegroundColor Cyan
# Eclipse Adoptium Temurin 21 (LTS). ADDLOCAL features set JAVA_HOME + PATH so
# javac lands on PATH (check-prerequisites.ps1 gates on javac, not java).
winget install -e --id EclipseAdoptium.Temurin.21.JDK --silent --accept-package-agreements --accept-source-agreements `
    --custom "ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJavaHome"

Write-Host "=== 2/6  Native PostgreSQL 17 (full) ===" -ForegroundColor Cyan
# NOTE: verify the exact id first:  winget search PostgreSQL.PostgreSQL
# The EDB installer accepts unattended args; --custom is passed straight through.
winget install -e --id PostgreSQL.PostgreSQL.17 --silent --accept-package-agreements --accept-source-agreements `
    --custom "--mode unattended --superpassword $PgPassword --serverport 5432 --enable-components server,commandlinetools,pgAdmin"
# If --custom args are rejected by your winget/installer build, run the EDB
# installer interactively instead and choose port 5432 + password '$PgPassword'.

$PgBin = "$env:ProgramFiles\PostgreSQL\17\bin"
if (-not (Test-Path "$PgBin\psql.exe")) { throw "psql not found at $PgBin - PG install may have failed" }

# Put psql/createdb on PATH (machine-wide) so the prereq script & shells see it
$machPath = [Environment]::GetEnvironmentVariable('Path','Machine')
if ($machPath -notlike "*$PgBin*") {
    [Environment]::SetEnvironmentVariable('Path', "$PgBin;$machPath", 'Machine')
}
$env:PATH = "$PgBin;$env:PATH"

# Create the solution DB(s) inside the NATIVE instance (CI uses murabex).
# Idempotent: query first, create only if absent. We avoid `createdb 2>$null`
# because in Windows PowerShell 5.1 a native command's stderr surfaces as a
# NativeCommandError, which $ErrorActionPreference='Stop' turns terminating.
$env:PGPASSWORD = $PgPassword
foreach ($db in 'murabex') {
    $exists = & "$PgBin\psql.exe" -U postgres -h localhost -p 5432 -tAc `
        "SELECT 1 FROM pg_database WHERE datname='$db'"
    if ("$exists".Trim() -eq '1') {
        Write-Host "  db already exists: $db"
    } else {
        & "$PgBin\createdb.exe" -U postgres -h localhost -p 5432 $db
        Write-Host "  created db: $db"
    }
}

Write-Host "=== 3/6  Docker Desktop ===" -ForegroundColor Cyan
winget install -e --id Docker.DockerDesktop --silent --accept-package-agreements --accept-source-agreements
Write-Host "  NOTE: log out/in (or reboot) for the docker CLI to land on PATH."

Write-Host "=== 4/6  Python 3.12 + py launcher + E2E modules ===" -ForegroundColor Cyan
# Python.Python.3.12 ships the py.exe launcher and registers itself with it.
winget install -e --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements

# winget updates the persistent PATH, but not this already-running session. Refresh
# it so 'py' resolves; fall back to known install locations if the launcher still
# isn't on PATH (winget installs Python per-user by default).
$env:PATH = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')
$py = (Get-Command py -ErrorAction SilentlyContinue).Source
if (-not $py) {
    $py = @("$env:WINDIR\py.exe", "$env:LocalAppData\Programs\Python\Launcher\py.exe") |
          Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $py) { throw "py launcher not found after install - open a new shell and re-run" }

# Install the modules the validators import, into the 3.12 interpreter specifically:
& $py -3.12 -m pip install --upgrade pip
& $py -3.12 -m pip install requests pyyaml jsonschema pyjwt websocket-client

if (Get-Command pixi -ErrorAction SilentlyContinue) {
    Write-Warning ("Pixi is installed - run-f4.bat would prefer it over 'py -3.12'. " +
                   "env.bat (below) forces PYTHON_BIN, so the fallback path is still used.")
}

Write-Host "=== 5/6  Node.js 22 (LTS) ===" -ForegroundColor Cyan
# Pinned to major 22 (check-prerequisites.ps1 requires Node 22+).
winget install -e --id OpenJS.NodeJS.22 --silent --accept-package-agreements --accept-source-agreements

Write-Host "=== 6/6  env.bat (forces iosif's PYTHON_BIN + DB creds) ===" -ForegroundColor Cyan
$envBat = Join-Path $RepoRoot 'env.bat'
@"
@echo off
REM Generated by scripts/tmp-env1.ps1 - mirrors the principal E2E dev's machine.
set "DATASOURCES_DEFAULT_USERNAME=postgres"
set "DATASOURCES_DEFAULT_PASSWORD=$PgPassword"
set "PYTHON_BIN=py -3.12"
"@ | Set-Content $envBat -Encoding ASCII
Write-Host "  wrote $envBat (gitignored)"

Write-Host "`nDone." -ForegroundColor Green
Write-Host "Open a NEW terminal (to pick up the refreshed PATH) and verify Python + E2E modules:" -ForegroundColor Green
Write-Host "  py -V"
Write-Host "  py -c `"import requests, yaml, jsonschema, jwt, websocket; print('all E2E modules OK')`""
Write-Host "Then re-run:  powershell -File .\check-prerequisites.ps1" -ForegroundColor Green
Write-Host "Expect step 5b to flag the native postgresql-x64-17 service as a :5432 conflict."
