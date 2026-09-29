# Disk and storage

Each distribution has its own disk, like WSL's `ext4.vhdx`: a sparse ext4 image named `ext4.img` in the distribution's install location. By default that's `~/Library/Application Support/msl/distros/<id>/ext4.img`; `msl --install --location <folder>` and `msl --import <name> <folder> <file>` put it in `<folder>`.

The image is a sparse file: macOS stores only the blocks that hold data. A disk with a 256 GB maximum takes a few hundred megabytes on macOS until the distribution fills it. The filesystem's root is the distribution's root, as in WSL, so an image converted to VHDX (`qemu-img convert -O vhdx`) can be imported by WSL, and the other way round.

Distributions installed by earlier versions of msl live on the shared disk, `data.img`, until you move them (see [Moving a distribution](#moving-a-distribution)).

## How disks are attached

Virtualization.framework can't add a disk to a running VM, so msl starts the VM with 16 empty disk slots and fills them as needed: every distribution's disk when the VM starts, and a distribution's disk when you use it. With all 16 slots taken, the distribution used longest ago that isn't running gives its slot up. Only a distribution whose disk is attached appears in `~/.msl/distros`.

## Size

A new disk is 256 GB, or the size of the macOS disk if that's smaller, so a distribution is never promised more space than the Mac has. To choose the size for one distribution:

```console
$ msl --install Ubuntu --vhd-size 64GB
```

To change the default, set `defaultVhdSize` in `~/.mslconfig`:

```ini
[msl2]
defaultVhdSize = 512GB
```

The minimum is 4 GB and the maximum 4 TB.

## How full the disks are

```console
$ msl --status
  Distribution disks:        3 disks, 2.4 GB used on macOS (768 GB max)
  macOS free space:          243.5 GB
```

Because the disks are sparse, the distributions can't see that macOS is running out of space: writes fail inside them when the macOS disk is full. `--status` warns when macOS has less than 16 GB free and less than the disks can still grow by.

## Growing a disk

```console
$ msl --terminate Ubuntu
$ msl --manage Ubuntu --resize 512GB
```

The distribution must be stopped. msl makes the file larger; the VM then checks the filesystem and grows it before mounting it again, which takes a few seconds. A disk can't shrink, and it can't grow beyond the size of the macOS disk.

For a distribution still on the shared `data.img`, `--resize` grows `data.img` instead, and every distribution must be stopped (`msl --shutdown`).

## Returning space to macOS

Deleting files in a distribution frees space inside its disk, not on macOS. msl hands freed blocks back to macOS every time the VM shuts down. To do it immediately:

```console
$ msl --manage Ubuntu --compact
```

## Moving a distribution

```console
$ msl --manage Ubuntu --move /Volumes/External/Ubuntu
```

This moves `ext4.img` into the new folder (a rename on the same volume, a copy to another one) and stops the distribution first. A distribution still on the shared `data.img` gets a disk of its own in that folder: msl copies its files over and then deletes them from `data.img`.

## Disk images

```console
$ msl --export Ubuntu ubuntu.img --vhd
$ msl --import Ubuntu-2 ~/distros/ubuntu-2 ubuntu.img --vhd
$ msl --import-in-place Ubuntu-3 ~/images/ubuntu-3.img
```

- `--export --vhd` copies the distribution's disk (an instant clone on APFS). It stops the distribution first so the copy is consistent.
- `--import --vhd` copies a disk image to `ext4.img` in the install location.
- `--import-in-place` uses the image where it is.

msl's images are raw ext4, not VHDX. Convert a WSL disk first: `qemu-img convert -O raw ext4.vhdx ext4.img`. `msl --unregister` deletes the distribution's disk, as WSL does, including one imported in place.

## Durability

msl serves the disks to the VM itself, and Virtualization.framework never tells it when a distribution calls `fsync`. So msl writes like `qemu-nbd` does by default: a write is done once it's in macOS's file cache, and each disk is flushed to the SSD when it's detached, including at shutdown. When you log out, restart or shut down the Mac, msl stops the distributions and unmounts and flushes their disks first, as `msl --shutdown` does, so nothing written by then is lost.

- If msl or the VM crashes, what the distribution had written to its disk is kept: macOS still writes out its cache. As after any Linux crash, writes still in the distribution's own memory are lost; `sync` or `fsync` guards against that.
- If macOS crashes or the Mac loses power, the last writes can be lost and a distribution's filesystem can be damaged. msl checks and repairs it (`e2fsck`) the next time it attaches the disk.
- `fsync` inside a distribution doesn't guarantee the data is on the SSD. `msl --shutdown` flushes every disk; do that before relying on data surviving a power loss.
