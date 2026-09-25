# Troubleshooting

## Where to look

- `msl --status` shows the VM's effective settings (memory, CPUs, kernel, networking, idle timeouts) and any `~/.mslconfig` changes that are waiting for a restart.
- `msl --version` shows the msl, kernel and macOS versions.
- `~/Library/Application Support/msl/msld.log` is the service's log. `console.log` in the same folder has the VM's console output.
- `MSL_ERROR_CODES=1 msl …` adds wsl.exe-style `Error code:` lines to error messages.
- `msl --debug-shell` opens a root BusyBox shell in the utility VM itself, outside every distribution.

## Common problems

**A `~/.mslconfig` change has no effect.** Settings apply at the next VM start. `msl --status` lists changes still pending; `msl --shutdown` applies them. See [Configuration](configuration.md).

**`~/.msl/distros` is empty.** The folders there are NFS mounts that exist only while the VM runs. Starting any distribution brings them back.

**The first-run setup mentions Windows.** Some distributions' setup scripts say "Provisioning the new WSL instance" or similar. That's their stock text; msl skips the steps that need Windows.

**`data.img` stays large after deleting files.** Run `msl --manage <Distro> --compact` to return the freed space to macOS.

**A distro runs out of space.** All distros share one disk. `msl --status` shows its size and what's free. Grow it with `msl --shutdown`, then `msl --manage <Distro> --resize <size>` (for example `512GB`). If `--status` warns that the Mac is nearly full, free up space on the Mac first: the disk is sparse, so the distros can't see that the Mac has run out.

**msl uses more memory than the distributions need.** Virtualization.framework doesn't give memory back to macOS while the VM runs, so it returns only when the VM stops, either after `vmIdleTimeout` or with `msl --shutdown`. [#37](https://github.com/onexay/msl/issues/37) explains why.

**A distribution is x86_64-only.** Not supported yet: `msl --list --online` leaves these distributions out, and `msl --install` refuses them. See [Compatibility with WSL distributions](wsl_compatibility.md).

**VS Code can't connect.** See the troubleshooting section of the [extension's README](../extensions/vscode/README.md).

## Reporting a bug

Open a [bug report](https://github.com/onexay/msl/issues/new/choose) with the output of `msl --version` and `msl --status`, and the relevant lines from `msld.log` and `console.log`. Remove anything private first. Report security problems privately, as described in [SECURITY.md](../SECURITY.md).
