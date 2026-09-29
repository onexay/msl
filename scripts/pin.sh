#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Pin the kernel or VS Code extension release that msl builds with and bundles.
# Writes <dir>/release.tag and <dir>/release.sha256 (the release's own
# checksums), then fetches the release and checks it. Commit both files.
#   scripts/pin.sh kernel kernel-<linux>-msl-<hash>   (github.com/onexay/msl-kernel)
#   scripts/pin.sh vscode vscode-<version>            (github.com/onexay/msl-vscode-extension)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case ${1:-} in
kernel) DIR=$ROOT/kernel; REPO=${MSL_KERNEL_REPO:-onexay/msl-kernel} ;;
vscode) DIR=$ROOT/extensions/vscode; REPO=${MSL_VSCODE_REPO:-onexay/msl-vscode-extension} ;;
*) echo "usage: scripts/pin.sh kernel|vscode <tag>" >&2; exit 2 ;;
esac
TAG=${2:?usage: scripts/pin.sh kernel|vscode <tag>}
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh release download "$TAG" --repo "$REPO" --pattern release.sha256 --output "$DIR/release.sha256" --clobber
else
  curl -fsSL -o "$DIR/release.sha256" "https://github.com/$REPO/releases/download/$TAG/release.sha256"
fi
echo "$TAG" > "$DIR/release.tag"
"$DIR/fetch.sh" >/dev/null
echo "pinned $TAG; commit ${DIR#"$ROOT"/}/release.tag and release.sha256"
