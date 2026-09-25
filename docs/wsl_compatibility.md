# Compatibility with WSL distributions

msl runs the images from Microsoft's WSL distribution list, unmodified. That list is what `msl --list --online` shows, and it's where `msl --install` downloads from. msl uses the arm64 variants. Tested: Ubuntu 26.04 and 24.04, and Debian 13.

| WSL feature | In msl |
|---|---|
| `.wsl` images and `wsl-distribution.conf` | Supported. The distro's own first-run setup runs as it does on Windows, and its icon is used in Finder. Debian's setup script is replaced by msl's own, because it differs only in Windows wording. |
| `/etc/wsl.conf` | Honoured. `/etc/msl.conf` takes precedence if present. Supported keys: `[boot] systemd`, `command`; `[user] default`; `[automount] enabled`, `root`, `mountFsTab`; `[network] hostname`, `generateHosts`, `generateResolvConf`. `[interop]` is ignored. |
| systemd | Yes, with `[boot] systemd=true`. Windows-only units are masked at run time. |
| `/mnt/c` | `/mnt/macos` (virtiofs). `[automount] root` changes the mount point. |
| `wslpath`, `WSLENV`, `WSL_DISTRO_NAME` | `mslpath`, `MSLENV`, `MSL_DISTRO_NAME`. WSL detection stays off, so tools don't assume Windows interop. |
| Windows interop (running `.exe` from Linux) | No, by design: nothing from macOS runs inside a distro. |
| WSLg, GPU, WSL 1, mirrored networking | No (see [Known limitations](../README.md#known-limitations)). |
| x86_64-only distributions | Not supported; deferred ([Nitrogen](https://github.com/onexay/msl/milestone/7), findings in [#40](https://github.com/onexay/msl/issues/40)). `--list --online` doesn't list them and `--install` refuses them. |

The only file msl adds to an image is the `/usr/bin/mslpath` symlink. `msl --export` writes a plain tar file, the format `wsl --import` takes.

Distros' first-run scripts sometimes mention Windows ("Provisioning the new WSL instance"). That's their stock text; the steps that need Windows are skipped.
