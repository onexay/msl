# MSL progress log

Newest entries at the bottom. Times are local (IST). Entries before 01:10 were backfilled from the session history.

## 2026-09-23 / 24 — planning
- **~23:50** Planning started. Researched WSL2 internals (open-source repo) and Apple's virtualization stack (Containerization 0.46, `container` 1.1, VZ on macOS 26 and 27).
- **~00:20** Decisions:
  - one shared utility VM with per-distro namespaces;
  - Apple-only virtualization, no GPU;
  - binary name `msl`;
  - no running macOS binaries from inside distros;
  - Rust guest (not Go);
  - unmodified WSL `.wsl` images, plus a compat layer.
- **~00:35** Plan approved. Written to `docs/PLAN.md`.

## 2026-09-24 — milestone 0 spike
- **00:40** Toolchain: rustup 1.98.1 with `aarch64-unknown-linux-musl`, protobuf. zig and cargo-zigbuild removed, because `rust-lld` links static musl directly.
- **00:50** `guest/` (Rust `msl-guest`, 660 KB) and `spike/` (Swift VM runner) written. Ubuntu 24.04 and Debian WSL tarballs downloaded (checksums OK).
- **00:52** First boot: VM up in 0.13 s, guest control channel in 41 ms, vmnet works with ad-hoc signing, Rosetta binfmt registered.
- **00:55** Imports (Ubuntu 4.5 s, Debian 1.0 s). systemd running as PID 1 in the distro namespaces; distro start takes 11–22 ms.
- **00:58** virtiofs reports files as owned by the calling UID, so the idmap work was dropped. Ubuntu OOBE runs with `WSL_DISTRO_NAME` set.
- **01:00** Fixes: cgroup cleanup on stop; `net.ifnames=0` (udev was renaming the shared NIC); the readiness race.
- **01:02** Custom kernel (Apple config + USB/quota/nfsd) built in about 3 min using Apple's `container`.
- **01:05** USB hot-attach works end to end (`/dev/sda` → mkfs/mount/write → detach/reattach). Spike complete; results in `docs/spike-results.md`.

## 2026-09-24 — milestone 1 (core lifecycle)
- **2026-09-24 01:13 IST** Started. Checked current versions: tonic 0.14.6 / prost 0.14 / tokio 1.53 / tokio-vsock 0.7.2 (guest); grpc-swift-2 2.4.3 / nio-transport 2.10 (UDS targets) / grpc-swift-protobuf 2.4.1 (host). Pulled WSL's exact CLI strings from `Resources.resw` for output fidelity. Next: `proto/msl/v1/msl.proto`.
- **01:20** `proto/msl/v1/msl.proto` written. `MiniInit` (VM-level) and `Agent` (per distro) services; tar and stdio bytes go over one-shot vsock data ports announced in stream events.
- **01:20** Guest rewritten on tokio (current-thread) + tonic 0.14: MiniInit (import/export in tar, tar.gz, tar.xz and zstd; start/stop/delete/list/shutdown) and Agent (Run with PTY or pipes, Resize, Signal, Info).
  - Pipe stdio passes the vsock socket straight to the child, with no copying.
  - A process starts only after the host has connected to its streams.
  - The distro counts as ready only after systemd's bus socket exists.
  - Binary: **1.4 MB**.
