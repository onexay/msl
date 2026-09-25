# MSL for VS Code (preview)

Opens folders inside msl distros, like the WSL extension on Windows. VS Code talks to the VS Code Server in the distro over managed pipes (msl → vsock → the server's Unix socket). It uses no SSH and opens no TCP port on the Mac. Design: [docs/design/vscode-integration.md](../../docs/design/vscode-integration.md) (option C′), milestone Sodium.

The extension uses VS Code's proposed `resolvers` API, so it isn't on the Marketplace. To try it:

```console
$ cd extensions/vscode && npm install && npm run compile && npm run package
$ code --install-extension msl-0.1.0.vsix
```

Then add `"enable-proposed-api": ["onexay.msl"]` to `~/.vscode/argv.json`, restart VS Code, and run **MSL: Connect to Distro**. You can also open `vscode-remote://msl+<distro>/home/<user>` directly.

On first connect, the extension downloads the VS Code Server that matches your VS Code into the distro (`~/.vscode-server/bin/<commit>`, using `curl` or `wget` in the distro). The server listens on `~/.vscode-server/msl/<commit>.sock`. Forwarded ports listen on the Mac's `127.0.0.1`.

**Settings:** `msl.path` sets the `msl` binary. By default the extension uses `~/.local/bin/msl`, then `/usr/local/bin/msl`, then `PATH`.

**Licence note:** the VS Code Server is Microsoft's build, which is licensed for use with VS Code.
