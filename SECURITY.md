# Security policy

## Supported versions

Only the latest `v*` release gets security fixes. Update with `msl --update`.

## Reporting a vulnerability

Please report vulnerabilities privately, through GitHub's **Report a vulnerability** button on the [Security tab](https://github.com/onexay/msl/security/advisories/new). Don't open a public issue.

Include the msl version (`msl --version`), your macOS version, and the steps to reproduce. You'll get an acknowledgement within 7 days. Once a fix is released, it will be announced in a GitHub security advisory that credits you, unless you'd rather not be named.

## Verifying a release

Current MSL, kernel and VS Code extension releases include SHA-256 checksums. For an MSL archive, verify it with:

```console
$ shasum -a 256 -c msl-<version>-macos-arm64.tar.gz.sha256
```

The checksum is published alongside the archive in the same GitHub release.

## Security model

msl runs Linux distributions in one lightweight VM (Apple's Virtualization.framework) on behalf of **one macOS user**.

- **Privileges.** `msl` and `msld` run as that user, never as root. `msld` holds the `com.apple.security.virtualization` entitlement only.
- **Isolation.** The VM is the security boundary between Linux and macOS. As in WSL, distributions are **not** isolated from each other: they share one kernel and one network namespace. Root inside a distro is root in its own namespaces, not on macOS.
- **What macOS exposes to Linux, by design:**
  - the macOS filesystem at `/mnt/macos`, with the user's permissions;
  - DNS resolution through macOS;
  - outbound network access through NAT.

  msl never runs macOS binaries from Linux.
- **What Linux exposes to macOS:**
  - Distro listening ports are forwarded to `127.0.0.1` / `[::1]` only (`localhostForwarding`).
  - The control socket is `~/Library/Application Support/msl/msld.sock`, mode 0600.

### Known limitations

- **`~/.msl/distros` file view.** Distro files are served over NFSv3 through a Unix socket in msl's folder (mode 0600), not a network port. macOS's NFS client connects from the kernel as root, so the socket's permissions alone don't stop another user from mounting it. msld therefore checks every NFS call ([#1](https://github.com/onexay/msl/issues/1)): only calls carrying your user ID or root's (the kernel's own) get through, and a MOUNT is accepted only while msld itself is mounting. Another local user can't mount the view, and gets an authentication error for anything in your mounts. With `fileViewTransport = tcp` the view is on a `127.0.0.1` port instead: the same checks apply, but a local program can connect to it directly and claim any user ID, so avoid that setting on a shared system.
- **Forwarded ports.** As with WSL's localhost forwarding, a port forwarded from a distro can be reached by every local user on macOS.
- **Release signing.** MSL executables are ad-hoc signed and not notarised.
- **`curl | sh` install.** The root `install.sh` downloads and runs `scripts/install.sh`; read both before piping the installer to a shell if that matters to you. The installer can also install a downloaded tarball with `--from`.
