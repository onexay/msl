# Files and paths

## macOS files in Linux: `/mnt/macos`

Every distribution sees the macOS filesystem at `/mnt/macos`, the way WSL shows `C:` at `/mnt/c`. `/mnt/macos/Users/me/src` is `/Users/me/src` on macOS. `[automount] root` in `/etc/wsl.conf` changes the parent directory: with `root=/`, it's `/macos`.

```console
$ cd /mnt/macos/Users/me/src
$ msl                    # from a macOS terminal: starts in the same directory, under /mnt/macos
```

Files there appear to belong to whichever Linux user reads them, and macOS checks permissions as your macOS user. Any Linux user can work in your macOS folders, and git's ownership check passes.

The macOS side is usually case-insensitive and slower than the distribution's own disk. Build and run tests in the Linux home directory when speed or case sensitivity matters, and use `/mnt/macos` to move files across.

msl never runs macOS programs from Linux, and never puts macOS paths on Linux's `PATH`. Tools such as `npm`, `node-gyp` and `configure` therefore find only Linux toolchains, and build output is Linux even under `/mnt/macos`.

## Converting paths: `mslpath`

`mslpath` works like WSL's `wslpath`:

```console
$ mslpath -w ~/project           # a Linux path as a macOS path
$ mslpath -u /Users/me/src       # a macOS path as a Linux path: /mnt/macos/Users/me/src
$ mslpath -a -u /Users/y/../x    # resolved to an absolute path: /mnt/macos/Users/x
```

A Linux path outside `/mnt/macos` converts to its location under `~/.msl/distros/<distro>`, so `mslpath -w /etc/hosts` gives a path you can open in Finder.

## Environment variables: `MSLENV`

`MSLENV` passes macOS environment variables into Linux, like `WSLENV`. List the variable names, separated by colons, each with an optional flag:

| Flag | Meaning |
|---|---|
| none | pass the value as it is |
| `/p` | the value is a macOS path: translate it |
| `/l` | the value is a colon-separated list of macOS paths: translate each |

```console
$ P=/Users/me MSLENV=P/p msl -e printenv P
/mnt/macos/Users/me
```

It works in one direction only, from macOS into Linux. `/u` is implied, and `/w` is ignored.

## Linux files in Finder: `~/.msl/distros`

While the VM runs, each distribution's files are at `~/.msl/distros/<distro>` and in Finder under Locations, with the distribution's logo. You can copy files in from macOS, including files with extended attributes. Finder's own files (`.DS_Store`, `._*`) stay on the macOS side and never appear in Linux. A new file takes the owner of the directory it's created in.

The folders are NFS mounts that msl creates when the VM starts and removes when it stops. msld serves them over a Unix socket that only your user can open, and checks every request, so other accounts on the same Mac can't read your distributions. [Security](internals/security.md) has the details.

## Disk images: `msl --mount`

`msl --mount <image>` attaches a disk image to the VM and mounts it at `/mnt/msl/<name>` in every distribution, like `wsl --mount`. `msl --unmount [<image>]` detaches it. `--bare`, `--name`, `--type`, `--options` and `--partition` work as in WSL.

The image is attached as a USB disk. Linux doesn't flush it the way it flushes a normal disk, so a write it considers saved can be lost if macOS crashes or loses power ([#43](https://github.com/onexay/msl/issues/43)). Keep a copy of anything you can't recreate.
