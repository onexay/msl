#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Download the published MSL VS Code extension (the release named in
# release.tag, from github.com/onexay/msl-vscode-extension) and verify it
# against release.sha256. scripts/pin.sh sets both. scripts/build.sh uses it,
# like scripts/fetch-kernel.sh, so building msl needs no Node.
# Output: extensions/vscode/dist/msl-<version>.vsix
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HERE=$ROOT/extensions/vscode
TAG=${VSCODE_EXT_TAG:-$(cat "$HERE/release.tag")}
REPO=${MSL_VSCODE_REPO:-onexay/msl-vscode-extension}
case $TAG in
  vscode-*) VERSION=${TAG#vscode-} ;; # legacy release tags
  v*) VERSION=${TAG#v} ;;
  *) echo "invalid VS Code extension release tag: $TAG" >&2; exit 1 ;;
esac
FILE=msl-$VERSION.vsix
mkdir -p "$HERE/dist"
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh release download "$TAG" --repo "$REPO" --dir "$HERE/dist" --pattern "$FILE" --clobber
else
  curl -fL# -o "$HERE/dist/$FILE" "https://github.com/$REPO/releases/download/$TAG/$FILE"
fi
(cd "$HERE/dist" && shasum -a 256 -c "$HERE/release.sha256")
