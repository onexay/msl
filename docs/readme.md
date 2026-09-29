# msl developer notes

User documentation is the MSL documentation site, **https://onexay.github.io/msl-docs/** ([source](https://github.com/onexay/msl-docs)). This folder has the notes for working on msl itself.

- [Architecture](architecture.md): the shared utility VM, host and guest, and how each WSL feature maps onto macOS
- [Comparison](comparison.md): msl next to WSL, OrbStack, Lima, Apple `container` and others
- [Security internals](internals/security.md), and [SECURITY.md](../SECURITY.md) for reporting and release verification
- Design notes are GitHub issues with the [`design`](https://github.com/onexay/msl/issues?q=label%3Adesign) label:
  - [vsock flow control](https://github.com/onexay/msl/issues/36): why every byte stream is credit-framed
  - [Memory reclaim](https://github.com/onexay/msl/issues/37): why `autoMemoryReclaim` has no effect on Virtualization.framework
  - [VS Code integration](https://github.com/onexay/msl/issues/38): options and open questions
- [Progress log](dev/progress.md): the timestamped development diary
- [Contributing](../CONTRIBUTING.md), [Governance](../GOVERNANCE.md), [Code of Conduct](../CODE_OF_CONDUCT.md), [Changelog](../CHANGELOG.md)
- [Third-party notices](third_party_notices.md) and [licence texts](licenses/), shipped in release packages
