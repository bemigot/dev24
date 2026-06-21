# Sharing a host directory with the Windows guest (virtiofs)

**Optional.** A live read/write folder shared between the Linux host and the
Windows VM — handy for dropping files in or iterating on `check-req.py` without
rebuilding `MAINTCD` and rebooting. Off by default; enable by editing
`win-vm.xml` as below.

Shared host directory: **`/home/mz0/p/dev24/tmp`** (create it first):

```bash
mkdir -p /home/mz0/p/dev24/tmp
```

## Host side — `win-vm.xml`

virtiofs needs the guest's RAM to be shared memory, plus a `<filesystem>` device.
Add both under `<domain>` (the memoryBacking goes at domain top level; the
filesystem goes inside `<devices>`):

```xml
  <memoryBacking>
    <source type="memfd"/>
    <access mode="shared"/>
  </memoryBacking>
```

```xml
    <filesystem type="mount" accessmode="passthrough">
      <driver type="virtiofs"/>
      <source dir="/home/mz0/p/dev24/tmp"/>
      <target dir="dev24"/>
    </filesystem>
```

- libvirt launches `virtiofsd` automatically — no other host setup (if it errors,
  confirm the `virtiofsd` binary is installed: it ships with QEMU).
- `target dir="dev24"` is a **mount tag**, not a path — the guest uses it to find
  the share.
- `harness.py` only patches the disk/cdrom *source* paths, so it leaves this block
  alone; the share is active on the next `./VM/harness.py up`.

## Guest side — Windows (one-time)

The guest needs a **VirtIO-FS driver + WinFsp**, both from `virtio-win.iso` (the
one `get-virtio-iso.sh` already fetched). Do this in the persistent **`go1`
overlay**, not golden, so golden stays bare — it survives across `up`/`down`.

1. Make `virtio-win.iso` reachable in the guest — attach it as a second cdrom, or
   copy the installers onto `MAINTCD`.
2. Install **WinFsp** (`winfsp-*.msi`).
3. Install the **VirtIO-FS** driver and start its service — easiest via
   `virtio-win-guest-tools.exe` (tick *VirtioFS*), which registers and starts
   `VirtioFsSvc`. (Manual route: install `viofs.inf`, then
   `sc create VirtioFsSvc binPath= "...\viofs\virtiofs.exe" start= auto` and
   `sc start VirtioFsSvc`.)
4. Once `VirtioFsSvc` is running, the share appears as a drive (typically `Z:`).

## Notes

- The `<memoryBacking>` block is **mandatory** — without shared memory the VM
  fails to start with a shared-memory error.
- Read/write both directions; no network involved, so it's fast.
- To disable, remove the `<filesystem>` element (and the `<memoryBacking>` block)
  from `win-vm.xml`.
