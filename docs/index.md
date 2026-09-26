# Modern Subsystem for Linux

msl runs Linux distributions on macOS the way WSL runs them on Windows. The `msl` command is `wsl.exe` for macOS: same arguments, same output, same exit codes. It runs Microsoft's WSL distribution images, unmodified, in one lightweight Linux VM, using only Apple's Virtualization.framework. It needs Apple silicon and macOS 26 or later.

Teams split across Windows and macOS end up with two developer setups, two sets of docs and two sets of bugs. With WSL on Windows and msl on macOS, everyone develops in the same Linux distribution, from the same image, with the same commands, scripts and `wsl.conf`.

```console
$ msl --install Ubuntu            # an arm64 image from Microsoft's WSL distribution list
$ msl                             # a shell in the default distro, in the current macOS directory
$ msl -d Debian -u root apt update
$ msl -l -v
  NAME            STATE           VERSION
* Ubuntu          Running         2
  Debian          Stopped         2
$ python3 -m http.server 8000     # inside a distro: http://localhost:8000 on macOS
$ ls ~/.msl/distros/Ubuntu/home   # the distro's files from macOS (also in Finder › Locations)
```

[Download msl](download.md){ .md-button .md-button--primary } [Getting started](getting_started.md){ .md-button }

## What you get

- The `wsl.exe` command line, so scripts and READMEs written for WSL work with `msl`. [The msl command](cli.md) lists every option.
- Microsoft's WSL images as they are, including their own first-run setup and `/etc/wsl.conf`. Tested with Ubuntu 26.04 and 24.04, and Debian 13.
- macOS files inside Linux at `/mnt/macos`, and each distribution's files in Finder under `~/.msl/distros`. See [Files and paths](files.md).
- One shared localhost: a server in a distribution answers on `localhost` on macOS. DNS goes through macOS's resolver, so VPNs and `.local` names work. See [Networking](networking.md).
- A VS Code extension that opens folders inside a distribution, like VS Code's WSL extension on Windows. See [VS Code](vscode.md).

## How it works

`msl` talks to `msld`, a per-user service it starts on demand. `msld` runs one Linux VM. Inside it, each distribution has its own `init` in its own namespaces, as in WSL 2, so a distribution starts in milliseconds and all of them share the VM's memory and localhost. [Architecture](architecture.md) has the details.

## Known limitations

- x86_64 distributions aren't supported yet.
- Memory goes back to macOS only when the VM stops. `autoMemoryReclaim` has no effect.
- All distributions share one disk. It can grow but not shrink, and `--manage --move` isn't supported. See [Disk and storage](storage.md).
- `~/.msl/distros` is available only while the VM runs.
- There's no GPU, WSLg or GUI app support, no WSL 1 and no mirrored networking.
- Releases aren't notarised yet.
- Distributions are isolated by namespaces, not by separate VMs, as in WSL 2.

Planned work is in the [milestones](https://github.com/onexay/msl/milestones), and bugs are tracked as [issues](https://github.com/onexay/msl/issues).

msl is an independent project, not affiliated with or endorsed by Microsoft or Apple. WSL and Windows are trademarks of Microsoft Corporation; Mac and macOS are trademarks of Apple Inc. They're used here only to describe compatibility.
