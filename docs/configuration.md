# Configuration

msl reads the same settings files as WSL: one file for the VM, one for each distro.

## VM: `~/.mslconfig`

`~/.mslconfig` is the `.wslconfig` equivalent: same keys, size suffixes and warnings. The VM section is `[msl2]`; `[wsl2]` also works, so a `.wslconfig` can be copied as is. `MSL_CONFIG` overrides the path. Unknown `.wslconfig` keys are accepted and ignored.

```ini
[msl2]
memory = 8GB                 # default: 50% of the Mac's RAM
processors = 4               # default: all
kernel = ~/kernels/Image     # custom kernel
kernelCommandLine = quiet
localhostForwarding = true   # default true
dnsTunneling = true          # default true; false uses vmnet's DNS
vmIdleTimeout = 60000        # ms; VM stops this long after the last distro stops

[general]
instanceIdleTimeout = 15000  # ms; an idle distro stops after this

[experimental]
autoMemoryReclaim = dropCache  # accepted for compatibility; no effect on macOS
```

Changes apply at the next VM start. `msl --status` shows the effective settings (memory, processors, kernel, kernel command line, localhost forwarding, DNS tunneling, idle timeouts, settings file, running/uptime) and lists any `.mslconfig` changes still pending until `msl --shutdown`.

## Per distro: `/etc/msl.conf`

msl reads `/etc/msl.conf`, falling back to `/etc/wsl.conf`, so existing distros work unchanged. Supported: `[boot] systemd`, `command`; `[user] default`; `[automount] enabled`, `root`, `mountFsTab`; `[network] hostname`, `generateHosts`, `generateResolvConf`. `[interop]` keys are parsed and ignored.

## Environment variables

- `MSLENV`: passes Mac variables into Linux (one way, with the `/p` and `/l` flags, like `WSLENV`).
- `MSL_ERROR_CODES=1`: adds wsl.exe-style `Error code:` lines to error messages.
- `MSL_DISTRIBUTION_LIST_URL`: replaces Microsoft's distribution list.
- `MSL_CONFIG`: path of the VM settings file (default `~/.mslconfig`).
