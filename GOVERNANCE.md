# Governance

msl is a young project with a single maintainer. This document says how decisions get made today and how that changes as more people contribute.

## Roles

- **Users** use msl, and report bugs and ideas through issues.
- **Contributors** send pull requests. Anyone can be one; see [CONTRIBUTING.md](CONTRIBUTING.md).
- **Maintainers** review and merge changes, triage issues, cut releases and enforce the [Code of Conduct](CODE_OF_CONDUCT.md). They are listed below and in [`.github/CODEOWNERS`](.github/CODEOWNERS).

## Maintainers

| Maintainer | Areas |
|---|---|
| [@onexay](https://github.com/onexay) | everything (project lead) |

## Decisions

- **Compatibility with wsl.exe is the default answer.** When msl's behaviour is in question, wsl.exe's behaviour decides. A deliberate difference needs a reason written into the docs; for example, msl never runs macOS binaries from Linux.
- Everyday changes are decided in review: one maintainer's approval merges a pull request.
- Larger changes (architecture, the host ↔ guest protocol, new dependencies with a new licence type, dropping a feature) are discussed in an issue first. The project lead decides if there is no consensus.
- Security fixes may be developed privately and released before public discussion (see [SECURITY.md](SECURITY.md)).

## Becoming a maintainer

A contributor with a record of good, sustained contributions and reviews can be nominated by any maintainer. The existing maintainers agree by consensus. A maintainer who has been inactive for a year may be moved to emeritus status.

## Changes to this document

By pull request, approved by the project lead.
