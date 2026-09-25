# Third-party components shipped with msl

msl itself is Apache-2.0 (`LICENSE`, `NOTICE`). This file is installed as `share/doc/msl/third_party_notices.md`. The full licence texts are in `licenses/` next to it:

- `licenses/rust_dependencies.txt`: every crate linked into `msl-guest`;
- `licenses/swift_dependencies.txt`: every SwiftPM package `msl` and `msld` are built from;
- `licenses/wsl_mit.txt`: Microsoft's notice for the adapted WSL strings.

Regenerate the first two with `scripts/gen-licenses.sh` after dependency changes.

| Component | Where | License | Notes |
|---|---|---|---|
| Linux kernel 6.18.15 | `share/msl/Image` | GPL-2.0 | Unmodified kernel.org `linux-6.18.15`, built with `kernel/base.config` + `kernel/msl.fragment` (`kernel/build.sh`). The source tarball and resulting config are attached to the matching `kernel-*` GitHub release. |
| BusyBox 1.37.0 (Debian `busybox-static` 1:1.37.0-6+b9) | inside `share/msl/initrd.gz` (`/bin/busybox`, for `msl --debug-shell`) | GPL-2.0 | Source: the Debian source package `busybox` 1:1.37.0-6 (`.dsc`, `.orig.tar.bz2`, `.debian.tar.xz`), attached to every msl `v*` GitHub release. Copyright file: `guest/vendor/busybox.COPYRIGHT`. |
| e2fsprogs 1.47.2 (`e2fsck`, `resize2fs`; Debian source `e2fsprogs` 1.47.2-3) | inside `share/msl/initrd.gz` (`/bin/e2fsck`, `/bin/resize2fs`, to grow the data disk at boot) | GPL-2.0 (its libraries: LGPL-2.0, BSD-3-Clause, MIT) | Built statically from the Debian source package by `scripts/build-e2fsprogs.sh`. Source: `e2fsprogs_1.47.2-3.dsc` and the files it lists, attached to every msl `v*` GitHub release. Copyright file: `guest/vendor/e2fsprogs.COPYRIGHT` (installed as `share/doc/msl/e2fsprogs.COPYRIGHT`). |
| nfsserve (adapted `mirrorfs` example) | `msl-guest` (`guest/src/nfs.rs`) | BSD-3-Clause | © XetData, © Hugging Face. Full notice in `guest/src/nfs.rs`. |
| tokio, tonic, prost, nix, tar, flate2, lzma-rs, ruzstd, tokio-vsock, … | `msl-guest` (static) | MIT and/or Apache-2.0 | See `guest/Cargo.lock`. |
| Apple Containerization (ContainerizationEXT4) | `msld` | Apache-2.0 | Formats the data disk. |
| grpc-swift-2, grpc-swift-nio-transport, grpc-swift-protobuf, SwiftNIO, swift-protobuf | `msld` | Apache-2.0 | |
| Microsoft WSL strings | CLI messages (`Sources/MSLCore/Messages.swift`) | MIT | Wording adapted from `localization/strings/en-US/Resources.resw` in github.com/microsoft/WSL. Copyright (c) Microsoft Corporation; full notice in `licenses/wsl_mit.txt`. |

Distribution images are downloaded from their publishers (Microsoft's `DistributionInfo.json`) and are not redistributed by msl.

GPL source for the kernel, BusyBox and e2fsprogs is attached to the GitHub releases; `scripts/gpl-sources.sh` downloads and verifies it, and both publish scripts attach it automatically.
