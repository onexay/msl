# Contributing to msl

Thanks for helping. msl aims to behave exactly like `wsl.exe` on macOS, so the best contributions are the ones that close a gap with WSL, or fix a place where msl behaves differently. Planned work is in the [milestones](https://github.com/onexay/msl/milestones) and [issues](https://github.com/onexay/msl/issues).

## Before you start

- For anything bigger than a small fix, open an issue first. It's a chance to agree on the approach, especially for CLI behaviour: the WSL behaviour is the spec.
- Design proposals and investigation write-ups are issues with the [`design`](https://github.com/onexay/msl/issues?q=label%3Adesign) label, not files in the repo.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues.
- Be kind: see the [Code of Conduct](CODE_OF_CONDUCT.md).

## Set up

You need macOS 26 or later on Apple silicon, plus:
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
- **Docs:** update `README.md` and `docs/` in the same pull request as the behaviour change, and add a line to `CHANGELOG.md` under *Unreleased*. Documentation files at the root are UPPERCASE (`SECURITY.md`); files under `docs/` are lowercase snake_case (`getting_started.md`). `scripts/check-links.py` checks relative links and headings, and `swift test` checks that `docs/cli.md` matches `msl --help`; CI runs both. A documentation website is in progress and not published: `mkdocs.yml` builds it from the same files (`scripts/docs_hooks.py` points links to files outside `docs/` at the right page or at GitHub). Preview it locally with `pip install -r docs/requirements.txt && mkdocs serve`. The Docs workflow is disabled.

## Commits and pull requests

- One logical change per commit, with an imperative summary line ("Add --foo", "Fix …").
- **Sign off every commit** ([Developer Certificate of Origin](https://developercertificate.org/)): `git commit -s` adds `Signed-off-by: Your Name <email>`. It certifies that you wrote the change, or otherwise have the right to submit it under the project's licence. Apache-2.0 section 5 covers the licensing of contributions, so there is no CLA.
- Keep pull requests focused; fill in the template.

## Kernel

`scripts/build.sh` downloads the prebuilt kernel from the GitHub release named in `kernel/release.tag` (`kernel/fetch.sh`, via `gh` or `curl`, checked against `kernel/release.sha256`). `kernel/build.sh` rebuilds it from source with Apple's `container`, for local testing. Both it and CI run `kernel/build-linux.sh`.

Kernel tags come from their inputs: `kernel/tag.sh` prints `kernel-<linux>-msl-<hash>`, where the hash covers the Linux version, `kernel/base.config` and `kernel/msl.fragment`. After a config change, push it: CI's *Kernel* workflow builds it on `ubuntu-24.04-arm` and uploads an artifact named after the tag. Then run `kernel/publish.sh`, which downloads that artifact, publishes it under the tag, and updates `kernel/release.tag` and `kernel/release.sha256` (commit both). `kernel/out/tag` records which kernel is in `kernel/out`; `scripts/build.sh` fetches again when it's neither the published one nor a build of the current config.

`scripts/build.sh` stamps the commit into `MSLBuild.commit`, so `msl --version` shows `x.y.z+<hash>`.

The initramfs also carries static `e2fsck` and `resize2fs` (`guest/vendor/`), which mini-init uses to grow the data disk. `scripts/build-e2fsprogs.sh` rebuilds them from Debian's e2fsprogs source package, also in a container.

## VS Code extension

`scripts/build.sh` bundles `extensions/vscode` as `build/share/msl/msl.vsix`. For `package.json`'s version, it uses a local build (`cd extensions/vscode && npm run package`, which writes `dist/msl-<version>.vsix`) if there is one. Otherwise it downloads the release named in `extensions/vscode/release.tag` (`fetch.sh`, checked against `release.sha256`). Building msl therefore needs Node only when you're changing the extension.

## Releases

- **msl** ships as `v<version>` releases. The Latest one is what `install.sh` and `msl --update` use. Set the version with `scripts/set-version.sh <version>` (the root `VERSION` file is the source of truth), move the *Unreleased* changelog entries under it, commit and push, wait for CI to pass, then run `scripts/publish.sh <version>`. CI's *Release package* job builds the release (tarball + `.sha256`, `update.json`) with the Xcode that matches msl's minimum macOS, 26: a newer Xcode's Swift runtime links libraries that macOS 26 lacks, so a package built on a newer Mac doesn't start there (0.1.9 didn't). `publish.sh` never builds: it downloads that job's artifact for HEAD, checks that it's from this commit and Xcode 26 and that it bundles the published kernel and extension, signs the checksum when `MSL_GPG_KEY` is set, attaches the BusyBox and e2fsprogs source, and takes the notes from `CHANGELOG.md`. `scripts/package.sh <version>` builds the same files locally, for testing only.
- **The kernel** has its own releases, `kernel-<linux version>-msl-<config hash>`, published only when it changes, with `kernel/publish.sh` (see [Kernel](#kernel)). They are never marked Latest. Each msl release's notes name the kernel it bundles.
- **The VS Code extension** has its own releases, `vscode-<version>`, published with `extensions/vscode/publish.sh` when it changes. Bump `"version"` in `package.json`, push, and wait for CI's *VS Code extension* workflow, which builds the `.vsix` as artifact `vscode-<version>`. `publish.sh` publishes that artifact, after checking that it was built from an `extensions/vscode` identical to HEAD's. Then commit the updated `release.tag` and `release.sha256`. They are never marked Latest. `scripts/publish.sh` refuses to publish an msl release whose bundled `.vsix` isn't the published one.
