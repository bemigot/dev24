#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    cboot1.ps1 - control bootstrap (maintainer convenience).

    Enables the OpenSSH server and authorizes the maintainer's keys so the VM
    can be driven over SSH instead of the console. Orthogonal to check-req.py.
    Idempotent. Run as Administrator from the MAINTCD control disc:

        powershell -ExecutionPolicy Bypass -File .\cboot1.ps1
#>
[CmdletBinding()]
param(
    # authorized_keys to install; defaults to the copy beside this script (on the CD).
    [string] $KeyFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve the default at runtime - $PSScriptRoot is not reliably populated inside
# a param() default, so compute it here (with a fallback for older hosts).
if (-not $KeyFile) {
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $KeyFile = Join-Path $here 'authorized_keys'
}

Write-Host "== cboot1: enable OpenSSH server =="

# 1. OpenSSH server capability (skip if already installed).
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
if ($cap.State -ne 'Installed') {
    Write-Host "Installing $($cap.Name) ..."
    Add-WindowsCapability -Online -Name $cap.Name | Out-Null
} else {
    Write-Host "OpenSSH.Server already installed."
}

# 2. Service: automatic start, running now.
Set-Service -Name sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }
Write-Host "sshd: $((Get-Service sshd).Status), startup Automatic."

# 3. Firewall rule for :22. The capability's default rule is scoped to
# Private/Domain only, but the libvirt NAT usually classifies as Public, so
# force the rule to ALL profiles (else inbound 22 is dropped and ssh times out).
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Any | Out-Null
    Write-Host "Added firewall rule for TCP/22 (all profiles)."
} else {
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -Profile Any
    Write-Host "Firewall rule for TCP/22 present - widened to all profiles."
}

# 4. Authorize keys.
if (-not (Test-Path $KeyFile)) {
    Write-Error "authorized_keys not found: $KeyFile"
    exit 1
}
$keys = Get-Content -Raw $KeyFile

# Windows OpenSSH quirk: for accounts in the Administrators group, sshd ignores
# the per-user file and reads %ProgramData%\ssh\administrators_authorized_keys,
# which must be owned by Administrators/SYSTEM only. Handle whichever applies.
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

if ($isAdmin) {
    $dest = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    Set-Content -Path $dest -Value $keys -Encoding ascii
    icacls $dest /inheritance:r /grant 'Administrators:F' 'SYSTEM:F' | Out-Null
    Write-Host "Installed keys -> $dest (admin account)."
} else {
    $sshDir = Join-Path $env:USERPROFILE '.ssh'
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    Set-Content -Path (Join-Path $sshDir 'authorized_keys') -Value $keys -Encoding ascii
    Write-Host "Installed keys -> $sshDir\authorized_keys."
}

Write-Host ""
Write-Host "Done. From the host:  ./VM/harness.py ssh"
