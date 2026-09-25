# Getting started

This page takes you from installing msl to a shell in Ubuntu and a VS Code window open inside it. You need macOS 26 or later on Apple silicon.

## 1. Install msl

```console
$ curl -fsSL https://raw.githubusercontent.com/onexay/msl/main/install.sh | sh
```

The installer asks before each step:

1. Where to install. The default, `~/.local`, needs no sudo.
2. Whether to add msl to `PATH` in your shell's startup file. Open a new terminal afterwards so the change applies.
3. Whether to set up the MSL extension, if it finds VS Code, VS Code Insiders, VSCodium or Cursor.
4. Whether to install a Linux distribution now. It lists what's available and suggests Ubuntu.

If you said yes to the last step, skip to step 3. [Installing msl](install.md) lists the installer's options and every file it creates.

## 2. Install a distribution

```console
$ msl --list --online      # distributions you can install: Microsoft's WSL list, arm64 images
$ msl --install Ubuntu
```

msl downloads the image and runs the distribution's own first-run setup, which asks you to create a Linux user. Some setup scripts mention Windows ("Provisioning the new WSL instance"). That's their stock text, and msl skips the steps that need Windows.

## 3. Open a shell

```console
$ msl
```

This opens a shell in your default distribution. It starts in the macOS directory you ran `msl` from, which Linux sees under `/mnt/macos`. To run one command instead:

```console
$ msl uname -a                 # through the shell
$ msl -e uname -m              # without a shell; the exit code is passed through
$ msl --cd ~ -- make test      # starting in your Linux home directory
```

`msl -l -v` lists your distributions and whether they're running. If you install more than one, `-d <Distro>` picks one and `msl -s <Distro>` changes the default.

## 4. Share files and ports with macOS

From Linux, macOS files are under `/mnt/macos`, as `C:` is under `/mnt/c` in WSL. `mslpath` converts between the two kinds of path:

```console
$ mslpath -w ~/project        # a Linux path as a macOS path
$ mslpath -u /Users/me/src    # and back
```

From macOS, each distribution's files are in `~/.msl/distros/<distro>` and in Finder under Locations, while the VM runs.

A server listening on `localhost` in a distribution is reachable at `localhost` on macOS:

```console
$ python3 -m http.server 8000      # inside the distro; open http://localhost:8000 on macOS
```

## 5. Open the distribution in VS Code

If the installer set up the extension, quit and reopen VS Code (⌘Q), then run **MSL: Connect to Distro** from the command palette. If it didn't, run `msl --manage-ide` first. The first connection installs the VS Code Server in the distribution. After that, the terminal, language servers, debuggers and extensions run in Linux, while the window stays on macOS.

See [VS Code and other IDEs](../README.md#vs-code-and-other-ides) for how the extension works and why it changes `argv.json`.

## 6. Stop it

You rarely need to. An idle distribution stops after 15 seconds, and the VM stops 60 seconds after the last distribution does. To stop everything now:

```console
$ msl --shutdown
```

Your distributions and their files stay on disk.

## Next

- [The msl command](cli.md): every command and option
- [Configuration](configuration.md): memory, CPUs and other VM settings in `~/.mslconfig`, and `/etc/wsl.conf` in each distribution
- [Troubleshooting](troubleshooting.md)
