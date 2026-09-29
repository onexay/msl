#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Download the published MSL VS Code extension (the release named in
# release.tag, from github.com/onexay/msl-vscode-extension) and verify it
# against release.sha256. scripts/pin.sh sets both. scripts/build.sh uses it,
# like kernel/fetch.sh, so building msl needs no Node.
# Output: extensions/vscode/dist/msl-<version>.vsix
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TAG=${VSCODE_EXT_TAG:-$(cat "$HERE/release.tag")}
REPO=${MSL_VSCODE_REPO:-onexay/msl-vscode-extension}
FILE=msl-${TAG#vscode-}.vsix
mkdir -p "$HERE/dist"
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh release download "$TAG" --repo "$REPO" --dir "$HERE/dist" --pattern "$FILE" --clobber
else
  curl -fL# -o "$HERE/dist/$FILE" "https://github.com/$REPO/releases/download/$TAG/$FILE"
fi
(cd "$HERE/dist" && shasum -a 256 -c "$HERE/release.sha256")
