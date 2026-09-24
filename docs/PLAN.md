# MSL — a WSL2-equivalent for macOS

## Context
Build `msl`, a macOS equivalent of WSL2. It should have the same CLI surface and the same behaviour as `wsl.exe` (distro lifecycle, shells, interop, networking and config), built only on Apple-native technology. The repo is empty apart from a README. Host: macOS 27 on Apple Silicon, Swift 6.3, Apple `container` 1.1.0 installed.

Decisions so far:
- **v1 scope:** core lifecycle plus host integration: the Mac filesystem, cwd translation, env passing and localhost networking.
- **Out of scope:** running macOS executables from inside a distro. Distros see Linux binaries only.
- **Binary name:** `msl`.
- **Stack:** Apple-only, with GPU deferred. Virtualization.framework only offers 2D virtio-gpu. The only GPU path today is libkrun/Venus, which is not Apple-native.

## Key decision: one shared utility VM (matches WSL2)
Research on the open-sourced WSL repo: WSL2 runs **one utility VM**.
- `mini_init` is PID 1 for the whole VM.
- Each distro gets **its own `init` in separate mount, PID and UTS namespaces**.
- The network namespace is shared, so all distros have one IP and localhost works across them.
- `/mnt/wsl` is shared between distros.
- Execution goes: session leader → relay → process, with stdio carried over hvsockets.

OrbStack uses the same model on macOS.

Why the shared VM wins on macOS:
- Virtualization.framework rarely gives freed guest RAM back to the host. With one VM per distro, idle distros each keep holding memory. One VM means one memory pool.
- Distro start and stop is near-instant, because it's a namespace rather than a VM boot.
- `--shutdown`, the `.wslconfig` resource limits and shared localhost all behave exactly as they do in WSL.

Trade-offs:
- We write our own guest init. Containerization's multi-container support (`LinuxPod`) is experimental and doesn't support per-distro systemd.
- Isolation between distros is weaker, same as WSL.
- The whole design sits behind a `DistroRuntime` protocol, so a VM-per-distro backend could be added later.

## Architecture

```
msl (CLI) ──XPC──▶ msld (per-user LaunchAgent: wslservice + wslhost + wslrelay)
                     │ owns VZVirtualMachine, registry, config, port relays
                     │ vsock (control + per-session stdio)
                     ▼
           Utility VM (Linux kernel + initrd)
             msl-mini-init (PID 1): mounts, networking, data disk, launches distros
               ├─ msl-init [distro A] (own mnt/pid/uts/cgroup ns; optional systemd)
               └─ msl-init [distro B]
```

### Host side (Swift, macOS 26+)
**`msl` CLI**
- A hand-written parser that reproduces wsl.exe's rules:
  - options may come in any order;
  - `--` passes the rest through unchanged;
  - `~` means start in the home directory;
  - short aliases work, e.g. `-l -v -q -d -u -e -s -t`.
- The English messages, table layouts (`NAME STATE VERSION`, `*` marking the default) and exit codes match WSL. The exit code is the Linux process's own code, or non-zero with an `Error code: Msl/<Component>/<Name>` line.
- Output is always UTF-8. WSL's UTF-16 quirk is not copied.
- stdin, stdout and stderr are passed to `msld` as file descriptors over XPC, and `msld` splices them to vsock. SIGWINCH and signals are sent as control messages.

**`msld`**
- A LaunchAgent with a Mach XPC service. It is started when `msl` first connects and stops the VM after `vmIdleTimeout`.
- Stores:
  - Registry (the Lxss equivalent): `~/Library/Application Support/msl/registry.json`, one entry per distro: GUID, name, state, default user, flags.
  - Global config: `~/.mslconfig`, the `.wslconfig` equivalent with the same INI keys and the same size-suffix and bad-file rules.
- VM setup:
  - virtio-blk data disk, a sparse ASIF image.
  - `VZVmnetNetworkDeviceAttachment` in shared (NAT) mode (macOS 26). It works with ad-hoc signing and only the virtualization entitlement (spike). The **subnet is pinned** with `vmnet_network_configuration_set_ipv4_subnet`, because it otherwise changes per launch.
  - `VZVirtioSocketDevice`.
  - virtiofs share of `/`.
  - `VZLinuxRosettaDirectoryShare`.
  - Memory balloon.
  - XHCI controller, for hot-attaching disks as USB mass storage.
