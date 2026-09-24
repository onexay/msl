# Security policy

## Supported versions

Only the latest `v*` release gets security fixes. Update with `msl --update`.

## Reporting a vulnerability

Please report vulnerabilities privately, through GitHub's **Report a vulnerability** button on the [Security tab](https://github.com/onexay/msl/security/advisories/new). Don't open a public issue.

Include the msl version (`msl --version`), your macOS version, and the steps to reproduce. You'll get an acknowledgement within 7 days. Once a fix is released, it will be announced in a GitHub security advisory that credits you, unless you'd rather not be named.

## Security model

msl runs Linux distributions in one lightweight VM (Apple's Virtualization.framework) on behalf of **one macOS user**.

- **Privileges.** `msl` and `msld` run as that user, never as root. `msld` holds the `com.apple.security.virtualization` entitlement only.
- **Isolation.** The VM is the security boundary between Linux and macOS. As in WSL, distributions are **not** isolated from each other: they share one kernel and one network namespace. Root inside a distro is root in its own namespaces, not on the Mac.
- **What the Mac exposes to Linux, by design:**
  - the Mac filesystem at `/mnt/mac`, with the user's permissions;
  - DNS resolution through macOS;
  - outbound network access through NAT.

  msl never runs macOS binaries from Linux.
- **What Linux exposes to the Mac:**
  - Distro listening ports are forwarded to `127.0.0.1` / `[::1]` only (`localhostForwarding`).
  - The control socket is `~/Library/Application Support/msl/msld.sock`, mode 0600.

### Known limitations

- **`~/MSL` file view.** Distro files are served over NFSv3 on a `127.0.0.1` port without authentication, so **other local user accounts on the same Mac** can reach it. On a shared Mac, avoid keeping secrets in distros until this is fixed (see "Open items" in docs/PLAN.md).
- **Forwarded ports.** As with WSL's localhost forwarding, a port forwarded from a distro can be reached by every local user on the Mac.
- **Release signing.** Releases are ad-hoc signed and not notarised yet. They are verified only by SHA-256 checksums published in the same GitHub release. `install.sh` removes the quarantine attribute from the files it installs.
- **`curl | sh` install.** Read `install.sh` before piping it to a shell if that matters to you. It's short, and it can also install a downloaded tarball with `--from`.
