#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Build the MSL kernel inside a Linux container (Apple `container`), for local
# testing. Releases are built by CI (.github/workflows/kernel.yml) and published
# with kernel/publish.sh. Both run kernel/build-linux.sh.
# Output: kernel/out/{Image,config,tag} (tag: kernel/tag.sh for these inputs)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
VER=${KVER:-6.18.15}
mkdir -p "$HERE/out"
container system start >/dev/null 2>&1 || true
container run --rm --cpus 8 --memory 8g -v "$HERE:/msl" docker.io/library/debian:trixie bash -euc "
  apt-get update -qq && apt-get install -y -qq build-essential flex bison bc libelf-dev libssl-dev curl xz-utils cpio kmod python3 >/dev/null
  /msl/build-linux.sh /msl /msl/out $VER
"
ls -la "$HERE/out"