- Entitlement: `com.apple.security.virtualization`. Ad-hoc signing for development; Developer ID plus notarisation for release.

### Guest side (Rust, statically linked)
- **Language and toolchain:** Rust. The guest runs as PID 1 and inside namespaces, so it needs `fork`/`setns`/`pivot_root` without a language runtime getting in the way. Rust also gives memory safety for code that parses input from the host, small static binaries, and direct prior art: the Kata Containers agent (which runs inside the VM, talks over vsock and spawns into namespaces) and youki.
  - Target `aarch64-unknown-linux-musl` only (arm64 first). x86_64 matters only as a Rosetta *test input*, never as a build target. Build with plain `cargo` on macOS: musl's startup files and libc come with the rustup target, and linking uses `rust-lld` (set in `.cargo/config.toml`). No zig or C cross-toolchain is needed.
  - **Pure-Rust dependencies only, no C code.** This is what keeps the cross build toolchain-free.
  - Release profile: `opt-level="z"`, `lto="fat"`, `codegen-units=1`, `panic="abort"`, `strip=true`. Keep musl's malloc; the agent allocates little. If profiling shows a problem, switch to a pure-Rust allocator.
  - **One multi-call binary**, `msl-guest`, which acts as `msl-mini-init`, `msl-init` or `mslpath` based on `argv[0]`, like WSL's `/init`. Target size is about 4–7 MB.
  - The initrd holds only this binary.
  - It is bind-mounted read-only as `/init` into each distro, so installing a distro changes nothing inside it.
- **Crates:**
  - `nix`/`rustix` for syscalls, mounts (including `open_tree`, `mount_setattr` and `move_mount` for idmapped mounts), `pivot_root` and namespaces;
  - `tokio` on a **current-thread runtime**, which keeps memory low and keeps the process single-threaded, so `setns`/`unshare` stay safe;
  - `tokio-vsock`;
  - `rtnetlink` for network setup;
  - `tonic` + `prost` for gRPC;
  - `rust-ini` for wsl.conf;
  - `tar`, `flate2` (`miniz_oxide` backend), `lzma-rs` and `ruzstd` for import/export streams (all pure Rust);
  - youki's `libcontainer`/`libcgroups` for cgroup v2 and namespace helpers where they fit (evaluate in the spike, and vendor narrowly if they're too heavy).
