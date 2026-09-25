# Installing msl

msl needs Apple silicon and macOS 26 or later.

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
| VS Code extension | Each IDE's extensions folder (VS Code, Insiders, VSCodium, Cursor) | Opens folders inside distros ([VS Code](../README.md#vs-code-and-other-ides)) | `msl --manage-ide --ide all --uninstall`, or `msl --uninstall` |
| `enable-proposed-api` | Each IDE's `argv.json` (for example `~/.vscode/argv.json`). The first change saves a backup, `argv.json.msl-backup`. | The extension needs VS Code's proposed remote-resolver API | Same as above; the entry is removed and the file restored |
| Which msl the extension runs | `~/Library/Application Support/msl/cli-path` | So the extension finds msl wherever it's installed | Same as above |

Created on first use, not by the installer:

| What | Where |
|---|---|
| Distributions and state | `~/Library/Application Support/msl/`: `data.img` (one sparse disk for all distros, 256 GiB maximum), `registry.json`, `msld.log`, and the sockets `msld.sock` and `connect.sock` |
| Distribution files in Finder | `~/.msl/distros/<distro>`: NFS mounts that exist while the VM runs |
| Downloads | `~/Library/Caches/msl/`: distribution images, and the VS Code Server for your IDE's version |
| VM settings | `~/.mslconfig`, only if you create it ([Configuration](configuration.md)) |

msl doesn't install a LaunchAgent, a kernel extension or a login item, and it never asks for administrator rights except to install into a system prefix. `msld` starts when you first run `msl`, and stops the VM after `vmIdleTimeout` (60 s by default) with nothing running.
