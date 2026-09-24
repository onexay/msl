## macOS Subsystem for Linux

**Linux as the development environment on macOS, the way WSL made it on Windows.**

`msl` is the `wsl.exe` command line on macOS: same arguments, same behaviour, same wording. It runs unmodified WSL distribution images in one lightweight Linux VM, using only Apple's Virtualization.framework, on Apple silicon with macOS 26 or later.

Why: teams split across Windows and macOS end up with two developer setups, two sets of docs and two sets of bugs. With WSL on Windows and msl on macOS, everyone develops in the same Linux distro, from the same image, with the same commands, scripts and `wsl.conf`. Your toolchain is Linux on both; the host OS is just where the editor and browser live.

```console
$ msl --install Ubuntu            # from Microsoft's WSL distribution list (arm64 images)
$ msl                             # a shell in the default distro, in the Mac's current directory
$ msl -d Debian -u root apt update
$ msl -l -v
  NAME            STATE           VERSION
* Ubuntu          Running         2
  Debian          Stopped         2
$ python3 -m http.server 8000     # inside a distro → http://localhost:8000 on the Mac
$ ls ~/MSL/Ubuntu/home            # the distro's files, from the Mac (also in Finder › Locations, with the distro's logo)
```

### Install

```console
$ curl -fsSL https://raw.githubusercontent.com/onexay/msl/main/install.sh | sh
```

The installer is interactive: it checks the Mac, asks where to install (default `~/.local`, no sudo), downloads the latest release and verifies its SHA-256, offers to add msl to `PATH`, and offers to install a first distro. For unattended installs: `… | sh -s -- --yes [--prefix /usr/local] [--version x.y.z] [--no-path]`; `--from <tarball>` installs a local package.

msl has no Homebrew formula: it's a self-contained environment and updates itself with `msl --update`; `msl --uninstall` removes it and keeps your distros.

### Quick start (from source)

```console
$ scripts/build.sh                     # builds build/bin/msl and msld (see "Build and test")
$ build/bin/msl --install Ubuntu       # downloads the arm64 .wsl image, runs Ubuntu's own first-run setup
$ build/bin/msl                        # shell in Ubuntu, cwd = the Mac's cwd under /mnt/mac
```

`msld` starts on first use and stops the VM when nothing has run for `vmIdleTimeout` (60 s by default).

### Examples

```console
$ msl -l -o                                    # distributions available to install
$ msl --install Debian --name work --no-launch
$ msl --install --from-file ~/Downloads/custom.wsl
$ msl -e uname -m                              # run one command, no shell; exit code is passed through
$ msl --cd ~ -- ls -la                         # start in the Linux home directory
$ git log | msl -e wc -l                       # pipes work both ways
$ msl --export Ubuntu ubuntu.tgz --format tar.gz   # tar (default), tar.gz, tar.xz; "-" for stdout
$ msl --import Dev ~/msl/dev ubuntu.tgz            # or "-" for stdin
$ msl --set-default Debian
$ msl -t Ubuntu                                # stop one distro
$ msl --shutdown                               # stop the VM
$ msl --mount ~/disk.img --name data           # at /mnt/msl/data in every distro
$ msl --status                                 # default distro plus the VM's effective settings
$ msl --debug-shell                            # root BusyBox shell in the VM itself
```

Inside a distro:

```console
$ mslpath -w ~/project           # Linux path → macOS path (like wslpath)
$ cd /mnt/mac/Users/me/src       # the Mac filesystem
$ echo $MSL_DISTRO_NAME
```

### What works

- **Distros:**
  - install from Microsoft's list or from a `.wsl` file, import and export (tar/gz/xz, including stdin/stdout);
  - the distro's own first-run setup;
  - `wsl.conf` / `msl.conf`, systemd, `--manage`, idle timeouts.
- **Running Linux:**
  - interactive PTY shells and pipes, exit codes, resize and signals;
  - `-e`, `--cd`, `~`, `--shell-type`;
  - `/mnt/mac` (the Mac filesystem), `mslpath`, `MSLENV`.
- **Networking:**
  - localhost forwarding (IPv4 and IPv6);
  - DNS through macOS's own resolver (VPN, split DNS, `.local`);
  - the Mac's name as the hostname, and a generated `/etc/hosts`.
