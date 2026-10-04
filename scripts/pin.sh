#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Pin the kernel or VS Code extension release that msl builds with and bundles.
# Writes <dir>/release.tag and <dir>/release.sha256 (the release's own
# checksums), then fetches the release and checks it. Commit both files.
# Without a tag, the repository's Latest release.
#   scripts/pin.sh kernel [v<semver>] (github.com/onexay/msl-kernel)
#   scripts/pin.sh vscode [v<semver>] (github.com/onexay/msl-vscode-extension)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case ${1:-} in
kernel) DIR=$ROOT/kernel; REPO=${MSL_KERNEL_REPO:-onexay/msl-kernel} ;;
vscode) DIR=$ROOT/extensions/vscode; REPO=${MSL_VSCODE_REPO:-onexay/msl-vscode-extension} ;;
*) echo "usage: scripts/pin.sh kernel|vscode [<tag>]" >&2; exit 2 ;;
esac
# Actions' GITHUB_TOKEN is scoped to the MSL repository, not the separate
# public kernel and extension repositories. Use their public release endpoints
# there; locally, use gh when authenticated (including for private overrides).
GH=; [ -n "${GITHUB_ACTIONS:-}" ] || { command -v gh >/dev/null && gh auth status >/dev/null 2>&1 && GH=1; }
TAG=${2:-}
if [ -z "$TAG" ]; then
  if [ -n "$GH" ]; then
    TAG=$(gh release view --repo "$REPO" --json tagName --jq .tagName)
  else
    TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/^  "tag_name": "\(.*\)",$/\1/p')
  fi
  [ -n "$TAG" ] || { echo "no Latest release in $REPO" >&2; exit 1; }
fi
if [ -n "$GH" ]; then
  gh release download "$TAG" --repo "$REPO" --pattern release.sha256 --output "$DIR/release.sha256" --clobber
else
  curl -fsSL -o "$DIR/release.sha256" "https://github.com/$REPO/releases/download/$TAG/release.sha256"
fi
echo "$TAG" > "$DIR/release.tag"
case ${1:-} in
kernel) "$ROOT/scripts/fetch-kernel.sh" >/dev/null ;;
vscode) "$ROOT/scripts/fetch-vscode.sh" >/dev/null ;;
esac
echo "pinned $TAG; commit ${DIR#"$ROOT"/}/release.tag and release.sha256"
