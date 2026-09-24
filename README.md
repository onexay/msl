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

### Quick start

```console
$ msl --install Ubuntu       # downloads the arm64 .wsl image, runs Ubuntu's own first-run setup
$ msl                        # shell in Ubuntu, in the Mac's current directory (under /mnt/mac)
```

To build from source instead, see [Development](#development).

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

Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (architecture and the WSL → msl feature mapping), [`docs/design/vsock-flow-control.md`](docs/design/vsock-flow-control.md), [`docs/design/memory-reclaim.md`](docs/design/memory-reclaim.md).

### Configuration

- **VM:** `~/.mslconfig`, with the same keys as `.wslconfig` (`memory`, `processors`, `kernel`, `localhostForwarding`, `dnsTunneling`, idle timeouts, …). `msl --status` shows the effective settings and any changes waiting for `msl --shutdown`.
- **Each distro:** `/etc/wsl.conf` works unchanged; `/etc/msl.conf` takes precedence.

Full reference: [docs/configuration.md](docs/configuration.md).

### How msl compares

Among Mac tools, msl is the only one that is a drop-in for `wsl.exe` and runs Microsoft's WSL distro images unmodified, so Windows and Mac developers share one workflow. OrbStack is the closest in design (one shared VM, full distros, Finder access). It is ahead on polish, x86_64, dynamic memory and containers, but it is proprietary and runs Mac binaries from Linux. Apple's `container machine` (container 1.0+) gives persistent systemd environments from OCI images, with one VM per machine. Lima/Colima, Docker Desktop, Podman, Multipass, UTM, Rancher Desktop and Tart solve neighbouring problems. The feature matrix, per-project notes and gaps are in [`docs/comparison.md`](docs/comparison.md).

### Known limitations

Tracked as [issues](https://github.com/onexay/msl/issues); planned work is in the [milestones](https://github.com/onexay/msl/milestones).

- **x86_64 distros:** not supported yet. arm64 images only in practice. An untested Rosetta path activates only if Rosetta is already installed (msl never installs it); the [Nitrogen](https://github.com/onexay/msl/milestone/7) milestone adds qemu-user instead.
- **Memory:** returned to macOS only when the VM stops (`vmIdleTimeout`). Virtualization.framework's balloon doesn't give pages back, so `autoMemoryReclaim` has no effect.
- **Disk:** `--manage --resize` isn't supported (no online resize of the shared 256 GiB sparse store). `--compact` and trim on shutdown do shrink `data.img`.
- **`~/MSL`** is only available while the VM runs.
- **No GPU** (Virtualization.framework has only 2D virtio-gpu), no WSLg/GUI apps, no WSL1, no mirrored networking.
- **Not notarised yet**; releases need a Developer ID.
- Distros are isolated by namespaces, not separate VMs (same as WSL2).

### Development

```console
$ scripts/build.sh      # guest + initrd + msl/msld → build/ (downloads the kernel release)
$ swift test            # host unit tests; see CONTRIBUTING.md for the guest and e2e suites
```

Build requirements, tests, code layout and the release process are in [CONTRIBUTING.md](CONTRIBUTING.md). The documentation index is [docs/README.md](docs/README.md).

### License

msl is an independent project, not affiliated with or endorsed by Microsoft or Apple. WSL and Windows are trademarks of Microsoft Corporation; Mac and macOS are trademarks of Apple Inc.; they are used only to describe compatibility.

msl is licensed under the [Apache License 2.0](LICENSE) (see also [NOTICE](NOTICE)). Release packages include the Linux kernel and BusyBox, which are GPL-2.0 and run inside the VM as separate programs; see [third-party notices](docs/THIRD_PARTY_NOTICES.md).
