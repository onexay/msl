## msl: Modern Subsystem for Linux

**Linux as the development environment on macOS, the way WSL made it on Windows.**

msl runs Linux distributions on a Mac the way WSL runs them on Windows. The `msl` command is `wsl.exe` for macOS: same arguments, same output, same exit codes. It runs Microsoft's WSL distribution images, unmodified, in one lightweight Linux VM. It needs Apple silicon and macOS 26 or later, and uses only Apple's Virtualization.framework.

Why: teams split across Windows and macOS end up with two developer setups, two sets of docs and two sets of bugs. With WSL on Windows and msl on macOS, everyone develops in the same Linux distro, from the same image, with the same commands, scripts and `wsl.conf`. The toolchain is Linux on both; the host OS is just where the editor and browser live.

```console
$ msl --install Ubuntu            # an arm64 image from Microsoft's WSL distribution list
$ msl                             # a shell in the default distro, in the Mac's current directory
$ msl -d Debian -u root apt update
$ msl -l -v
  NAME            STATE           VERSION
* Ubuntu          Running         2
  Debian          Stopped         2
$ python3 -m http.server 8000     # inside a distro: http://localhost:8000 on the Mac
$ ls ~/.msl/distros/Ubuntu/home   # the distro's files from the Mac (also in Finder › Locations)
```

