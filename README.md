## msl: Modern Subsystem for Linux

**Linux as the development environment on macOS, the way WSL made it on Windows.**

msl runs Linux distributions on macOS the way WSL runs them on Windows. The `msl` command is `wsl.exe` for macOS: same arguments, same output, same exit codes. It runs Microsoft's WSL distribution images, unmodified, in one lightweight Linux VM. It needs Apple silicon and macOS 26 or later, and uses only Apple's Virtualization.framework.

Why: teams split across Windows and macOS end up with two developer setups, two sets of docs and two sets of bugs. With WSL on Windows and msl on macOS, everyone develops in the same Linux distro, from the same image, with the same commands, scripts and `wsl.conf`. The toolchain is Linux on both; the host OS is just where the editor and browser live.

```console
$ msl --install Ubuntu            # an arm64 image from Microsoft's WSL distribution list
$ msl                             # a shell in the default distro, in the current macOS directory
$ msl -d Debian -u root apt update
$ msl -l -v
  NAME            STATE           VERSION
* Ubuntu          Running         2
  Debian          Stopped         2
$ python3 -m http.server 8000     # inside a distro: http://localhost:8000 on macOS
$ ls ~/.msl/distros/Ubuntu/home   # the distro's files from macOS (also in Finder › Locations)
```

