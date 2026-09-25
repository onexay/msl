# The msl command

`msl` accepts `wsl.exe`'s arguments and prints the same messages. Anything that works with `wsl.exe` in a script or a README should work with `msl`. This is `msl --help`:

## `msl --help`

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

## Running Linux

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

## Installing and managing distributions

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
| `msl --manage <Distro> --move <location>` | Not supported: every distro lives on the shared disk, so there's no per-distro file to move. |
| `msl --manage <Distro> --resize <size>` | Not supported yet ([#3](https://github.com/onexay/msl/issues/3)): the shared disk is fixed at 256 GiB. |
| `msl --manage <Distro> --set-sparse <bool>` | Accepted; the disk is always sparse. |
| `msl --set-version <Distro> 2`, `msl --set-default-version 2` | Accepted. Version 1 isn't available on macOS. |

## The VM, updates and msl's own additions

| Command | What it does |
|---|---|
| `msl --status [--json]` | The default distro, plus the VM's effective settings (memory, CPUs, kernel, networking, idle timeouts) and any `.mslconfig` changes waiting for a restart. |
| `msl --version [--json]` | msl, kernel and macOS versions. |
| `msl --mount <image> [--name <n>] [--type <fs>] [--options <o>] [--partition <n>] [--bare]` | Attaches a disk image to the VM, mounted at `/mnt/msl/<name>` in every distro. `--vhd` is accepted. `msl --unmount [<image>]` detaches it. |
| `msl --update [--pre-release]` | Updates msl in place from the latest release. Distributions are kept. |
| `msl --uninstall` | Removes msl and undoes the IDE setup. Distributions and settings stay in `~/Library/Application Support/msl`. |
| `msl --manage-ide` | Sets up the VS Code extension ([VS Code](../README.md#vs-code-and-other-ides)). |
| `msl --debug-shell` | A root BusyBox shell in the utility VM itself, outside every distro. |
| `--json` | Machine-readable output for `--list`, `--list --online`, `--status` and `--version` ([JSON output](json.md)). |

Not available on macOS, as in WSL without the matching Windows feature: `--system`, `--enable-wsl1`, `--inbox`, and WSL 1. `--import-in-place` is planned.

## Inside a distribution

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
