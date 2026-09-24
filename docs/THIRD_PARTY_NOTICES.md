# Third-party components shipped with msl

msl itself is Apache-2.0 (`LICENSE`, `NOTICE`). This file is installed as `share/doc/msl/THIRD_PARTY_NOTICES.md`. The full licence texts are in `licenses/` next to it:

- `licenses/rust-dependencies.txt`: every crate linked into `msl-guest`;
- `licenses/swift-dependencies.txt`: every SwiftPM package `msl` and `msld` are built from;
- `licenses/WSL-MIT.txt`: Microsoft's notice for the adapted WSL strings.

Regenerate the first two with `scripts/gen-licenses.sh` after dependency changes.

| Component | Where | License | Notes |
|---|---|---|---|
| Linux kernel 6.18.15 | `share/msl/Image` | GPL-2.0 | Source: kernel.org `linux-6.18.15` plus `kernel/base.config` and `kernel/msl.fragment` from this repository (`kernel/build.sh` reproduces the build). |
| BusyBox 1.37.0 (Debian `busybox-static` 1:1.37.0-6+b9) | inside `share/msl/initrd.gz` (`/bin/busybox`, for `msl --debug-shell`) | GPL-2.0 | Source: the Debian source package `busybox` 1:1.37.0-6. Copyright file: `guest/vendor/busybox.COPYRIGHT`. |
| nfsserve (adapted `mirrorfs` example) | `msl-guest` (`guest/src/nfs.rs`) | BSD-3-Clause | © XetData, © Hugging Face. Full notice in `guest/src/nfs.rs`. |
| tokio, tonic, prost, nix, tar, flate2, lzma-rs, ruzstd, tokio-vsock, … | `msl-guest` (static) | MIT and/or Apache-2.0 | See `guest/Cargo.lock`. |
| Apple Containerization (ContainerizationEXT4) | `msld` | Apache-2.0 | Formats the data disk. |
| grpc-swift-2, grpc-swift-nio-transport, grpc-swift-protobuf, SwiftNIO, swift-protobuf | `msld` | Apache-2.0 | |
| Microsoft WSL strings | CLI messages (`Sources/MSLCore/Messages.swift`) | MIT | Wording adapted from `localization/strings/en-US/Resources.resw` in github.com/microsoft/WSL. Copyright (c) Microsoft Corporation; full notice in `licenses/WSL-MIT.txt`. |

Distribution images are downloaded from their publishers (Microsoft's `DistributionInfo.json`) and are not redistributed by msl.
