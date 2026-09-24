# Original plan (historical)

The plan msl started from (2026-09-23), kept for reference: its context and its end-to-end test plan. The current design is in [architecture.md](../architecture.md), and status in [roadmap.md](../roadmap.md).

## Context
Build `msl`, a macOS equivalent of WSL2. It should have the same CLI surface and the same behaviour as `wsl.exe` (distro lifecycle, shells, interop, networking and config), built only on Apple-native technology. The repo is empty apart from a README. Host: macOS 27 on Apple Silicon, Swift 6.3, Apple `container` 1.1.0 installed.

Decisions so far:
- **v1 scope:** core lifecycle plus host integration: the Mac filesystem, cwd translation, env passing and localhost networking.
- **Out of scope:** running macOS executables from inside a distro. Distros see Linux binaries only.
- **Binary name:** `msl`.
- **Stack:** Apple-only, with GPU deferred. Virtualization.framework only offers 2D virtio-gpu. The only GPU path today is libkrun/Venus, which is not Apple-native.

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
