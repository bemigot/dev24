# E2E Python setup: checks for Pixi and the always-on global 'py' env.
# Dot-sourced by check-prerequisites.ps1 - shares $errors, $warnings, $fixes,
# $missing, $warningMessages, and Read-YesNo from helper.ps1.
#
# Required third-party modules (grepped from platform24-spa/tests/ and
# borderlands-rust/tests/):
#   requests, pyyaml (import: yaml), jsonschema, pyjwt (import: jwt),
#   websocket-client (import: websocket)
#
# Recommended approach on Windows: Pixi global 'py' env with Python 3.14.
# If Python 3.12+ with all modules is already present but Pixi is absent,
# the user is offered Pixi install + Python version selection (default: 3.14).

if (-not (Get-Variable -Name 'errors' -Scope Script -ErrorAction SilentlyContinue) -and
    -not (Get-Variable -Name 'errors' -Scope Global -ErrorAction SilentlyContinue)) {
    Write-Error "This script must be dot-sourced from check-prerequisites.ps1, not run directly."
    exit 1
}

# --- Discovery ---

$pixiBinDir      = "$env:UserProfile\.pixi\bin"
$pixiKnownExe    = "$pixiBinDir\pixi.exe"
$pixiCmd         = Get-Command pixi -ErrorAction SilentlyContinue
$pixiExe         = if ($pixiCmd) { $pixiCmd.Source } elseif (Test-Path $pixiKnownExe) { $pixiKnownExe } else { $null }
$pyGlobalPython  = "$env:UserProfile\.pixi\envs\py\python.exe"

# conda-forge/pip package name -> Python import name
$reqModules = [ordered]@{
    'requests'         = 'requests'
    'pyyaml'           = 'yaml'
    'jsonschema'       = 'jsonschema'
    'pyjwt'            = 'jwt'
    'websocket-client' = 'websocket'
}

# $pythonCmd is either a bare exe path (string) or a command array such as
# @($pyLauncher, '-3') for the Windows 'py' launcher. @($pythonCmd) normalises a
# string to a 1-element array, so existing string call sites keep working.
function Test-Imports($pythonCmd, $importNames) {
    $parts = @($pythonCmd)
    $exe   = $parts[0]
    $pre   = if ($parts.Count -gt 1) { $parts[1..($parts.Count - 1)] } else { @() }
    $missing = @()
    foreach ($imp in $importNames) {
        & $exe @pre -c "import $imp" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $missing += $imp }
    }
    return $missing
}

function Read-PyVersion {
    $answer = (Read-Host "    Python version [3.12/3.13/3.14]").Trim()
    if ($answer -match '^3\.(12|13|14)$') { return $answer }
    return '3.14'  # TODO explain
}

function Install-PixiPyEnv($pyVersion) {
    Write-Host "  Setting up Pixi global 'py' env (Python $pyVersion + E2E modules)..."
    & $pixiExe global install --environment py `
        --expose python3=python --expose python=python `
        "python=$pyVersion.*" requests pyyaml jsonschema pyjwt websocket-client
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAIL: pixi global install failed"
        $script:missing += "Python env  ->  pixi global install --environment py python=$pyVersion.* requests pyyaml jsonschema pyjwt websocket-client"
        $script:errors++
        return $false
    }
    Write-Host "  FIXED: Pixi 'py' env ready with Python $pyVersion"
    $script:fixes++
    return $true
}

# --- Step 1: ensure Pixi is present ---

