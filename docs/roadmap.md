# Roadmap

Milestones and open items. The design is in [architecture.md](architecture.md); changes per release are in [CHANGELOG.md](../CHANGELOG.md).

## Milestones
0. ✅ **Spike** (de-risk, about 1 week). Boot VZ with our kernel, initrd and `msl-mini-init`, and get a vsock ping working. Confirm:
   - USB mass-storage hot-attach works;
   - the vmnet attachment works with ad-hoc signing;
   - Rosetta works;
   - namespace plus pivot_root works for systemd as PID 1 inside the namespace;
   - the Ubuntu 24.04 and Debian WSL tarballs, unmodified: boot them, run their OOBE (`wsl-setup`), check cloud-init falls back cleanly, and list every systemd unit that fails, to seed the `compat` mask list.
   - **Status:** done. Only the host memory-reclaim measurement is still open. See [spike results](dev/spike-results.md).
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

7. **VS Code integration** (proposal, for discussion; recorded 2026-09-24): SSH entries per distro via ProxyCommand, then a thin Remote Explorer extension on top of Remote-SSH. See [design/vscode-integration.md](design/vscode-integration.md).

## Open items (after milestone 5)

- **`~/MSL` NFS view is reachable by other local users** (security): the bridge listens on an unauthenticated `127.0.0.1` port. Fix options: only accept connections from the owning user (check the peer's UID through `LOCAL_PEERCRED`-style lookup of the socket owner), or serve NFS over a user-only Unix socket. See SECURITY.md.
- **Notarisation:** run `scripts/package.sh` with `MSL_SIGN_IDENTITY` and `MSL_INSTALLER_IDENTITY`, then `scripts/notarize.sh`. Needs the owner's Developer ID and a notarytool profile.
- ~~**Xcode**~~: done 2026-09-24. Xcode 27.0 (Swift 6.4) is the active toolchain, and the host tests are a swift-testing target again (`swift test`: 16 tests in 5 suites).
- **`--manage --resize`:** needs an offline `resize2fs`, i.e. a static e2fsprogs in the initrd, run before mounting `/dev/vda`.
- **x86_64 distros:** listing and installing through Rosetta is implemented but untested; milestone 6 adds a Rosetta-free path (qemu-user) and the tests.
- **vsock:** file the Apple Feedback report (host-initiated connections freeze the VM); consider guest dial-back for data streams ([`design/vsock-flow-control.md`](design/vsock-flow-control.md)).
- **`~/MSL` view** only works while the VM runs (no auto-start on access); an FSKit implementation could fix that.
- **Third-party notices:** generate full license texts for all Rust and Swift dependencies before a public release.
