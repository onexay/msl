# Changelog

All notable changes to msl are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and msl uses [semantic versioning](https://semver.org/). `scripts/publish.sh` copies a version's section into its GitHub release notes.

## [Unreleased]

### Changed
- Distro files on the Mac moved from `~/MSL/<distro>` to `~/.msl/distros/<distro>`, so they no longer add a visible folder to your home directory. Each distro still appears in Finder › Locations with its logo. On start, msld unmounts any old `~/MSL` mounts and removes `~/MSL` if it's empty. `MSL_VIEW_DIR` still overrides the location.

### Fixed
- msld now removes its `run/vsock-*.sock` bridge sockets when the VM stops, so stale sockets no longer pile up.

### Added
- Preview VS Code extension (`extensions/vscode`) that opens folders in a distro through managed pipes: no SSH, and no port on the Mac. It needs VS Code's proposed `resolvers` API (Sodium).
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
