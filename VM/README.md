# VM Harness - maintainer only

KVM/libvirt tooling for testing `check-req.py` on Windows without accumulating
configuration drift. Each test run gets a fresh overlay on top of a stable
golden image; the overlay is discarded after the run.

## Prerequisites

Run the one-time host setup script (Debian/Ubuntu), which installs the stack,
enables libvirt's default network, grants VM access, and creates the image dir:

```bash
./setup-host.sh        # requires sudo; log out/in afterwards for the group change
```

Equivalent manual steps:

```bash
sudo apt install qemu-system-x86 qemu-utils \
  libvirt-daemon-system libvirt-clients virtinst \
  ovmf swtpm python3-libvirt virt-viewer genisoimage
sudo usermod -aG libvirt,kvm "$USER"  # log out/in for group change to take effect
```

- `ovmf` provides the UEFI firmware and `swtpm` the emulated TPM 2.0 — both are
  required to boot Windows 11 (see `win-vm.xml`).
- `python3-libvirt` is the distro package the harness imports; do **not** `pip
  install libvirt-python` — the system package is pinned to the host's libvirt.
- `genisoimage` provides `mkisofs`, which `quickget` uses to build the
  `unattended.iso` answer disk. Without it quickget skips that step and the
  Windows install runs attended (see "Building the golden image").
- `quickemu` / `quickget` mint the golden image, vendored as a submodule (see
  "Installing quickemu" and "Building the golden image" below).

## Installing quickemu

`quickget` and `quickemu` come from the
[quickemu project](https://github.com/quickemu-project/quickemu) and are
vendored here as a git submodule at `VM/quickemu/`, pinned to a known-good commit
(this sidesteps `quickget`'s moving Windows 11 bugs — see below). They run
in-place from the submodule.

```bash
git submodule update --init VM/quickemu   # after cloning dev24
```

*quickemu* reuses the host QEMU/OVMF/swtpm and `mkisofs` (`genisoimage`
package) that `setup-host.sh` installs.

To advance the pin later:
`git -C VM/quickemu fetch && git -C VM/quickemu checkout <ref>`,
then commit the new submodule SHA.

## Building the golden image

The golden image is a **plain Windows 11 install**, with one piece of harness
plumbing baked in by the answer file: the **OpenSSH Server capability** (binaries
only — `cboot1.ps1` enables and authorizes it per run; see `SPEC.md`). Built via
*quickemu*:

1. Mint a *golden* Windows 11 qcow2:
   ```bash
   cd VM/quickemu
   ./quickget windows 11
   # see additional manual steps below
   ./quickemu --vm windows-11.conf --viewer remote-viewer
   ```
   `--viewer remote-viewer` avoids quickemu's default `spicy` client (which may
   not be installed; `setup-host.sh` provides `remote-viewer` instead). Or use
   `--display sdl` for a plain QEMU window with no SPICE client.

   **Manual steps after `quickget`, before `quickemu`:**
   - Download the Windows ISO manually, verify it against the saved SHA, and
     link it: `ln -s Win11_25H2_English_x64_v2.iso windows-11/windows-11.iso`
   - Run `../get-virtio-iso.sh` to fetch and verify the virtio driver ISO, then
     symlink it: `ln -sf ../virtio-win-0.1.285.iso windows-11/virtio-win.iso`
   - Build `unattended.iso` from `VM/unattended/autounattend.xml`, which adds the
     `Microsoft-Windows-International-Core-WinPE` component so Setup doesn't stop
     on the "Select language settings" screen:
     ```bash
     ../make-unattended-iso.sh  # build windows-11/unattended.iso from
                                # VM/unattended/autounattend.xml (+ MSIs)
     ```

   **Untested:** the `International-Core-WinPE` addition in
   `VM/unattended/autounattend.xml` and `make-unattended-iso.sh` have not been
   validated through a full mint — confirm the language screen is actually
   skipped on the next mint.

2. When the unattended install finishes, shut the VM down **cleanly** — from
   inside Windows (Start → Power → Shut down), or from the host:
   ```bash
   ./quickemu --vm windows-11.conf --viewer none --monitor-cmd system_powerdown
   pgrep -af 'windows-11/disk.qcow2'   # no output = stopped
   ```
   `--viewer none` skips quickemu's `spicy` viewer check; `system_powerdown` sends
   ACPI power-off so Windows shuts down gracefully (`--kill` is a hard pull — last
   resort, can corrupt the disk). Then place the disk as the golden image:
   ```bash
   mv windows-11/disk.qcow2 /opt/dev24-vm/golden.qcow2
   ```
   The ISOs in `windows-11/` (`windows-11.iso`, `virtio-win.iso`, `unattended.iso`)
   stay put, so a re-mint only re-runs the unattended install — no re-downloading.
   `/opt/dev24-vm` is the default `IMAGE_DIR` (override with `DEV24_VM_IMAGE_DIR`).
   Don't install anything into it — do not snapshot; the qcow2 itself is the
   golden state.

Re-mint the golden image when expiry hits (the free eval license is
time-limited) or when the base Windows image needs refreshing — not for every
check-req.py iteration.

## Usage

Maintainer bring-up — **`SPEC.md`** has the full design. Run it with the system
Python (`./VM/harness.py` uses `/usr/bin/python3`, which has `python3-libvirt`; a
`python3` on PATH may be a pixi env without it):

```bash
./VM/harness.py up        # build the control CD, boot the VM, leave it running
./VM/harness.py down      # graceful shutdown, keep the go1 overlay
./VM/harness.py reset     # discard the go1 overlay (next up starts clean)
./VM/harness.py teardown  # destroy the VM, remove the overlay + CD image
./VM/harness.py ip        # print the guest's IPv4 (from its DHCP lease)
./VM/harness.py ssh [cmd] # ssh in as Quickemu (after cboot1.ps1 has run)
```

After `up`, open the VM console on the host and follow the `MAINTCD` drive's
`Readme.md`:

```bash
virt-viewer --connect qemu:///system dev24-win-test 2>/dev/null &
```

## How it works

```
golden.qcow2 - read-only backing file — pristine bare Windows
  └── go1.qcow2 - persistent overlay; all changes land here
        └── Windows VM boots here, with maintcd.iso attached
```

`up` builds `maintcd.iso` fresh (the control-CD payload — `ubootstrap.ps1` /
`cboot1.ps1` / `check-req.py` + fixture + your SSH keys), ensures the `go1`
overlay exists, and boots the VM. You drive it by hand on the host console;
`cboot1.ps1` on the CD enables SSH for remote control later.

## Bring-up status / next steps

`harness.py` implements the `up`/`down`/`reset`/`teardown` bring-up in `SPEC.md`,
but has **not yet been run end-to-end.** Once the host is set up (above) and a
golden image is minted:

- `python3 VM/harness.py up`, then watch the VM console. First real test of the
  Secure-Boot + TPM 2.0 setup in `win-vm.xml` plus the auto-mounted control CD;
  confirm Windows 11 boots and `MAINTCD` mounts.

The Linux host needs a physical display (or a SPICE viewer) to drive the VM by hand.
