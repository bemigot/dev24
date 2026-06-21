# dev24 Windows VM harness — SPEC

Test `check-req.py` (and the Windows bootstrap UX) on a VM that resembles a
**typical developer Windows machine**, without ever mutating a known-good base.
Maintainer-only; run on a Linux KVM/libvirt host.

## Images

- **`golden.qcow2`** — a pristine, *bare* Windows 11 install: the state a
  developer *user* machine is in fresh from the vendor.
  No Python (we steer around the Microsoft Store stubs), no Git, no toolchain.
  The **only** harness plumbing baked in at mint is the **OpenSSH Server
  capability** (binaries only — service disabled, no keys); `cboot1.ps1` enables
  and authorizes it per run, which moves its slow Windows Update download into
  the one-time mint instead of every overlay. Read-only backing file; never
  modified.
- **`go1.qcow2`** — a **persistent** qcow2 overlay on *golden*. Everything
  `ubootstrap.ps1` / `cboot1.ps1` / hand-run tools change lands here, so *golden*
  stays pristine. It **persists across `up` calls** so you resume where you left off
  (e.g. Python already installed); `reset` discards it to start a clean UX run.

## Control CD

`harness.py` builds it fresh on each bring-up (`mkisofs`), volume label
**`MAINTCD`**, attached read-only and auto-mounted by libvirt. It is the
friction-free delivery path: the maintainer runs the scripts from it **by hand**
on Linux host console — no browser download / SmartScreen first-run friction.
The scripts are self-contained so a real developer could also fetch `ubootstrap.ps1`
over HTTP and run it standalone. Contents:

- `ubootstrap.ps1`, `cboot1.ps1`
- `authorized_keys` — copied from the host's `~/.ssh/authorized_keys` at build time
- `check-req.py` + `lib/` — from the repo root
- `sample-project/` — so `check-req.py` has a `<repo_root>` to run against
- `Readme.md` — a 3-line on-console cheat sheet (the commands, in order)

## Scripts

Self-contained, independent, idempotent. Neither lives in the repo yet;
source is `VM/cd/`.

### `ubootstrap.ps1` — user bootstrap
- **Only** install Python: `winget install 9NQ7512CXL7T` (Python install manager 26.1).
- Toggle **off** the `python.exe` / `python3.exe` App-execution alias stubs so
  the real interpreter wins over the Store redirect.
- Re-running is a no-op when Python is already present and real (e.g. 'import json' is OK)

### `cboot1.ps1` — control bootstrap (maintainer convenience)
Orthogonal to `check-req.py` — lets the maintainer drive the VM over SSH
instead of the console.
- Enable the OpenSSH **server** (service auto-start + firewall :22). The
  capability itself is pre-baked into golden, so this is instant — no Windows
  Update download — and the firewall rule is widened to all profiles (the
  default is Private-only, but the libvirt NAT classifies as Public).
- Install `authorized_keys` from the CD into the Windows account
  (handling the admin-account `administrators_authorized_keys` + ACL gotcha).

## `harness.py`

Maintainer-only; drives libvirt via the `python3-libvirt` bindings and patches
`win-vm.xml` at runtime (overlay path + control-CD path).
Bring-up oriented, not automated run→teardown:

- **`up`** — build the control CD, create the `go1` overlay if missing, boot
  the VM with the CD attached, and leave it running for hands-on use.
- **`down`** — graceful shutdown; keep the overlay.
- **`reset`** — discard the `go1` overlay (next `up` starts clean from *golden*).
- **`teardown`** — destroy the VM; remove the overlay and the CD image.
- **`ip`** — print the guest's IPv4 (from its libvirt DHCP lease).
- **`ssh [cmd]`** — ssh in as `Quickemu` at that IP (after `cboot1.ps1` has
  authorized the host keys); optional remote command, else an interactive shell.

## Manual workflow (current)

On Linux host physical console:

1. `harness.py up`
2. In the VM, from the `MAINTCD` drive: run `ubootstrap.ps1` — install Python,
   watching the UX a real developer hits.
3. `py check-req.py sample-project` — watch it report the missing toolchain.
4. *(optional)* run `cboot1.ps1` as admin to enable SSH.

## Future

- SSH-driven automation (once `cboot1.ps1` is proven)
  replaces the by-hand console steps.
- The `harness.py` rewrite to the verbs above is the active work item; the
  committed `harness.py` still encodes the older provisioned-image model.

## Conventions

- Call the running guest a **VM**, not a libvirt "domain".
- Nothing dev24-specific goes into golden; everything rides on the per-run CD
  or is installed by the scripts under test.
- The CD's `.ps1` scripts are **ASCII-only** — Windows PowerShell 5.1 reads a
  BOM-less `.ps1` as the ANSI codepage, so non-ASCII (em-dashes, curly quotes)
  corrupts parsing.
