# Shared function library for check-prerequisites.ps1, its sub-scripts, and
# scripts\defender-exclusions.ps1.
#
# This file only DEFINES functions - it has NO top-level side effects - so it is
# safe to dot-source from anywhere: check-prerequisites.ps1 sources it right after
# initialising its counters, and defender-exclusions.ps1 sources it just for the
# shared Defender exclusion rules.
#
# Functions that bump the shared counters ($errors/$warnings/$fixes) or append to
# the shared lists ($missing/$warningMessages) use the $script: scope, so the
# caller must have those variables defined (check-prerequisites.ps1 does). The
# rule/definition functions (Get-DefenderExclusionRules, Read-YesNo) use no
# counters and are safe to call from any context.

function Read-YesNo($prompt) {
    $answer = Read-Host "  $prompt [Y/n]"
    return ($answer -eq '' -or $answer -match '^[Yy]')
}

# PowerShell version pre-check. On Windows PowerShell 5.1 it offers the PS7
# upgrade. Returns $true when the caller should exit (PS7 was just installed and
# the user must restart under it); $false to continue in the current shell.
function Test-PowerShellVersion {
    if ($PSVersionTable.PSVersion.Major -ge 7) { return $false }
    Write-Host "  NOTE: PowerShell $($PSVersionTable.PSVersion) detected - PS 7+ recommended"
    if (Read-YesNo "Upgrade PowerShell to version 7?") {
        winget install -e --id Microsoft.PowerShell
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FAIL: winget install failed - continuing with PS $($PSVersionTable.PSVersion)"
            Write-Host "  MANUAL: winget install Microsoft.PowerShell"
        } else {
            Write-Host "  PowerShell 7 installed. Run 'pwsh' to start it, then re-run this script."
            Write-Host ""
            Write-Host "  To make PS7 the default in Windows Terminal:"
            Write-Host "    Settings -> Startup -> Default profile -> PowerShell"
            Write-Host "    (if not listed: Settings -> Add new profile -> set command line to pwsh.exe)"
            Write-Host ""
            Write-Host "  Other launchers:"
            Write-Host "    Win+R          : type 'pwsh' instead of 'powershell'"
            Write-Host "    Start menu     : search 'pwsh' - pin it"
            Write-Host "    VS Code        : Ctrl+Shift+P -> 'Open User Settings JSON'"
            Write-Host "                     set terminal.integrated.defaultProfile.windows to 'PowerShell'"
            return $true
        }
    } else {
        $env:MISE_PWSH_CHPWD_WARNING = 0
    }
    return $false
}

# Discovers mise.exe, offers a winget install if absent, activates mise for the
# current session, and ensures 'mise activate pwsh' is wired into $PROFILE so
# mise-managed tools (Java, Node, ...) are on PATH in every new terminal.
# Sets $script:miseExe for later steps (Java install, Invoke-NodeReinstall).
function Initialize-Mise {
    $miseKnownPaths = @(
        "$env:LocalAppData\Microsoft\WinGet\Links\mise.exe",
        "$env:LocalAppData\Microsoft\WinGet\Packages\jdx.mise_Microsoft.Winget.Source_8wekyb3d8bbwe\mise\bin\mise.exe",
        "$env:UserProfile\.local\bin\mise.exe"
    )
    $mise = Get-Command mise -ErrorAction SilentlyContinue
    $script:miseExe = if ($mise) { $mise.Source } else { $miseKnownPaths | Where-Object { Test-Path $_ } | Select-Object -First 1 }

    if (-not $script:miseExe) {
        Write-Host "  MISSING: mise not found"
        if (Read-YesNo "Install mise (dev toolchain manager)?") {
            Write-Host "  Installing mise via winget..."
            winget install -e --id jdx.mise
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  FAIL: winget install failed"
                Write-Host "  MANUAL: https://mise.jdx.dev/getting-started.html"
                $script:missing += "mise  ->  winget install jdx.mise"
                $script:errors++
            } else {
                Write-Host "  FIXED: mise installed"
                $script:fixes++
                $script:miseExe = $miseKnownPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            }
        } else {
            Write-Host "  SKIPPED"
            $script:warningMessages += "mise not installed  ->  winget install jdx.mise"
            $script:warnings++
        }
    } elseif (-not $mise) {
        $miseVer = (& $script:miseExe --version 2>&1)
        Write-Host "  WARN: mise $miseVer found at $script:miseExe but not on PATH"
        Write-Host '  Run: $env:PATH = "' + (Split-Path $script:miseExe) + ';" + $env:PATH'
        $script:warningMessages += "mise not on PATH  ->  " + '$env:PATH = "' + (Split-Path $script:miseExe) + ';" + $env:PATH'
        $script:warnings++
    } else {
        $miseVer = (& mise --version 2>&1)
        Write-Host "  OK: mise $miseVer"
    }

    if ($script:miseExe) {
        & $script:miseExe activate pwsh | Out-String | Invoke-Expression

        $miseActivationLine = 'mise activate pwsh | Out-String | Invoke-Expression'
        $profileExists  = Test-Path $PROFILE
        $profileContent = if ($profileExists) { Get-Content $PROFILE -Raw } else { '' }
        if ($profileContent -notmatch [regex]::Escape('mise activate pwsh')) {
            Write-Host "  NOTE: mise is not activated in your PowerShell profile - tools installed via mise"
            Write-Host "        (Java, Node, etc.) won't be on PATH in new terminals"
            if (Read-YesNo "Add mise activation to your PowerShell profile ($PROFILE)?") {
                if (-not $profileExists) { New-Item -ItemType File -Force $PROFILE | Out-Null }
                Add-Content $PROFILE "`n# mise dev-tool manager`n$miseActivationLine"
                Write-Host "  FIXED: mise activation added to profile - takes effect in new terminals"
                $script:fixes++
            } else {
                Write-Host "  SKIPPED"
                Write-Host "  MANUAL: add this line to your `$PROFILE:"
                Write-Host "          $miseActivationLine"
                $script:warningMessages += "mise not in `$PROFILE  ->  add: $miseActivationLine"
                $script:warnings++
            }
        } else {
            Write-Host "  OK: mise activation present in PowerShell profile"
        }
    }
}

