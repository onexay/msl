# Changelog

All notable changes to msl are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and msl uses [semantic versioning](https://semver.org/). `scripts/publish.sh` copies a version's section into its GitHub release notes.

## [Unreleased]

### Fixed
- Sessions get the distribution's locale (`LANG`, `LANGUAGE`, `LC_*` from `/etc/default/locale` or `/etc/locale.conf`), as in WSL and login shells. Without it, VS Code's terminal set `LANG` from its own UI language, and bash printed `setlocale: cannot change locale (en_US.UTF-8)` on distros that don't have that locale, such as Ubuntu with only `C.UTF-8`.

## [0.1.8] - 2026-09-25

### Fixed
- `msl` failed with "could not start <current directory>/msld" when msld wasn't already running, for example right after `msl --update`. It looked for msld next to `argv[0]`, which is just `msl` when run from `PATH`. The same lookup set the install prefix for `--update`, `--uninstall` and `--version --json`, and the msl path recorded for the VS Code extension. msl now uses its real executable path.

### Security
- Other local user accounts can no longer read or change your distributions through `~/.msl/distros` ([#1](https://github.com/onexay/msl/issues/1)). The view is served through a 0600 Unix socket instead of a `127.0.0.1` port, and msld checks every NFS call: only your user ID and the kernel's get through, and only msld can mount the view. `[msl2] fileViewTransport = tcp` brings back the port, with the same checks but weaker protection.

## [0.1.7] - 2026-09-25

### Fixed
- `msl --shutdown` leaves the shared disk clean. It used to power off with the filesystem still marked for journal recovery, which then ran at every boot ([#45](https://github.com/onexay/msl/issues/45)).

### Added
- `msl --manage <distro> --resize <size>` grows the disk all distributions share ([#3](https://github.com/onexay/msl/issues/3)). Stop every distribution first (`msl --shutdown`). msl restarts the VM, which checks and grows the filesystem before mounting it (about 3 s for 256 GB). The disk can't shrink, and can't be larger than the macOS disk.
- `defaultVhdSize` in `[msl2]` (as in `.wslconfig`) sets the disk's size when it's created. Without it, a new disk is 256 GB, but never more than the macOS disk.
- `msl --status` shows the disk: its maximum size, what it uses on macOS, and what's free in the distributions and on macOS. It warns when macOS is nearly out of disk space, which the distributions can't see.

### Changed
- **Renamed, breaking:** macOS files are mounted at `/mnt/macos` in every distribution, not `/mnt/mac` (`/macos` under a custom `[automount] root`). The environment variables `MSL_MAC_USER`, `MSL_MAC_HOME` and `MSL_MAC_VIEW` are now `MSL_MACOS_*`, and `msl --version --json` reports `macos` instead of `macOS`. Scripts that use the old names need updating.
- Messages and docs say "macOS" throughout, instead of mixing "Mac" and "macOS".
- `msl --version` and msld's log show the commit a build came from, as semver build metadata: `0.1.7+3af5916` (`.dirty` for uncommitted changes). Update checks still compare `0.1.7`.
- Kernel releases are tagged with a hash of their config instead of a counter: `kernel-6.18.15-msl-76f230e`. The same config always gives the same tag, and `msl --version` shows it.
- The kernel enables device-mapper (`CONFIG_BLK_DEV_DM`) and the NBD client (`CONFIG_BLK_DEV_NBD`).
- The initramfs carries static `e2fsck` and `resize2fs` from Debian's e2fsprogs 1.47.2 (GPL-2.0); their source is attached to each release.

## [0.1.6] - 2026-09-25

### Changed
- `msl --manage <distro> --move` now fails with "not supported" instead of reporting success. It only recorded the location: every distro lives on the shared disk, so nothing was moved.
- The VM section of `~/.mslconfig` is now `[msl2]`. `[wsl2]` still works, so existing files and a copied `.wslconfig` need no change.

### Fixed
- Names that are CNAME aliases (deb.debian.org, cdn.kernel.org, www.apple.com) resolve in distros again. 0.1.5's DNS fix made macOS report the CNAME record as well, and msld then answered with the alias alone or with records glibc rejects, so lookups failed and `apt` and `curl` couldn't reach those hosts ([#42](https://github.com/onexay/msl/issues/42)).

## [0.1.5] - 2026-09-25

### Fixed
- DNS lookups in distros no longer stall for 5 to 10 seconds when a name has an IPv4 address but no IPv6 one, as github.com does. msld now passes on macOS's "no such record" answer instead of waiting out its timeout. Tools that look up both address families, such as VS Code's extension host, curl and git, used to hit connect timeouts; VS Code timed out connecting to `api.github.com` while cloning ([#41](https://github.com/onexay/msl/issues/41)).

## [0.1.4] - 2026-09-25

### Changed
- x86_64-only distributions (Arch Linux, SUSE Linux Enterprise, eLxr) are no longer offered by `msl --list --online`, and `msl --install` refuses them. Under Rosetta, which is built into macOS 27, they don't boot cleanly yet, and x86_64 support is deferred ([#40](https://github.com/onexay/msl/issues/40)). `--install --from-file` still accepts x86_64 images.
- Releases no longer include a `.pkg`. `install.sh` is the way to install msl, and the only one that sets up IDEs.
- The VS Code extension has its own releases, `vscode-<version>`, like the kernel. Each msl release bundles the published one. The first is [`vscode-0.1.0`](https://github.com/onexay/msl/releases/tag/vscode-0.1.0).
- Distro files on the Mac moved from `~/MSL/<distro>` to `~/.msl/distros/<distro>`, so they no longer add a visible folder to your home directory. Each distro still appears in Finder › Locations with its logo. On start, msld unmounts any old `~/MSL` mounts and removes `~/MSL` if it's empty. `MSL_VIEW_DIR` still overrides the location.
- The README covers installing and the basics. The command reference, installer details and WSL compatibility table moved to [`docs/`](docs/readme.md), which adds a [Getting started](docs/getting_started.md) walkthrough and a [Troubleshooting](docs/troubleshooting.md) page.

### Fixed
- `msl --help` now lists every command msl accepts, adding `--debug-shell`, `--mount`/`--unmount`, `--update`, `--uninstall`, `--manage`, `--set-version`, `--set-default-version` and `--list --online`. [docs/cli.md](docs/cli.md) includes the full help text.
- The VS Code extension no longer hands back a dead server. After a VM restart it used to trust a pidfile that a new, unrelated process could now match, because pids start over. It also didn't notice a server that was still running but auto-shutting down and refusing connections. It now requires the server's own command line and a successful connection, and starts only one server when a window's connections resolve at the same time.
- The VS Code extension works with distros that have no `curl` or `wget`, such as stock Debian. It downloads the VS Code Server on the Mac, caches it for every distro, and pipes it in.
- VS Code tunnels (forwarded ports) no longer cut off a download when the local client reads slowly: the tunnel now applies backpressure and ends cleanly instead of dropping queued data.
- msld now removes its `run/vsock-*.sock` bridge sockets when the VM stops, so stale sockets no longer pile up.

### Added
- `msl --manage-ide [--ide <vscode|vscode-insiders|vscode-oss|cursor|all>] [--install|--uninstall]` sets up the VS Code extension. It installs the bundled `.vsix` and adds it to `enable-proposed-api` in the IDE's `argv.json`, keeping comments and other keys. Without options, it lists the IDEs found and asks what to do. The installer runs it for the IDEs it finds (`--no-ide` skips this), and `msl --uninstall` undoes it. The extension (0.1.1) runs whichever msl set it up, recorded in `cli-path` in msl's data folder, so msl can be installed anywhere without setting `msl.path` ([#35](https://github.com/onexay/msl/issues/35)).
- Preview VS Code extension (`extensions/vscode`) that opens folders in a distro through managed pipes: no SSH, and no port on the Mac. It needs VS Code's proposed `resolvers` API (Sodium).
- msld's connect socket (`connect.sock`): `CONNECT distro=<name> unix=<path>|tcp=<port>` opens a byte stream into a distro, over vsock 1026 or the localhost forwarder. Unix sockets are limited to `~/.vscode-server/msl/*.sock`, and the connection is made as the distro's default user. The VS Code extension uses it for every pipe and falls back to `msl-bridge` with an older msld ([#32](https://github.com/onexay/msl/issues/32)).
- `/run/msl/init msl-bridge unix:<path>|tcp:<port>`: relays stdio to a Unix socket or localhost port inside a distro ([#29](https://github.com/onexay/msl/issues/29)).

## [0.1.3] - 2026-09-25

### Added
- `--json` for the query commands (`--list` and its variants, `--list --online`, `--status`, `--version`). Errors go to stderr as JSON, with wsl.exe's exit codes. See [docs/json.md](docs/json.md).

## [0.1.2] - 2026-09-24

### Fixed
- Stopping a distro (`--terminate`, idle timeout, `--shutdown`) now shuts it down cleanly instead of killing it. systemd distros power off (`SIGRTMIN+4`), and other distros' processes get `SIGTERM`. Anything still running after 10 seconds is killed. Previously journald reported "corrupted or uncleanly shut down" journals, and services could lose unflushed data ([#19](https://github.com/onexay/msl/issues/19)).
- The network interface stays `eth0`, as in WSL. systemd 259 (Ubuntu 26.04) treats the distro as a container, so it ignores `net.ifnames=0` and renamed the shared NIC to `enp0s1`. msl now masks `99-default.link` at runtime ([#20](https://github.com/onexay/msl/issues/20)).

## [0.1.1] - 2026-09-24

First release. (0.1.0 was withdrawn before announcement; 0.1.1 replaces it.)

### Added
- The `wsl.exe` command line on macOS, with the same arguments, behaviour and messages:
  - install, import, export and unregister;
  - list, set the default, terminate and shut down;
  - `--status` (including the VM's effective settings), `--manage`, `--mount`/`--unmount`;
  - `--debug-shell`, `--update`, `--uninstall`, `--version`.
- Runs unmodified WSL distribution images (arm64) from Microsoft's distribution list or from a `.wsl` file, in one lightweight Virtualization.framework VM. Each distro gets its own init and can run systemd.
- Integration with the Mac:
  - the Mac filesystem at `/mnt/mac`, and the Mac's current directory carried into the distro;
  - `MSLENV`, `mslpath`;
  - localhost forwarding and DNS through macOS;
  - each distro's files at `~/MSL/<distro>`, shown in Finder with the distro's logo.
- `.mslconfig` (the `.wslconfig` equivalent), `wsl.conf`/`msl.conf`, idle timeouts, and msl's own first-run setup for Debian.
- An interactive installer (`install.sh`), a `.pkg`, and self-update through `update.json`.
- Support for PGP-signed release checksums (`.sha256.asc`): `install.sh` verifies the signature when `gpg` is installed and a signature is published; see SECURITY.md.
- Releases include the full licence texts of all dependencies (`share/doc/msl/licenses/`), and the GPL source of BusyBox and the kernel.
- `kernel/fetch.sh` works without the GitHub CLI.
- Licensed under Apache-2.0. msl stands for **Modern Subsystem for Linux**.

[Unreleased]: https://github.com/onexay/msl/compare/v0.1.8...HEAD
[0.1.8]: https://github.com/onexay/msl/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/onexay/msl/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/onexay/msl/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/onexay/msl/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/onexay/msl/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/onexay/msl/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/onexay/msl/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/onexay/msl/releases/tag/v0.1.1