- [Install](#install)
- [Documentation](#documentation)
- [VS Code and other IDEs](#vs-code-and-other-ides)
- [How it works](#how-it-works)
- [Known limitations](#known-limitations)
- [How msl compares](#how-msl-compares)
- [Development](#development)

## Install

```console
$ curl -fsSL https://raw.githubusercontent.com/onexay/msl/main/install.sh | sh
```

The installer asks before each step. [Installing msl](docs/install.md) lists its options for an unattended install, and everything msl adds to macOS with what undoes it. Update with `msl --update`. `msl --uninstall` removes msl and undoes the IDE setup, but keeps your distributions.

[Getting started](docs/getting_started.md) goes from here to a shell in Ubuntu and a VS Code window inside it.

## Documentation

`msl` accepts `wsl.exe`'s arguments and prints the same messages, so anything that works with `wsl.exe` in a script or a README should work with `msl`. It runs the images from Microsoft's WSL distribution list, unmodified, and honours their `/etc/wsl.conf`. Tested: Ubuntu 26.04 and 24.04, and Debian 13.

- [Getting started](docs/getting_started.md): install, a first distribution, files, ports and VS Code
- [The msl command](docs/cli.md): the full `msl --help`, every command, and `/mnt/macos`, `mslpath`, localhost and DNS inside a distribution
- [Configuration](docs/configuration.md): `~/.mslconfig`, `/etc/wsl.conf` and `/etc/msl.conf`, environment variables
- [Compatibility with WSL distributions](docs/wsl_compatibility.md): each WSL feature and its msl equivalent
- [JSON output](docs/json.md): `--json` for scripts
- [Troubleshooting](docs/troubleshooting.md)

The [documentation index](docs/readme.md) lists everything, including the architecture and design notes.

## VS Code and other IDEs

The MSL extension does for msl what VS Code's WSL extension does on Windows. The window runs on macOS, while the terminal, language servers, debuggers and extensions run inside the distro.

**Why an extension is needed:** VS Code's own WSL extension runs only on Windows: it calls `wsl.exe` and uses `\\wsl$` paths. Remote-SSH would work, but it needs an SSH server in every distro and a port on macOS. The MSL extension connects VS Code to its server in the distro through msl instead. It uses no SSH and opens no network port on macOS. Forwarded ports work, and so does opening several distros at once.

**Why `argv.json` has to change:** connecting VS Code to a remote machine requires VS Code's remote-resolver API. VS Code keeps that API "proposed", available only to Microsoft's own remote extensions unless the user enables it for an extension. It is enabled by listing the extension under `enable-proposed-api` in `argv.json`. For the same reason the extension can't be published on the Marketplace. It ships with msl, and each version is also a [GitHub release](https://github.com/onexay/msl/releases?q=vscode) (`vscode-<version>`).

**Setting it up:** the installer does it for you, or you can run it yourself:

```console
$ msl --manage-ide                             # lists the IDEs found and asks
$ msl --manage-ide --ide vscode --install      # also vscode-insiders, vscode-oss (VSCodium), cursor, all
$ msl --manage-ide --ide all --uninstall
```

Then quit and reopen the IDE (⌘Q). In the command palette, run **MSL: Connect to Distro**, or use `code --folder-uri vscode-remote://msl+<distro>/home/<user>`. The first connection to a distro installs the VS Code Server that matches your IDE's version. It's downloaded on macOS and cached, so the distro needs no `curl` or `wget`.

More: [extensions/vscode/README.md](extensions/vscode/README.md), including troubleshooting.

## How it works

```
msl (CLI) ──Unix socket──▶ msld (per-user service, started on demand)
                            │ owns the VM, the registry, port forwarding, the DNS proxy,
                            │ the ~/.msl/distros NFS mounts, and connect.sock (IDE pipes)
                            │ gRPC and flow-controlled streams over vsock
                            ▼
                 One utility VM (msl kernel + initrd)
                   msl-guest as PID 1: data disk, network, NFS view, DNS stub
                     ├─ distro A init (own mount/PID/UTS/cgroup namespaces; systemd optional)
                     └─ distro B init
                   shared: network namespace (one localhost), /mnt/macos (virtiofs), /mnt/msl
```

- **Same model as WSL 2:** one VM, and one `init` per distro in its own namespaces. A distro starts in milliseconds, all distros share memory and localhost, and `--shutdown` stops everything.
- **Apple-native only:** Virtualization.framework (vmnet NAT, virtiofs, vsock, USB mass storage for `--mount`) and a kernel built from Apple's `container` configuration. No QEMU and no third-party hypervisor.
- **Guest:** one static Rust binary (`msl-guest`) is the VM's init, each distro's init and agent, `mslpath`, the NFS server and the DNS stub.

Details: [docs/architecture.md](docs/architecture.md), and the [design issues](https://github.com/onexay/msl/issues?q=label%3Adesign).

## Known limitations

Tracked as [issues](https://github.com/onexay/msl/issues); planned work is in the [milestones](https://github.com/onexay/msl/milestones).

- **x86_64 distros:** not supported yet.
- **Memory:** returned to macOS only when the VM stops, because Virtualization.framework's balloon doesn't give pages back. `autoMemoryReclaim` has no effect.
- **Disk:** all distros share one sparse disk, 256 GiB by default (`defaultVhdSize`). `--manage --resize` grows it for all of them; it can't shrink, and `--move` isn't supported. `--compact` and trim on shutdown shrink `data.img` on macOS.
- **`~/.msl/distros`:** available only while the VM runs.
- **Not available:** GPU, WSLg and GUI apps, WSL 1, mirrored networking.
- **Signing:** releases aren't notarised yet.
- **Isolation:** distros are isolated by namespaces, not separate VMs (as in WSL 2).

## How msl compares

msl is the only macOS tool that is a drop-in for `wsl.exe` and runs WSL images unmodified. OrbStack is closest in design (one shared VM, full distros, Finder access) and ahead on polish, x86_64 and memory, but it's proprietary and runs macOS binaries from Linux. Apple's `container machine`, Lima, Colima, Docker Desktop, Podman, Multipass, UTM and Tart solve neighbouring problems. See [docs/comparison.md](docs/comparison.md).

## Development

```console
$ scripts/build.sh      # guest, initrd, msl/msld → build/ (downloads the kernel and VS Code extension releases)
$ swift test            # host unit tests; CONTRIBUTING.md covers the guest and e2e suites
```

Build requirements, tests, code layout and releases (msl, the kernel and the VS Code extension each have their own) are in [CONTRIBUTING.md](CONTRIBUTING.md). The documentation index is [docs/readme.md](docs/readme.md).

## License

msl is an independent project, not affiliated with or endorsed by Microsoft or Apple. WSL and Windows are trademarks of Microsoft Corporation; Mac and macOS are trademarks of Apple Inc.; they are used only to describe compatibility.

msl is licensed under the [Apache License 2.0](LICENSE) (see also [NOTICE](NOTICE)). Release packages include the Linux kernel, BusyBox and e2fsprogs (`e2fsck`, `resize2fs`), which are GPL-2.0 and run inside the VM as separate programs; see [third-party notices](docs/third_party_notices.md).
