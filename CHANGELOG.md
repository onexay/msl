# Changelog

All notable changes to msl are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and msl uses [semantic versioning](https://semver.org/). `scripts/publish.sh` copies a version's section into its GitHub release notes.

## [Unreleased]

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

[Unreleased]: https://github.com/onexay/msl/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/onexay/msl/releases/tag/v0.1.1
