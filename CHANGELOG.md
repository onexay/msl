# Changelog

All notable changes to msl are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and msl uses [semantic versioning](https://semver.org/). `scripts/publish.sh` copies a version's section into its GitHub release notes.

## [Unreleased]

### Changed
- Releases no longer include a `.pkg`. `install.sh` is the way to install msl, and the only one that sets up IDEs.
- The VS Code extension has its own releases, `vscode-<version>`, like the kernel. Each msl release bundles the published one. The first is [`vscode-0.1.0`](https://github.com/onexay/msl/releases/tag/vscode-0.1.0).
- Distro files on the Mac moved from `~/MSL/<distro>` to `~/.msl/distros/<distro>`, so they no longer add a visible folder to your home directory. Each distro still appears in Finder › Locations with its logo. On start, msld unmounts any old `~/MSL` mounts and removes `~/MSL` if it's empty. `MSL_VIEW_DIR` still overrides the location.

### Fixed
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

[Unreleased]: https://github.com/onexay/msl/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/onexay/msl/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/onexay/msl/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/onexay/msl/releases/tag/v0.1.1
