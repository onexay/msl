# Contributing to msl

Thanks for helping. msl aims to behave exactly like `wsl.exe` on macOS, so the best contributions are the ones that close a gap with WSL, or fix a place where msl behaves differently. The kernel and the VS Code extension have their own repositories, [msl-kernel](https://github.com/onexay/msl-kernel) and [msl-vscode-extension](https://github.com/onexay/msl-vscode-extension); msl pins a release of each. Planned work is in the [milestones](https://github.com/onexay/msl/milestones) and [issues](https://github.com/onexay/msl/issues).

## Before you start

- For anything bigger than a small fix, open an issue first. It's a chance to agree on the approach, especially for CLI behaviour: the WSL behaviour is the spec.
- Design proposals and investigation write-ups are issues with the [`design`](https://github.com/onexay/msl/issues?q=label%3Adesign) label, not files in the repo.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues.
- Be kind: see the [Code of Conduct](CODE_OF_CONDUCT.md).

## Set up

You need macOS 26 or later on Apple silicon, plus:
- Xcode 27 (Swift 6.4);
- Rust 1.98 (`rustup`) with the `aarch64-unknown-linux-musl` target (`guest/rust-toolchain.toml` pins it);
- `protoc`.

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
| `kernel/` | the pinned [msl-kernel](https://github.com/onexay/msl-kernel) release (`release.tag`, `release.sha256`) and `fetch.sh` |
| `extensions/vscode/` | the pinned [msl-vscode-extension](https://github.com/onexay/msl-vscode-extension) release and `fetch.sh` |
| `scripts/` | build, initrd, packaging, publishing, pinning, licence and GPL-source tools; `install.sh` is at the root |
| `Tests/` | `MSLCoreTests` (swift-testing) and `e2e/` suites driving a real `msl` |
| `docs/` | documentation; start at the [index](docs/readme.md): [architecture](docs/architecture.md), [comparison](docs/comparison.md), design notes, [third-party notices](docs/third_party_notices.md) |
| `docs/dev/` | development log (`progress.md`) |

## Test

Run what your change touches, and say in the pull request what you ran:

```console
$ swift test                       # host unit tests
$ scripts/test-guest.sh            # guest unit tests (in Linux, via Apple's container)
$ Tests/e2e/<milestone>.sh         # end-to-end, against a real VM: helium, lithium,
                                   # beryllium, boron, carbon, neon, sodium, magnesium
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
- **Docs:** update `README.md` and `docs/` in the same pull request as the behaviour change, and add a line to `CHANGELOG.md` under *Unreleased*. Documentation files at the root are UPPERCASE (`SECURITY.md`); files under `docs/` are lowercase snake_case (`getting_started.md`). `scripts/check-links.py` checks relative links and headings, and `swift test` checks that `docs/cli.md` matches `msl --help`; CI runs both. The documentation website is [msl-docs](https://github.com/onexay/msl-docs), the authoritative user documentation: open a pull request there for every user-visible change as well.

## Commits and pull requests

- One logical change per commit, with an imperative summary line ("Add --foo", "Fix …").
- **Sign off every commit** ([Developer Certificate of Origin](https://developercertificate.org/)): `git commit -s` adds `Signed-off-by: Your Name <email>`. It certifies that you wrote the change, or otherwise have the right to submit it under the project's licence. Apache-2.0 section 5 covers the licensing of contributions, so there is no CLA.
- Keep pull requests focused; fill in the template.

## Kernel

The kernel's config, build and release scripts are in [msl-kernel](https://github.com/onexay/msl-kernel). `scripts/build.sh` downloads the release named in `kernel/release.tag` (`kernel/fetch.sh`, via `gh` or `curl`, checked against `kernel/release.sha256`) into `kernel/out`, and fetches again when `kernel/out/tag` isn't the pinned one. To try a local kernel build: `MSL_KERNEL_OUT=<msl-kernel>/out scripts/build.sh`.

To move msl to a new kernel release: `scripts/pin.sh kernel <tag>`, which writes `kernel/release.tag` and `kernel/release.sha256` from the release and checks the download. Commit both.

`scripts/build.sh` stamps the commit into `MSLBuild.commit`, so `msl --version` shows `x.y.z+<hash>`.

The initramfs also carries static `e2fsck` and `resize2fs` (`guest/vendor/`), which mini-init uses to grow the data disk. `scripts/build-e2fsprogs.sh` rebuilds them from Debian's e2fsprogs source package, also in a container.

## VS Code extension

The extension's source is in [msl-vscode-extension](https://github.com/onexay/msl-vscode-extension). `scripts/build.sh` bundles the release named in `extensions/vscode/release.tag` (`fetch.sh`, checked against `release.sha256`) as `build/share/msl/msl.vsix`, so building msl needs no Node. To bundle a local build instead: `MSL_VSIX=<msl-vscode-extension>/dist/msl-<version>.vsix scripts/build.sh`. To move msl to a new extension release: `scripts/pin.sh vscode vscode-<version>`, then commit the pin.

## Releases

- **msl** ships as `v<version>` releases. The Latest one is what `install.sh` and `msl --update` use. Set the version with `scripts/set-version.sh <version>` (the root `VERSION` file is the source of truth), move the *Unreleased* changelog entries under it, commit and push, wait for CI to pass, then run `scripts/publish.sh <version>`. CI's *Release package* job builds the release (tarball + `.sha256`, `update.json`) with the Xcode that matches msl's minimum macOS, 26: a newer Xcode's Swift runtime links libraries that macOS 26 lacks, so a package built on a newer Mac doesn't start there (0.1.9 didn't). `publish.sh` never builds: it downloads that job's artifact for HEAD, checks that it's from this commit and Xcode 26 and that it bundles the published kernel and extension, signs the checksum when `MSL_GPG_KEY` is set, attaches the BusyBox and e2fsprogs source, and takes the notes from `CHANGELOG.md`. `scripts/package.sh <version>` builds the same files locally, for testing only.
- **The kernel** is released from [msl-kernel](https://github.com/onexay/msl-kernel) as `kernel-<linux version>-msl-<config hash>`; its README describes how. Each msl release's notes name the kernel it bundles.
- **The VS Code extension** is released from [msl-vscode-extension](https://github.com/onexay/msl-vscode-extension) as `vscode-<version>`.
- `scripts/publish.sh` refuses to publish an msl release whose bundled kernel or `.vsix` isn't the pinned one (see [Kernel](#kernel) and [VS Code extension](#vs-code-extension)).
