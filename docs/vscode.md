# VS Code

The MSL extension does for msl what VS Code's WSL extension does on Windows. The VS Code window runs on macOS, while the terminal, language servers, debuggers and extensions run inside the distribution. It works with VS Code, VS Code Insiders, VSCodium and Cursor.

## Setting it up

The installer sets it up if it finds one of those IDEs. To do it yourself:

```console
$ msl --manage-ide                             # lists the IDEs found and asks
$ msl --manage-ide --ide vscode --install      # also vscode-insiders, vscode-oss, cursor, all
$ msl --manage-ide --ide all --uninstall
```

Quit and reopen the IDE afterwards (⌘Q); closing the window isn't enough. [Download](download.md#install-the-vs-code-extension) covers installing the `.vsix` by hand.

`--manage-ide --install` installs the extension with the IDE's own command-line tool, and adds `"enable-proposed-api": ["onexay.msl"]` to the IDE's `argv.json`, keeping its comments and other settings. The first change saves a backup, `argv.json.msl-backup`. `--uninstall`, and `msl --uninstall`, remove both.

## Connecting

In the command palette, run **MSL: Connect to Distro** and pick a distribution. Or open a folder directly:

```console
$ code --folder-uri vscode-remote://msl+Ubuntu/home/me/project
```

The first connection to a distribution installs the VS Code Server that matches your IDE's version, into `~/.vscode-server` in the distribution. msl downloads it on macOS and caches it in `~/Library/Caches/msl/vscode-server/` for every distribution, so the distribution needs no `curl` or `wget`.

You can have windows open on several distributions at once. Ports the distribution forwards appear in VS Code's Ports view and listen on macOS's `127.0.0.1`.

## How it connects

VS Code's WSL extension runs only on Windows, because it calls `wsl.exe`. Remote-SSH would work, but it needs an SSH server in every distribution and a network port on macOS. The MSL extension connects VS Code to its server through msld's socket and the VM's internal channel instead. It uses no SSH and opens no network port on macOS.

Connecting VS Code to a remote machine needs VS Code's remote-resolver API, which VS Code keeps "proposed": only Microsoft's own remote extensions may use it, unless the user enables it for an extension in `argv.json`. That's what `--manage-ide` changes, and it's why the extension isn't on the Marketplace.

## Which msl the extension runs

The extension looks for msl in this order:

1. The `msl.path` setting, if it's set.
2. The msl that last ran `msl --manage-ide --install`, which records its path in `~/Library/Application Support/msl/cli-path`.
3. `~/.local/bin/msl`, then `/usr/local/bin/msl`, then `PATH`.

It needs msl 0.1.3 or later.

## Troubleshooting

"No remote extension installed to resolve msl"
: The extension didn't start. The IDE's extension host log (Output › Log (Extension Host)) shows `CANNOT use API proposal: resolvers`. Run `msl --manage-ide`, or add `enable-proposed-api` to `argv.json` yourself with **Preferences: Configure Runtime Arguments**. Then quit the IDE with ⌘Q.

"msl --list --verbose --json exited with 255"
: The extension found an msl older than 0.1.3. Run `msl --manage-ide --install` with the msl you want, or set `msl.path`.

`bash: warning: setlocale: … cannot change locale` in the terminal
: The VS Code Server started without the distribution's locale, so the terminal fell back to VS Code's own. msl 0.1.9 and later start it with the locale from `/etc/default/locale`. After updating, reload the window or run `msl --shutdown`.

The extension's log is under Output › MSL.
