# Contributing to msl

Thanks for helping. msl aims to behave exactly like `wsl.exe` on the Mac, so the best contributions are the ones that close a gap with WSL, or fix a place where msl behaves differently. The open items are in [`docs/PLAN.md`](docs/PLAN.md) and the [issues](https://github.com/onexay/msl/issues).

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

## Test

Run what your change touches, and say in the pull request what you ran:

```console
$ swift test                       # host unit tests
$ scripts/test-guest.sh            # guest unit tests (in Linux, via Apple's container)
$ Tests/e2e/m1.sh … m5.sh          # end-to-end, against a real VM
$ Tests/e2e/release.sh             # packaging, install, --update, --uninstall
```

The e2e suites use a throwaway `MSL_HOME` and never touch your real distros or `~/MSL`. Keep it that way in new tests: set `MSL_HOME`, `MSL_CONFIG` and `MSL_VIEW_DIR`.

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

## Releases

Maintainers release with `scripts/publish.sh <version>` (and `kernel/publish.sh` when the kernel changes); see the README's "Build and test" section.
