#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Download (and verify) the complete corresponding source of the GPL-2.0
# binaries msl ships, for attaching to GitHub releases:
#   kernel   dist/sources/linux-<ver>.tar.xz   (+ our config: kernel/base.config, kernel/msl.fragment)
#   busybox  dist/sources/busybox_<ver>.{dsc,orig.tar.bz2,debian.tar.xz}  (Debian source package)
#   e2fsprogs  dist/sources/e2fsprogs_<ver>.{dsc,orig.tar.gz,…}  (Debian source package; scripts/build-e2fsprogs.sh)
#   scripts/gpl-sources.sh kernel|busybox|e2fsprogs   prints the file paths
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/dist/sources
mkdir -p "$OUT"
get() { [ -s "$OUT/$1" ] || curl -fsSL -o "$OUT/$1" "$2"; }

case ${1:?usage: scripts/gpl-sources.sh kernel|busybox|e2fsprogs} in
kernel)
  V=$(sed -n 's/^# Linux\/arm64 \([^ ]*\) Kernel Configuration/\1/p' "$ROOT/kernel/out/config")
  get "linux-$V.tar.xz" "https://cdn.kernel.org/pub/linux/kernel/v${V%%.*}.x/linux-$V.tar.xz"
  get "linux-$V.sha256sums.asc" "https://cdn.kernel.org/pub/linux/kernel/v${V%%.*}.x/sha256sums.asc"
  want=$(awk -v f="linux-$V.tar.xz" '$2==f{print $1}' "$OUT/linux-$V.sha256sums.asc")
  [ "$(shasum -a 256 "$OUT/linux-$V.tar.xz" | cut -d' ' -f1)" = "$want" ] || { echo "linux-$V.tar.xz: checksum mismatch" >&2; exit 1; }
  echo "$OUT/linux-$V.tar.xz"
  ;;
busybox)
  # guest/vendor/busybox.version names the Debian binary package; "+bN" rebuilds share the source.
  PKG=$(sed 's/%3a/:/' "$ROOT/guest/vendor/busybox.version")
  V=$(echo "$PKG" | sed -E 's/^busybox-static_[0-9]+:([^+_]+).*/\1/')   # 1.37.0-6
  UP=${V%-*}
  POOL=https://deb.debian.org/debian/pool/main/b/busybox
  get "busybox_$V.dsc" "$POOL/busybox_$V.dsc"
  for f in "busybox_$UP.orig.tar.bz2" "busybox_$V.debian.tar.xz"; do
    get "$f" "$POOL/$f"
    want=$(awk -v f="$f" '/^Checksums-Sha256:/{s=1;next} /^[^ ]/{s=0} s&&$3==f{print $1}' "$OUT/busybox_$V.dsc")
    [ "$(shasum -a 256 "$OUT/$f" | cut -d' ' -f1)" = "$want" ] || { echo "$f: checksum mismatch" >&2; exit 1; }
  done
  printf '%s\n' "$OUT/busybox_$V.dsc" "$OUT/busybox_$UP.orig.tar.bz2" "$OUT/busybox_$V.debian.tar.xz"
  ;;
e2fsprogs)
  # guest/vendor/e2fsprogs.version names the Debian source package the static tools were built from.
  V=$(sed 's/^e2fsprogs_//' "$ROOT/guest/vendor/e2fsprogs.version")   # 1.47.2-3
  POOL=https://deb.debian.org/debian/pool/main/e/e2fsprogs
  get "e2fsprogs_$V.dsc" "$POOL/e2fsprogs_$V.dsc"
  echo "$OUT/e2fsprogs_$V.dsc"
  for f in $(awk '/^Checksums-Sha256:/{s=1;next} /^[^ ]/{s=0} s{print $3}' "$OUT/e2fsprogs_$V.dsc"); do
    get "$f" "$POOL/$f"
    want=$(awk -v f="$f" '/^Checksums-Sha256:/{s=1;next} /^[^ ]/{s=0} s&&$3==f{print $1}' "$OUT/e2fsprogs_$V.dsc")
    [ "$(shasum -a 256 "$OUT/$f" | cut -d' ' -f1)" = "$want" ] || { echo "$f: checksum mismatch" >&2; exit 1; }
    echo "$OUT/$f"
  done
  ;;
*) echo "usage: scripts/gpl-sources.sh kernel|busybox|e2fsprogs" >&2; exit 2 ;;
esac
