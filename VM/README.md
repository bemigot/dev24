# VM Harness (maintainer only)

KVM/libvirt tooling for testing `check-req.py` on Windows without accumulating
configuration drift. Each test run gets a fresh overlay on top of a stable
golden image; the overlay is discarded after the run.

## Prerequisites (on pug.lan host)

Run the one-time host setup script (Debian/Ubuntu), which installs the stack,
enables libvirt's default network, grants VM access, and creates the image dir:

```bash
./setup-host.sh        # requires sudo; log out/in afterwards for the group change
```

Equivalent manual steps:

```bash
sudo apt install qemu-system-x86 qemu-utils \
  libvirt-daemon-system libvirt-clients virtinst \
  ovmf swtpm python3-libvirt virt-viewer
sudo usermod -aG libvirt,kvm "$USER"   # log out/in for group change to take effect
```

- `ovmf` provides the UEFI firmware and `swtpm` the emulated TPM 2.0 — both are
  required to boot Windows 11 (see `win-vm.xml`).
- `python3-libvirt` is the distro package the harness imports; do **not** `pip
  install libvirt-python` — the system package is pinned to the host's libvirt.
- `quickemu` / `quickget` mint the golden image (see "Installing quickemu" and
  "Building the golden image" below). They are **not** installed by
  `setup-host.sh` — they are a one-time minting tool, vendored as a submodule.

## Installing quickemu

`quickget` and `quickemu` come from the
[quickemu project](https://github.com/quickemu-project/quickemu) and are
vendored here as a git submodule at `VM/quickemu/`, pinned to a known-good commit
(this sidesteps `quickget`'s moving Windows 11 bugs — see below). They run
in-place from the submodule; there is no PATH install.

```bash
git submodule update --init VM/quickemu   # after cloning dev24
```

quickemu reuses the host QEMU/OVMF/swtpm that `setup-host.sh` installs; it has a
few extra runtime tools of its own (e.g. `genisoimage`/`mkisofs`, `mesa-utils`)
— if a mint run complains about a missing command, `apt install` it. To advance
the pin later: `git -C VM/quickemu fetch && git -C VM/quickemu checkout <ref>`,
then commit the new submodule SHA.

## Building the golden image

The golden image is minted by `quickget` (unattended, hands-free) rather than a
manual GUI install. Run the vendored scripts from `VM/quickemu/`:

1. Mint a clean Windows 11 qcow2:
   ```bash
   cd VM/quickemu
   ./quickget windows 11
   ./quickemu --vm windows-11.conf   # boots and runs the unattended install
   ```
   **Note:** `quickget`'s Windows 11 path currently has open bugs (e.g. it may
   pull 25H2 while the generated `.conf` still says 24H2). The submodule is
   pinned to contain the blast radius; if a mint still fails, advance/rewind the
   pin or apply the upstream workaround.
2. Inside the VM, while quickemu still owns it (reachable on its forwarded SSH
   port), enable the **OpenSSH _server_** and start it. This is required — the
   libvirt harness reaches the VM over libvirt's NAT via `virsh domifaddr`, so
   quickemu's port-forward does not carry over. Best baked into the unattended
   first-logon step.
3. Install only the harness runtime: **Git + Python 3.11+**, then clone the repo:
   `git clone https://github.com/bemigot/dev24.git`. Do **not** install the
   checked toolchain (JDK, Node, Docker, pixi, …) — the image must stay clean of
   those so `check-req.py` actually exercises its "missing → here's the fix" path.
4. Shut down cleanly and move the disk to `/opt/dev24-vm/golden-win.qcow2` (the
   default `IMAGE_DIR` in `harness.py`; override with `DEV24_VM_IMAGE_DIR`) — do
   not snapshot; the qcow2 itself is the golden state.

Re-mint the golden image when expiry hits (the free eval license is
time-limited) or when the harness runtime changes — not for every check-req.py
iteration.

**Limitation:** because Python is pre-installed in the golden image, the harness
tests the *toolchain* checks but not the Windows "no Python → install it"
bootstrap recommendation. That path needs a bare (Python-less) image and is
tested separately.

## Usage

```bash
python3 vm/harness.py run     # spin up, SSH in, run check-req.py, print output, teardown
python3 vm/harness.py shell   # spin up and drop into SSH session for manual testing
python3 vm/harness.py teardown  # force-destroy if a previous run left a VM up
```

## How it works

```
golden-win.qcow2  (read-only backing file)
      │
      └── run-overlay.qcow2  (created per run, thin-provisioned, discarded after)
                │
                └── Windows VM boots here
```

SSH is used to drive commands inside the VM. The VM's IP is obtained via
`virsh domifaddr` after boot.

## Bring-up status / next steps

The harness code is written but has **not yet been run end-to-end** — the host
`pug` had no virtualization stack installed as of this writing. Remaining steps,
in order:

1. **Host setup** — run `./setup-host.sh`, then log out/in for the group change.
2. **Mint the golden image** — `git submodule update --init VM/quickemu`, then
   from `VM/quickemu/` run `./quickget windows 11`, run the
   unattended install, enable the in-guest OpenSSH server, install only
   Git + Python + clone the repo, and move the disk to
   `/opt/dev24-vm/golden-win.qcow2` (see "Building the golden image").
3. **Validate the harness** — `virsh define win-vm.xml` then `python3 harness.py
   run`. This is the **first real test** of the Secure-Boot + TPM 2.0 additions
   in `win-vm.xml`; confirm Windows 11 boots under libvirt and SSH comes up via
   `virsh domifaddr`.

Open question to resolve at step 2: **is `pug` headless or does it have a
display?** The Windows unattended install needs a console to watch — on a
headless host, use `virt-viewer` over SSH X-forwarding or a SPICE client from
another machine.

Known latent issue (out of scope for the current pass): `harness.py:get_ip()`
takes a `dom` argument it never uses — it queries by `DOMAIN_NAME` via `virsh`.
Harmless, flagged for a later cleanup.