- **01:20** Guest unit tests: 3/3 passing on Linux (`scripts/test-guest.sh`, via Apple `container`).
- **01:30** Host package set up: `Package.swift`, Swift gRPC code generated (`scripts/gen-proto.sh`), and MSLCore written (wsl-compatible parser, message catalogue, registry, IPC with fd passing through a C shim, list formatting). The CLT toolchain can't discover swift-testing tests, so the tests run as an executable: `swift run msl-core-tests` → **47 checks, 0 failures**.
- **01:41** `msld` and `msl` built and working end to end. Two host bugs found and fixed: (1) pinning the vmnet subnet stops DHCP answering the kernel's `ip=dhcp`, so the pin is dropped until milestone 4 (static guest addressing); (2) grpc-swift sent the socket path as the HTTP/2 `:authority`, which tonic/hyper rejects with RST_STREAM, so it is now set to `msl-guest`. `msl --install --from-file debian.wsl` works. All commands and output are now logged to `LOG.md` via `scripts/logrun`.
- **01:53** Fixed `msld` event handling. Each run session used to start its own reader for resize/signal events, so after the first-run setup two threads read the same socket, corrupted the frames and hung up the shell. Now there is one `EventRouter` per connection.
- **01:53** PTY harness bug: it matched prompts against output it had already seen, so it sent the second password early and `passwd` flushed it. Fixed, and the harness now has a 180 s limit.
- **01:53** **Milestone 1 e2e suite (`Tests/e2e/m1.sh`): 40/40 passing.** Covered: install (`--from-file`, `--name`, `--no-launch`, duplicate rejection); Ubuntu's own `wsl-setup` OOBE through a real PTY; default user; `-l` / `-l -v` / `-l -q` / `--running`; `-s`; `--status`; `-e`; exit codes; cwd translation; `--cd ~`; `msl ~`; `-u`; stdin/stdout/stderr pipes; `--shell-type login`; export (tar.gz, stdout); import (file, stdin); setuid and ownership preserved; `--unregister`; `-t`; `--shutdown [--force]`; error messages and codes.

## 2026-09-24 — milestone 2 (distros and config)
- **01:59** Pre-M2 audit of `LOG.md` for "Windows" text: none comes from msl itself. Debian's `/usr/lib/wsl/oobe.sh` prints *"does not need to match your Windows username"* and `aka.ms/wslusers`. Ubuntu's `wsl-setup` only has hidden powershell calls. Decision: msl's own OOBE replaces Debian's script (first M2 task). Fixed an unclosed fence in `LOG.md`.
- **02:10** Guest compat layer:
  - runtime systemd masks in `/run/systemd/system` (`wsl-pro-service`, `console-getty`, `getty@tty1`), so the image is never modified;
  - built-in OOBE (`/run/msl/init msl-oobe`) replaces Debian's `oobe.sh`, with neutral wording and the Mac user name prefilled.
- **02:10** wsl.conf keys supported: `[boot] command`, `[automount] enabled/root/mountFsTab`, `[network] generateResolvConf`.
- **02:10** Host:
  - `.mslconfig` (`memory`, `processors`, `kernel`, `kernelCommandLine`, `vmIdleTimeout`, `instanceIdleTimeout`) with WSL-style warnings;
  - online install from Microsoft's `DistributionInfo.json` (arm64 entries, SHA-256 verified, cached in `~/Library/Caches/msl`) and `-l -o`;
  - `--manage` (`--set-default-user`, `--move`, `--set-sparse`; `--resize` and `--compact` deferred);
  - idle timeouts.
  - Removed the async semaphore waits that the Swift 6 checker flagged.
- **02:10** Guest bug fixed: `stop` and the distro watcher both waited on the same supervisor PID, and the reaper gives the status to only one of them, so `stop` always sat out its 10 s timeout. `msl -t` went from about 10 s to **0.12 s**. This also unblocked the VM idle timeout.
- **02:10** **Milestone 2 e2e (`Tests/e2e/m2.sh`): 25/25. M1 regression: 40/40. Unit tests: guest 4/4, host 58/58.**

## 2026-09-24 — milestone 3 (host integration)
- **02:12** Started. Scope: cwd translation moves into the guest (so it honours `[automount] root`), `mslpath` (`-u/-w/-m/-a`), `MSLENV` (Mac → Linux, with `/p` and `/l`).
- **02:15** Implemented:
  - `mslpath`: `-u` (default), `-w`, `-m`, `-a` and combined flags. Linux-only paths map to `~/MSL/<distro>/…`, the milestone 4 file view. It is exposed as the `/usr/bin/mslpath` → `/run/msl/init` symlink, like WSL's `/usr/bin/wslpath`.
  - `MSLENV`: Mac → Linux, with `/p` and `/l` translation; `/w` entries are skipped.
  - cwd translation moved into the guest, so `[automount] root` changes the cwd, `mslpath` and `MSLENV` together.
- **02:15** **Milestone 3 e2e (`Tests/e2e/m3.sh`): 24/24 on the first run.** Regressions: M1 40/40, M2 25/25. Unit tests: guest 7/7, host 58/58.