# Node.js reinstall via mise, called from the Node step when the installed
# version is older than 22 or not the latest LTS patch.
function Invoke-NodeReinstall($currentVer) {
    if (Read-YesNo "Uninstall Node.js v$currentVer and install latest LTS via mise?") {
        Write-Host "  Uninstalling Node.js..."
        winget uninstall --id OpenJS.NodeJS.LTS --silent 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  WARN: winget uninstall failed - uninstall Node.js manually, then run:"
            Write-Host "        mise use --global node@lts"
            $script:warningMessages += "Node.js uninstall failed - uninstall manually, then: mise use --global node@lts"
            $script:warnings++
        } else {
            Write-Host "  Installing latest Node.js LTS via mise..."
            & $script:miseExe use --global node@lts
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  FAIL: mise install failed"
                $script:missing += "Node.js  ->  mise use --global node@lts"
                $script:errors++
            } else {
                Write-Host "  FIXED: Node.js LTS installed via mise"
                $script:fixes++
            }
        }
    } else {
        Write-Host "  SKIPPED"
        $script:warningMessages += "Node.js v$currentVer outdated - run: mise use --global node@lts"
        $script:warnings++
    }
}

# PostgreSQL client tools: psql (>= 17) and pgAdmin 4, with winget install offers.
# pgAdmin bundled with the EDB installer lives under the PostgreSQL dir, not in a
# standalone 'pgAdmin 4' folder, so both locations are probed.
function Test-PostgresTools {
    $pgNeedInstall      = $false
    $pgAdminNeedInstall = $false

    $psqlKnownPaths = 16..20 | ForEach-Object { "$env:ProgramFiles\PostgreSQL\$_\bin\psql.exe" }
    $psql = Get-Command psql -ErrorAction SilentlyContinue
    $psqlExe = if ($psql) { $psql.Source } else { $psqlKnownPaths | Where-Object { Test-Path $_ } | Select-Object -First 1 }

    if (-not $psqlExe) {
        Write-Host "  FAIL: psql not found - not installed"
        $script:missing += "PostgreSQL 17+  ->  winget install PostgreSQL.PostgreSQL.18"
        $pgNeedInstall = $true
        $script:errors++
    } else {
        $psqlVerLine = (& $psqlExe --version 2>&1)
        $psqlVer     = ($psqlVerLine -split ' ')[2]
        $psqlMajor   = [int]($psqlVer -split '\.')[0]
        if ($psqlMajor -lt 17) {
            $newerExe = $psqlKnownPaths | Where-Object { Test-Path $_ } | ForEach-Object {
                $v = (& $_ --version 2>&1) -split ' ' | Select-Object -Last 1
                [PSCustomObject]@{ Exe = $_; Ver = $v; Major = [int]($v -split '\.')[0] }
            } | Where-Object { $_.Major -ge 17 } | Select-Object -First 1
            if ($newerExe) {
                Write-Host "  WARN: psql $psqlVer on PATH is too old - psql $($newerExe.Ver) found at $($newerExe.Exe)"
                Write-Host '  Run: $env:PATH = "' + (Split-Path $newerExe.Exe) + ';" + $env:PATH'
                $script:warningMessages += "psql $psqlVer on PATH too old  ->  " + '$env:PATH = "' + (Split-Path $newerExe.Exe) + ';" + $env:PATH'
                $script:warnings++
            } else {
                Write-Host "  FAIL: psql $psqlVer is older than 17 - version 17+ is required"
                $script:missing += "PostgreSQL 17+  ->  winget install PostgreSQL.PostgreSQL.18"
                $pgNeedInstall = $true
                $script:errors++
            }
        } elseif (-not $psql) {
            Write-Host "  WARN: psql $psqlVer found at $psqlExe but not on PATH"
            Write-Host '  Run: $env:PATH = "' + (Split-Path $psqlExe) + ';" + $env:PATH'
            $script:warningMessages += "psql not on PATH  ->  " + '$env:PATH = "' + (Split-Path $psqlExe) + ';" + $env:PATH'
            $script:warnings++
        } else {
            Write-Host "  OK: psql $psqlVer"
        }
    }

    $pgAdminPaths = @(
        "$env:ProgramFiles\pgAdmin 4\runtime\pgAdmin4.exe",
        "${env:ProgramFiles(x86)}\pgAdmin 4\runtime\pgAdmin4.exe",
        "$env:LocalAppData\Programs\pgAdmin 4\runtime\pgAdmin4.exe"
    ) + (16..20 | ForEach-Object {
        "$env:ProgramFiles\PostgreSQL\$_\pgAdmin 4\runtime\pgAdmin4.exe"
    })
    $pgAdminFound = $pgAdminPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($pgAdminFound) {
        Write-Host "  OK: pgAdmin 4 found"
    } else {
        Write-Host "  MISSING: pgAdmin 4 not found"
        $pgAdminNeedInstall = $true
    }

    if ($pgNeedInstall -or $pgAdminNeedInstall) {
        $promptText = if ($pgNeedInstall -and $pgAdminNeedInstall) { "Install PostgreSQL 18 + pgAdmin 4?" }
                      elseif ($pgNeedInstall)                       { "Install PostgreSQL 18 (psql)?" }
                      else                                          { "Install pgAdmin 4?" }
        if (Read-YesNo $promptText) {
            if ($pgNeedInstall) {
                Write-Host "  Installing PostgreSQL 18 via winget (~350 MB download, ~9 min install - please wait)..."
                winget install -e --id PostgreSQL.PostgreSQL.18
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "  FAIL: winget install failed"
                    Write-Host "  MANUAL: https://www.postgresql.org/download/windows/"
                    $script:missing += "PostgreSQL 18  ->  winget install PostgreSQL.PostgreSQL.18"
                    $script:errors++
                } else {
                    Write-Host "  FIXED: PostgreSQL 18 installed"
                    Write-Host "  NOTE: psql is not on PATH yet. Run in your shell:"
                    Write-Host '        $env:PATH = "C:\Program Files\PostgreSQL\18\bin;" + $env:PATH'
                    $script:fixes++
                }
            }
            if ($pgAdminNeedInstall) {
                Write-Host "  Installing pgAdmin 4 via winget (~220 MB download, ~1 min install - please wait)..."
                winget install -e --id PostgreSQL.pgAdmin
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "  FAIL: winget install failed"
                    Write-Host "  MANUAL: https://www.pgadmin.org/download/pgadmin-4-windows/"
                    $script:missing += "pgAdmin 4      ->  winget install PostgreSQL.pgAdmin"
                    $script:errors++
                } else {
                    Write-Host "  FIXED: pgAdmin 4 installed"
                    $script:fixes++
                }
            }
        } else {
            Write-Host "  SKIPPED"
            if ($pgNeedInstall)      { $script:missing += "PostgreSQL 18  ->  winget install PostgreSQL.PostgreSQL.18" }
            if ($pgAdminNeedInstall) { $script:missing += "pgAdmin 4      ->  winget install PostgreSQL.pgAdmin" }
            $script:warningMessages += "PostgreSQL tools install skipped"
            $script:warnings++
        }
    }
}

