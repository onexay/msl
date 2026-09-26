# Download

msl needs Apple silicon and macOS 26 or later. Releases are on [GitHub](https://github.com/onexay/msl/releases). They're built by CI and signed ad hoc; they aren't notarised yet.

## Install msl

```console
$ curl -fsSL https://raw.githubusercontent.com/onexay/msl/main/install.sh | sh
```

The installer asks before each step: where to install (`~/.local` by default, no sudo), whether to add msl to `PATH`, whether to set up the VS Code extension, and whether to install a first distribution. [Installer details](install.md) lists its options for an unattended install and every file it creates.

To install without piping a script into `sh`, download the release by hand:

1. Open the [latest release](https://github.com/onexay/msl/releases/latest) and download `msl-<version>-macos-arm64.tar.gz` and its `.sha256` file.
2. Check the download:

    ```console
    $ shasum -a 256 -c msl-<version>-macos-arm64.tar.gz.sha256
    ```

3. Install it with the installer's `--from` option:

    ```console
    $ curl -fsSL -o install.sh https://raw.githubusercontent.com/onexay/msl/main/install.sh
    $ sh install.sh --from msl-<version>-macos-arm64.tar.gz
    ```

Update later with `msl --update`. `msl --uninstall` removes msl and undoes the IDE setup, but keeps your distributions. Before updating across a breaking change, read [Upgrading](upgrading.md).

## Install the VS Code extension

The installer sets the extension up if it finds VS Code, VS Code Insiders, VSCodium or Cursor. To do it later, or for another IDE:

```console
$ msl --manage-ide                             # lists the IDEs found and asks
$ msl --manage-ide --ide vscode --install      # also vscode-insiders, vscode-oss, cursor, all
```

Then quit and reopen the IDE (⌘Q).

The extension isn't on the Visual Studio Marketplace, because it uses VS Code's proposed remote-resolver API. Each version is a GitHub release named `vscode-<version>`. To install it by hand:

1. Download `msl-<version>.vsix` from the newest [extension release](https://github.com/onexay/msl/releases?q=vscode).
2. Install it:

    ```console
    $ code --install-extension msl-<version>.vsix
    ```

3. Run **Preferences: Configure Runtime Arguments** in VS Code, add `"enable-proposed-api": ["onexay.msl"]` to `argv.json`, save, and quit and reopen VS Code (⌘Q).

[VS Code](vscode.md) covers connecting to a distribution and troubleshooting.