## 2026-09-24 — milestone 4 (networking and files)
- **02:18** Started. Order: hostname and hosts generation → localhost forwarding (port watcher + vsock relay) → a design check for `~/MSL/<distro>`.
  - Decision: no subnet pinning. WSL's NAT address also changes between boots, and pinning breaks vmnet DHCP (M1 finding).
- **02:25** Hostname and hosts generation work (hostname `supernova` from the Mac's name, WSL-style `/etc/hosts` with `host.internal`). Localhost forwarding works over IPv4 and IPv6 (a Python http.server in Ubuntu answers `curl localhost:8765` on the Mac).
- **02:25** `~/MSL/<distro>` design verified. A normal macOS user can `mount_nfs` a userspace NFSv3 server (tested with nfsserve's mirrorfs: `mounted by the Mac user`, reads and writes both ways).
  - Implemented: nfsserve (BSD-3) in mini-init on guest loopback :21049; msld mounts it at `<msl>/files` (nobrowse, soft) through a private vsock bridge; `~/MSL/<name>` symlinks.
  - New files take their parent directory's owner.
  - Verified: `echo > ~/MSL/Ubuntu-24.04/home/tester/note.txt` gives `tester:tester`.
- **02:25** Finding: the vmnet gateway's DNS does not resolve Mac-only names (`supernova.local`), so VPN split-DNS would likely fail too. Implementing the DNS tunneling equivalent: a guest stub at 10.255.255.254:53 relays over vsock to msld, which resolves with `DNSServiceQueryRecord` (mDNSResponder).
- **02:36** M4 e2e hung: vCPU 0 hit an RCU stall about 31 s after boot, so mini-init stopped answering and every msld request blocked on it. Suspected trigger: concurrent export → import over vsock, or NFS load. Reproducing in isolation next.
- **02:52** **Root cause found (a latent bug since M1):** Virtualization.framework's vsock device blocks when the host doesn't read a connection promptly, which freezes every vsock connection and vCPU 0. Repro: `msl -e sh -c 'head -c 200000000 /dev/zero' | (sleep 30; cat)` leaves the VM unresponsive, even after the reader drains. The export|import pipe in the M4 e2e hit the same thing. Idle boot (DNS tunneling on or off) and export or import alone are fine.
- **02:52** Fix: credit-based framing (`data`/`credit`/`eof`, 1 MB window) on every guest↔host byte stream (session stdio/tty, export, import, forwarder, NFS bridge). Receivers always drain their vsock socket, and backpressure moves to the real producer.
- **03:03** Implemented `FramedBridge` (Swift) and `framed.rs` (Rust). Session stdio now goes through pipes relayed by the agent instead of handing the vsock socket to the child. Verified: slow reader → VM stays responsive; export|import pipe of 1.3 GB completes in 4 s.
- **03:03** Second bug found by stress-testing (10/60 `msl cat` runs had empty output): both bridges `shutdown()` an fd *number* after the owning object had closed it, hitting whichever connection reused the number. Fixed in both. Now 0/60.
- **03:03** **Milestone 4 e2e (`Tests/e2e/m4.sh`): 33/33.** New regression checks: paused reader, no lost output in 30 short sessions. Regressions: M1 40/40, M2 25/25, M3 24/24. Unit tests: guest 12/12, host 58/58.
- **03:06** Wrote `docs/vsock-flow-control.md`: the VZ vsock limitation, evidence, isolation experiments, the credit-framing design, the fd-reuse bug, and alternatives (unbounded buffering, SO_RCVBUF, SIGSTOP/SIGCONT, TCP over vmnet, virtio-console, virtiofs file transfer, VZCustomVirtioDevice, libkrun, waiting for Apple). Linked from PLAN.md.
- **03:15** Checked Apple Containerization. Its stdio relay has the same naive read→blocking-write pattern, but `container exec … | (sleep 30; cat)` does **not** freeze and applies real backpressure (producer done at 21 s, host RSS +27 MB for 200 MB). Experiment in msl: a guest-dialled vsock connection (`AF_VSOCK` → host `VZVirtioSocketListener`), unframed, host not reading for 20 s → VM responsive, sender blocked until read. **The VZ flaw is specific to host-initiated `connect(toPort:)` connections.** Doc updated; 'reverse the connection direction' added as the leading alternative. The experiment hook was removed afterwards.

## 2026-09-24 — milestone 5 (remainder)
- **03:20** Started. Order: --debug-shell → --mount/--unmount → x86_64 distros via Rosetta → memory reclaim → --manage --resize/--compact → --update → packaging (notarisation scripted; needs the user's Developer ID).
- **03:36** Done: `--debug-shell` (BusyBox 1.37 static in the initrd; mini-init also serves Agent) and `--mount/--unmount` (USB hot-attach, shared `/mnt/msl` propagated as a slave mount into running distros, disks identified by `diskseq` so a re-attached `sda` isn't missed). The user asked not to install Rosetta: none was installed (it was already present); x86_64 distro testing dropped, and the code path only activates if Rosetta is already installed. Found and fixed: overwriting a running msld in place breaks its signature, so VZ refuses to start VMs ('Internal Virtualization error'). Fix: atomic install in build.sh, a strict self-signature check, and exit after --shutdown when replaced.
- **03:46** Memory reclaim investigated and dropped: VZ's traditional balloon does not return ballooned pages to macOS (guest MemFree 17 GB → 0.49 GB while inflated; host footprint 3989 → 3987 MB). Memory comes back when the VM exits (vmIdleTimeout). autoMemoryReclaim is accepted and documented as having no effect. --manage --compact works (FITRIM; 1 GiB returned), trim-on-shutdown added. --manage --resize refuses honestly: the ContainerizationEXT4 formatter uses sparse_super2, so online ext4 resize is impossible (follow-up: static resize2fs).
- **04:01** Done:
  - `--update` (release manifest, verified download, atomic replace, old msld hands over);
  - `--uninstall` (keeps data);
  - `scripts/package.sh` (tarball, .pkg, update.json, Homebrew formula; xattrs stripped; the .pkg expands with 0 AppleDouble files and valid signatures);
  - `scripts/notarize.sh` (not run: needs a Developer ID).
- **04:01** Release path test (`Tests/e2e/release.sh`): install the 0.1.0 tarball into a scratch prefix, run Debian, `--update` → 0.1.1 (the distro survives), up to date, `--uninstall` (0 files left, data kept).
- **04:01** **Milestone 5 e2e (`Tests/e2e/m5.sh`): 20/20.** Full regression: M1 40/40, M2 25/25 (2 expectations updated for intentional changes), M3 24/24, M4 33/33, release ✓. Unit tests: guest 12/12, host 63/63. Docs: `docs/memory-reclaim.md`, PLAN open items, README.
- **04:15** Planned **milestone 6: x86_64 emulation with qemu-user** (docs/PLAN.md). Rosetta check: general-purpose Rosetta ends after macOS 27, but Apple keeps Rosetta for Intel binaries in Linux VMs. Feasibility measured: Debian qemu-user 10.0.13 (static-pie, 14 MB) runs x86_64 BusyBox in the msl VM; SHA-256 of 64 MB: native 0.38 s, Rosetta 0.35 s, qemu 0.70 s. Xcode 27.0 is installed but its license isn't accepted (needs the user's sudo); the swift-testing move waits for that.
- **04:19** Xcode 27.0 license accepted; Xcode is now the active toolchain (Swift 6.4). Host tests moved from the `msl-core-tests` executable back to a swift-testing target: `swift test` gives 16 tests in 5 suites, all passing. Full build under Swift 6.4 has no warnings; smoke test (install, run, debug shell) OK.
- **04:45** User feedback: the NFS view wasn't in Finder (it was mounted `nobrowse`), then showed as "127.0.0.1". Reworked:
  - one browsable mount per distro (`127.0.0.1:/<name>` at `~/MSL/<name>`), because Finder names a network volume after its export path, so Locations shows each distro by name;
  - distro logos from `wsl-distribution.conf` `[shortcut] icon` (.ico → .icns via ImageIO) as volume icons; verified with NSWorkspace (Debian swirl, Ubuntu logo);
  - macOS metadata (`.DS_Store`, AppleDouble `._*`, `.VolumeIcon.icns`, `Icon\r`) kept in guest memory (`nfsview.rs`). Refusing it had broken `ditto`/Finder copies of files with xattrs; now copies work and Linux never sees the files.
- **04:45** Bugs found:
  - `isNFS` used `URL.resolvingSymlinksInPath`, which strips `/private`, so mounts under /tmp weren't recognised. Fixed with realpath plus getmntinfo (which never touches a possibly stale mount).
  - The guest dropped an export before the Mac unmounted it (stale mount on unregister). Now unmount first.
  - m1–m3 leaked test symlinks into the real `~/MSL`. Removed, and every suite now sets MSL_VIEW_DIR.
- **04:45** Error-code lines are now hidden unless `MSL_ERROR_CODES=1` (user's choice).
- **04:45** Regression: M1 40/40, M2 25/25, M3 24/24, M4 45/45, M5 20/20; `swift test` 17/17.

## 2026-09-24 04:53 — `msl --status` shows effective VM settings
- `--status` keeps wsl.exe's two lines, then adds the VM state (running with uptime, or stopped) and the settings: memory, CPUs, kernel, kernel command line, localhost forwarding, DNS tunneling, idle timeouts and the settings file. Any `.mslconfig` change waiting for `msl --shutdown` is listed as a pending diff.
- `VMHost.resolve(_:)` is the single place that applies defaults. The VM boots from it, and `--status` reports from it, so the two always match. New in MSLCore: `VMSettings`, `VMStatus`, `StatusFormat`, and `Reply.status`.
- Tests: `swift test` 19/19 (new StatusTests), e2e m1 40/40, m2 25/25.
- Found: a long `MSL_HOME` path (over the 104-byte Unix-socket limit) makes the VM fail to start with `io(48)`. The default location is not affected.

## 2026-09-24 05:04: VS Code integration recorded for later
- The WSL extension is Windows-only. Options (SSH ProxyCommand entries, a thin extension on top of Remote-SSH, why a full resolver extension is blocked, `code .`) are written up in docs/vscode-integration.md and listed as M7 (proposal) in PLAN.

## 2026-09-24 05:08: published to GitHub (private)
- Created the private repo github.com/onexay/msl and pushed `main` (1 commit, 100 files). LOG.md and build outputs are git-ignored.
- Published the kernel as release `kernel-6.18.15-msl` (Image, config, release.sha256). `scripts/build.sh` fetches it through `kernel/fetch.sh` (gh + checksum) when `kernel/out/Image` is missing. Tested from a fresh clone: Image OK, config OK.

## 2026-09-24 10:18: interactive installer replaces Homebrew
- New `install.sh` (POSIX sh, repo root). It checks for Apple silicon and macOS 26+, then asks for a prefix (default `~/.local`, no sudo; `/usr/local` uses sudo). It downloads the latest `v*` release through `gh` or the GitHub API with GITHUB_TOKEN, and parses the JSON with macOS's own JavaScript. It verifies the SHA-256, asks before stopping a running msld, swaps each tree in with a rename, and restarts msld the same way `--update` does. It then offers to add msl to PATH in the shell's rc file and to install a first distro. Prompts come from /dev/tty, so `curl | sh` stays interactive. Also supports `--yes`, `--prefix`, `--version`, `--from` and `--no-path`.
- Removed the Homebrew formula (packaging/). `scripts/package.sh` now also writes `<tarball>.sha256`.
- Tested in a scratch HOME and prefix: interactive install through a PTY, the PATH line, the file tree, a reinstall with msld running (the old msld exits), a bad checksum (refused) and `--uninstall`. Not yet tested: the GitHub download path, because there is no `v0.1.0` release yet.

## 2026-09-24 10:24: release scheme and v0.1.0
- The kernel has its own releases, `kernel-<linux>-msl.<n>`. The tag lives in `kernel/release.tag`, which `kernel/fetch.sh` reads. `kernel/publish.sh` publishes with `--latest=false` and rewrites `release.sha256`. `kernel-6.18.15-msl` was re-published as `kernel-6.18.15-msl.1` and the old tag deleted.
- msl releases are `v<version>`, made with `scripts/publish.sh` and marked Latest. It requires a clean, pushed tree, checks the bundled kernel against `kernel/release.sha256`, and names the kernel tag in the notes. Published **v0.1.0**: tarball + .sha256, .pkg, update.json.
- install.sh download path tested: via gh (latest), via curl + GITHUB_TOKEN piped with no gh (same binary), no auth (clear error), unknown version (clear error).
- Known: `msl --update` uses `releases/latest/download/update.json`, which needs the repo to be public (there's no auth for private downloads).

## 2026-09-24 10:28: repo is public
- The unauthenticated `curl -fsSL https://raw.githubusercontent.com/onexay/msl/main/install.sh | sh` installs v0.1.0 with its SHA-256 verified, and `msl --update` reads the public update.json ("already installed"). The README shows the one-liner.
- `kernel/fetch.sh` falls back to curl when gh isn't logged in, so building from source no longer needs gh.

## 2026-09-24 10:35: licensed Apache-2.0
- Added LICENSE (canonical Apache-2.0 text) and NOTICE. The README has a License section, `guest/Cargo.toml` changes from MIT to Apache-2.0, THIRD_PARTY_NOTICES names the licence, and packages install LICENSE and NOTICE in `share/doc/msl`.
- Future commits use `onexay <…noreply…>`. Rewriting the earlier commits' author was blocked by the permission check and is left to the user.

## 2026-09-24 11:11: open-source governance pass (audit items 1–20)
1. Microsoft's MIT notice for the adapted WSL strings is included: `docs/licenses/WSL-MIT.txt`, referenced in `Messages.swift`.
2. Full dependency licence texts are generated by `scripts/gen-licenses.sh` (cargo-about for the Rust crates, SwiftPM checkouts for the Swift packages) and shipped in `share/doc/msl/licenses`.
3. GPL corresponding source: `scripts/gpl-sources.sh` fetches and verifies the kernel.org tarball and Debian's busybox 1.37.0-6 source. Both publish scripts attach them, and they were uploaded to the existing releases.
4. Trademark and non-affiliation notice added to NOTICE and the README. The rename is left to the owner.
5. Commit history rewrite: left to the owner.
6. SECURITY.md: reporting, supported versions, security model. Found: the `~/MSL` NFS bridge is reachable by other local users (roadmap open item).
7. Dependabot config (cargo, Swift, Actions).
8. Branch protection: needs the owner's go-ahead (repo setting).
9. PGP-signed checksums (`MSL_GPG_KEY`); `install.sh` verifies them against the pinned release key when gpg is present.
10–14. CONTRIBUTING (DCO), CODE_OF_CONDUCT (Contributor Covenant 2.1; contact still to be filled in), CI (Swift, Rust, shellcheck, version check), issue and PR templates, CODEOWNERS, CHANGELOG (release notes come from it), GOVERNANCE.
15. Topics and homepage: needs the owner's go-ahead.
16. Moved the dev log and spike under `docs/dev` and the entitlements next to `msld`. m1 now downloads its own test images (it depended on the deleted `spike/cache`).
17. Docs index; PLAN split into architecture.md and roadmap.md, with the original kept as `dev/plan.md`; design notes under `docs/design`.
18. Shorter README; the configuration reference is in `docs/configuration.md`, and build and release details are in CONTRIBUTING.
19. A single `VERSION` file, with `scripts/set-version.sh` and `check-version.sh`; the guest crate is `publish = false`.
20. SPDX headers in 76 source files (`nfs.rs`: Apache-2.0 AND BSD-3-Clause).

## 2026-09-24 11:27: roadmap moved to GitHub
- Milestones created from the roadmap: M0–M5 (closed), M6 x86_64 via qemu-user, M7 VS Code integration, and Later.
- Open items became issues #1–#6: the NFS view exposure (security), notarisation, `--resize`, testing x86_64 distros (M6), the vsock Apple report and dial-back, and `~/MSL` auto-start (Later).
- Removed `docs/roadmap.md` and `docs/dev/plan.md`, and renamed `docs/architecture.md` to `docs/ARCHITECTURE.md`. References now point to the milestones and issues.
