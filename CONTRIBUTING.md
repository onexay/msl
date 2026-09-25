# Contributing to msl

Thanks for helping. msl aims to behave exactly like `wsl.exe` on the Mac, so the best contributions are the ones that close a gap with WSL, or fix a place where msl behaves differently. Planned work is in the [milestones](https://github.com/onexay/msl/milestones) and [issues](https://github.com/onexay/msl/issues).

## Before you start

- For anything bigger than a small fix, open an issue first. It's a chance to agree on the approach, especially for CLI behaviour: the WSL behaviour is the spec.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues.
- Be kind: see the [Code of Conduct](CODE_OF_CONDUCT.md).

## Set up

You need an Apple silicon Mac with macOS 26 or later, plus:
- Xcode 27 (Swift 6.4);
- Rust 1.98 (`rustup`) with the `aarch64-unknown-linux-musl` target (`guest/rust-toolchain.toml` pins it);
- `protoc`;
- to rebuild the kernel: Apple's `container`.

```console
$ scripts/build.sh            # guest + initrd + msl/msld → build/ (downloads the kernel release)
$ build/bin/msl --help
```

## Code layout

| Path | What |
|---|---|
| `Sources/msl` | CLI (argument parsing and output mirror `wsl.exe`) |
| `Sources/msld`, `Sources/MSLService` | service: VM, sessions, forwarding, DNS, file view, disks |
| `Sources/MSLCore` | parser, messages, registry, `.mslconfig`, IPC |
| `guest/` | `msl-guest`: VM init, per-distro init and agent, NFS server, DNS stub |
| `proto/msl/v1/msl.proto` | host ↔ guest gRPC protocol |
| `kernel/` | kernel config (Apple's + `msl.fragment`), build, fetch and publish scripts |
| `scripts/` | build, initrd, packaging, publishing, licence and GPL-source tools; `install.sh` is at the root |
| `Tests/` | `MSLCoreTests` (swift-testing) and `e2e/` suites driving a real `msl` |
| `docs/` | documentation; start at the [index](docs/README.md): [architecture](docs/ARCHITECTURE.md), [comparison](docs/comparison.md), design notes, [third-party notices](docs/THIRD_PARTY_NOTICES.md) |
| `docs/dev/` | development log (`progress.md`) and the Hydrogen (milestone 0) spike |

## Test

Run what your change touches, and say in the pull request what you ran:

```console
$ swift test                       # host unit tests
$ scripts/test-guest.sh            # guest unit tests (in Linux, via Apple's container)
$ Tests/e2e/<milestone>.sh         # end-to-end, against a real VM: helium, lithium,
                                   # beryllium, boron, carbon, neon, sodium
$ Tests/e2e/release.sh             # packaging, install, --update, --uninstall
```

The e2e suites use a throwaway `MSL_HOME` and never touch your real distros or `~/.msl/distros`. Keep it that way in new tests: set `MSL_HOME`, `MSL_CONFIG` and `MSL_VIEW_DIR`.

CI runs the unit tests and lints. It can't run the e2e suites, because hosted runners can't start VMs.

## Code

- **Match the code around you**: naming, comment density, error handling. Comments explain *why*, not *what*.
- **User-facing text** lives in `Sources/MSLCore/Messages.swift`. It follows wsl.exe's wording, with "Windows" adapted to "macOS".
- **Guest code** (`guest/`) is a static musl binary running as PID 1 and as each distro's init. Avoid dependencies that need libc features musl lacks, and never block the reaper.
- **Host ↔ guest protocol:** change `proto/msl/v1/msl.proto`, then run `scripts/gen-proto.sh` and commit the generated Swift.
- **Dependencies:** after changing `guest/Cargo.lock` or `Package.resolved`, run `scripts/gen-licenses.sh` and commit `docs/licenses/`. New dependencies must be under a licence compatible with Apache-2.0.
- **Docs:** update `README.md` and `docs/` in the same pull request as the behaviour change, and add a line to `CHANGELOG.md` under *Unreleased*.

## Commits and pull requests

- One logical change per commit, with an imperative summary line ("Add --foo", "Fix …").
- **Sign off every commit** ([Developer Certificate of Origin](https://developercertificate.org/)): `git commit -s` adds `Signed-off-by: Your Name <email>`. It certifies that you wrote the change, or otherwise have the right to submit it under the project's licence. Apache-2.0 section 5 covers the licensing of contributions, so there is no CLA.
- Keep pull requests focused; fill in the template.

## Kernel

`scripts/build.sh` downloads the prebuilt kernel from the GitHub release named in `kernel/release.tag` (`kernel/fetch.sh`, via `gh` or `curl`, checked against `kernel/release.sha256`). `kernel/build.sh` rebuilds it from source with Apple's `container`.

## Releases

- **msl** ships as `v<version>` releases. The Latest one is what `install.sh` and `msl --update` use. Set the version with `scripts/set-version.sh <version>` (the root `VERSION` file is the source of truth), move the *Unreleased* changelog entries under it, commit and push, then run `scripts/publish.sh <version>`. It packages the release (tarball + `.sha256`, `.pkg`, `update.json`), signs the checksum when `MSL_GPG_KEY` is set, attaches the BusyBox source, and takes the notes from `CHANGELOG.md`. `scripts/package.sh <version>` builds the same files locally without publishing.
- **The kernel** has its own releases, `kernel-<linux version>-msl.<n>`, published only when it changes, with `kernel/publish.sh`. Bump `n` for config-only changes. They are never marked Latest. Each msl release's notes name the kernel it bundles.