# Confirms port 5432 is free for a Postgres container. check-req does NOT manage
# the container (name, runtime, lifecycle are the caller's business). A container
# already serving 5432 is fine; only a native PostgreSQL instance holding the port
# is flagged, since it would shadow the container.
function Test-Port5432 {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    $stoppedService = $false
    $pgServices = Get-Service -Name 'postgresql-x64-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Running' }
    if ($pgServices) {
        $svcNames = $pgServices.Name -join ', '
        Write-Host "  WARN: Native PostgreSQL service(s) running: $svcNames"
        Write-Host "        This binds port 5432, so a Postgres container cannot claim it."
        Write-Host "        The test suite would hit this native instance instead of the"
        Write-Host "        container and miss the solution databases."
        if (-not $isAdmin) {
            # Stop-Service / Set-Service need elevation. Don't attempt them un-elevated:
            # they fail silently (swallowed by -ErrorAction SilentlyContinue) and we must
            # not report a stop that never happened. Let the user run them in a side
            # elevated shell, then re-check on Enter so a fix is recognised here without
            # a full re-run - only warn if a service is still running or still enabled.
            Write-Host "  NOTE: stopping and disabling a service requires an elevated shell"
            Write-Host "        Re-run this script as Administrator, or run these elevated,"
            Write-Host "        then press Enter to re-check:"
            foreach ($svc in $pgServices) {
                Write-Host "          Stop-Service $($svc.Name) -Force; Set-Service $($svc.Name) -StartupType Disabled"
            }
            Read-Host "  Press Enter to continue" | Out-Null
            $stillActive = $pgServices.Name |
                ForEach-Object { Get-Service $_ -ErrorAction SilentlyContinue } |
                Where-Object { $_.Status -ne 'Stopped' -or $_.StartType -ne 'Disabled' }
            if ($stillActive) {
                $saNames = ($stillActive.Name) -join ', '
                Write-Host "  WARN: still running or not disabled: $saNames"
                $script:warningMessages += "Native PostgreSQL service ($saNames) holds port 5432  ->  run elevated: Stop-Service -Force + Set-Service -StartupType Disabled"
                $script:warnings++
            } else {
                Write-Host "  OK: native PostgreSQL service(s) now stopped and disabled"
                $stoppedService = $true
            }
        } elseif (Read-YesNo "Stop and disable native PostgreSQL service(s) now?") {
            foreach ($svc in $pgServices) {
                Stop-Service $svc.Name -Force -ErrorAction SilentlyContinue
                Set-Service  $svc.Name -StartupType Disabled -ErrorAction SilentlyContinue
                $now = Get-Service $svc.Name -ErrorAction SilentlyContinue
                if ($now -and $now.Status -eq 'Stopped') {
                    Write-Host "  FIXED: $($svc.Name) stopped and disabled"
                    $script:fixes++
                    $stoppedService = $true
                } else {
                    Write-Host "  FAIL: $($svc.Name) is still '$($now.Status)' - could not stop it"
                    $script:warningMessages += "Could not stop $($svc.Name)  ->  Stop-Service $($svc.Name) -Force (elevated)"
                    $script:warnings++
                }
            }
        } else {
            Write-Host "  SKIPPED"
            $script:warningMessages += "Native PostgreSQL service ($svcNames) holds port 5432  ->  Stop-Service -Force + Set-Service -StartupType Disabled to free it"
            $script:warnings++
        }
    } else {
        Write-Host "  OK: port 5432 not held by a native PostgreSQL service"
    }

    # Catch a postgres still on :5432 that no running service accounts for: a
    # standalone instance, or a straggler after a successful service stop. Skip it
    # when a running service was already reported above (it would just re-warn about
    # the same port). A container's :5432 forward is owned by a docker/podman process,
    # not postgres.exe, so it is never matched here.
    if ($stoppedService -or -not $pgServices) {
        if ($stoppedService) { Start-Sleep -Seconds 2 }
        $port5432Procs = Get-NetTCPConnection -LocalPort 5432 -ErrorAction SilentlyContinue |
            Where-Object { $_.State -eq 'Listen' } |
            ForEach-Object { Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue } |
            Where-Object { $_.Name -eq 'postgres' } |
            Select-Object -Unique
        if ($port5432Procs) {
            $pids = $port5432Procs.Id -join ', '
            Write-Host "  WARN: postgres.exe (PID $pids) still listening on :5432"
            if (-not $isAdmin) {
                Write-Host "  NOTE: killing the process requires an elevated shell"
                Write-Host "        Re-run as Administrator, or run elevated: Stop-Process -Id $pids -Force"
                $script:warningMessages += "postgres.exe (PID $pids) holds :5432  ->  run elevated: Stop-Process -Id $pids -Force"
                $script:warnings++
                Read-Host "  Press Enter to continue" | Out-Null
            } elseif (Read-YesNo "Kill the lingering postgres.exe process(es) now?") {
                $port5432Procs | Stop-Process -Force -ErrorAction SilentlyContinue
                Write-Host "  FIXED: postgres.exe killed - port 5432 is now free"
                $script:fixes++
            } else {
                Write-Host "  SKIPPED"
                $script:warningMessages += "postgres.exe (PID $pids) holds :5432  ->  Stop-Process -Id $pids -Force to free it"
                $script:warnings++
            }
        } elseif ($stoppedService) {
            Write-Host "  NOTE: port 5432 is now free for your Postgres container."
        }
    }
}

