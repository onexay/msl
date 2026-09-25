# MSL for VS Code (preview)

Opens folders inside msl distros, like the WSL extension on Windows. VS Code talks to the VS Code Server in the distro over managed pipes (msl → vsock → the server's Unix socket). It uses no SSH and opens no TCP port on the Mac. Design: [docs/design/vscode-integration.md](../../docs/design/vscode-integration.md) (option C′), milestone Sodium.

The extension uses VS Code's proposed `resolvers` API, so it isn't on the Marketplace. To try it:

```console
$ cd extensions/vscode && npm install && npm run compile && npm run package
$ code --install-extension msl-0.1.0.vsix
```

Then add `"enable-proposed-api": ["onexay.msl"]` to `~/.vscode/argv.json`, restart VS Code, and run **MSL: Connect to Distro**. You can also open `vscode-remote://msl+<distro>/home/<user>` directly.

Every connection goes through msld's `connect.sock`. With an older msld that doesn't have it, the extension falls back to one `msl -e … msl-bridge` process per connection. On first connect, the extension downloads the VS Code Server that matches your VS Code into the distro (`~/.vscode-server/bin/<commit>`, using `curl` or `wget` in the distro). The server listens on `~/.vscode-server/msl/<commit>.sock`. Forwarded ports listen on the Mac's `127.0.0.1`.

**Settings:** `msl.path` sets the `msl` binary. By default the extension uses `~/.local/bin/msl`, then `/usr/local/bin/msl`, then `PATH`.

**Licence note:** the VS Code Server is Microsoft's build, which is licensed for use with VS Code.

## Testing

`Tests/e2e/sodium.sh` covers everything below the extension: `msl-bridge`, `connect.sock`, its allowlist, and idle-timeout sessions. The extension needs a manual check. Launch an isolated VS Code so your own profile is left alone. Keep `--user-data-dir` short, because VS Code's IPC socket path must be at most 103 characters.

```console
$ code --user-data-dir /tmp/msl-vsc --extensions-dir /tmp/msl-vsc-ext --enable-proposed-api onexay.msl \
    --extensionDevelopmentPath=$PWD/extensions/vscode --folder-uri vscode-remote://msl+<distro>/home/<user>
```

- [ ] **Open:** the window connects, and the log (Output › MSL, or `exthost/onexay.msl/*.log`) shows `server at …`. No `msl` processes are running for pipes.
- [ ] **VM restart:** `msl --shutdown` while the window is open. VS Code resolves again, `resolve()` starts the distro and server, and the window reloads.
- [ ] **Forwarded port:** start a server in the distro. It's auto-forwarded, and a large download through the local port matches its hash even when read slowly (`curl … | shasum`).
- [ ] **Two distros:** windows on two distros at once, each with its own server and label.
- [ ] **Label:** the window title and remote indicator show `MSL: <distro>`.
- [ ] **Install:** install the `.vsix` into a normal profile, add `enable-proposed-api` to `~/.vscode/argv.json`, then run **MSL: Connect to Distro**.
