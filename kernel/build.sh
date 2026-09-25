#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Build the MSL kernel inside a Linux container (Apple `container`).
# Output: kernel/out/{Image,config,tag} (tag: kernel/tag.sh for these inputs)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
VER=${KVER:-6.18.15}
mkdir -p "$HERE/out"
container run --rm --cpus 8 --memory 8g -v "$HERE:/msl" docker.io/library/debian:trixie bash -euxc "
  apt-get update -qq && apt-get install -y -qq build-essential flex bison bc libelf-dev libssl-dev curl xz-utils cpio kmod python3 >/dev/null
  cd /tmp && curl -sSfL https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$VER.tar.xz | tar xJ
  cd linux-$VER
  cp /msl/base.config .config
  scripts/kconfig/merge_config.sh -m .config /msl/msl.fragment
  make olddefconfig
  for o in USB_XHCI_PCI USB_STORAGE QUOTA NFSD BLK_DEV_DM BLK_DEV_NBD; do grep -q \"^CONFIG_\$o=y\" .config || { echo missing \$o; exit 1; }; done
  make -j8 Image
  cp arch/arm64/boot/Image /msl/out/Image
  cp .config /msl/out/config
"
"$HERE/tag.sh" > "$HERE/out/tag"
ls -la "$HERE/out"