# Single source of truth for the Defender dev-exclusion rules, shared by
# scripts\defender-exclusions.ps1 (which applies them) and Test-DefenderExclusions
# below (which check-prerequisites.ps1 uses to verify them). Uses no counters.
function Get-DefenderExclusionRules {
    $repoRoot = (Resolve-Path "$PSScriptRoot\.." -ErrorAction SilentlyContinue).Path
    if (-not $repoRoot) { $repoRoot = Split-Path $PSScriptRoot -Parent }
    [PSCustomObject]@{
        Paths = @(
            $repoRoot,                              # repo root
            "$env:USERPROFILE\.gradle",             # Gradle dependency cache
            "$env:USERPROFILE\.local\share\mise",   # mise tool installs (Java, Node)
            "$env:USERPROFILE\.local\share\gradle", # Gradle wrapper cache
            "$env:USERPROFILE\.pixi",               # Pixi environments
            "$env:LocalAppData\ms-playwright",      # Playwright browser binaries
            "$env:LocalAppData\Temp"                # build/compile temp files
        )
        Processes = @(
            'java.exe', 'javac.exe', 'node.exe', 'npm.cmd', 'npx.cmd',
            'pixi.exe', 'mise.exe', 'gradle', 'pwsh.exe', 'powershell.exe'
        )
    }
}

