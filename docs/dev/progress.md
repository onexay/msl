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
- Milestones renamed to elements, with short goals only: Hydrogen … Carbon (done), Nitrogen (x86_64 via qemu-user), Oxygen (VS Code), and Fluorine (was "Later"). The detail moved into issues: #7–#9 and #4 (Nitrogen), #10–#12 (Oxygen), and #13–#17 plus #6 (Fluorine). Docs refer to milestones by name.

## 2026-09-24 11:48: history rewrite and repo protections
- Rewrote the history so every commit is authored as `onexay` with the no-reply email, and scrubbed the user name and paths from the old PROGRESS/PLAN text. Force-pushed `main` and the two tags (both now at `c97549e`) and updated the commit hash in the release notes. GitHub still keeps the pre-rewrite commits reachable through `refs/pull/18/head` (Dependabot's merged PR); only GitHub Support can purge them.
- Protected `main`: no force pushes or deletion; pull requests need Lint, Host (Swift) and Guest (Rust) to pass, with conversations resolved; admins can still push directly.
- Turned on private vulnerability reporting, Dependabot alerts and security updates, and secret scanning with push protection. Added topics: wsl, linux, macos, virtualization-framework, apple-silicon, developer-experience.

## 2026-09-24 11:57: v0.1.1 replaces v0.1.0
- The name is now "Modern Subsystem for Linux". Deleted the v0.1.0 release and tag, merged the changelog into a single 0.1.1 entry, and set the version to 0.1.1 everywhere.
- Published **v0.1.1** (Latest): tarball + .sha256, .pkg, update.json and the BusyBox source. Not PGP-signed, because the key isn't on the build Mac.
- Checked the public one-liner install: msl 0.1.1 with kernel 6.18.15-msl, the new name in CLI output, LICENSE/NOTICE/licences in share/doc/msl, and `msl --update` reporting it's current.

## 2026-09-24 12:31: clean distro stop (#19) and eth0 on systemd 259 (#20)
- A user reported unclean journals and `eth0` renamed to `enp0s1` in Ubuntu 26.04.
- #19: stopping used `SIGKILL`. Now a systemd distro gets `SIGRTMIN+4` (poweroff), and other distros' processes get `SIGTERM`, with the namespace ending once only msl's processes are left. Anything left after 10 s is killed. `--shutdown` stops distros in parallel. Measured: Ubuntu 26.04 stops in 3.2 s with a clean journal; a distro without systemd stops in 0.07 s; a process ignoring TERM is killed at 10 s.
- #20: systemd 259 treats the pid namespace as a container and ignores `net.ifnames=0`. The compat layer now runtime-masks `99-default.link`, and the NIC stays `eth0`.
- e2e m1–m5 all pass (40/25/24/45/20).

## 2026-09-24 12:35: v0.1.2
- Published **v0.1.2** (Latest) with the fixes for #19 and #20. Checked the upgrade from the public one-liner: installed v0.1.1, `msl --update` moved it to 0.1.2, and a second `--update` reports it's current.

## 2026-09-25 00:10: Neon: --json for the query commands
- `--json` works with `--list` (all variants), `--list --online`, `--status` and `--version`. The models are in `MSLCore/JSONOutput.swift`, and `Arguments.parseInvocation` accepts the flag first or among those commands' options, never inside a Linux command line. Other commands reject it with `Msl/E_INVALIDARG`.
- Conventions: one object on stdout with `schema: 1`, sorted camelCase keys, raw numbers, no nulls; pretty on a terminal, compact when piped. Errors go to stderr as JSON, with wsl.exe's exit codes (e.g. `-l --json` with nothing installed exits 255). In `--status`, `.mslconfig` warnings go into the JSON instead of stderr.
- Docs: `docs/json.md` (examples from real output), `--help`, README, CHANGELOG.
- Tests: 5 new unit tests (24 in total), a new `Tests/e2e/neon.sh` (19/19), and m1 40/40 and m2 25/25 still pass.

## 2026-09-25 00:12: e2e suites named after milestones
- `Tests/e2e/m1.sh`…`m5.sh` are now `helium`, `lithium`, `beryllium`, `boron` and `carbon`, next to `neon`. Their headers and temp-dir prefixes match, and `release.sh` keeps its name. Updated CONTRIBUTING, the vsock doc, and issue #4 (Nitrogen's suite will be `nitrogen.sh`).

## 2026-09-25 00:16: v0.1.3
- Published **v0.1.3** (Latest) with `--json` for the query commands (Neon). Checked: installed v0.1.2 with the public one-liner, ran `msl --update` to 0.1.3, and `--version --json` reports 0.1.3 with the install prefix.

## 2026-09-25 01:26: VS Code managed-pipe transport (design)
- Added option C′ to `docs/design/vscode-integration.md`: a resolver extension whose `makeConnection()` pipe runs extension → msld Unix socket → vsock:1026 → msl-guest → the server's Unix socket inside the distro. It reuses the forwarder's framed bridge. Still depends on the proposed `resolvers` API, which is recorded as an open question.

## 2026-09-25 09:35: Sodium started (VS Code via managed pipes)
- New milestone **Sodium** with #27–#33: resolver skeleton, server install, `msl-bridge`, `makeConnection`, `tunnelFactory`, msld connect socket, tests/docs.
- #29 `msl-bridge` (`/run/msl/init msl-bridge unix:<path>|tcp:<port>`): stdio relay with half-close both ways. Unit test plus a real distro check: 100 MB echoed through `msl -e` with matching SHA-256 in 0.41 s; the TCP target and the error exits (1, and 2 for usage) work.
- Found: `/run/user/<uid>` does not exist for `msl -e` sessions (no PAM/logind), so the server socket moves to `~/.vscode-server/msl/<commit>.sock`. Updated the design doc, #28 and #32.

## 2026-09-25 09:43: Sodium extension works end to end
- `extensions/vscode`: resolver for `msl+<distro>` (#27), server install/start in the distro (#28), `makeConnection` over `msl-bridge` (#30), and `tunnelFactory` (#31). VS Code 1.138.0 was tested in an isolated instance (`--enable-proposed-api`).
- First resolve took 1.65 s (7.7 s when the server was downloaded on an earlier run), and both pipes finished the handshake in about 60 ms. After killing the bridges in the distro, VS Code resolved again (24 ms, reusing the server) and reconnected both channels. A distro port was auto-forwarded through `tunnelFactory`, and 50 MB downloaded through it with a matching SHA-256 in 0.16 s.
- Gotcha: VS Code refuses a `--user-data-dir` whose IPC socket path is longer than 103 characters.

## 2026-09-25 10:10: clean slate script, view dir move, reinstall
- `scripts/clean-slate.sh [--stop-msld]` resets msl (terminate/unregister all, retrying once for #34; shutdown; stale sockets; optional msld stop) and reports what is left, with a log in `build/logs/`.
- #34 filed: the first `--unregister` failed with ENOTEMPTY and left 47,816 files registered; the retry worked.
- The file view moved from `~/MSL` to `~/.msl/distros` (the old folder is removed when empty; tested). Finder still lists the `Ubuntu-26.04` disk at the hidden path, with its volume icon.
- Stale `run/vsock-*.sock` files are now removed when the VM stops.
- Reinstalled Ubuntu-26.04 with `--no-launch` (7.3 s).

## 2026-09-25 10:36: #32 msld connect socket
- `connect.sock` (msld, `Connect.swift`) plus guest vsock 1026 (`connect.rs`). The guest connects from a thread that has entered the distro's mount namespace and taken the default user's uid and gids. Only `<home>/.vscode-server/msl/<name>.sock` is allowed.
- Tests: 3 guest unit tests and 2 Swift parser tests. A 100 MB echo took 0.39 s with a matching SHA-256. Refused as expected: docker.sock, systemd private, `..`, a symlink to a root-only socket (EACCES), a symlink to a VM-only path (ENOENT), a bad distro, and a malformed line. The TCP target works, and a connect to a stopped distro starts it.
- The extension now uses connect.sock for every pipe (no `msl` processes; handshake about 48 ms). The distro stays running while VS Code holds pipes.
- Found and fixed a tunnel bug: with a slow local reader, 10 of 12 50 MB downloads were cut short (40-47 MB), because `onDidClose` destroyed the socket with data still queued. Added backpressure (`Pipe.pause/resume`) and a clean end; after the fix, 12 of 12 were correct.

## 2026-09-25 10:46: #33 Sodium tests and docs
- `Tests/e2e/sodium.sh`: 22 of 22 pass in 24 s (msl-bridge echo, tcp and exit codes; connect.sock mode, a 100 MB echo, tcp, 6 allowlist refusals, the symlink EACCES/ENOENT cases, a bad distro, a malformed line; pipes count as sessions for the idle timeout; auto-start; the extension compiles). It stops only its own msld.
- VM restart under a connected window: found that `resolve()` returned a dead server, because the old pidfile matched a new process (pids start over). Fixed by checking the process's cmdline for `--socket-path <sock>` and taking a start lock. After the fix, a new server started in 1.7 s. VS Code then rejected its old reconnection token and offered to reload, as it does with WSL after `wsl --shutdown`.
- Added a manual checklist to extensions/vscode/README.md. Still to check by hand: the window label, two distros, and installing the .vsix (reading the window title needs Accessibility permission).

## 2026-09-25 11:02: Debian and two distros side by side
- Installed Debian (2.8 s from cache). Stock Debian has no curl, wget or python3, so the server download moved to the Mac: `~/Library/Caches/msl/vscode-server/`, then piped into the distro. Debian took 4 s to download 211 MB and 3.6 s to install.
- Found a second dead-server case: a server that was auto-shutting down still matched pid+cmdline but refused connections. `running()` now also connects through `msl-bridge`.
- Two windows, Ubuntu-26.04 and Debian, from the installed `.vsix` in an isolated profile: each distro had its own server and remote extension host, and a Debian forwarded port passed 3 of 3 slow 50 MB downloads. Windows started with `--extensionDevelopmentPath` share one development host, so a second launch reloads it.
- My mistake: a zsh launch passed all options as one argument (zsh does not split variables into words), so the user saw a "No remote extension installed to resolve msl" window. It was a separate instance with a junk profile, and it had exited by the time I checked. Launches now go through a bash script.

## 2026-09-25 11:50: #35 msl --manage-ide
- `ArgvJSON` (MSLCore): a comment-preserving text edit of `enable-proposed-api`, with 8 unit tests (a byte-exact round trip of the stock file and variants, idempotence, other ids, lookalikes, refusals). The user chose to keep the text edit over a lossy parse-and-rewrite; it is brittle, to be revisited.
- `IDE` catalog, `--manage-ide` parsing (2 tests), and `Sources/msl/ManageIDE.swift`: detection by app bundle, PATH and config dir; status read from extensions.json (the IDE deletes the folder of an uninstalled extension later); install/uninstall through the IDE's CLI; a one-time argv.json backup; atomic writes; refuses to run as root; under sudo, `--uninstall` re-runs itself as SUDO_USER.
- `build.sh` builds `share/msl/msl.vsix` (needs npm); `package.sh` requires it. `install.sh` prompts to set up the IDEs it finds (`--no-ide` skips).
- release.sh: install.sh with a throwaway HOME set up VS Code; `--update` kept it; `--uninstall` removed it and restored argv.json byte for byte.

## 2026-09-25 11:59: .pkg dropped; extension released separately
- Removed the `.pkg` from package.sh, publish.sh and CONTRIBUTING (the README documents only install.sh).
- The extension version is package.json's, released as `vscode-<version>` (never Latest) by `extensions/vscode/publish.sh`, which records `release.tag` and `release.sha256`. `extensions/vscode/fetch.sh` downloads and verifies it. `scripts/build.sh` uses a local `dist/msl-<version>.vsix` if present, else fetches, so building msl needs no Node. The msl `publish.sh` refuses to publish unless the bundled .vsix is the published one.
- Published **vscode-0.1.0** (msl-0.1.0.vsix, sha256 32e1054d…). A build with no local dist fetched it, and the hash matched. Added LICENSE to the extension; vsce warned it was missing from 0.1.0.

## 2026-09-25 12:04: #35 msl.path via cli-path
- Instead of editing each IDE's settings.json, `msl --manage-ide --install` writes its resolved path to `<MSL_HOME>/cli-path`, and uninstall removes it (only if it names this msl; under sudo, as SUDO_USER). Extension 0.1.1 looks up msl in this order: the msl.path setting, then cli-path (ignored if the file it names is gone), then ~/.local/bin, /usr/local/bin, PATH. A Node harness with a stubbed vscode module passes 4 of 4. release.sh confirms cli-path is written by install.sh and removed by --uninstall.

## 2026-09-25 12:53: README rewrite and complete --help
- Rewrote README.md. New sections: what the installer sets up and what undoes each change; the full `msl --help` with grouped explanations; why the VS Code extension and the `argv.json` change are needed; a table of compatibility with WSL distributions.
- `--help` now lists every accepted command (it had omitted --manage, --mount/--unmount, --update, --uninstall, --debug-shell, --set-version, --set-default-version, --list --online); --manage-ide moved to the MSL group. The README embeds the output verbatim, checked with diff.
- Corrected README and ARCHITECTURE: msld is not a LaunchAgent and msl does not talk to it over XPC. msl starts msld on demand and passes stdio over a Unix socket (SCM_RIGHTS).
- Removed unverified claims from the draft (a `code .` example; Ubuntu 22.04 as tested; exports round-tripping into WSL).

## 2026-09-25 13:03: documentation restructure
- README.md cut from 445 to 122 lines. It keeps the pitch, install, VS Code, how it works, limitations, comparison and development, and links to the reference pages.
- Moved to docs/, unchanged apart from headings and links: cli.md (the full `msl --help` and the command tables; the help text is byte-identical to the old README block), install.md (installer options, what it sets up), wsl-compatibility.md.
- New: getting-started.md (install through VS Code, following install.sh's prompts), troubleshooting.md (logs, --status, --debug-shell, common problems). Idle-timeout defaults checked against MSLConfig.swift.
- docs/README.md regrouped as Getting started, Guides, Reference, How it works (the Diátaxis split).

## 2026-09-25 13:07: design notes moved to GitHub issues
- New `design` label. The three notes in docs/design/ became issues, each linking to its last version in the repo: vsock flow control (#36, closed as fixed in Boron; its open items are #5), memory reclaim (#37, open for the re-test when Apple ships free-page reporting), VS Code integration (#38, open; C′ shipped in Sodium, and B, D and E are #10 to #12).
- Removed docs/design/. Links in the README, ARCHITECTURE, comparison, troubleshooting, the docs index, the extension README and a comment in MSLConfig.swift now point to the issues, as do the bodies of #5 and #10. CONTRIBUTING says design write-ups go in issues.

## 2026-09-25 13:15: spike code removed
- Deleted docs/dev/spike/. It no longer ran: its JSON control protocol on vsock 1024 was replaced by gRPC before the first commit, and nothing built or tested it. spike-results.md stays, since ARCHITECTURE cites its findings, and links to the folder at d0430e1.
- Dropped "(spike finding)" from comments in guest/src/distroinit.rs and Sources/MSLService/Service.swift; the comments keep their reasons.

## 2026-09-25 13:19: spike results removed; docs file names
- Deleted docs/dev/spike-results.md and the "(spike finding)" and "(spike)" tags in ARCHITECTURE.
- Naming rule, now in CONTRIBUTING: UPPERCASE at the root, lowercase snake_case under docs/. Renamed ARCHITECTURE.md, README.md (to readme.md), THIRD_PARTY_NOTICES.md, getting-started.md, wsl-compatibility.md and the three licence texts. Updated links, gen-licenses.sh, package.sh (the installed notices file is now share/doc/msl/third_party_notices.md), NOTICE and two source comments.
- Issue links: #38 now points to ARCHITECTURE at d0430e1; #27 and #35 pointed to the deleted design note and now point to #38.

## 2026-09-25 13:23: crate list; docs checks in CI
- architecture.md's guest crate list now matches guest/Cargo.toml. Removed rtnetlink, rust-ini, youki and rustix, which were never dependencies. Added nfsserve and serde_json. Noted that the kernel does DHCP (`ip=dhcp`) and wsl.conf uses msl's own INI reader.
- scripts/check-links.py checks relative links and GitHub-style anchors in every Markdown file, with no dependencies. It passes on 20 files, and a test file with a missing file and a missing heading fails as expected. CI's lint job runs it.
- DocsTests in MSLCoreTests compares the help block in docs/cli.md with Messages.usage. It passes, and fails when one line of the doc is changed.

## 2026-09-25 13:40: Nitrogen: Apple's Rosetta position
- Apple's Rosetta doc (developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment): general-purpose Rosetta for Intel Mac apps lasts through macOS 27; macOS 28 keeps only a subset for older games. Separately, "macOS 27 directly integrates support for Intel binary translation, without needing to install Rosetta. This enables support for Intel Linux binaries running in ARM virtual machines (VMs) as well as Intel Linux containers." No end date is given for the Linux part, and VZLinuxRosettaDirectoryShare isn't deprecated.
- Checked on macOS 27.0: `VZLinuxRosettaDirectoryShare.availability` is `.installed`, `/Library/Apple/usr/libexec/oah/RosettaLinux/` holds `rosetta` and `rosettad`, and `arch -x86_64 /usr/bin/true` fails with "Bad CPU type". So the Linux translator ships with the OS and is independent of macOS Rosetta; msl's "only if Rosetta is already installed" caveat doesn't apply on 27.

## 2026-09-25 14:00: Nitrogen: Arch under Rosetta; missing syscalls
- archlinux installs through Rosetta, and its x86_64 systemd 261 starts, then exits with "Failed to allocate manager object: Invalid argument". Found with strace: systemd checks systemd-executor with `faccessat(fd, "", X_OK, AT_EMPTY_PATH)`. glibc makes that the `faccessat2` syscall; Rosetta answers ENOSYS without calling the kernel, and glibc turns that into EINVAL.
- A static x86_64 probe (cross-built in Debian with gcc-x86-64-linux-gnu) shows that Rosetta on macOS 27.0 returns ENOSYS for faccessat2, close_range, openat2, clone3, pidfd_getfd, mount_setattr, landlock_*, process_madvise, epoll_pwait2, memfd_secret, futex_waitv, cachestat, fchmodat2, statmount, listmount, io_uring_setup, pkey_alloc and rseq. pidfd_open, the new mount API (open_tree, fsopen …), statx and memfd_create work.
- Apple doesn't publish Rosetta's Linux syscall coverage. Its docs cover only setup, AVX-512 (unsupported) and an optional kernel patch that exposes the TSO bit through prctl. Rosetta calls that prctl (`0x4d4d444c`) at startup, and msl's kernel returns EINVAL. Per Apple, without the patch every process in the VM runs under TSO, which slows native arm64 processes too.

## 2026-09-25 14:40: Nitrogen: amd64 Debian/Ubuntu under Rosetta
- Installed the amd64 WSL images of Debian 13 (systemd 257), Ubuntu 24.04 (255) and Ubuntu 26.04 (259) with `--from-file`. All three boot systemd. A `/run/systemd/system/service.d/` drop-in with `MemoryDenyWriteExecute=no` takes all three from `degraded` to `running`: Rosetta JITs, so units that set MDWX (journald, udevd, logind, resolved, timedated) died with SIGTRAP.
- binfmt_misc is shared by the whole VM. Ubuntu's `systemd-binfmt.service` clears every entry at start, which removes Rosetta for every distro ("Exec format error"). For testing I masked it in each rootfs.
- Full x86_64 syscall sweep, with the same sweep run natively on arm64 as a baseline: 33 calls are ENOSYS only under Rosetta. Missing are clone3 (5.3), openat2 and pidfd_getfd (5.6), faccessat2 (5.8), close_range (5.9) and later calls; pidfd_open and the new mount API (5.2–5.3) work. So x86_64 programs see roughly a 5.2–5.3 kernel through Rosetta, while `uname` reports 6.18, and that is below systemd's 5.10 minimum. Obsolete calls get SIGTRAP instead of ENOSYS. 19 calls are ENOSYS in msl's kernel too (config: userfaultfd, landlock, kcmp, process_vm_*, pkey, modules, acct); Apple's container kernel (6.18.5) enables userfaultfd, kcmp and cross-memory attach.
- On Debian 13 amd64: setuid `sudo` works, `apt-get install gcc` takes 1m21s, and compiling and running a C program works. procps `ps`/`pgrep` 4.0.4 on Debian 13 and Ubuntu 24.04 crash Rosetta (`assertion failed [true_path_length_other >= 0]`, ThreadContextFcntl.cpp:179 `is_rosetta_process`) for any PID; the same version on Ubuntu 26.04 works, and `top` works everywhere. Under Rosetta, `/proc/<pid>/exe` of an x86_64 process shows `/run/rosetta/rosetta`.

## 2026-09-25 15:10: Nitrogen: first qemu-user run
- No code changes: copied Debian's static `qemu-x86_64` 10.0.13 to `/var/lib/msl/emu/`, unregistered Rosetta, and registered qemu with the same magic and mask and `OCF` flags.
- Syscall sweep under qemu: it implements faccessat2, close_range and openat2 (the calls Rosetta lacks), but returns ENOSYS for seccomp, bpf, ptrace, keyctl/add_key, set_robust_list, native AIO (io_setup …), perf_event_open, fanotify, mbind/mempolicy and mlock2. Like Rosetta, it lacks clone3, rseq, io_uring and 5.10+ calls. A garbage rt_sigreturn trips a qemu assertion (`cpu_exec_longjmp_cleanup`).
- Boot: archlinux (systemd 261) boots under qemu, which it can't under Rosetta. All four x86_64 distros reach `degraded` in 3–5 s. Blockers: "Failed to set up credentials: Invalid argument" (journald, sysctl, tmpfiles, udev-load-credentials; exit 243) and "Failed to set up mount namespacing: Invalid argument" (logind, udevd; exit 226). No failing mount syscall reaches the kernel, so qemu rejects the call itself. Next: get qemu's own log (`QEMU_STRACE`) into the executor, which needs a debug environment hook in distro init.
- Stopped testing; the Rosetta vs qemu-user comparison and proposal are in #40 (design). The test VM is shut down.
- x86_64 support deferred: #4, #7 and #9 updated, Nitrogen marked deferred, docs say so.
- Hid x86_64-only distros: `Online.x86Supported = false` removes them from `--list --online` (text and JSON), and `--install <x86-only>` now fails with "only available for x86_64, which msl doesn't support yet". `--from-file` is unchanged. Checked with the dev build: 15 JSON entries, none emulated; `--install archlinux` exits 255.
- Moved the x86_64 switch into MSLCore (`Manifest.x86Supported`, `x86Available`, `installRefusal`) and added the `x86Deferred` test (37 tests pass). With the switch flipped to true, the test fails with 5 issues.

## 2026-09-25 15:20: msl 0.1.4 released
- CHANGELOG: cut 0.1.4 from Unreleased, adding the entry for hiding x86_64-only distros. `scripts/set-version.sh 0.1.4`. Build, 37 unit tests, the link check and `Tests/e2e/release.sh` (install, `--update`, `--uninstall`) passed.
- `scripts/publish.sh 0.1.4` published v0.1.4 as Latest (ad-hoc signed, checksum not PGP-signed, as before). The `update.json` channel serves 0.1.4, and the downloaded tarball matches its SHA-256 (96942cc8…). The kernel (`kernel-6.18.15-msl.1`) and VS Code extension (`vscode-0.1.1`) releases are unchanged and bundled.

## 2026-09-25 16:30: VS Code extensions in a distro; DNS stall fixed (#41)
- Extensions install in the distro. The server's `code-server --install-extension` fetched Prettier and `rust-analyzer-0.3.3057-linux-arm64` from the Marketplace in 7.8 s, and the rust-analyzer binary runs. The running server noticed both. `code --remote msl+<distro> --install-extension` on the Mac installs locally (darwin-arm64), as it does for WSL and SSH. GitHub Repositories is `extensionKind: ["ui", "workspace"]`, so it installs on the Mac by design.
- Reported: cloning from GitHub in a connected window failed with a connect timeout for api.github.com:443. In the distro, `getent ahostsv6 github.com` took 10 s, `ahosts` 5 s, and names with an AAAA record answered at once. Node fetch took 5 s for api.github.com and 10 s (or UND_ERR_CONNECT_TIMEOUT) for github.com; undici's 10 s connect timeout includes the lookup.
- Cause: DNSProxy called `DNSServiceQueryRecord` without `kDNSServiceFlagsReturnIntermediates`, and mDNSResponder then never delivers a negative answer, so every NODATA AAAA query ran into msld's 5 s timeout. A Swift probe on the Mac: AAAA github.com with the timeout flag alone never completed in 8 s; with ReturnIntermediates it returned NoSuchRecord (-65554) in 0.00 s.
- Fix: add the flag. The dev build in a throwaway MSL_HOME (Debian) resolves github.com and api.github.com in 1–8 ms for v4, v6 and both.

## 2026-09-25 16:57: msl 0.1.5 released
- Filed #41 (DNS stall for IPv4-only names, with the RCA). The fix commit carries the symptom, root cause and verification, and closed #41 on push.
- CHANGELOG: cut 0.1.5 from Unreleased. `scripts/set-version.sh 0.1.5`. Build, 37 unit tests, the link check and `Tests/e2e/release.sh` passed.
- `scripts/publish.sh 0.1.5` published v0.1.5 as Latest (ad-hoc signed, checksum not PGP-signed). The `update.json` channel serves 0.1.5, and the downloaded tarball matches its SHA-256 (9c1b2613…). Kernel and VS Code extension releases are unchanged.

## 2026-09-25 17:15: [msl2] section in .mslconfig
- The VM section is now `[msl2]`, with `[wsl2]` accepted as an alias (as `/etc/msl.conf` falls back to `/etc/wsl.conf`). Warnings name the section as written. Updated configuration.md, architecture.md, the proto comment and the lithium, boron and neon e2e configs.
- 37 unit tests pass (the config test now also parses a `[wsl2]` file); lithium.sh 25 of 25.

## 2026-09-25 17:45: per-distro disks: USB mass storage benchmark
- Question: can per-distro images be hot-added as USB mass storage (the only hot-pluggable block device in Virtualization.framework; virtio-blk, NVMe and NBD attachments are fixed at boot, and virtio-fs shares can change at runtime but can't hold a Linux root)?
- Driver: the guest binds `usb-storage` (Bulk-Only Transport, protocol 0x50), not `uas`. SuperSpeed (5000), `max_sectors_kb=1024`, queue depth 1 (`nr_requests=1`); virtio-blk has 256. Both attachments use `.automatic` caching and `.full` sync.
- fio (Debian, 4 vCPU, 2 GiB file, direct I/O, 15 s), virtio-blk (data.img) vs USB: seq read 1M qd8 1099 vs 1880 MiB/s; seq write 902 vs 766 MiB/s; rand read 4k qd1 10.1k vs 5.3k IOPS, qd32 66.0k vs 5.5k; rand write 4k qd1 28.8k vs 10.8k, qd32 145k vs 11.2k; rand write 4k + fsync 205 vs 10.6k. Untar of 277 MB / 10,197 entries + sync: 554 vs 464 ms; cold read of all files: 664 vs 1475 ms.
- USB doesn't queue: qd32 equals qd1, so random I/O is 2–26× slower.
- USB reports `write through` (`/sys/block/sda/queue/write_cache`), so Linux never sends a cache flush. Its fsync at ~95 µs can't include a full flush to the Mac's storage (virtio-blk's fsync costs ~5 ms with `.full`). Guest fsyncs on USB disks probably aren't durable against a Mac crash or power loss. That applies to `--mount` today.
- Conclusion: USB isn't suitable for distro root filesystems. Next candidates: NBD + device-mapper ranges, and loop devices over virtio-fs.

## 2026-09-25 18:20: DNS regression in 0.1.5: CNAME names don't resolve
- Found while building a kernel in a distro: `curl: (6) Could not resolve host: cdn.kernel.org`. With the dev build (0.1.5 code), `getent ahostsv4` of cdn.kernel.org, www.apple.com and deb.debian.org returned nothing; github.com worked.
- Cause: with `kDNSServiceFlagsReturnIntermediates` (the #41 fix), mDNSResponder also delivers the CNAME record. For cdn.kernel.org it reported the CNAME with `more=true` and then the A record; for AAAA, the CNAME came in a batch of its own (`more=false`). DNSProxy stopped after that batch with only the CNAME, or answered with CNAME plus A records all owned by the question name, which glibc rejects. Without the flag, mDNSResponder delivered only the final records, which DNSProxy puts under the question name as a flattened answer.
- Fix: keep only records of the requested type (all for CNAME and ANY queries), and finish on such a record or on a negative answer. Dev build: cdn.kernel.org, www.apple.com, deb.debian.org, github.com, api.github.com and example.org resolve on v4, v6 and both in 1–35 ms, and NXDOMAIN answers in 23 ms.
- boron.sh gained three DNS checks: an IPv4-only name answers A+AAAA in under 2 s (#41), and a CNAME name resolves on A and on AAAA. With the 0.1.5 code the two CNAME checks fail (46 passed, 2 failed); with the fix, 48 of 48 pass.

## 2026-09-25 19:10: --manage --move refuses; storage direction
- Per-distro disk spike ended. NBD attachments are accepted over `nbd+unix://` (no TCP port), but the VZ NBD disk reports write-through, like USB, so guest flushes probably never reach the server (not confirmed). Loop images inside data.img would work but aren't needed now. Decision: keep one shared disk and several distros; do #3 (offline grow) next. The spike code was removed.
- `--manage --move` used to record the location and report success without moving anything. It now fails with "All distributions share one disk, so a single distribution can't be moved." (unsupported). Mac storage is internal; external drives can be unplugged under a running VM, so moving storage there isn't offered. lithium.sh 25 of 25.
- Docs: cli.md lists --move and --resize as unsupported; architecture.md no longer calls data.img an ASIF image or says --resize sets a project quota.

## 2026-09-25 19:30: msl 0.1.6 released
- Filed #42 (CNAME names don't resolve, a 0.1.5 regression from #41) with the root cause, and closed it with a link to the release.
- CHANGELOG: cut 0.1.6 (the `[msl2]` section, `--move` refused, the CNAME fix). `scripts/set-version.sh 0.1.6`. Build, 37 unit tests, the link check, `Tests/e2e/release.sh` and boron.sh (48 of 48) passed.
- `scripts/publish.sh 0.1.6` published v0.1.6 as Latest (ad-hoc signed, checksum not PGP-signed). The `update.json` channel serves 0.1.6, and the downloaded tarball matches its SHA-256 (319e9350…). Kernel and VS Code extension releases are unchanged.

## 2026-09-25 19:55: Magnesium milestone; NFS over a Unix socket
- macOS's `mount_nfs` supports Unix-domain sockets, undocumented but in Apple's NFS source: a host written as `<path>` is AF_LOCAL (netid `ticotsord`), and `port=`/`mountport=` take a path. Mounted `"</tmp/msl-nfs/nfs.sock>:/Debian"` as a normal user through a relay in front of msld's NFS bridge and listed the root. (The write round trip used the distro's `/tmp`, a separate tmpfs, so it proved nothing; boron's `/home` checks will cover it.)
- New milestone Magnesium (security and data safety): #1 (file view over a Unix socket by default, TCP as a `.mslconfig` option; plan in a comment on #1), #3, #21, #34, and new #43 (`--mount` USB disks are write-through, so fsync isn't durable) and #44 (release gate: publish.sh runs the full e2e suite). #2 (notarisation) waits for a Developer ID.

## 2026-09-25 20:45: #3 disk growth; clean shutdown (#45); kernel DM/NBD; build versions
- The formatter hard-codes `sparse_super2` with no resize inode, meta_bg or 64-bit blocks, so ext4 can't grow online. Offline grow checked first on a clone of a real data.img (256 → 300 GiB, Debian's resize2fs over USB): e2fsck 4.6 s, resize2fs 3.5 s, clean re-check, marker hash intact.
- `scripts/build-e2fsprogs.sh` builds static `e2fsck` (1.5 MB) and `resize2fs` (1.1 MB) from Debian's e2fsprogs 1.47.2-3 in a container; they go in the initramfs (now 3.2 MB). GPL source via `gpl-sources.sh e2fsprogs`, attached by publish.sh; copyright file shipped.
- mini-init grows `/dev/vda` before mounting it when the device is ≥ 64 MiB larger than the filesystem: `e2fsck -f -p`, then `resize2fs`. Stage 1 now copies every initramfs tool (it copied only busybox, the first e2e failure). PingReply reports total/free and the grow result.
- `msl --manage <distro> --resize <size>`: grow only, up to the Mac volume, refused while distros run; stops the VM, grows data.img (sparse), boots, and checks the grow result. On a 256 GiB disk with Debian: 5.4 s end to end (2.8 s at boot), the Mac file grew ~7 MB.
- `[msl2] defaultVhdSize` (WSL's key) sizes a new disk; the default is min(256 GiB, Mac volume). The formatter rounds up one 128 MiB group. `--status` shows disk max, Mac usage, free in the VM and on the Mac, and warns when the Mac has < 16 GB free and less than the distros see.
- Shutdown now remounts /var/lib/msl read-only before power-off (#45): data.img's superblock reads clean with no needs_recovery.
- Kernel: CONFIG_MD, CONFIG_BLK_DEV_DM, CONFIG_BLK_DEV_NBD; built with kernel/build.sh (container). Tags are now `kernel-<linux>-msl-<config hash>` (kernel/tag.sh): current `kernel-6.18.15-msl-76f230e`, not published yet.
- Versions: build.sh stamps the commit; `msl --version` shows `0.1.6+<hash>` (`.dirty` for uncommitted changes); JSON keeps `msl` plain and adds `commit`.
- Tests: 39 unit tests; guest 17; magnesium.sh 16 of 16; helium 40, lithium 25, beryllium 24, boron 48, carbon 20, neon 20, sodium 22, all passing.

## 2026-09-25 21:30: "macOS" in prose, `macos` in user-visible names
- Naming rule: "macOS" in prose, `macos` in code. Renamed the user-visible names: the distro mount `/mnt/mac` → `/mnt/macos` (`/macos` under `[automount] root=/`), `MSL_MAC_{USER,HOME,VIEW}` → `MSL_MACOS_*`, and the `--version --json` key `macOS` → `macos` (nothing read it). Internal names (virtio-fs tag `mac`, the VM-root `/mnt/mac`, `macCwd`), code comments, the trademark notice and OrbStack's `/mnt/mac` in comparison.md stay.
- About 90 prose uses of "Mac" in docs, CLI and error messages, `--status`, install.sh and the extension README now say macOS, reworded where "Mac" meant the hardware.
- All e2e suites pass: helium 40, lithium 25, beryllium 24, boron 48, carbon 20, neon 20, sodium 22, magnesium 16; unit 39; guest 17.

## 2026-09-25 21:40: msl 0.1.7 released
- Published `kernel-6.18.15-msl-76f230e` (device-mapper, NBD client) with kernel/publish.sh: Image, config, release.sha256 and linux-6.18.15.tar.xz; not Latest. kernel/fetch.sh downloads it back with both checksums OK.
- CHANGELOG: cut 0.1.7 (#3 disk growth and defaultVhdSize, #45 clean shutdown, `/mnt/macos` and `MSL_MACOS_*` renames, `x.y.z+<commit>` versions, config-hashed kernel tags). `scripts/set-version.sh 0.1.7`. Build, 39 unit tests, the link check and `Tests/e2e/release.sh` passed; all feature e2e suites passed before the cut (215 checks).
- `scripts/publish.sh 0.1.7` published v0.1.7 as Latest (ad-hoc signed, checksum not PGP-signed), with the BusyBox and e2fsprogs Debian source packages attached. `update.json` serves 0.1.7; the downloaded tarball matches its SHA-256 (57174631…); its `msl --version` prints `0.1.7+66fb0af` and kernel `6.18.15-msl-76f230e`, and it ships e2fsprogs.COPYRIGHT. VS Code extension unchanged (vscode-0.1.1). #3 and #45 closed.

## 2026-09-25 21:50: issue triage
- Reviewed all open issues. Closed #21 as obsolete: it tracked flakiness in a `~/MSL` auto-start that no longer exists (the view is at `~/.msl/distros`, unmounted at shutdown, and nothing starts the VM on access); #6 still tracks a view that works while the VM is stopped. Closed #8 as superseded by #9 (msl owns the VM-wide binfmt entry), with its flag notes moved to #9. Already closed by commits: #3, #42, #45. 18 open.

## 2026-09-25 22:30: #1 file view: Unix socket and per-call RPC filter
- Tested before relying on socket permissions: with the socket at mode 0000, `mount_nfs "<sock>:/Debian"` still mounted, and the relay saw peer uid 0 on both connections. macOS's NFS client connects from the kernel as root, so file permissions on the socket don't stop other users. The MOUNT call also arrives as uid 0; file calls carry the accessing user's AUTH_SYS uid (501), plus some uid-0 calls from the kernel (GETATTR, LOOKUP, a READ from read-ahead).
- Fix, in msld only: the view is served on `<MSL_HOME>/nfs.sock` (0600; raw clients connect with their own credentials, so they can't forge AUTH_SYS), and every call passes `RPCFilter` in a record-aware relay in front of the framed vsock bridge. Allowed: AUTH_SYS uid = owner or 0, AUTH_NONE NULL pings, and MOUNT only while msld runs its own `mount_nfs`. Denied calls get MSG_DENIED/AUTH_ERROR/AUTH_TOOWEAK, written between whole guest replies. `[msl2] fileViewTransport = tcp` keeps the old 127.0.0.1 port with the same filter (weaker: raw clients can forge the uid there).
- boron.sh gained: mount over the socket, socket 0600, a rogue `mount_nfs` refused and logged, a raw GETATTR as uid 12345 denied and as the owner accepted, and the tcp option mounting from 127.0.0.1. A socket path with a space (as in `~/Library/Application Support`) mounts. neon.sh now stops its own msld (it leaked one before). All suites pass (boron 55); unit 40; guest 17.

## 2026-09-25 22:55: msl found msld through argv[0]
- Reported: `msl -v` → "msl: could not start /Users/akshay/msld". msl located msld (and the install prefix, the bundled .vsix and the path written to cli-path) from `CommandLine.arguments[0]`, which zsh passes as typed: `msl` from PATH resolves against the current directory. Hidden while msld is already running; seen once it had exited (after `msl --update`).
- Fix: one `selfExecutable` from `_NSGetExecutablePath`, symlinks resolved, used in all four places. helium.sh's first check runs `msl --version` through PATH from `/` with a fresh MSL_HOME, so it has to start msld: before the fix "could not start /msld", after it passes (helium 41 of 41). release.sh and neon pass.
- architecture.md no longer calls msld a LaunchAgent with an XPC service: it's a per-user process that msl starts on demand.

## 2026-09-25 23:20: msl 0.1.8 released
- Pre-release e2e: all suites passed except neon's commit check (build/ predated the last commit; passes after a rebuild) and sodium, which failed 4 checks in about one run in three: the distro could idle-stop (instanceIdleTimeout=2000) between starting the test's echo server and using it. sodium.sh now holds a session open until the idle checks; 5 of 5 runs pass.
- CHANGELOG: cut 0.1.8 (#1 file view security, the argv[0] msld lookup fix). `scripts/set-version.sh 0.1.8`. Build, 40 unit tests, the link check and `Tests/e2e/release.sh` passed.
- `scripts/publish.sh 0.1.8` refused an untracked file in the tree (a rotated LOG.md.old); it was moved aside for the publish and put back unchanged. v0.1.8 published as Latest (ad-hoc signed, checksum not PGP-signed); `update.json` serves 0.1.8; the tarball matches its SHA-256 (8dde8321…); its msl run through PATH from `/` prints `0.1.8+36cb3ef`. #1 closed. Kernel kernel-6.18.15-msl-76f230e and extension vscode-0.1.1 unchanged.

## 2026-09-25 23:45: locale in sessions
- Reported: the VS Code terminal in Ubuntu printed `bash: warning: setlocale: LC_CTYPE: cannot change locale (en_US.UTF-8)`. The VS Code Server ran with no LANG (msl set none); VS Code's `terminal.integrated.detectLocale` then set `LANG=en_US.UTF-8` for the terminal (seen in bash's /proc environ). Ubuntu has only C.utf8, and declares `LANG=C.UTF-8` in /etc/default/locale. macOS's own LANG is en_IN.UTF-8, so it didn't come through msl.
- Fix: the guest adds LANG, LANGUAGE and LC_* from the distro's /etc/default/locale (else /etc/locale.conf) to every session, before the request's own env, as a login shell and WSL do. Stock Debian declares en_US.UTF-8 (and LC_ALL) and has it generated. beryllium.sh checks LANG/LC_TIME from the file and no setlocale warning (26 of 26); guest parser unit test (18 guest tests).

## 2026-09-26 00:00: msl 0.1.9 released
- Pre-release e2e: all suites passed (helium 41, lithium 25, beryllium 26, boron 55, carbon 20, neon 20, sodium 22, magnesium 16; guest 18). Found during the run: boron, carbon, beryllium and lithium ended with `pkill -f build/bin/msld`, and helium with `pkill -f msld -U <user>`, stopping any dev-build msld (or any msld) including one serving the real MSL_HOME. All now kill only the msld of their own MSL_HOME; rerun, the real one survived.
- CHANGELOG: cut 0.1.9 (distro locale in sessions). Build, 40 unit tests, the link check and `Tests/e2e/release.sh` passed. LOG.md.old moved aside for publish.sh and restored unchanged.
- v0.1.9 published as Latest; `update.json` serves 0.1.9; the tarball matches its SHA-256 (8d91794e…) and prints `0.1.9+99cc265`. Kernel and extension unchanged.

## 2026-09-26 00:30: release packages built by CI (Xcode 26)
- Reported: msld doesn't start on an M1 with macOS 26.6: missing Swift library. 0.1.9 was packaged on this Mac with Xcode 27 (Swift 6.4, macOS 27 SDK) although msl claims macOS 26.0. msld links several Swift runtime dylibs strongly (`libswift_DarwinFoundation1/2/3`, `libswiftSynchronization`, `libswift_Concurrency`); msl doesn't link DarwinFoundation2. Exact dyld message still to be collected from the M1.
- The linker records the deployment target as the SDK version (LC_BUILD_VERSION shows sdk 26.0 for an Xcode 27 build), so a check on that field can't catch this; dropped it.
- CI gets a "Release package" job on macos-26: selects the newest Xcode whose major is Package.swift's minimum (26) and fails otherwise, adds the musl target and protobuf, runs `scripts/package.sh` with the release URLs, and uploads the tarball, .sha256, update.json and build-info.txt (commit, version, Xcode, Swift) as artifact `package`.
- `scripts/publish.sh` no longer packages: it downloads the artifact of HEAD's successful CI run, checks the commit, Xcode 26, the checksum and update.json, and that the bundled kernel and .vsix are the published ones (from the tarball), then publishes. The notes name the CI run and Xcode.

## 2026-09-26 00:50: kernel and VS Code extension built by CI too
- `kernel/build-linux.sh` holds the build (any Debian/Ubuntu arm64); `kernel/build.sh` runs it in Apple `container` for local testing. New `.github/workflows/kernel.yml` runs it on ubuntu-24.04-arm when the kernel inputs change and uploads artifact `<kernel/tag.sh tag>` (Image, config, tag, build-info). `kernel/publish.sh` downloads the newest unexpired artifact with that tag and publishes it; the tag is a hash of the config, so any CI build of the same inputs qualifies.
- New `.github/workflows/vscode.yml` builds the .vsix when `extensions/vscode` changes, as artifact `vscode-<version>` with the commit. `extensions/vscode/publish.sh` publishes it after checking that `extensions/vscode` at that commit is identical to HEAD's; it no longer needs Node locally.

## 2026-09-26 11:00: msl 0.1.10 released (first CI-built release)
- CI: MSLd now pins Host (Swift) to Xcode 26 as well and skips the Release package job for PRs; renamed from "CI". The Kernel job runs in `debian:trixie`: on the bare Ubuntu runner, GCC 13 and rustc changed CONFIG_GCC_VERSION, CONFIG_RUSTC_* and more under the same tag; in trixie the config is identical to the published one, and the mismatched artifact was deleted. upload-artifact v7 (Node 24); the extension builds with Node 24.
- CHANGELOG: cut 0.1.10 (msld starts on macOS 26 again). `scripts/set-version.sh 0.1.10`, 40 unit tests, link check; code unchanged since the last full e2e pass.
- MSLd run 36220303941 built the package (Xcode 26.6, Swift 6.3.3). `scripts/publish.sh 0.1.10` downloaded that artifact and checked the commit, Xcode, checksums, kernel and .vsix before publishing (LOG.md.old moved aside and restored). v0.1.10 is Latest; the notes name the CI run; `update.json` serves 0.1.10; the tarball matches its SHA-256 (e7cb14fa…) and prints `0.1.10+bb75105`, kernel 6.18.15-msl-76f230e.
- Still to confirm on the M1 with macOS 26.6 that msld starts.

## 2026-09-26 13:30: documentation site (MkDocs, GitHub Pages)
- MkDocs Material 9.7.7 (pinned in docs/requirements.txt; MkDocs 1.x) from docs/, `mkdocs.yml` at the root; `docs/dev/`, `docs/readme.md` and `requirements.txt` stay off the site. Nav: Get started (Download, Getting started, Installer details, Upgrading, Troubleshooting), Using msl, Reference, Internals, Project.
- `scripts/docs_hooks.py`: a page containing only `<!-- include: FILE -->` becomes that root file (CHANGELOG, CONTRIBUTING, SECURITY), and every relative link is resolved in repo coordinates and pointed at its site page or at the file on GitHub, so docs/ keeps working on GitHub too.
- New pages, written against the avoid-ai-writing rules (docs context, technical voice) and only from facts in the existing docs, code and tests: index (home), download (msl and the .vsix, one-line and by hand), upgrading (0.1.4, 0.1.6, 0.1.7, 0.1.10), files, networking, storage, vscode. The skill's detector (technical mode, rendered-markdown) scores all seven 0 with no issues; a deliberately bad sample scores 47, so the engine works. No em dashes.
- `mkdocs build --strict` passes with no warnings; no .md links remain in the built HTML. `.github/workflows/docs.yml` builds with --strict on PRs and pushes, and on main uploads and deploys with configure-pages v6, upload-pages-artifact v5 and deploy-pages v5 (all Node 24).

## 2026-09-26 14:15: docs site on the mkdocs-terminal theme
- Theme switched from Material to mkdocs-terminal 4.8.0 (docs/requirements.txt pins mkdocs 1.6.1 and mkdocs-terminal 4.8.0), palette `default`. Material-only config (palette toggles, features, button classes on the home page) removed.
- The theme has no logo setting: `docs_theme/partials/top-nav/top.html` (a copy of the theme's, one line changed) puts `assets/logo.png` in front of the site name. It loads its favicon from fixed paths, so `docs/img/favicon.ico`, `favicon-16x16.png` and `favicon-32x32.png` are made from the logo.
- The theme clips the site name (`.logo { overflow: hidden }` in a shrinking flex row): "Modern Subsystem for Li". `docs/css/msl.css` keeps it whole on wide screens and lets it wrap below 720 px, so the menu stays visible. Checked with headless Chrome screenshots at 1280 and 420 px. Strict build clean.

## 2026-09-27 10:00: docs site unpublished
- Unpublished for local polishing; a move from MkDocs to Hugo is under consideration. GitHub Pages turned off (`DELETE /repos/onexay/msl/pages`; the URL now returns 404) and the Docs workflow disabled with `gh workflow disable` (the file stays). README, CONTRIBUTING and docs/readme.md no longer link to the site. mkdocs.yml, the hook, the theme override and the new pages stay for `mkdocs serve`.

## 2026-09-27 01:30: Nitrogen: FEX-Emu evaluation (first pass)
- Apple's "Running Intel Binaries in Linux VMs" page says the Virtualization framework "doesn't support the bootstrapping or installation of Intel Linux distributions", only Intel apps in an ARM distribution. So full x86_64 distros under Rosetta are unsupported by Apple. The same page recommends binfmt flags `CPF` (msl uses `OCF`) and documents Rosetta's AOT caching (`rosettad`, `VZLinuxRosettaCachingOptions`). Apple's TSO kernel patch (`RosettaPatch.zip`, 619 lines, MIT-style licence, written for 6.10) adds `PR_SET_MEM_MODEL` (0x4d4d444c).
- Confirmed a bug in the supported setup: booting stock Ubuntu 24.04 arm64 runs its `systemd-binfmt`, which clears every binfmt_misc entry. That removes Rosetta for the whole VM, leaving only `python3.12`.
- FEX 2609.1 (Ubuntu PPA, `fex-emu-armv8.4`) set up without code changes: `FEX` and `FEXServer` plus five arm64 libraries (10 MB), patched with `patchelf --set-interpreter /.msl-fex/lib/ld-linux-aarch64.so.1 --force-rpath --set-rpath /.msl-fex/lib`. `DT_RUNPATH` isn't enough, because FEXServer's libstdc++ needs libm first. The bundle is copied into each x86 rootfs and into the VM root, and registered as `/.msl-fex/bin/FEX` with `POCF`. The path must be the same in both places, because FEX finds FEXServer next to `/proc/self/exe`. msl's kernel meets FEX's requirements (4K pages, 48-bit VA).
- Result: x86_64 systemd runs as PID 1 under FEX for both archlinux (systemd 261, which Rosetta can't start) and Debian 13 (257). But every unit fails with "Failed to spawn executor: Invalid argument", including mounts. Suspected cause: systemd starts the executor through glibc `pidfd_spawn`, i.e. `clone3` with `CLONE_INTO_CGROUP`, which FEX lists as unsupported (`Thread.cpp`, `ForkGuest`). FEX also can't honour `PR_SET_MDWE` (FEX issue #2684), so `MemoryDenyWriteExecute` will be a problem next. Not yet confirmed: FEX's logging didn't appear with a global Config.json.
- podman-fex (FEX in Podman's libkrun VM on Apple silicon) measures FEX ahead of qemu in 19 of 20 workloads and of Rosetta in 16 of 20, for containers rather than systemd distros.

## 2026-09-27 02:10: Nitrogen: FEX clone3 patch
- Confirmed the executor-spawn failure with a static x86_64 test: FEX-2609 returns EINVAL for `clone3(CLONE_CLEAR_SIGHAND)`. glibc 2.39's `posix_spawn` can fall back to `clone`, but not when a cgroup is requested (`POSIX_SPAWN_SETCGROUP`), which is how systemd starts every unit. FEX's fork path (`CloneFork`) also drops `CLONE_PIDFD`, so `pidfd_spawn` "succeeds" with pidfd 0. Test results: native arm64 9/9, stock FEX 3/9.
- Patched FEX (+37/−11 in `Syscalls.cpp` and `Syscalls/Thread.cpp`): accept `CLONE_CLEAR_SIGHAND` (EINVAL with `CLONE_SIGHAND`, as the kernel does), send non-thread clones with it or `CLONE_INTO_CGROUP` through `ForkGuest` (a real fork), fork with the host `clone3` when a pidfd or cgroup is requested, and reset guest handlers to SIG_DFL in the child while keeping ignored signals ignored. Built in the arm64 Ubuntu (clang 18, `CMAKE_CXX_SCAN_FOR_MODULES=OFF`, 27 s): 9/9 pass.
- Boot with the patched FEX plus a `service.d` `MemoryDenyWriteExecute=no` drop-in: Debian 13 amd64 (systemd 257) only fails `e2scrub_reap`, as it does under every engine. Arch (systemd 261) runs journald, udevd and dbus, but logind and nsresourced die with SIGILL, homed with SIGSEGV, networkd/resolved/userdbd hang in `activating`, and `/usr/bin/ldconfig` (static-pie) segfaults when run directly, so that one is a separate FEX issue.
- FEX logs `Failed to remap /proc/pid/cmdline data (prctl … errno 22)`: `PR_SET_MM` needs `CONFIG_CHECKPOINT_RESTORE` in msl's kernel.
- Opened #46 for the binfmt flush bug.

## 2026-09-27 02:50: Nitrogen: x86_64 distros with systemd=false
- Set `[boot] systemd=false` in the archlinux and Debian 13 amd64 WSL images (both ship `systemd=true`), so msl's arm64 init is PID 1 and only the distro's programs are x86_64, as in a container. Same script under Rosetta (macOS 27.0) and the patched FEX 2609; packages downloaded beforehand and removed between runs.

| | Rosetta: Debian | Rosetta: Arch | FEX: Debian | FEX: Arch | native arm64 |
|---|---|---|---|---|---|
| package install (gcc, sudo …, from cache) | 25.3 s | 2.2 s | 13.1 s | 2.3 s | |
| gcc -O2 hello, then run | ok, 0.30 s | ok, 0.43 s | ok, 0.50 s | ok, 0.84 s | 0.13 s |
| `ps -e`, `pgrep` | **crash** (Rosetta assertion) | ok | ok | ok | |
| setuid `sudo` | ok | ok | ok | ok | |
| `ldconfig` (Arch, static-pie) | | ok | | **SIGSEGV** | |
| sha256sum 256 MB | 0.49 s | 0.49 s | 0.54 s | 0.54 s | 0.11 s |
| xz -6, 64 MB, 1 thread | 24.5 s | 23.6 s | 24.9 s | 25.2 s | 20.0 s |
| 300 × fork+exec `true` | 2.64 s | 2.69 s | 4.58 s | 4.67 s | 0.05 s |

- Rosetta ran first, so its Debian install includes cold caches (first translation of dpkg and friends, and the page cache); the 25 s vs 13 s is not a clean comparison. The native sha256 uses the ARMv8 SHA instructions; the x86 build gets no SHA-NI under either translator.
- Without systemd, the distros' first-boot units don't run: Arch needed `pacman-key --init && pacman-key --populate archlinux` (normally `pacman-init.service`). pacman 7 also needs `--disable-sandbox` (or `DisableSandbox` in pacman.conf), because msl's kernel has no Landlock.

## 2026-09-27 03:05: Decision: arm64 only for now
- x86_64 distro support stays deferred (Nitrogen), and msl supports arm64 distros only. Everything from 2026-09-25 to 09-27 is summarised in #40's update comment: Apple's guidance, the Rosetta/qemu/FEX results, the `systemd=false` table, the FEX `clone3` patch and its test program (both inlined in the issue), and the steps if this resumes. The FEX patch was not sent upstream.
- The test VM is shut down and its temporary home removed. #46 (binfmt flush) stays open: it also affects x86 programs in arm64 distros.
- Closed #46 as not planned: x86_64 programs inside arm64 distros are not supported either.
