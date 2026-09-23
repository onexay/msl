#!/bin/sh
# Download the prebuilt MSL kernel (Image + config) from the GitHub release
# instead of building it (kernel/build.sh). Verifies against kernel/release.sha256.
# Output: kernel/out/{Image,config}
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TAG=${KERNEL_TAG:-kernel-6.18.15-msl}
REPO=${MSL_REPO:-onexay/msl}
mkdir -p "$HERE/out"
gh release download "$TAG" --repo "$REPO" --dir "$HERE/out" --pattern Image --pattern config --clobber
(cd "$HERE/out" && shasum -a 256 -c "$HERE/release.sha256")