# Verifies the Defender dev-exclusions (from Get-DefenderExclusionRules) are
# configured. Non-elevated shells can't read the exclusion list - Get-MpPreference
# returns "N/A: Must be an administrator to view exclusions" instead of the real
# values - so that case is reported as SKIP, not a false "not set".
function Test-DefenderExclusions {
    $mpPref = Get-MpPreference -ErrorAction SilentlyContinue
    if (-not $mpPref) {
        Write-Host "  SKIP: Could not read Defender preferences (non-Windows or policy restricted)"
        return
    }
    $excluded = @($mpPref.ExclusionPath) + @($mpPref.ExclusionProcess)
    if ($excluded -match 'Must be an administrator') {
        Write-Host "  WARN: cannot read Defender exclusions without elevation"
        $script:warningMessages += "Defender exclusions not verified. Run as Administrator either this script, or scripts\defender-exclusions.ps1"
        $script:warnings++
        return
    }
    $rules = Get-DefenderExclusionRules
    $have  = @($mpPref.ExclusionPath) | ForEach-Object { $_.TrimEnd('\').ToLower() }
    $missingPaths = $rules.Paths | Where-Object { $have -notcontains $_.TrimEnd('\').ToLower() }
    if (-not $missingPaths) {
        Write-Host "  OK: Defender exclusions configured"
    } else {
        Write-Host "  WARN: Defender dev exclusions missing/incomplete ($($missingPaths.Count) of $($rules.Paths.Count) path(s) not excluded)"
        Write-Host "        Defender scanning Gradle/JVM/Node artifacts slows builds significantly"
        Write-Host "        Run as Administrator: .\scripts\defender-exclusions.ps1"
        $script:warningMessages += "Defender exclusions not set  ->  run as admin: .\scripts\defender-exclusions.ps1"
        $script:warnings++
    }
}
