# msl documentation

**Getting started**
- [Getting started](getting_started.md): install msl, a first distribution, files, ports and VS Code
- [Installing msl](install.md): installer options, and everything msl adds to macOS with what undoes it

**Guides**
- [VS Code and other IDEs](../README.md#vs-code-and-other-ides): what the extension does and how to set it up; [extension README](../extensions/vscode/README.md) for details and troubleshooting
- [Troubleshooting](troubleshooting.md): logs, diagnostics and common problems

**Reference**
- [The msl command](cli.md): the full `msl --help`, every command, and what's different inside a distribution
- [Configuration](configuration.md): `.mslconfig`, `wsl.conf`/`msl.conf`, environment variables
- [Compatibility with WSL distributions](wsl_compatibility.md): each WSL feature and its msl equivalent
- [JSON output](json.md): `--json` for `--list`, `--status` and `--version`
- [Changelog](../CHANGELOG.md)

**How it works**
- [Architecture](architecture.md): the shared utility VM, host and guest, and how each WSL feature maps onto macOS
- [Comparison](comparison.md): msl next to WSL, OrbStack, Lima, Apple `container` and others
- [Security](../SECURITY.md): reporting, release verification, security model
- Design notes are GitHub issues with the [`design`](https://github.com/onexay/msl/issues?q=label%3Adesign) label:
  - [vsock flow control](https://github.com/onexay/msl/issues/36): why every byte stream is credit-framed
  - [Memory reclaim](https://github.com/onexay/msl/issues/37): why `autoMemoryReclaim` has no effect on Virtualization.framework
  - [VS Code integration](https://github.com/onexay/msl/issues/38): options and open questions
- [Milestones](https://github.com/onexay/msl/milestones) and [issues](https://github.com/onexay/msl/issues): planned work and open items

**Contributing**
- [Contributing](../CONTRIBUTING.md), [Governance](../GOVERNANCE.md), [Code of Conduct](../CODE_OF_CONDUCT.md)
- [Third-party notices](third_party_notices.md) and [licence texts](licenses/)

**Development history**
- [Progress log](dev/progress.md): the timestamped development diary
