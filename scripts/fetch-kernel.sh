#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Download the prebuilt MSL kernel (Image + config) from the GitHub release
# (github.com/onexay/msl-kernel). The tag is kernel/release.tag;
# files are verified against kernel/release.sha256. scripts/pin.sh sets both.
# Output: kernel/out/{Image,config,kernel.version,tag}
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HERE=$ROOT/kernel
TAG=${KERNEL_TAG:-$(cat "$HERE/release.tag")}
REPO=${MSL_KERNEL_REPO:-onexay/msl-kernel}
mkdir -p "$HERE/out"
rm -f "$HERE/out/kernel.version"
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh release download "$TAG" --repo "$REPO" --dir "$HERE/out" --pattern Image --pattern config --clobber
else
  for f in Image config; do
    curl -fL# -o "$HERE/out/$f" "https://github.com/$REPO/releases/download/$TAG/$f"
  done
fi
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh release download "$TAG" --repo "$REPO" --dir "$HERE/out" --pattern kernel.version --clobber 2>/dev/null || true
else
  curl -fsSL -o "$HERE/out/kernel.version" "https://github.com/$REPO/releases/download/$TAG/kernel.version" || true
fi
(cd "$HERE/out" && shasum -a 256 -c "$HERE/release.sha256")
if [ ! -s "$HERE/out/kernel.version" ]; then
  case $TAG in
    kernel-*) echo "${TAG#kernel-}" > "$HERE/out/kernel.version" ;;
    *) echo "kernel release $TAG has no kernel.version asset" >&2; exit 1 ;;
  esac
fi
echo "$TAG" > "$HERE/out/tag"