- **Files from the Mac:** each distro's filesystem at `~/MSL/<distro>` (NFS over vsock), listed in Finder › Locations under its own name and logo, while the VM runs.
- **Disks and debugging:** `--mount`/`--unmount` (images at `/mnt/msl/<name>` in every distro), `--debug-shell`, `--manage --compact`.
- **Service:** `--update`, `--uninstall`, `.mslconfig` (the `.wslconfig` equivalent), `--status`. Errors print just the message; set `MSL_ERROR_CODES=1` to add wsl.exe-style `Error code:` lines.

msl never runs macOS binaries inside distros: Linux sees only Linux binaries. `npm`, `node-gyp`, `configure` and friends can only find Linux toolchains, so build output is always Linux ELF, even under `/mnt/mac`.

### How it works

```
msl (CLI) ──XPC──▶ msld (per-user LaunchAgent)
                     │ owns the VZVirtualMachine, registry, .mslconfig,
                     │ port forwarding, DNS proxy, ~/MSL NFS mounts
                     │ gRPC + credit-framed streams over vsock
                     ▼
           One utility VM (msl kernel + initrd)
             msl-guest as PID 1: data disk, network, NFS view, DNS stub
               ├─ distro A init (own mount/PID/UTS/cgroup namespaces; systemd optional)
               └─ distro B init
             shared: network namespace (localhost across distros), /mnt/mac (virtiofs), /mnt/msl
```

- **Same model as WSL2:** one VM, one `init` per distro in its own namespaces. A distro starts in milliseconds, all distros share one memory pool and one localhost, and `--shutdown` stops everything.
- **Apple-native only:** Virtualization.framework (vmnet NAT, virtiofs, vsock, USB mass storage for `--mount`), plus a kernel built from Apple's `container` config with a small fragment. No QEMU, no third-party hypervisor on the Mac.
- **Guest:** one static Rust binary (`msl-guest`) is VM init, per-distro init and agent, `mslpath`, NFS server and DNS stub. It is bind-mounted into each distro; the only file msl adds to an image is the `/usr/bin/mslpath` symlink.
- **Distros are the WSL images, unmodified.** Windows-only systemd units are masked at runtime, WSL detection stays off (`MSL_DISTRO_NAME` is set instead), and the distro's OOBE runs as it does on Windows.

Details: [`docs/PLAN.md`](docs/PLAN.md) (architecture and the WSL → msl feature mapping), [`docs/vsock-flow-control.md`](docs/vsock-flow-control.md), [`docs/memory-reclaim.md`](docs/memory-reclaim.md).

### Configuration

**VM settings: `~/.mslconfig`**, the `.wslconfig` equivalent (same INI sections, keys, size suffixes and warnings; `MSL_CONFIG` overrides the path). Unknown `.wslconfig` keys are accepted and ignored.

```ini
[wsl2]
memory = 8GB                 # default: 50% of the Mac's RAM
processors = 4               # default: all
kernel = ~/kernels/Image     # custom kernel
kernelCommandLine = quiet
localhostForwarding = true   # default true
dnsTunneling = true          # default true; false uses vmnet's DNS
vmIdleTimeout = 60000        # ms; VM stops this long after the last distro stops

[general]
instanceIdleTimeout = 15000  # ms; an idle distro stops after this

[experimental]
autoMemoryReclaim = dropCache  # accepted for compatibility; no effect on macOS
```

Changes apply at the next VM start. `msl --status` shows the effective settings (memory, processors, kernel, kernel command line, localhost forwarding, DNS tunneling, idle timeouts, settings file, running/uptime) and lists any `.mslconfig` changes still pending until `msl --shutdown`.

**Per distro: `/etc/msl.conf`**, falling back to `/etc/wsl.conf`, so existing distros work unchanged. Supported: `[boot] systemd`, `command`; `[user] default`; `[automount] enabled`, `root`, `mountFsTab`; `[network] hostname`, `generateHosts`, `generateResolvConf`. `[interop]` keys are parsed and ignored.

**Environment:** `MSLENV` passes Mac variables into Linux (one way, with `/p` and `/l`, like `WSLENV`). `MSL_ERROR_CODES=1` adds `Error code:` lines. `MSL_DISTRIBUTION_LIST_URL` replaces the distribution list.

### How msl compares

