# Developer documentation

The [MSL documentation site](https://onexay.github.io/msl-docs/) covers user-facing setup and use. This folder documents the implementation and development of MSL.

## System design

- [Architecture](architecture.md) describes the shared utility VM, host and guest components, and WSL feature mappings.
- [Comparison](comparison.md) compares MSL with WSL and other Linux development environments.
- [Security internals](internals/security.md) points to the security model and reporting instructions in [SECURITY.md](../SECURITY.md).

## Design records

Open design questions and decisions are tracked in GitHub issues with the [`design` label](https://github.com/onexay/msl/issues?q=label%3Adesign):

- [Vsock flow control](https://github.com/onexay/msl/issues/36) documents why some streams use credit framing.
- [Memory reclaim](https://github.com/onexay/msl/issues/37) explains why `autoMemoryReclaim` cannot return memory through Virtualization.framework.
- [VS Code integration](https://github.com/onexay/msl/issues/38) tracks integration options and open questions.

## Project and legal records

- [Progress log](dev/progress.md) records development milestones and test results in chronological order.
- [Contributing](../CONTRIBUTING.md), [governance](../GOVERNANCE.md), [code of conduct](../CODE_OF_CONDUCT.md), and [changelog](../CHANGELOG.md) cover project participation and releases.
- [Third-party notices](third_party_notices.md) and the accompanying [license texts](licenses/) ship in release packages.
