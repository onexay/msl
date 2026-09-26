# Disk and storage

All distributions live on one disk, `~/Library/Application Support/msl/data.img`. Each distribution is a directory on it, so they share its space. WSL, by contrast, gives each distribution its own `ext4.vhdx`.

`data.img` is a sparse file: macOS stores only the blocks that hold data. A disk with a 256 GB maximum takes a few gigabytes on macOS until the distributions fill it.

## Size

msl creates the disk the first time the VM starts. It's 256 GB, or the size of the macOS disk if that's smaller, so distributions are never promised more space than the Mac has. To choose the size, set `defaultVhdSize` in `~/.mslconfig` before the first start:

```ini
[msl2]
defaultVhdSize = 512GB
```

The minimum is 4 GB. The setting has no effect once `data.img` exists; grow the disk instead.

## How full it is

```console
$ msl --status
  Disk:                      257 GB max, 5.2 GB used on macOS (data.img)
  macOS free space:          243.5 GB
```

While the VM runs, a `Disk free` line also shows the space left inside the disk. Because the disk is sparse, the distributions can't see that macOS is running out of space: writes fail inside them when the macOS disk is full. `--status` warns when macOS has less than 16 GB free and less than the distributions think they have.

## Growing the disk

```console
$ msl --shutdown
$ msl --manage Ubuntu --resize 512GB
```

This grows `data.img`, and with it the space for every distribution; the distribution name is only there because WSL's command takes one. Every distribution must be stopped. msl makes the file larger, restarts the VM, checks the filesystem and grows it before mounting it. For a 256 GB disk that takes a few seconds.

The disk can't shrink, and it can't grow beyond the size of the macOS disk.

## Returning space to macOS

Deleting files in a distribution frees space inside the disk, not on macOS. msl hands freed blocks back to macOS every time the VM shuts down. To do it immediately:

```console
$ msl --manage Ubuntu --compact
```

## Moving a distribution

`msl --manage <distro> --move` isn't supported. There's no per-distribution disk to move: all of them live in `data.img`. To copy a distribution elsewhere, use `msl --export <distro> <file>` and `msl --import <name> <location> <file>`.