- [Install](#install)
- [What the installer sets up](#what-the-installer-sets-up)
- [The msl command](#the-msl-command)
- [VS Code and other IDEs](#vs-code-and-other-ides)
- [Compatibility with WSL distributions](#compatibility-with-wsl-distributions)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Known limitations](#known-limitations)
- [How msl compares](#how-msl-compares)
- [Development](#development)

## Install

```console
$ curl -fsSL https://raw.githubusercontent.com/onexay/msl/main/install.sh | sh
```

The installer asks before each step. For an unattended install, pass `--yes` and whichever options you need:

```console
$ curl -fsSL https://raw.githubusercontent.com/onexay/msl/main/install.sh | sh -s -- --yes [options]
```

| Option | Effect |
|---|---|
| `--prefix <dir>` | Where to install. Default `~/.local` (no sudo). `/usr/local` asks for sudo. |
| `--version <x.y.z>` | Install a specific release instead of the latest. |
| `--from <tarball>` | Install a local `msl-<version>-macos-arm64.tar.gz`. |
| `--no-path` | Don't add the prefix to `PATH`. |
| `--no-ide` | Don't set up the VS Code extension. |
| `--yes`, `-y` | Accept the defaults without asking. |

Update with `msl --update`. `msl --uninstall` removes msl and undoes the IDE setup, but keeps your distributions. msl has no Homebrew formula, because it's a self-contained environment that updates itself.

## What the installer sets up

Everything msl touches on your Mac, and what undoes it:

| What | Where | Why | Undone by |
|---|---|---|---|
| msl itself | `<prefix>/bin/msl`, `<prefix>/libexec/msl/msld`, `<prefix>/share/msl/` (kernel, initrd, `msl.vsix`), `<prefix>/share/doc/msl/` | The CLI, the service, the VM images, the VS Code extension | `msl --uninstall` |
| `PATH` | One line in `~/.zshrc`, `~/.bash_profile`, `~/.config/fish/config.fish` or `~/.profile` | So `msl` runs from any terminal | Remove the line by hand |
| VS Code extension | Each IDE's extensions folder (VS Code, Insiders, VSCodium, Cursor) | Opens folders inside distros ([below](#vs-code-and-other-ides)) | `msl --manage-ide --ide all --uninstall`, or `msl --uninstall` |
| `enable-proposed-api` | Each IDE's `argv.json` (for example `~/.vscode/argv.json`). The first change saves a backup, `argv.json.msl-backup`. | The extension needs VS Code's proposed remote-resolver API | Same as above; the entry is removed and the file restored |
| Which msl the extension runs | `~/Library/Application Support/msl/cli-path` | So the extension finds msl wherever it's installed | Same as above |

Created on first use, not by the installer:

| What | Where |
|---|---|
| Distributions and state | `~/Library/Application Support/msl/`: `data.img` (one sparse disk for all distros, 256 GiB maximum), `registry.json`, `msld.log`, and the sockets `msld.sock` and `connect.sock` |
| Distribution files in Finder | `~/.msl/distros/<distro>`: NFS mounts that exist while the VM runs |
| Downloads | `~/Library/Caches/msl/`: distribution images, and the VS Code Server for your IDE's version |
| VM settings | `~/.mslconfig`, only if you create it ([Configuration](#configuration)) |

msl doesn't install a LaunchAgent, a kernel extension or a login item, and it never asks for administrator rights except to install into a system prefix. `msld` starts when you first run `msl`, and stops the VM after `vmIdleTimeout` (60 s by default) with nothing running.

## The msl command

`msl` accepts `wsl.exe`'s arguments and prints the same messages. Anything that works with `wsl.exe` in a script or a README should work with `msl`. This is `msl --help`:

```text
Usage: msl [Argument] [Options...] [CommandLine]

Arguments for running Linux binaries:

    If no command line is provided, msl launches the default shell.

    --exec, -e <CommandLine>
        Execute the specified command without using the default Linux shell.

    --shell-type <standard|login|none>
        Execute the specified command with the provided shell type.

    --
        Pass the remaining command line as-is.

Options:
    --cd <Directory>
        Sets the specified directory as the current working directory.
        If ~ is used the Linux user's home path will be used. The path is
        interpreted as an absolute Linux path; macOS paths are under /mnt/mac.

    --distribution, -d <DistroName>
        Run the specified distribution.

    --distribution-id <DistroGuid>
        Run the specified distribution ID.

    --user, -u <UserName>
        Run as the specified user.

Arguments for managing Modern Subsystem for Linux:

    --debug-shell
        Open a root shell in the utility virtual machine, outside every
        distribution, for diagnostics.

    --help
        Display usage information.

    --install [Distro] [Options...]
        Install a Modern Subsystem for Linux distribution.
        For a list of valid distributions, use 'msl --list --online'.

        Options:
            --from-file <Path>
                Install a distribution from a local file.

            --location <Location>
                Set the install path for the distribution.

            --name <Name>
                Set the name of the distribution.

            --no-launch, -n
                Do not launch the distribution after install.

            --version <Version>
                Specifies the version to use for the new distribution.

    --manage-ide [--ide <IDE>] [--install | --uninstall]
        Set up the MSL extension in VS Code or a similar IDE, so it can
        open folders inside distributions. Without options, lists the IDEs
        found and asks what to do.

        Options:
            --ide <vscode | vscode-insiders | vscode-oss | cursor | all>
                The IDE to change (vscodium is an alias for vscode-oss).

            --install
                Install the extension and enable its proposed API in argv.json.

            --uninstall
                Uninstall the extension and remove it from argv.json.

    --mount <Disk> [Options...]
        Attaches and mounts a disk image in all distributions, at
        /mnt/msl/<Name>.

        Options:
            --vhd
                Accepted for compatibility; every disk is an image file.

            --bare
                Attach the disk, but don't mount it.

            --name <Name>
                Mount the disk using a custom name for the mountpoint.

            --type, -t <Type>
                Filesystem to use when mounting a disk, if not specified defaults to ext4.

            --options, -o <Options>
                Additional mount options.

            --partition <Index>
                Index of the partition to mount, if not specified defaults to the whole disk.

    --set-default-version <Version>
        Changes the default install version for new distributions.
        Only version 2 is available.

    --shutdown
        Immediately terminates all running distributions and the
        lightweight utility virtual machine.

        Options:
            --force
                Terminate the virtual machine even if an operation is in progress. Can cause data loss.

    --status
        Show the status of Modern Subsystem for Linux.

    --uninstall
        Remove Modern Subsystem for Linux from this Mac and undo --manage-ide.
        Distributions and settings are kept.

    --unmount [Disk]
        Unmounts and detaches a disk from all distributions.
        Unmounts and detaches all disks if called without argument.

    --update [Options]
        Update Modern Subsystem for Linux to the latest release.

        Options:
            --pre-release
                Download a pre-release version if available.

    --version, -v
        Display version information.

    --json
        With --list, --status or --version: print JSON instead of text.

Arguments for managing distributions in Modern Subsystem for Linux:

    --export <Distro> <FileName> [Options]
        Exports the distribution to a tar file.
        The filename can be - for stdout.

        Options:
            --format <Format>
                Specifies the export format. Supported values: tar, tar.gz, tar.xz.

    --import <Distro> <InstallLocation> <FileName> [Options]
        Imports the specified tar file as a new distribution.
        The filename can be - for stdin.

        Options:
            --version <Version>
                Specifies the version to use for the new distribution.

    --list, -l [Options]
        Lists distributions.

        Options:
            --all
                List all distributions, including distributions that are
                currently being installed or uninstalled.

            --running
                List only distributions that are currently running.

            --quiet, -q
                Only show distribution names.

            --verbose, -v
                Show detailed information about all distributions.

            --online, -o
                Displays a list of available distributions for install with 'msl --install'.

    --manage <Distro> <Options...>
        Changes distro specific options.

        Options:
            --set-default-user <Username>
                Set the default user of the distribution.

            --compact
                Return the space freed inside the distribution to macOS.

            --move <Location>
                Accepted for compatibility; all distributions share one disk.

            --set-sparse, -s <true|false>
                Accepted for compatibility; the disk is always sparse.

    --set-default, -s <Distro>
        Sets the distribution as the default.

    --set-version <Distro> <Version>
        Changes the version of the specified distribution.
        Only version 2 is available.

    --terminate, -t <Distro>
        Terminates the specified distribution.

    --unregister <Distro>
        Unregisters the distribution and deletes the root filesystem.
```

### Running Linux

With no arguments, `msl` opens the default distro's shell in the Mac's current directory, under `/mnt/mac`. Anything after the options is a command line for that shell. `-e` runs a program directly, without a shell.

```console
$ msl                                  # interactive shell
$ msl ls -la                           # through the shell: globs, variables, pipes inside Linux
$ msl -e uname -m                      # no shell; the exit code is passed through
$ msl --cd ~ -- make test              # start in the Linux home directory
$ msl -d Debian -u root apt upgrade    # another distro, another user
$ git log | msl -e wc -l               # stdin and stdout are pipes both ways
```

Terminals work as in WSL: a PTY when you're interactive, pipes otherwise; window resizes and Ctrl-C reach the Linux process.

### Installing and managing distributions

| Command | What it does |
|---|---|
| `msl --list --online` (`-l -o`) | Distributions you can install: Microsoft's WSL list, arm64 images. |
| `msl --install <Distro>` | Downloads and installs a distribution, then runs its first-run setup (creating your user). `--name`, `--location` and `--no-launch` work as in WSL. `--from-file <x.wsl>` installs a local image. `--web-download`, `--vhd-size` and `--fixed-vhd` are accepted and ignored. |
| `msl -l [-v \| -q \| --running \| --all]` | Installed distributions, their state and WSL version (always 2). |
| `msl -s <Distro>` | Sets the default distribution. |
| `msl -t <Distro>` | Stops one distribution. |
| `msl --shutdown [--force]` | Stops every distribution and the VM. |
| `msl --unregister <Distro>` | Deletes a distribution and its files. |
| `msl --export <Distro> <file> [--format tar\|tar.gz\|tar.xz]` | Exports a distribution. Use `-` for stdout. |
| `msl --import <Distro> <location> <file>` | Imports a tar file as a new distribution. Use `-` for stdin. |
| `msl --manage <Distro> --set-default-user <user>` | Sets the user that shells run as. |
| `msl --manage <Distro> --compact` | Frees space in `data.img` after deleting files. |
| `msl --manage <Distro> --move <location>` | Accepted; the location is only recorded, because every distro lives on the shared disk. |
| `msl --manage <Distro> --set-sparse <bool>` | Accepted; the disk is always sparse. |
| `msl --set-version <Distro> 2`, `msl --set-default-version 2` | Accepted. Version 1 isn't available on macOS. |

### The VM, updates and msl's own additions

| Command | What it does |
|---|---|
| `msl --status [--json]` | The default distro, plus the VM's effective settings (memory, CPUs, kernel, networking, idle timeouts) and any `.mslconfig` changes waiting for a restart. |
| `msl --version [--json]` | msl, kernel and macOS versions. |
| `msl --mount <image> [--name <n>] [--type <fs>] [--options <o>] [--partition <n>] [--bare]` | Attaches a disk image to the VM, mounted at `/mnt/msl/<name>` in every distro. `--vhd` is accepted. `msl --unmount [<image>]` detaches it. |
| `msl --update [--pre-release]` | Updates msl in place from the latest release. Distributions are kept. |
| `msl --uninstall` | Removes msl and undoes the IDE setup. Distributions and settings stay in `~/Library/Application Support/msl`. |
| `msl --manage-ide` | Sets up the VS Code extension ([below](#vs-code-and-other-ides)). |
| `msl --debug-shell` | A root BusyBox shell in the utility VM itself, outside every distro. |
| `--json` | Machine-readable output for `--list`, `--list --online`, `--status` and `--version` ([docs/json.md](docs/json.md)). |

Not available on macOS, as in WSL without the matching Windows feature: `--system`, `--enable-wsl1`, `--inbox`, and WSL 1. `--import-in-place` is planned.

### Inside a distribution

```console
$ cd /mnt/mac/Users/me/src         # the Mac's filesystem (like /mnt/c)
$ mslpath -w ~/project             # a Linux path as a macOS path (like wslpath)
$ mslpath -u /Users/me/src         # and back
$ echo $MSL_DISTRO_NAME            # set instead of WSL_DISTRO_NAME
```

- **localhost:** a server listening on `localhost` in any distro is reachable at `localhost` on the Mac, over IPv4 and IPv6. Distros share one localhost, as in WSL 2.
- **DNS:** goes through macOS's own resolver, so VPNs, split DNS and `.local` names work.
- **Hostname:** the Mac's name, with a generated `/etc/hosts`.
- **Mac environment variables:** reach Linux through `MSLENV`, which works like `WSLENV`.
- **No macOS binaries:** msl never runs them from Linux. `npm`, `node-gyp` or `configure` can only find Linux toolchains, so build output is always Linux, even under `/mnt/mac`.

## VS Code and other IDEs

The MSL extension does for msl what VS Code's WSL extension does on Windows. The window runs on the Mac, while the terminal, language servers, debuggers and extensions run inside the distro.

**Why an extension is needed:** VS Code's own WSL extension runs only on Windows: it calls `wsl.exe` and uses `\\wsl$` paths. Remote-SSH would work, but it needs an SSH server in every distro and a port on the Mac. The MSL extension connects VS Code to its server in the distro through msl instead. It uses no SSH and opens no network port on the Mac. Forwarded ports work, and so does opening several distros at once.

**Why `argv.json` has to change:** connecting VS Code to a remote machine requires VS Code's remote-resolver API. VS Code keeps that API "proposed", available only to Microsoft's own remote extensions unless the user enables it for an extension. It is enabled by listing the extension under `enable-proposed-api` in `argv.json`. For the same reason the extension can't be published on the Marketplace. It ships with msl, and each version is also a [GitHub release](https://github.com/onexay/msl/releases?q=vscode) (`vscode-<version>`).

**Setting it up:** the installer does it for you, or you can run it yourself:

```console
$ msl --manage-ide                             # lists the IDEs found and asks
$ msl --manage-ide --ide vscode --install      # also vscode-insiders, vscode-oss (VSCodium), cursor, all
$ msl --manage-ide --ide all --uninstall
```

Then quit and reopen the IDE (⌘Q). In the command palette, run **MSL: Connect to Distro**, or use `code --folder-uri vscode-remote://msl+<distro>/home/<user>`. The first connection to a distro installs the VS Code Server that matches your IDE's version. It's downloaded on the Mac and cached, so the distro needs no `curl` or `wget`.

More: [extensions/vscode/README.md](extensions/vscode/README.md), including troubleshooting.

## Compatibility with WSL distributions

msl runs the images from Microsoft's WSL distribution list, unmodified. That list is what `msl --list --online` shows, and it's where `msl --install` downloads from. msl uses the arm64 variants. Tested: Ubuntu 26.04 and 24.04, and Debian 13.

| WSL feature | In msl |
|---|---|
| `.wsl` images and `wsl-distribution.conf` | Supported. The distro's own first-run setup runs as it does on Windows, and its icon is used in Finder. Debian's setup script is replaced by msl's own, because it differs only in Windows wording. |
| `/etc/wsl.conf` | Honoured. `/etc/msl.conf` takes precedence if present. Supported keys: `[boot] systemd`, `command`; `[user] default`; `[automount] enabled`, `root`, `mountFsTab`; `[network] hostname`, `generateHosts`, `generateResolvConf`. `[interop]` is ignored. |
| systemd | Yes, with `[boot] systemd=true`. Windows-only units are masked at run time. |
| `/mnt/c` | `/mnt/mac` (virtiofs). `[automount] root` changes the mount point. |
| `wslpath`, `WSLENV`, `WSL_DISTRO_NAME` | `mslpath`, `MSLENV`, `MSL_DISTRO_NAME`. WSL detection stays off, so tools don't assume Windows interop. |
| Windows interop (running `.exe` from Linux) | No, by design: nothing from macOS runs inside a distro. |
| WSLg, GPU, WSL 1, mirrored networking | No (see [Known limitations](#known-limitations)). |
| x86_64-only distributions | Not yet. `--list --online` marks them, and the untested Rosetta path works only if Rosetta is already installed. qemu-user support is planned ([Nitrogen](https://github.com/onexay/msl/milestone/7)). |

The only file msl adds to an image is the `/usr/bin/mslpath` symlink. `msl --export` writes a plain tar file, the format `wsl --import` takes.

Distros' first-run scripts sometimes mention Windows ("Provisioning the new WSL instance"). That's their stock text; the steps that need Windows are skipped.

## Configuration

- **VM:** `~/.mslconfig`, with the same sections and keys as `.wslconfig`: `memory`, `processors`, `kernel`, `kernelCommandLine`, `localhostForwarding`, `dnsTunneling`, `vmIdleTimeout`, and `[general] instanceIdleTimeout`. Changes apply at the next VM start; `msl --status` lists any that are pending.
- **Each distro:** `/etc/wsl.conf` or `/etc/msl.conf` (above).
- **Environment:** `MSLENV`, `MSL_ERROR_CODES=1` (adds wsl.exe-style `Error code:` lines), `MSL_CONFIG`, `MSL_DISTRIBUTION_LIST_URL`.

Full reference: [docs/configuration.md](docs/configuration.md).

## How it works

```
msl (CLI) ──Unix socket──▶ msld (per-user service, started on demand)
                            │ owns the VM, the registry, port forwarding, the DNS proxy,
                            │ the ~/.msl/distros NFS mounts, and connect.sock (IDE pipes)
                            │ gRPC and flow-controlled streams over vsock
                            ▼
                 One utility VM (msl kernel + initrd)
                   msl-guest as PID 1: data disk, network, NFS view, DNS stub
                     ├─ distro A init (own mount/PID/UTS/cgroup namespaces; systemd optional)
                     └─ distro B init
                   shared: network namespace (one localhost), /mnt/mac (virtiofs), /mnt/msl
```

- **Same model as WSL 2:** one VM, and one `init` per distro in its own namespaces. A distro starts in milliseconds, all distros share memory and localhost, and `--shutdown` stops everything.
- **Apple-native only:** Virtualization.framework (vmnet NAT, virtiofs, vsock, USB mass storage for `--mount`) and a kernel built from Apple's `container` configuration. No QEMU and no third-party hypervisor.
- **Guest:** one static Rust binary (`msl-guest`) is the VM's init, each distro's init and agent, `mslpath`, the NFS server and the DNS stub.

Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/design/](docs/design/).

## Known limitations

Tracked as [issues](https://github.com/onexay/msl/issues); planned work is in the [milestones](https://github.com/onexay/msl/milestones).

- **x86_64 distros:** not supported yet.
- **Memory:** returned to macOS only when the VM stops, because Virtualization.framework's balloon doesn't give pages back. `autoMemoryReclaim` has no effect.
- **Disk:** `--manage --resize` isn't supported (the shared disk is fixed at 256 GiB). `--compact` and trim on shutdown shrink `data.img`.
- **`~/.msl/distros`:** available only while the VM runs.
- **Not available:** GPU, WSLg and GUI apps, WSL 1, mirrored networking.
- **Signing:** releases aren't notarised yet.
- **Isolation:** distros are isolated by namespaces, not separate VMs (as in WSL 2).

## How msl compares

msl is the only Mac tool that is a drop-in for `wsl.exe` and runs WSL images unmodified. OrbStack is closest in design (one shared VM, full distros, Finder access) and ahead on polish, x86_64 and memory, but it's proprietary and runs Mac binaries from Linux. Apple's `container machine`, Lima, Colima, Docker Desktop, Podman, Multipass, UTM and Tart solve neighbouring problems. See [docs/comparison.md](docs/comparison.md).

## Development

```console
$ scripts/build.sh      # guest, initrd, msl/msld → build/ (downloads the kernel and VS Code extension releases)
$ swift test            # host unit tests; CONTRIBUTING.md covers the guest and e2e suites
```

Build requirements, tests, code layout and releases (msl, the kernel and the VS Code extension each have their own) are in [CONTRIBUTING.md](CONTRIBUTING.md). The documentation index is [docs/README.md](docs/README.md).

## License

msl is an independent project, not affiliated with or endorsed by Microsoft or Apple. WSL and Windows are trademarks of Microsoft Corporation; Mac and macOS are trademarks of Apple Inc.; they are used only to describe compatibility.

msl is licensed under the [Apache License 2.0](LICENSE) (see also [NOTICE](NOTICE)). Release packages include the Linux kernel and BusyBox, which are GPL-2.0 and run inside the VM as separate programs; see [third-party notices](docs/THIRD_PARTY_NOTICES.md).
