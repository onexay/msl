# Security policy

## Supported versions

Only the latest `v*` release gets security fixes. Update with `msl --update`.

## Reporting a vulnerability

Please report vulnerabilities privately, through GitHub's **Report a vulnerability** button on the [Security tab](https://github.com/onexay/msl/security/advisories/new). Don't open a public issue.

Include the msl version (`msl --version`), your macOS version, and the steps to reproduce. You'll get an acknowledgement within 7 days. Once a fix is released, it will be announced in a GitHub security advisory that credits you, unless you'd rather not be named.

## Verifying a release

Each release's tarball has a SHA-256 checksum (`.sha256`). From now on, that file is also signed with the release key (`.sha256.asc`):

- key: `E880 3CF7 DBA7 8BCB 3F0B  8F1D 43E8 9DC4 4167 036A` (rsa4096, onexay)
- published on [keys.openpgp.org](https://keys.openpgp.org/search?q=E8803CF7DBA78BCB3F0B8F1D43E89DC44167036A) and on [github.com/onexay.gpg](https://github.com/onexay.gpg)

`install.sh` checks the checksum, and also checks the signature when `gpg` is installed. To verify by hand:

```console
$ gpg --keyserver hkps://keys.openpgp.org --recv-keys E8803CF7DBA78BCB3F0B8F1D43E89DC44167036A
$ gpg --verify msl-<version>-macos-arm64.tar.gz.sha256.asc msl-<version>-macos-arm64.tar.gz.sha256
$ shasum -a 256 -c msl-<version>-macos-arm64.tar.gz.sha256
```

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

- **`~/MSL` file view.** Distro files are served over NFSv3 on a `127.0.0.1` port without authentication, so **other local user accounts on the same Mac** can reach it. On a shared Mac, avoid keeping secrets in distros until this is fixed ([#1](https://github.com/onexay/msl/issues/1)).
- **Forwarded ports.** As with WSL's localhost forwarding, a port forwarded from a distro can be reached by every local user on the Mac.
- **Release signing.** Releases are ad-hoc signed and not notarised yet. Releases without a `.sha256.asc` (including v0.1.1) are verified only by a SHA-256 checksum published in the same GitHub release; signed releases also carry a PGP signature (see above). `install.sh` removes the quarantine attribute from the files it installs.
- **`curl | sh` install.** Read `install.sh` before piping it to a shell if that matters to you. It's short, and it can also install a downloaded tarball with `--from`.