if (-not $pixiExe) {
    # Recognise the Windows 'py' launcher first. If it yields Python >= 3.12 with
    # all E2E modules, that satisfies the suite (run-f4 uses PYTHON_BIN=py -3.12),
    # so Pixi is not needed - report OK and skip the Pixi-centric path entirely.
    $pyLauncher = (Get-Command py -ErrorAction SilentlyContinue).Source
    if (-not $pyLauncher) {
        $pyLauncher = @("$env:WINDIR\py.exe", "$env:LocalAppData\Programs\Python\Launcher\py.exe") |
                      Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if ($pyLauncher) {
        # Resolve the real interpreter via the launcher ONCE, then use that exe
        # directly for the version + module checks. The empty-stdin pipe ('' |) is
        # required: the py launcher blocks reading console stdin when its output is
        # redirected, which hangs an interactive run (a background job has no console
        # stdin, so it never shows there). A direct python.exe has no such issue.
        $pyExe = ('' | & $pyLauncher -3 -c "import sys; print(sys.executable)" 2>$null) |
                 Select-Object -First 1
        if ($pyExe -and (Test-Path $pyExe)) {
            $verRaw = & $pyExe -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>&1
            $pyVer  = ($verRaw | Select-Object -First 1)
            if ("$pyVer" -match '^\d+\.\d+') {
                $p = $pyVer -split '\.'
                $pyOk = ([int]$p[0] -gt 3) -or ([int]$p[0] -eq 3 -and [int]$p[1] -ge 12)
                if ($pyOk) {
                    $missMods = Test-Imports $pyExe $reqModules.Values
                    if ($missMods.Count -eq 0) {
                        Write-Host "  OK: py launcher -> Python $pyVer with all E2E modules (Pixi not needed)"
                        return
                    }
                    $pkgs = $missMods | ForEach-Object { ($reqModules.GetEnumerator() | Where-Object Value -eq $_).Key }
                    Write-Host "  NOTE: py launcher -> Python $pyVer but missing modules: $($missMods -join ', ')"
                    Write-Host "        add them with:  py -3 -m pip install $($pkgs -join ' ')"
                }
            }
        }
    }

    # Check whether an existing Python is good enough to unblock the user.
    # Skip the Windows Store alias stubs in WindowsApps: they don't run Python,
    # they print "Python was not found; install from the Microsoft Store...",
    # which would otherwise be parsed as a version and crash the [int] cast below.
    # (No ?? operator: it is PowerShell 7+ only and this script must parse under 5.1.)
    $existingPy = Get-Command python3, python -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -and $_.Source -notmatch '\\WindowsApps\\' } |
        Select-Object -First 1
    $existingOk = $false
    $existingVer = ''

    if ($existingPy) {
        $verOut = (& $existingPy.Source -c `
            "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>&1) | Select-Object -First 1
        # Only trust output that actually looks like a version (guards against any
        # stray stub/error text leaking through).
        if ("$verOut" -match '^\d+\.\d+') {
            $existingVer = "$verOut"
            $parts = $existingVer -split '\.'
            $atLeast312 = ([int]$parts[0] -gt 3) -or ([int]$parts[0] -eq 3 -and [int]$parts[1] -ge 12)
            if ($atLeast312) {
                $missMods = Test-Imports $existingPy.Source $reqModules.Values
                $existingOk = ($missMods.Count -eq 0)
                if (-not $existingOk) {
                    Write-Host "  NOTE: Python $existingVer found but missing modules: $($missMods -join ', ')"
                }
            }
        }
    }

    if ($existingOk) {
        Write-Host "  NOTE: Python $existingVer with required modules found"
        Write-Host "        Pixi is the recommended approach on Windows (locked env, Python 3.14)"
    } else {
        Write-Host "  MISSING: Pixi not installed (recommended Python manager on Windows)"
    }

    if (Read-YesNo "Install Pixi and set up always-on Python env?") {
        Write-Host "  Installing Pixi via winget..."
        winget install -e --id prefix-dev.pixi
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FAIL: winget install failed"
            Write-Host "  MANUAL: https://pixi.sh"
            if ($existingOk) {
                $warningMessages += "Pixi install failed  ->  winget install prefix-dev.pixi"
                $warnings++
            } else {
                $missing += "pixi  ->  winget install prefix-dev.pixi"
                $errors++
            }
        } else {
            Write-Host "  FIXED: Pixi installed"
            $fixes++
            $env:PATH = "$pixiBinDir;" + $env:PATH
            $pixiExe = $pixiKnownExe
        }
    } else {
        Write-Host "  SKIPPED"
        if ($existingOk) {
            $warningMessages += "Pixi not installed  ->  winget install prefix-dev.pixi"
            $warnings++
        } else {
            $missing += "pixi  ->  winget install prefix-dev.pixi"
            $errors++
        }
    }
}

# --- Step 2: ensure the global 'py' env is set up ---

if ($pixiExe) {
    $pixiVer = (& $pixiExe --version 2>&1)
    if (-not $pixiCmd) {
        Write-Host "  WARN: pixi $pixiVer found at $pixiExe but not on PATH (restart terminal)"
        $warningMessages += "pixi not on PATH  ->  restart terminal or add $pixiBinDir to PATH"
        $warnings++
    } else {
        Write-Host "  OK: pixi $pixiVer"
    }

    if (-not (Test-Path $pyGlobalPython)) {
        Write-Host "  NOTE: Pixi global 'py' env not set up (always-on Python 3.14 with E2E modules)"
        if (Read-YesNo "Set up always-on Python env now?") {
            Write-Host "  (press Enter to accept default 3.14)"
            $pyVer = Read-PyVersion
            Install-PixiPyEnv $pyVer | Out-Null
        } else {
            Write-Host "  SKIPPED"
            $warningMessages += "Pixi 'py' env not set up  ->  pixi global install --environment py python=3.14.* requests pyyaml jsonschema pyjwt websocket-client"
            $warnings++
        }
    } else {
        $missMods = Test-Imports $pyGlobalPython $reqModules.Values
        if ($missMods.Count -gt 0) {
            Write-Host "  WARN: Pixi 'py' env missing modules: $($missMods -join ', ')"
            if (Read-YesNo "Add missing modules to Pixi 'py' env?") {
                $pkgsToAdd = $missMods | ForEach-Object {
                    ($reqModules.GetEnumerator() | Where-Object Value -eq $_).Key
                }
                & $pixiExe global install --environment py @pkgsToAdd
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  FIXED: modules added to Pixi 'py' env"
                    $fixes++
                } else {
                    Write-Host "  FAIL: pixi global install failed"
                    $warningMessages += "Pixi 'py' env still missing: $($missMods -join ', ')"
                    $warnings++
                }
            } else {
                Write-Host "  SKIPPED"
                $warningMessages += "Pixi 'py' env missing: $($missMods -join ', ')  ->  pixi global install --environment py <pkg>"
                $warnings++
            }
        } else {
            $pyVer = (& $pyGlobalPython -c `
                "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')" 2>&1)
            Write-Host "  OK: Pixi 'py' env, Python $pyVer, all E2E modules present"
        }
    }

    # --- Step 3: check for Windows App execution alias interference ---
    # WindowsApps stubs for python/python3 redirect to the Microsoft Store and
    # typically sit earlier on PATH than .pixi\bin, shadowing Pixi's shims.
    # The stubs live in user-writable %LOCALAPPDATA%\Microsoft\WindowsApps so
    # we can remove them directly, same effect as toggling them off in Settings.
    if (Test-Path $pyGlobalPython) {
        $winAppsDir = "$env:LocalAppData\Microsoft\WindowsApps"
        $stubs = @('python.exe', 'python3.exe') |
            Where-Object { Test-Path "$winAppsDir\$_" } |
            ForEach-Object { "$winAppsDir\$_" }

        if ($stubs) {
            $names = $stubs | ForEach-Object { Split-Path $_ -Leaf }
            Write-Host "  WARN: $($names -join ' and ') in WindowsApps shadow Pixi's shims"
            if (Read-YesNo "Remove Windows Store stubs ($($names -join ', ')) so python/python3 resolve to Pixi?") {
                $removed = @()
                foreach ($stub in $stubs) {
                    Remove-Item $stub -Force -ErrorAction SilentlyContinue
                    if (-not (Test-Path $stub)) { $removed += (Split-Path $stub -Leaf) }
                }
                if ($removed.Count -eq $stubs.Count) {
                    Write-Host "  FIXED: removed $($removed -join ', ') - python/python3 now resolve to Pixi"
                    $fixes++
                } else {
                    $failed = $names | Where-Object { $removed -notcontains $_ }
                    Write-Host "  PARTIAL: could not remove $($failed -join ', ')"
                    Write-Host "           Fix manually: Settings > Apps > Advanced app settings > App execution aliases"
                    Write-Host "                        toggle OFF: python.exe  and  python3.exe"
                    $warningMessages += "Windows App alias still active for $($failed -join '/')  ->  Settings > Apps > App execution aliases"
                    $warnings++
                }
            } else {
                Write-Host "  SKIPPED"
                $warningMessages += "$($names -join '/') shadowed by Windows App alias  ->  Settings > Apps > App execution aliases > disable python.exe / python3.exe"
                $warnings++
            }
        }
    }
}
