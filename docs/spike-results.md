# Milestone 0 spike results

Date: 2026-09-24. Host: macOS 27.0, Apple Silicon, arm64 only.

## What was built
- **`guest/`**: the Rust `msl-guest` binary, statically linked for `aarch64-unknown-linux-musl` with `rust-lld` (no zig, no C toolchain). It is **660 KB** stripped, and the initrd is 359 KB.
  - It works as mini-init (PID 1) and as `msl-distro-init` (namespace setup plus the in-distro agent).
  - The control protocol is newline-delimited JSON over vsock. This is spike-only; gRPC comes in milestone 1.
- **`docs/dev/spike/host/`**: the Swift `msl-spike` VM runner.
  - Uses Virtualization.framework, with ContainerizationEXT4 formatting the data disk.
  - Bridges guest vsock ports to Unix sockets.
  - Has a control socket for USB attach/detach and the balloon.
- **`docs/dev/spike/mslctl.py`**: a client for the guest control socket.
- **`kernel/`**: Apple's 6.18.15 config plus `msl.fragment` (USB/XHCI/usb-storage, quota, nfsd). It is built in a Linux container with Apple's `container` tool.

Reproduce:
```sh
docs/dev/spike/build.sh && docs/dev/spike/run.sh --cmdline-extra net.ifnames=0 &
docs/dev/spike/mslctl.py 1024 '{"op":"import","name":"ubuntu-24.04","file":"/mnt/share/ubuntu-24.04.wsl"}'
docs/dev/spike/mslctl.py 1024 '{"op":"start","name":"ubuntu-24.04","systemd":true}'
docs/dev/spike/mslctl.py 2000 '{"op":"exec","argv":["systemctl","is-system-running","--wait"]}'
```

## Results

| Check | Result |
|---|---|
| VM boot (VZ `start`) | 0.13 s. From launching the runner to a guest vsock ping: **0.95 s**. Guest init stage 2: 41 ms |
| vmnet (`VZVmnetNetworkDeviceAttachment`, macOS 26 API) | ✅ Works with **ad-hoc signing and only `com.apple.security.virtualization`**. Kernel `ip=dhcp`, DNS from `/proc/net/pnp`, IPv6 works, apt download at about 7 MB/s |
| ext4 data disk formatted on the host (ContainerizationEXT4) | ✅ 32 GiB sparse image formatted in 0.04 s, then mounted read-write by the guest |
| Distro import (tar crate) | ✅ Ubuntu 24.04: 49k entries in 4.5 s. Debian 13: 10.5k entries in 1.0 s |
| Namespaces + `pivot_root` + systemd as PID 1 | ✅ Needed a first stage that moves init off the initramfs (tmpfs + `MS_MOVE` + chroot), because the initramfs root can't be pivoted. Distro start takes **11–22 ms** |
| Ubuntu 24.04 (unmodified `.wsl`) | ✅ `systemctl is-system-running` → `running`, **0 failed units**, userspace boot 5.6 s |
| Debian 13 (unmodified `.wsl`) | ⚠️ `degraded`, but the only failures are `console-getty` and `getty@tty1` (the distros share the VM console) → add to the compat masks |
| Localhost between distros | ✅ Python server in Ubuntu; Debian's bash `/dev/tcp/127.0.0.1` gets `HTTP/1.0 200 OK` |
| Rosetta | ✅ An x86_64 static BusyBox runs through binfmt (`F` flag, so it works in every namespace). Only used as a test input |
| `/mnt/mac` (virtiofs share of `/`) | ✅ See "virtiofs ownership" below |
| USB hot-attach | ✅ On the **custom kernel** (`kernel/out/Image`, built in about 3 min in a container): attaching makes `/dev/sda` appear in about 1 s; Ubuntu can `mkfs.ext4`, mount, write and unmount it; detaching removes it; re-attaching read-only shows the data persisted. Ubuntu stays `running` on the custom kernel. The device node shows up in every distro (shared devtmpfs), which matches WSL `--mount` semantics |
| Memory balloon | ✅ Guest `MemAvailable` 3.9 GB → 1.8 GB at a 2 GiB target. ❓ Host reclaim is **not yet measured reliably**, because `phys_footprint` didn't follow guest page-cache growth |
| VM memory on the Mac | Footprint of the VM helper process: about 500–620 MB with 1–2 systemd distros running (to be re-checked with a better metric) |

## Findings that change the plan
1. **virtiofs ownership (the big one).** Apple's virtiofs reports each file as **owned by the calling UID**: root sees `0:0`, and UID 1000 sees `1000:1000`. The Mac enforces permissions as the VM's Mac user. Writes from the guest land on the Mac as `501:20`.
   - So no idmap is needed, and `git status` as UID 1000 works on `/mnt/mac`.
   - Idmapped mounts are **not supported** on virtiofs anyway (`mount_setattr` → `EINVAL`).
   - → Drop the "default user = Mac UID 501" requirement and the idmap work. The distro's own OOBE user (UID 1000) is fine.
   - Security note: every Linux user gets the Mac user's access to `/mnt/mac`, the same as WSL's DrvFs.
2. **The distro's udev renames the shared NIC** (`eth0` → `enp0s1`). `net.ifnames=0` on the kernel command line fixes it. Add that to the default command line.
3. **Readiness race.** The agent is ready before systemd creates its bus socket, so `systemctl` fails if called too early. The distro should only count as "Running" after `/run/systemd/private` exists and `systemctl is-system-running --wait` has returned.
4. **Hostname and `/etc/hosts`.** systemd resets the hostname (Ubuntu → `localhost.localdomain`; Debian → the image's `/etc/hostname`, `arrakis`), and `sudo` then warns `unable to resolve host`. msl must write `/etc/hostname` and `/etc/hosts` (WSL's `generateHosts` / `hostname`), in milestone 4.
5. **Ubuntu OOBE (`/usr/lib/wsl/wsl-setup`) runs unmodified**, as long as `WSL_DISTRO_NAME` is set. The script uses `set -u` and aborts without it.
   - Its `powershell.exe` calls fail harmlessly.
   - It creates UID 1000 in groups `adm,cdrom,sudo,dip,plugdev` and writes `[user] default=<name>` to `/etc/wsl.conf`.
   - → Set `WSL_DISTRO_NAME` in the **OOBE environment only**. Interactive prompts need the PTY path (milestone 1).
   - Debian's `oobe.sh` follows the same pattern (`read -p` + `adduser --uid 1000`).
6. **cloud-init** in Ubuntu is `disabled-by-generator` and harmless. No override needed.
7. **cgroups.** The supervisor stays outside the distro's cgroup. The distro's PID 1 joins `msl/<name>` and then unshares the cgroup namespace; the agent moves to the `msl-agent` leaf, and systemd delegation works. Stopping a distro must **remove the cgroup tree**, or a restart fails with `EBUSY`.
8. **vmnet subnet changes per launch** (192.168.64.0/24 → 192.168.65.0/24). msld must pin it with `vmnet_network_configuration_set_ipv4_subnet` (or persist and serialize the network).
9. **Apple's kernel lacks** USB, quota and nfsd → ship our own kernel (Apple config + `kernel/msl.fragment`).

## Open items
- Host memory reclaim: measure with a reliable metric (Activity Monitor "Memory" / `vmmap`), and try `drop_caches` + balloon cycling.
- Interactive OOBE through a real PTY (milestone 1).
