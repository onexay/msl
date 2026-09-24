# msl documentation

**Using msl**
- [README](../README.md): install, quick start, known limitations
- [Configuration](configuration.md): `.mslconfig`, `wsl.conf`/`msl.conf`, environment variables
- [Comparison](comparison.md): msl next to WSL, OrbStack, Lima, Apple `container` and others
- [Security](../SECURITY.md): reporting, release verification, security model
- [Changelog](../CHANGELOG.md)

**How it works**
- [Architecture](architecture.md): the shared utility VM, host and guest, and how each WSL feature maps onto macOS
- [Roadmap](roadmap.md): milestones and open items
- Design notes:
  - [vsock flow control](design/vsock-flow-control.md): why every byte stream is credit-framed
  - [Memory reclaim](design/memory-reclaim.md): why `autoMemoryReclaim` has no effect on Virtualization.framework
  - [VS Code integration](design/vscode-integration.md): proposal

**Contributing**
- [Contributing](../CONTRIBUTING.md), [Governance](../GOVERNANCE.md), [Code of Conduct](../CODE_OF_CONDUCT.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md) and [licence texts](licenses/)

**Development history**
- [Progress log](dev/progress.md): the timestamped development diary
- [Original plan](dev/plan.md) and [spike results](dev/spike-results.md) (milestone 0; code in [dev/spike](dev/spike/))
