# --- 7. Container runtime (Docker / Podman) ---
# Dot-sourced by check-prerequisites.ps1 - shares its error/warning variables.

if (-not (Get-Command Read-YesNo -ErrorAction SilentlyContinue)) {
    Write-Error "This script must be dot-sourced from check-prerequisites.ps1, not run directly."
    exit 1
}

$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
$podmanCmd = Get-Command podman -ErrorAction SilentlyContinue

if ($dockerCmd) {
    $dockerVer = (& docker --version 2>&1) -replace 'Docker version ', ''
    Write-Host "  OK: docker $dockerVer"

    # The CLI alone is not enough - the engine must be running for the suite to
    # start its Postgres container. Probe it; offer to start Docker Desktop if down.
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARN: docker CLI found but the engine is not running"
        # Hardware virtualization must be enabled in firmware or the Linux engine
        # (WSL2/Hyper-V) cannot start - Docker reports "no virtualization detected".
        # Check before offering to launch Docker Desktop, which is futile without it.
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
        $virtEnabled = -not ($cpu -and (@($cpu.VirtualizationFirmwareEnabled) -contains $false))
        if (-not $virtEnabled) {
            Write-Host "  FAIL: hardware virtualization is disabled in BIOS/UEFI firmware"
            Write-Host "        Docker Desktop's Linux engine cannot start without it. Reboot into"
            Write-Host "        BIOS/UEFI and enable AMD 'SVM Mode' (or Intel 'VT-x' / 'Virtualization"
            Write-Host "        Technology'), then reboot. Starting Docker Desktop now would not help."
            $warningMessages += "virtualization disabled in BIOS  ->  enable AMD SVM Mode / Intel VT-x in firmware, then reboot"
            $warnings++
        } else {
            $dd = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
            if ((Test-Path $dd) -and (Read-YesNo "Start Docker Desktop now?")) {
                if (-not (Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue)) { Start-Process $dd }
                Write-Host "  Docker Desktop is starting. On a fresh install you must first complete"
                Write-Host "  the one-time 'Welcome to Docker' screen (accept terms / skip sign-in) -"
                Write-Host "  the engine will not finish starting until you do."
                Read-Host "  Press Enter once Docker Desktop shows 'Engine running'" | Out-Null
                & docker info *> $null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  FIXED: docker engine is running"
                    $fixes++
                } else {
                    Write-Host "  WARN: docker engine still not reachable"
                    $warningMessages += "docker engine not running  ->  start Docker Desktop, complete first-run setup, then: docker ps"
                    $warnings++
                }
            } else {
                Write-Host "  SKIPPED"
                $warningMessages += "docker engine not running  ->  start Docker Desktop (complete 'Welcome to Docker'), then: docker ps"
                $warnings++
            }
        }
    } else {
        Write-Host "  OK: docker engine is running"
    }
} elseif ($podmanCmd) {
    $podmanVer = (& podman --version 2>&1) -replace 'podman(\.exe)? version ', ''
    Write-Host "  OK: podman $podmanVer"
    try {
        $wingetOut = (winget list --id RedHat.Podman 2>&1) -join "`n"
        $availableVer = if ($wingetOut -match 'RedHat\.Podman\s+([\d.]+)\s+([\d.]+)') { $Matches[2] } else { $null }
        if ($availableVer) {
            Write-Host "  NOTE: Podman $($availableVer) available (installed: $podmanVer)"
            $curParts = $podmanVer   -split '\.'; $newParts = $availableVer -split '\.'
            $safeUpgrade = ([int]$curParts[0] -eq [int]$newParts[0]) -and
                           ([int]$curParts[1] -eq [int]$newParts[1]) -and
                           (([int]$newParts[2] - [int]$curParts[2]) -lt 4)
            if ($safeUpgrade) {
                if (Read-YesNo "Upgrade Podman to version $($availableVer)?") {
                    Write-Host "  Upgrading Podman..."
                    winget upgrade -e --id RedHat.Podman 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "  FAIL: upgrade failed"
                        $warningMessages += "Podman upgrade failed  ->  winget upgrade -e --id RedHat.Podman"
                        $warnings++
                    } else {
                        Write-Host "  FIXED: Podman upgraded to $($availableVer)"
                        $fixes++
                    }
                } else {
                    Write-Host "  SKIPPED"
                    $warningMessages += "Podman $podmanVer outdated  ->  winget upgrade -e --id RedHat.Podman"
                    $warnings++
                }
            } else {
                Write-Host "  NOTE: version gap too large for in-place upgrade (known Podman Windows installer limitation)"
                Write-Host "        reinstall is required: uninstall $podmanVer then install $($availableVer) fresh"
                if (Read-YesNo "Reinstall Podman now (uninstall + fresh install)?") {
                    Write-Host "  Uninstalling Podman $podmanVer..."
                    winget uninstall --id RedHat.Podman 2>&1 | Out-Null
                    Write-Host "  Installing Podman $($availableVer)..."
                    winget install -e --id RedHat.Podman 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "  FAIL: install failed"
                        $warningMessages += "Podman reinstall failed  ->  winget uninstall RedHat.Podman; winget install -e --id RedHat.Podman"
                        $warnings++
                    } else {
                        Write-Host "  FIXED: Podman reinstalled at $($availableVer)"
                        $fixes++
                    }
                } else {
                    Write-Host "  SKIPPED"
                    $warningMessages += "Podman $podmanVer outdated  ->  reinstall: winget uninstall RedHat.Podman; winget install -e --id RedHat.Podman"
                    $warnings++
                }
            }
        }
    } catch {}
    $shimDir  = "$env:USERPROFILE\.local\bin"
    $shimPath = "$shimDir\docker.cmd"
    if (Test-Path $shimPath) {
        Write-Host "  OK: docker shim already exists at $shimPath"
    } else {
        Write-Host "  NOTE: no 'docker' CLI found - a shim can delegate 'docker' commands to Podman"
        if (Read-YesNo "Create 'docker' -> 'podman' shim in $($shimDir)?") {
            if (-not (Test-Path $shimDir)) { New-Item -ItemType Directory -Force $shimDir | Out-Null }
            "@echo off`npodman %*" | Set-Content "$shimPath" -Encoding ASCII
            # Also create an extensionless shell script for Git Bash / MSYS2
            @'
#!/bin/sh
exec podman "$@"
'@ | Set-Content "$shimDir\docker" -Encoding ASCII
            Write-Host "  FIXED: shim created at $shimPath (+ Git Bash shell script)"
            if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $shimDir })) {
                Write-Host "  NOTE: add $shimDir to your PATH to activate the shim:"
                Write-Host "        `$env:PATH = `"$shimDir;`" + `$env:PATH"
                $warningMessages += "docker shim created but $shimDir not on PATH  ->  " + "`$env:PATH = `"$shimDir;`" + `$env:PATH"
                $warnings++
            } else {
                $fixes++
            }
        } else {
            Write-Host "  SKIPPED"
            $warningMessages += "No 'docker' CLI - create shim or install Rancher Desktop: winget install SUSE.RancherDesktop"
            $warnings++
        }
    }
    # Backfill the extensionless shell script for Git Bash if only the .cmd shim exists
    if ((Test-Path $shimPath) -and -not (Test-Path "$shimDir\docker")) {
        @'
#!/bin/sh
exec podman "$@"
'@ | Set-Content "$shimDir\docker" -Encoding ASCII
        Write-Host "  FIXED: added Git Bash shell script shim at $shimDir\docker"
        $fixes++
    }
    # Check ~/.local/bin is on PATH in Git Bash
    if (Test-Path "$shimDir\docker") {
        $bashrcPath  = "$env:USERPROFILE\.bashrc"
        $profilePath = "$env:USERPROFILE\.bash_profile"
        $alreadyInBash = @($bashrcPath, $profilePath) |
            Where-Object { Test-Path $_ } |
            ForEach-Object { Get-Content $_ -Raw -ErrorAction SilentlyContinue } |
            Where-Object { $_ -match '\.local[/\\]bin' }
        if (-not $alreadyInBash) {
            Write-Host "  NOTE: ~/.local/bin not on PATH in Git Bash - 'docker' won't be found there"
            if (Read-YesNo "Add ~/.local/bin to PATH in ~/.bashrc?") {
                if (-not (Test-Path $bashrcPath)) { New-Item -ItemType File -Force $bashrcPath | Out-Null }
                Add-Content $bashrcPath "`n# Local bin (docker->podman shim)`nexport PATH=`"`$HOME/.local/bin:`$PATH`""
                Write-Host "  FIXED: ~/.local/bin added to ~/.bashrc - open a new Git Bash to pick it up"
                $fixes++
            } else {
                Write-Host "  SKIPPED"
                $warningMessages += "~/.local/bin not in Git Bash PATH  ->  add to ~/.bashrc: export PATH=`"`$HOME/.local/bin:`$PATH`""
                $warnings++
            }
        } else {
            Write-Host "  OK: ~/.local/bin in Git Bash PATH (~/.bashrc / ~/.bash_profile)"
        }
    }
} else {
    Write-Host "  FAIL: neither docker nor podman found on PATH"
    Write-Host "  Options:"
    Write-Host "    [P] Podman          - free, rootless  (winget install RedHat.Podman)"
    Write-Host "    [R] Rancher Desktop - free, includes docker CLI + k3s  (winget install SUSE.RancherDesktop)"
    Write-Host "    [D] Docker Desktop  - commercial licence required for large orgs  (winget install Docker.DockerDesktop)"
    $choice = (Read-Host "  Install which? [P/r/d/n]").Trim().ToLower()
    if ($choice -eq '' -or $choice -eq 'p') {
        Write-Host "  Installing Podman via winget..."
        winget install -e --id RedHat.Podman 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FAIL: winget install failed"
            $missing += "Podman  ->  winget install RedHat.Podman"
            $errors++
        } else {
            Write-Host "  FIXED: Podman installed - re-run this script to create the docker shim"
            $fixes++
        }
    } elseif ($choice -eq 'r') {
        Write-Host "  Installing Rancher Desktop via winget..."
        winget install -e --id SUSE.RancherDesktop 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FAIL: winget install failed"
            Write-Host "  MANUAL: https://rancherdesktop.io/"
            $missing += "Rancher Desktop  ->  winget install SUSE.RancherDesktop"
            $errors++
        } else {
            Write-Host "  FIXED: Rancher Desktop installed - restart your terminal to pick up the docker CLI"
            $fixes++
        }
    } elseif ($choice -eq 'd') {
        Write-Host "  Installing Docker Desktop via winget..."
        winget install -e --id Docker.DockerDesktop 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FAIL: winget install failed"
            Write-Host "  MANUAL: https://www.docker.com/products/docker-desktop/"
            $missing += "Docker Desktop  ->  winget install Docker.DockerDesktop"
            $errors++
        } else {
            Write-Host "  FIXED: Docker Desktop installed - restart your terminal to pick up the docker CLI"
            $fixes++
        }
    } else {
        Write-Host "  SKIPPED"
        $missing += "Docker/Podman  ->  winget install RedHat.Podman"
        $errors++
    }
}
Write-Host ""
