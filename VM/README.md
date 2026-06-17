# VM Harness (maintainer only)

KVM/libvirt tooling for testing `check-req.py` on Windows without accumulating
configuration drift. Each test run gets a fresh overlay on top of a stable
golden image; the overlay is discarded after the run.

## Prerequisites (on pug.lan host)

- KVM/QEMU + libvirt + `virsh`
- `python3 -m pip install libvirt-python`
- A golden Windows image (see "Building the golden image" below)

## Building the golden image

1. Install Windows 10/11 into `golden-win.qcow2`
2. Install: Git, Python 3.11+, OpenSSH server (enable + start)
3. Clone the dev24 repo into the VM: `git clone https://github.com/bemigot/dev24.git`
4. Shut down cleanly — do not snapshot; the qcow2 itself is the golden state

Rebuild the golden image when toolchain versions change (JDK, Node, etc.),
not for every check-req.py iteration.

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
