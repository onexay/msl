#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Build static e2fsck and resize2fs (for the initrd: mini-init grows data.img
# offline at boot) from Debian's e2fsprogs source package, inside a Linux
# container (Apple `container`). Debian ships no static resize2fs.
# Output: guest/vendor/{e2fsck,resize2fs,e2fsprogs.version,e2fsprogs.COPYRIGHT}
#   scripts/build-e2fsprogs.sh
# The source is the Debian package named in e2fsprogs.version;
# scripts/gpl-sources.sh e2fsprogs downloads it for the releases.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/guest/vendor
container system start >/dev/null 2>&1 || true
container run --rm --cpus 8 --memory 4g -v "$OUT:/out" docker.io/library/debian:trixie bash -euxc '
  apt-get update -qq && apt-get install -y -qq build-essential dpkg-dev curl pkg-config file >/dev/null
  V=$(apt-cache policy e2fsprogs | awk "/Candidate:/{print \$2}")   # e.g. 1.47.2-3+b1
  V=${V%+b*}                                                         # binNMUs share the source
  POOL=https://deb.debian.org/debian/pool/main/e/e2fsprogs
  cd /tmp && curl -fsSLO "$POOL/e2fsprogs_$V.dsc"
  for f in $(awk "/^Files:/{s=1;next} /^[^ ]/{s=0} s{print \$3}" e2fsprogs_$V.dsc); do curl -fsSLO "$POOL/$f"; done
  dpkg-source -x e2fsprogs_$V.dsc src >/dev/null   # verifies the .dsc checksums, applies Debian patches
  cd src
  ./configure -q --disable-nls --disable-fuse2fs --disable-elf-shlibs --disable-uuidd \
    --disable-debugfs --disable-imager --disable-defrag --without-libarchive LDFLAGS=-static
  make -s -j8 libs
  make -s -j8 -C e2fsck e2fsck
  make -s -j8 -C resize resize2fs
  for b in e2fsck/e2fsck resize/resize2fs; do
    strip "$b"
    file "$b" | grep -q "statically linked" || { echo "$b is not static"; exit 1; }
    cp "$b" /out/
  done
  echo "e2fsprogs_$V" > /out/e2fsprogs.version
  cp debian/copyright /out/e2fsprogs.COPYRIGHT
'
ls -la "$OUT"
