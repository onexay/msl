# Contributing to msl

Thanks for helping. msl aims to behave exactly like `wsl.exe` on macOS, so the best contributions are the ones that close a gap with WSL, or fix a place where msl behaves differently. The kernel and the VS Code extension have their own repositories, [msl-kernel](https://github.com/onexay/msl-kernel) and [msl-vscode-extension](https://github.com/onexay/msl-vscode-extension); msl pins a release of each. Planned work is in the [milestones](https://github.com/onexay/msl/milestones) and [issues](https://github.com/onexay/msl/issues).

## Before you start

- For anything bigger than a small fix, open an issue first. It's a chance to agree on the approach, especially for CLI behaviour: the WSL behaviour is the spec.
- Design proposals and investigation write-ups are issues with the [`design`](https://github.com/onexay/msl/issues?q=label%3Adesign) label, not files in the repo.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues.
- Be kind: see the [Code of Conduct](CODE_OF_CONDUCT.md).

## Set up

You need macOS 27 or later on Apple silicon, plus:
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
| `core/` | shared support, CLI core, protocol library and gRPC schema |
| `host/` | macOS CLI, service, VM, sessions, forwarding, DNS, file view and disks |
| `guest/` | `msl-guest`: VM init, per-distro init and agent, NFS server, DNS stub |
| `tests/` | Swift and Rust unit tests, plus end-to-end suites that drive a real `msl` |
| `kernel/` | pinned [msl-kernel](https://github.com/onexay/msl-kernel) release metadata and downloaded build files |
| `extensions/vscode/` | pinned [msl-vscode-extension](https://github.com/onexay/msl-vscode-extension) release metadata and downloaded VSIX |
| `scripts/` | build, fetch, install, test, packaging, release, pinning, license and source tools |
| `docs/` | developer notes; start at the [index](docs/readme.md): [architecture](docs/architecture.md), [comparison](docs/comparison.md), [third-party notices](docs/third_party_notices.md). User documentation is in [msl-docs](https://github.com/onexay/msl-docs) |
| `docs/dev/` | development log (`progress.md`) |

## Test

Run what your change touches, and say in the pull request what you ran:

```console
$ swift test                       # core unit tests
$ scripts/test-guest.sh            # guest unit tests (in Linux, via Apple's container)
$ tests/e2e/<milestone>.sh           # end-to-end, against a real VM: helium, lithium,
                                   # beryllium, boron, carbon, neon, sodium, magnesium
$ tests/e2e/release.sh               # packaging, install, --update, --uninstall
```

The e2e suites use a throwaway `MSL_HOME` and never touch your real distros or `~/.msl/distros`. Keep it that way in new tests: set `MSL_HOME`, `MSL_CONFIG` and `MSL_VIEW_DIR`.

CI runs the unit tests and lints. It can't run the e2e suites, because hosted runners can't start VMs.

## Code

- **Match the code around you**: naming, comment density, error handling. Comments explain *why*, not *what*.
- **User-facing text** lives in `core/MSLCore/Messages.swift`. It follows wsl.exe's wording, with "Windows" adapted to "macOS".
- **Guest code** (`guest/`) is a static musl binary running as PID 1 and as each distro's init. Avoid dependencies that need libc features musl lacks, and never block the reaper.
- **Host ↔ guest protocol:** change `core/proto/msl/v1/msl.proto`, then run `scripts/gen-proto.sh` and commit the generated Swift.
- **Dependencies:** after changing `guest/Cargo.lock` or `Package.resolved`, run `scripts/gen-licenses.sh` and commit `docs/licenses/`. New dependencies must be under a licence compatible with Apache-2.0.
- **Docs:** user-visible changes need a pull request in [msl-docs](https://github.com/onexay/msl-docs), the documentation site (https://onexay.github.io/msl-docs/). Keep `README.md` and the developer notes in `docs/` (architecture, design) in step in the same pull request as the change. Documentation files at the root are UPPERCASE (`SECURITY.md`); files under `docs/` are lowercase snake_case. `scripts/check-links.py` checks relative links and headings; CI runs it.

## Commits and pull requests

- One logical change per commit, with an imperative summary line ("Add --foo", "Fix …").
- **Sign off every commit** ([Developer Certificate of Origin](https://developercertificate.org/)): `git commit -s` adds `Signed-off-by: Your Name <email>`. It certifies that you wrote the change, or otherwise have the right to submit it under the project's licence. Apache-2.0 section 5 covers the licensing of contributions, so there is no CLA.
- Keep pull requests focused; fill in the template.

## Kernel

The kernel's config, build and release scripts are in [msl-kernel](https://github.com/onexay/msl-kernel). `scripts/build.sh` downloads the release named in `kernel/release.tag` (`scripts/fetch-kernel.sh`, via `gh` or `curl`, checked against `kernel/release.sha256`) into `kernel/out`, and fetches again when `kernel/out/tag` isn't the pinned one. To try a local kernel build: `MSL_KERNEL_OUT=<msl-kernel>/out scripts/build.sh`.

To move msl to a new kernel release: `scripts/pin.sh kernel` (the Latest release, or name a tag), which writes `kernel/release.tag` and `kernel/release.sha256` from the release and checks the download. Commit both.

`scripts/build.sh` stamps the commit into `MSLBuild.commit` for JSON diagnostics. `msl --version` displays the SemVer version; the kernel's `uname -r` includes its short source commit hash for build identification.

The initramfs also carries static `e2fsck` and `resize2fs` (`guest/vendor/`), which mini-init uses to grow the data disk. `scripts/build-e2fsprogs.sh` rebuilds them from Debian's e2fsprogs source package, also in a container.

## VS Code extension

The extension's source is in [msl-vscode-extension](https://github.com/onexay/msl-vscode-extension). `scripts/build.sh` bundles the release named in `extensions/vscode/release.tag` (`scripts/fetch-vscode.sh`, checked against `release.sha256`) as `build/share/msl/msl.vsix`, so building msl needs no Node. To bundle a local build instead: `MSL_VSIX=<msl-vscode-extension>/dist/msl-<version>.vsix scripts/build.sh`. To move msl to a new extension release: `scripts/pin.sh vscode` (the Latest release, or name a tag), then commit the pin.

## Releases

- **msl** ships as `v<version>` releases. `install.sh` and `msl --update` use the Latest release. CI calculates the next version from conventional commits since the latest `v<semver>` tag: breaking changes bump major, `feat:` bumps minor, and other changes bump patch. With no SemVer tag, it uses `VERSION`; that file is also a floor if it is newer than the calculated version. After main's CI passes, run the **Release** workflow manually from `main`; it resolves the Latest kernel and extension releases at release time, fetches and verifies their assets, builds MSL with them using the released Xcode matching macOS 27, and publishes that package without a version input. A newer Xcode's Swift runtime links libraries that the minimum macOS lacks, so a package built on a newer Mac doesn't start there (0.1.9 didn't on macOS 26). The workflow attaches the BusyBox and e2fsprogs source and asks GitHub to generate release notes from changes since the previous release. For a PGP-signed checksum, configure `MSL_GPG_KEY` and `MSL_GPG_PRIVATE_KEY` repository secrets. The regular CI package check and `scripts/package.sh <version>` use the checked-in pins. `scripts/pin.sh kernel` and `scripts/pin.sh vscode` update those development pins to Latest; passing a tag selects that release explicitly.
- **The kernel** is released from [msl-kernel](https://github.com/onexay/msl-kernel) as `v<semver>`; its `uname -r` suffix includes the short source commit hash. Each msl release's notes name the kernel it bundles.
- **The VS Code extension** is released from [msl-vscode-extension](https://github.com/onexay/msl-vscode-extension) as `v<semver>`; development VSIX files use the base manifest version without a hash.
- `scripts/publish.sh` verifies that its package contains the exact kernel and VSIX assets fetched from each repository's Latest release.
