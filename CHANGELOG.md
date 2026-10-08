# Changelog

All notable changes to MSL are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and MSL uses [semantic versioning](https://semver.org/). `scripts/publish.sh` uses the Unreleased section for GitHub release notes.

## [Unreleased]

### Added
- Mirror macOS proxy settings into new distro sessions with `autoProxy`, and optionally use the Mac's DNS servers with `dnsProxy` when DNS tunneling is off.

### Fixed
- Check ext4 disks with recorded filesystem errors before mounting them.

## [0.1.0] - 2026-10-04

Initial release.

### Added
- A WSL-compatible command-line workflow to install and run arm64 Linux distributions in one Virtualization.framework VM.
- macOS integration: files at `/mnt/macos`, DNS through macOS, outbound network access, localhost TCP forwarding, and distro files in Finder.
- VS Code integration that opens distro folders over MSL-managed pipes and vsock, without an SSH server or Mac TCP port.
- Versioned MSL, kernel and VS Code extension releases, bundled together by the MSL installer.

### Changed
- **Breaking:** MSL requires macOS 27 or later. On older versions, the installer, `msl`, `msld` and `msl --update` stop with a clear message.
- Kernel and extension pins accept SemVer release tags. `msl --version` and development VSIX versions use plain SemVer; `uname -r` includes the kernel source's short hash.
- Build, install, fetch and end-to-end scripts live in `scripts/`; shared code and protocols live in `core/`, macOS executables and services in `host/`, and tests in `tests/`.

[Unreleased]: https://github.com/onexay/msl/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/onexay/msl/releases/tag/v0.1.0