Among Mac tools, msl is the only one that is a drop-in for `wsl.exe` and runs Microsoft's WSL distro images unmodified, so Windows and Mac developers share one workflow. OrbStack is the closest in design (one shared VM, full distros, Finder access). It is ahead on polish, x86_64, dynamic memory and containers, but it is proprietary and runs Mac binaries from Linux. Apple's `container machine` (container 1.0+) gives persistent systemd environments from OCI images, with one VM per machine. Lima/Colima, Docker Desktop, Podman, Multipass, UTM, Rancher Desktop and Tart solve neighbouring problems. The feature matrix, per-project notes and gaps are in [`docs/COMPARISON.md`](docs/COMPARISON.md).

### Known limitations

Also tracked under "Open items" in [`docs/PLAN.md`](docs/PLAN.md).

- **x86_64 distros:** not supported yet. arm64 images only in practice. An untested Rosetta path activates only if Rosetta is already installed (msl never installs it); milestone 6 plans qemu-user instead.
- **Memory:** returned to macOS only when the VM stops (`vmIdleTimeout`). Virtualization.framework's balloon doesn't give pages back, so `autoMemoryReclaim` has no effect.
- **Disk:** `--manage --resize` isn't supported (no online resize of the shared 256 GiB sparse store). `--compact` and trim on shutdown do shrink `data.img`.
- **`~/MSL`** is only available while the VM runs.
- **No GPU** (Virtualization.framework has only 2D virtio-gpu), no WSLg/GUI apps, no WSL1, no mirrored networking.
- **Not notarised yet**; releases need a Developer ID.
- Distros are isolated by namespaces, not separate VMs (same as WSL2).

### Build and test

```console
$ scripts/build.sh                 # guest (Rust, static musl) + initrd + msl/msld → build/
$ build/bin/msl --help
$ swift test                       # host unit tests (swift-testing)
$ scripts/test-guest.sh            # guest unit tests (Linux, via Apple's `container`)
$ Tests/e2e/m1.sh … m5.sh          # end-to-end suites (use a throwaway MSL_HOME)
$ Tests/e2e/release.sh             # package → install → --update → --uninstall
$ scripts/package.sh 0.1.0         # dist/: tarball + .sha256, .pkg, update.json
$ scripts/publish.sh 0.1.0         # package and publish GitHub release v0.1.0 (Latest)
```

Requirements: Xcode 27 (Swift 6.4), Rust 1.98 with `aarch64-unknown-linux-musl`, `protoc`. `scripts/build.sh` downloads the prebuilt kernel from the GitHub release named in `kernel/release.tag` (`kernel/fetch.sh`, via `gh` or `curl`, checked against `kernel/release.sha256`); `kernel/build.sh` rebuilds it from source with Apple's `container`.

Releases: msl ships as `v<version>` releases (the Latest one, used by `install.sh` and `msl --update`), each bundling a kernel. The kernel has its own releases, `kernel-<linux version>-msl.<n>`, published only when the kernel changes (`kernel/publish.sh`: bump `n` for config-only changes) and never marked Latest; each msl release's notes name the kernel it contains.

### Layout

| Path | What |
|---|---|
| `Sources/msl` | CLI (argument parsing and output mirror `wsl.exe`) |
| `Sources/msld`, `Sources/MSLService` | service: VM, sessions, forwarding, DNS, file view, disks |
| `Sources/MSLCore` | parser, messages, registry, `.mslconfig`, IPC |
| `guest/` | `msl-guest`: VM init, per-distro init and agent, NFS server, DNS stub |
| `proto/msl/v1/msl.proto` | host ↔ guest gRPC protocol |
| `kernel/` | kernel config (Apple's + `msl.fragment`) and build script |
| `docs/` | [plan](docs/PLAN.md), [comparison](docs/COMPARISON.md), [spike results](docs/spike-results.md), [vsock flow control](docs/vsock-flow-control.md), [memory reclaim](docs/memory-reclaim.md), [third-party notices](docs/THIRD_PARTY_NOTICES.md) |
| `PROGRESS.md` | development log |

### License

msl is licensed under the [Apache License 2.0](LICENSE) (see also [NOTICE](NOTICE)). Release packages include the Linux kernel and BusyBox, which are GPL-2.0 and run inside the VM as separate programs; see [third-party notices](docs/THIRD_PARTY_NOTICES.md).
