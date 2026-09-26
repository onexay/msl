# Upgrading

`msl --update` installs the latest release in place and keeps your distributions and settings. This page lists the changes that can break a script or a habit, newest first. The [changelog](project/changelog.md) has everything else.

## 0.1.10: reinstall on macOS 26 if you have 0.1.9

msl 0.1.9 was built with an Xcode newer than msl's minimum macOS, and its `msld` doesn't start on macOS 26 (a missing Swift library). If you installed 0.1.9 on macOS 26, reinstall with the one-line installer from [Download](download.md). Your distributions are kept. On macOS 27, `msl --update` is enough.

## 0.1.7: `/mnt/mac` is now `/mnt/macos`

| Before 0.1.7 | From 0.1.7 |
|---|---|
| macOS files at `/mnt/mac` | `/mnt/macos` |
| under `[automount] root=/`: `/mac` | `/macos` |
| `MSL_MAC_USER`, `MSL_MAC_HOME`, `MSL_MAC_VIEW` | `MSL_MACOS_USER`, `MSL_MACOS_HOME`, `MSL_MACOS_VIEW` |
| `msl --version --json`: key `macOS` | key `macos` |

Update scripts, shell profiles and editor settings that use the old paths or names. There's no compatibility link from `/mnt/mac`.

## 0.1.6: `--manage --move` is refused

`msl --manage <distro> --move <location>` used to report success without moving anything, because every distribution lives on the one shared disk. It now fails with "not supported". See [Disk and storage](storage.md).

The VM section of `~/.mslconfig` is now `[msl2]`. `[wsl2]` still works, so a copied `.wslconfig` needs no change.

## 0.1.4: the file view moved to `~/.msl/distros`

Distribution files on macOS moved from `~/MSL/<distro>` to `~/.msl/distros/<distro>`. `msld` unmounts old `~/MSL` mounts when it starts and removes `~/MSL` if it's empty. Finder still lists each distribution under Locations. `MSL_VIEW_DIR` still overrides the location.
