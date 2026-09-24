#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Download the prebuilt MSL kernel (Image + config) from the GitHub release
# instead of building it (kernel/build.sh). The tag is kernel/release.tag;
# files are verified against kernel/release.sha256.
# Output: kernel/out/{Image,config}
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TAG=${KERNEL_TAG:-$(cat "$HERE/release.tag")}
REPO=${MSL_REPO:-onexay/msl}
mkdir -p "$HERE/out"
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh release download "$TAG" --repo "$REPO" --dir "$HERE/out" --pattern Image --pattern config --clobber
else
  for f in Image config; do
    curl -fL# -o "$HERE/out/$f" "https://github.com/$REPO/releases/download/$TAG/$f"
  done
fi
(cd "$HERE/out" && shasum -a 256 -c "$HERE/release.sha256")