- **Process-model rules:**
  - A distro is created by `fork` (or `clone3`) with `CLONE_NEWNS|NEWPID|NEWUTS|NEWCGROUP`. The child sets mount propagation (private, except the shared `/mnt/msl`), does `pivot_root` and then continues as `msl-init`. User processes are spawned with `Command::pre_exec` for setsid, controlling tty, credentials and supplementary groups (read from the distro's own `/etc/group`).
  - **Only async-signal-safe calls** are allowed between `fork` and `exec`. Fork before starting the tokio runtime, or from a dedicated spawn path that doesn't allocate.
  - **systemd distros:** `msl-init` forks. The parent execs `/sbin/init` (systemd becomes PID 1 of the namespace) and the child stays as the agent, re-parented to systemd. Without systemd, `msl-init` is PID 1 itself.
  - **Reaping:** a single SIGCHLD handler (`tokio::signal`) calls `waitid`/`waitpid(-1)` and hands exit statuses to waiters by PID. Nothing else waits on children. The agent sets `PR_SET_CHILD_SUBREAPER` when it isn't PID 1.
  - Sessions are tokio tasks inside `msl-init`, not separate relay processes. The only processes are the user's own.
- **`msl-mini-init`** (PID 1):
  - mounts the base filesystems and the data disk (`/var/lib/msl/distros/<guid>/rootfs`);
  - sets up networking and DNS;
  - registers binfmt for Rosetta (x86_64 ELF only);
  - on request, launches a distro's init with `clone(CLONE_NEWNS|NEWPID|NEWUTS|NEWCGROUP)` and `pivot_root`;
  - handles import/export as tar streams, `--mount`, and the debug shell.
- **`msl-init`**, one per distro, and a multi-call binary like WSL's `/init`:
  - parses `/etc/msl.conf`, falling back to `/etc/wsl.conf` so existing distros work unchanged;
  - automounts the Mac filesystem at `/mnt/mac` (a bind of the VM-wide virtiofs mount; no uid mapping needed);
  - optionally boots systemd and runs `boot.command`;
  - generates `/etc/hosts`, `/etc/resolv.conf` and the hostname;
  - runs each `msl` invocation as a session task: a PTY or pipes relayed to its vsock streams;
  - runs the localhost port watcher (polls `/proc/net/tcp{,6}`).
  - When invoked as `mslpath`, it translates paths (`-u/-w/-m/-a`, with `-w` producing a macOS path).
- **Protocol:** gRPC over vsock. The `.proto` files in `proto/` are the single source of truth: the host uses code generated by grpc-swift, and the guest uses code generated by `tonic-build`/`prost-build` in `build.rs`. Stdio uses raw vsock streams, one port per session stream, so bytes aren't framed through gRPC.
- **Kernel:**
  - Apple's 6.18 config (`kernel/base.config`, extracted from the kernel `container` ships) plus `kernel/msl.fragment`. It already has binfmt_misc, namespaces, overlayfs, bpf, virtiofs and vsock; the fragment adds XHCI/usb-storage, quota and nfsd.
  - `kernel/build.sh` builds it inside a Debian container using Apple's `container`.

### Feature mapping (WSL → MSL)
| WSL | MSL |
|---|---|
| Distro storage | One shared ext4 data disk (sparse ASIF). Each distro is a directory on it. `--manage --resize` sets an ext4 project quota. `--move` relocates the data disk. |
| `.vhdx` import and `--mount` | Raw or ext4 images are hot-attached as USB mass storage, since virtio-blk can't be hot-plugged. `--import --vhd` copies the image into the store. |
| `--install` | Uses **Microsoft's `DistributionInfo.json` `Arm64Url` entries** directly, so `.wsl` tarballs work as they are. `--from-file`, `--name`, `--location` and `--no-launch` are supported. `wsl-distribution.conf` OOBE is honoured; shortcut and terminal sections are ignored. Override with `MSL_DISTRIBUTION_LIST_URL`. |
| amd64 distros | Rosetta, through binfmt. |
| `/mnt/c` and DrvFs | `/mnt/mac` over virtiofs (`automount.root` still applies). |
| `\\wsl.localhost\<distro>` | A userspace NFSv3 server in mini-init (adapted from `nfsserve`, BSD-3) exports `/run/msl-view`, one bind mount per distro **name**. msld mounts each distro separately as the user (`127.0.0.1:/<name>` at `~/MSL/<name>`, browsable, `nfc`) through a private vsock bridge, so Finder lists every distro under its own name in Locations, with the distro's logo (`[shortcut] icon` from `wsl-distribution.conf`, converted to `.VolumeIcon.icns`). macOS metadata (`.DS_Store`, AppleDouble `._*`, volume and folder icons) is kept in guest memory (`nfsview.rs`), so copies with extended attributes work and Linux never sees the files. Mounts follow the registry and are removed on shutdown; available while the VM runs. New files inherit the parent directory's owner. |
| Running Windows `.exe` from Linux | **Not supported (decided).** There is no Mach-O binfmt, no `mac` command, and Mac paths are never added to `PATH`. Every binary name therefore resolves only to Linux, so npm/node-gyp, autotools and similar builds can only find Linux toolchains. `[interop] enabled` and `appendWindowsPath` are parsed and ignored, and a Mach-O file fails with `Exec format error`. |
| `WSLENV` | `MSLENV`, **one-way (Mac → Linux) only**, with the `/p` and `/l` flags. `/u` is implied; `/w` is ignored. |
| `/mnt/mac` ownership | **Nothing to do (spike finding).** Apple's virtiofs reports files as owned by the calling UID, and the Mac enforces permissions as the Mac user. So any Linux UID, including the distro's usual 1000, can use `/mnt/mac`, and git's ownership checks pass. Idmapped mounts aren't supported on virtiofs (`EINVAL`) and aren't needed. `automount` `uid/gid/umask` are parsed and ignored. Docs recommend building in the distro's ext4 home for speed and case sensitivity. |
| cwd inheritance | The macOS cwd is translated to `/mnt/mac/...`. `--cd` accepts Linux paths, `~` or Mac paths. |
| Localhost forwarding (NAT) | The guest streams its listening TCP ports (`MiniInit.WatchPorts`); `msld` binds `127.0.0.1`/`::1` for each (skipping ports in use on the Mac) and relays connections over vsock to a guest forwarder. `host.internal` in the generated `/etc/hosts` points at the vmnet gateway. |
| `dnsTunneling` | Guest stub at `10.255.255.254:53` (UDP+TCP) relays queries over vsock; `msld` answers with `DNSServiceQueryRecord` (mDNSResponder), so VPN split DNS, `/etc/resolver`, `.local` and the Mac's hosts file work. Loopback/link-local answers are dropped. `[wsl2] dnsTunneling=false` falls back to vmnet DNS. |
| vsock flow control | **Required:** Virtualization.framework's vsock device blocks (freezing all vsock traffic and a vCPU) if the host stops reading a connection. Every guest↔host byte stream uses credit framing (`guest/src/framed.rs`, `Sources/MSLService/FramedBridge.swift`; 1 MB window), so receivers always drain their socket. Details, evidence and alternatives: [`docs/vsock-flow-control.md`](vsock-flow-control.md). |
| `autoMemoryReclaim` | **No effect on macOS**: VZ's balloon doesn't release pages to the host (measured). Memory comes back when the VM exits after `vmIdleTimeout`. See [`docs/memory-reclaim.md`](memory-reclaim.md). |
| Error codes | The `Error code: Msl/…` line (wsl.exe prints `Wsl/…`) is only shown with `MSL_ERROR_CODES=1`; by default msl prints just the message. |
| `--set-version 1`, `--enable-wsl1`, `--inbox`, `--legacy`, `--system`, WSLg, GPU | Accepted by the parser and return an "unsupported on macOS" error in WSL's error format. |
| `--debug-shell` | Root shell (BusyBox) in the VM's root namespace. mini-init also serves the `Agent` service for it. |
| `--mount`/`--unmount` | Image files (or `/dev/diskN`, which needs root) are hot-attached as USB mass storage and mounted at `/mnt/msl/<name>` in every distro (a shared mount, propagated as a slave into running distros). `--bare`, `--name`, `--type`, `--options` and `--partition` are supported. |
| `--manage --compact` / `--resize` | `--compact` runs FITRIM on the shared store (and every shutdown trims), so `data.img` shrinks on the Mac. `--resize` isn't supported yet: the store is one sparse 256 GiB disk, and its `sparse_super2` format rules out online resize. |
| `--update [--pre-release]`, `--uninstall` | `--update` reads a release manifest (a channel URL baked in by `scripts/package.sh`, or `MSL_UPDATE_URL`), verifies the SHA-256, stops the service, and replaces files atomically. The old `msld` exits once replaced. `--uninstall` removes the program files and keeps distributions and settings. Both refuse on development builds. |

### Distro compatibility (WSL images, unmodified)
msl has no distro builds of its own. A WSL image is a plain rootfs tarball with no Windows code and no kernel. Its WSL-specific parts are `wsl.conf`, `wsl-distribution.conf` (OOBE) and a few helper packages, and msl already honours the first two.

**Availability** (checked against `DistributionInfo.json` on 2026-09-24):
- **arm64, runs natively:** Ubuntu 20.04–26.04, Debian, Fedora 43/44, AlmaLinux 8/9/10/Kitten, openSUSE Tumbleweed/Leap 16, Kali.
- **x86-only, runs through Rosetta:** archlinux, SLES 15 SP7 and 16.0, eLxr.

**Compatibility layer**, the guest package `compat`, applied by `msl-init` on each distro start. It never edits the image except for the systemd masks listed here:
- **Windows-only systemd units** are runtime-masked at each distro start (`/run/systemd/system/<unit>` → `/dev/null` on the distro's msl-owned tmpfs), so the image itself is never modified.
  - The initial list is `wsl-pro-service.service` (Ubuntu Pro for WSL), `console-getty.service` and `getty@tty1.service`. The gettys fight over the shared VM console; Debian goes `degraded` because of them.
  - The list lives in `guest/src/compat.rs` (`MASKED_UNITS`).
- **WSL detection is left off.** msl sets neither `WSL_DISTRO_NAME` nor `WSL_INTEROP`, and it does not put `microsoft` in `/proc/version`. Distro scripts therefore take their non-WSL code paths.
  - msl sets `MSL_DISTRO_NAME` instead.
- **`wslu`** (`wslview`, `wslvar`, …) is left as it is. It only fails when someone invokes it.
  - `/usr/bin/wslpath` is not overridden. `mslpath` is provided as `/usr/bin/mslpath` → `/run/msl/init` (the multi-call binary), the same way WSL provides `/usr/bin/wslpath`. It is the only file msl adds to an image.
- **First run (OOBE) and user creation:**
  - If `wsl-distribution.conf` defines `oobe.command` (for example Ubuntu's `wsl-setup`), msl runs it on the first interactive start, as WSL does.
  - The OOBE runs with `WSL_DISTRO_NAME=<name>` set **in its environment only**. Ubuntu's `wsl-setup` uses `set -u` and aborts without it (spike finding); its `powershell.exe` calls fail harmlessly.
  - If it's missing or exits non-zero, msl uses its **own OOBE**: prompt for a username (defaulting to the macOS short name), create it as UID 1000, add it to the sudo/wheel group, and set it as the default user.
  - OOBE commands that only add Windows wording are replaced by msl's built-in OOBE (`guest/src/compat.rs` `OOBE_OVERRIDES`; currently Debian's `oobe.sh`).
- **cloud-init:** Ubuntu's is `disabled-by-generator` on msl (spike finding), so no override is needed.
- **Kernel command line:** `net.ifnames=0`, otherwise the distro's udev renames the shared NIC `eth0` → `enp0s1` (spike finding).
- **Readiness:** a systemd distro is reported `Running` only after `/run/systemd/private` exists and `systemctl is-system-running --wait` has returned. Stopping a distro removes its cgroup tree (`msl/<name>`); otherwise a restart fails with `EBUSY`.

**Later:** msl's own distro list (`MSL_DISTRIBUTION_LIST_URL`) combining the same WSL tarballs with OCI images (`docker.io/library/*`, which need systemd/init packages added). An `msl-setup` package only if the upstream WSL-specific pieces cause real problems.

## Repo layout
- `Package.swift`:
  - Pins `apple/containerization` at exactly 0.46.0. We use `ContainerizationEXT4` (formatting the data disk), `ContainerizationOCI` (optional `--install` from OCI images) and `ContainerizationOS`.
  - Also depends on grpc-swift and swift-protobuf.
- `Sources/msl`: the CLI.
- `Sources/MSLCore`: argument parser, message catalogue, INI parser, config models.
- `Sources/MSLService` (`msld`): VM manager, registry, port relay, NFS mounter.
- `proto/`: the shared `.proto` files. `Sources/MSLProtocol` holds the generated Swift.
- `guest/`: a Cargo crate (`Cargo.toml`, `rust-toolchain.toml` pinning the toolchain and musl targets), with the binary `msl-guest` and modules `miniinit`, `distroinit`, `session`, `portwatch`, `config`, `compat` and `mslpath`. A `Makefile` target runs `cargo build --release --target aarch64-unknown-linux-musl` and packs the result into the initrd.
- `kernel/`: config fragment and build script. `scripts/`: initrd build, signing, packaging (tarball, .pkg) and `install.sh`, the interactive installer (no Homebrew).
- `Tests/`:
  - `MSLCoreTests` (swift-testing, `swift test`): parser, output formats, registry, IPC fd passing, `.mslconfig`, manifest.
  - `e2e/`: shell scripts that drive a real `msl`.

## Milestones
0. ✅ **Spike** (de-risk, about 1 week). Boot VZ with our kernel, initrd and `msl-mini-init`, and get a vsock ping working. Confirm:
   - USB mass-storage hot-attach works;
   - the vmnet attachment works with ad-hoc signing;
   - Rosetta works;
   - namespace plus pivot_root works for systemd as PID 1 inside the namespace;
   - the Ubuntu 24.04 and Debian WSL tarballs, unmodified: boot them, run their OOBE (`wsl-setup`), check cloud-init falls back cleanly, and list every systemd unit that fails, to seed the `compat` mask list.
   - **Status:** done. Only the host memory-reclaim measurement is still open. See `docs/spike-results.md`.
1. ✅ **Core lifecycle** (done 2026-09-24; `Tests/e2e/m1.sh` 40/40): data disk, `--import`/`--install --from-file`, per-distro init, interactive PTY shell (`msl`, `-d`, `-u`, `-e`, `--`, `--cd`, `~`), `-l [-v|-q|--running]`, `--terminate`, `--shutdown [--force]`, `--unregister`, `--export [--format]`.
2. ✅ **Distros and config** (done 2026-09-24; `Tests/e2e/m2.sh` 25/25; `--manage --resize/--compact` deferred to M5): online `--install` and `-l -o`, OOBE and default user (the distro's own OOBE, with msl's OOBE as fallback), the `compat` layer (unit masks, cloud-init fallback), `wsl.conf`/`msl.conf`, `.mslconfig`, `--set-default`, `--status`, `--manage`, idle timeouts.
3. ✅ **Host integration** (done 2026-09-24; `Tests/e2e/m3.sh` 24/24): `/mnt/mac` with uid mapping, cwd translation, `MSLENV` (Mac → Linux), `mslpath`.
4. ✅ **Networking and files** (done 2026-09-24; `Tests/e2e/m4.sh` 33/33): localhost forwarding, DNS proxy, hosts file, hostname, NFS export to `~/MSL/<distro>`.
5. ✅ **Remainder** (done 2026-09-24; `Tests/e2e/m5.sh` 20/20, `Tests/e2e/release.sh`): `--debug-shell` (BusyBox in the initrd), `--mount`/`--unmount` (USB hot-attach, shared `/mnt/msl`), `--manage --compact` (FITRIM, plus trim on every shutdown), `--update`/`--uninstall`, packaging (`scripts/package.sh`: tarball, `.pkg`, update manifest; `scripts/notarize.sh`; `install.sh` interactive installer, Homebrew formula dropped. Not done: `--manage --resize`, memory reclaim, x86_64 distros, notarisation (see Open items).
6. **x86_64 emulation with qemu-user** (planned 2026-09-24): run x86_64 distros and binaries without Rosetta.
   - **Why:** general-purpose Rosetta 2 ends after macOS 27. Apple says Rosetta for Intel binaries in Linux VMs continues, but a Rosetta-free path removes the dependency (and the owner prefers not to install Rosetta).
   - **What:** QEMU *user-mode* (`qemu-x86_64`, optionally `qemu-i386`) inside the guest, registered with `binfmt_misc` (`F` flag, like the Rosetta entry, so it works in every distro namespace). No full-system QEMU on the Mac, so the Apple-only host rule holds.
   - **Shipping:** Debian `qemu-user` 1:10.0.13 static-pie binaries (14 MB each) in `share/msl/emu/`, exposed read-only to the guest over virtiofs rather than packed into the initrd, to avoid holding them in VM memory. GPL-2: add a source offer to the third-party notices.
   - **Selection:** `.mslconfig [wsl2] x86Emulation = auto | rosetta | qemu | none`. `auto` means Rosetta if already installed, otherwise QEMU. Nothing is ever installed on the Mac. `-l -o` and `--install` offer x86_64-only distros whenever an emulator is available.
   - **Feasibility (measured):** x86_64 BusyBox runs under qemu-user in the msl VM. SHA-256 of 64 MB: native 0.38 s, Rosetta 0.35 s, qemu-user 0.70 s. Expect 3–10× slower than Rosetta for heavy work (compilers, JITs, package installs).
   - **Risks to test:**
     - systemd as PID 1 under qemu-user (unsupported syscalls; may need `[boot] systemd=false` for emulated distros);
     - setuid binaries such as `sudo` (binfmt `C`/`O` flags);
     - `pacman` performance.
   - **Verification (`Tests/e2e/m6.sh`):** with `x86Emulation=qemu` on this Mac, `msl --install archlinux`, then check:
     - `uname -m`/`file` for the emulated userland;
     - systemd state (or the documented fallback);
     - `sudo`;
     - a `pacman -Q` query;
     - compiling and running a small C program;
     - `x86Emulation=none` makes x86_64 installs refuse clearly.

Later: GPU (once Apple ships 3D/compute virtio-gpu), mirrored networking, an FSKit-based `~/MSL` replacing NFS, GUI apps (Wayland → macOS windows), Terminal.app profiles, and a VM-per-distro runtime.

7. **VS Code integration** (proposal, for discussion; recorded 2026-09-24): SSH entries per distro via ProxyCommand, then a thin Remote Explorer extension on top of Remote-SSH. See [vscode-integration.md](vscode-integration.md).

## Verification
- `cargo test` and `cargo clippy -- -D warnings` in `guest/` must pass. They cover the wsl.conf parser, mslpath translation, port-watch parsing of `/proc/net/tcp` fixtures, and namespace, pivot_root and reaper tests. Tests that need root run on this Mac inside a Linux VM: `container run --privileged` with a rust:musl image. The stripped `msl-guest` binary must be under 10 MB, and idle RSS per distro agent under 5 MB.
- `swift test` must pass. It covers parser golden tests (every flag combination in WSL's usage text), the INI/config parser and the registry.
- The `Tests/e2e/*.sh` scripts, run on this Mac:
  - `msl --install Ubuntu`, then check that `msl -l -v` shows `* Ubuntu Running 2`;
  - `msl -e uname -a` exits 0, and `msl -- exit 7` makes `$?` equal 7;
  - `msl --cd ~ pwd` and running `msl pwd` from `~/Projects` gives `/mnt/mac/Users/<you>/Projects`;
  - `python3 -m http.server 8000` in the guest, then `curl localhost:8000` on the Mac;
  - export, unregister, import and the file is still there;
  - two distros can reach each other on localhost;
  - `--shutdown` leaves no VM process running;
  - `ls ~/MSL/Ubuntu/etc` works.
  - **Build hygiene:** `npm install better-sqlite3` (native addon via node-gyp) and `./configure && make` on a GNU autotools project (e.g. GNU hello), run both in `~` and in `/mnt/mac/...`. `file` must report ELF aarch64 for every output. `command -v cc make node` must resolve only to Linux paths. Running `/mnt/mac/bin/ls` must fail with `Exec format error`.
- **Distro compatibility matrix** (`Tests/e2e/distros.sh`), run on each arm64 distro in the manifest:
  - install;
  - OOBE creates a UID-501 default user;
  - `systemctl is-system-running` returns `running`, with no failed units after masking;
  - `sudo` works;
  - the package manager can install `build-essential` or its equivalent.
  - The x86-only distros get the same checks under Rosetta in milestone 5.
- Manual: a systemd distro boots, `/etc/wsl.conf` settings from an unchanged `.wsl` distro are applied, and memory drops after `--shutdown`.

## Open items (after milestone 5)

- **Notarisation:** run `scripts/package.sh` with `MSL_SIGN_IDENTITY` and `MSL_INSTALLER_IDENTITY`, then `scripts/notarize.sh`. Needs the owner's Developer ID and a notarytool profile.
- ~~**Xcode**~~: done 2026-09-24. Xcode 27.0 (Swift 6.4) is the active toolchain, and the host tests are a swift-testing target again (`swift test`: 16 tests in 5 suites).
- **`--manage --resize`:** needs an offline `resize2fs`, i.e. a static e2fsprogs in the initrd, run before mounting `/dev/vda`.
- **x86_64 distros:** listing and installing through Rosetta is implemented but untested; milestone 6 adds a Rosetta-free path (qemu-user) and the tests.
- **vsock:** file the Apple Feedback report (host-initiated connections freeze the VM); consider guest dial-back for data streams ([`docs/vsock-flow-control.md`](vsock-flow-control.md)).
- **`~/MSL` view** only works while the VM runs (no auto-start on access); an FSKit implementation could fix that.
- **Third-party notices:** generate full license texts for all Rust and Swift dependencies before a public release.
