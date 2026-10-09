#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Publish the next MSL version as GitHub release v<version>, marked Latest: tarball +
# .sha256 (install.sh), update.json (msl --update).
#   [MSL_GPG_KEY=<key id>] scripts/publish.sh [--prerelease]
# Requires a clean, pushed tree and Xcode matching msl's minimum macOS. It
# resolves the Latest kernel and extension releases, builds them into the MSL
# package, and publishes that package from HEAD. With MSL_GPG_KEY, the
# tarball's .sha256 is signed (.sha256.asc) for install.sh.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
PRE=${1:-}
[ -z "$PRE" ] || [ "$PRE" = --prerelease ] || { echo "usage: scripts/publish.sh [--prerelease]" >&2; exit 2; }
VERSION=$(python3 scripts/next-version.py)
REPO=${MSL_REPO:-onexay/msl}
TAG=v$VERSION
NAME=msl-$VERSION-macos-arm64.tar.gz

# Check that the repository's source version files agree.
scripts/check-version.sh >/dev/null

[ -z "$(git status --porcelain)" ] || { echo "commit your changes first" >&2; exit 1; }
git fetch -q origin main --tags && [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "release HEAD must match origin/main" >&2; exit 1; }

HEAD=$(git rev-parse HEAD)

if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "$TAG already exists" >&2
  exit 1
fi

# Resolve GitHub's Latest releases now, not the repository's previously saved pins.
scripts/pin.sh kernel
scripts/pin.sh vscode
KTAG=$(cat kernel/release.tag)
XTAG=$(cat extensions/vscode/release.tag)

MIN=$(sed -n 's/.*\.macOS("\([0-9]*\)\..*/\1/p' Package.swift)
XCODE=$(xcodebuild -version | head -1)
printf '%s\n' "$XCODE" | grep -q "^Xcode $MIN\." || { echo "selected $XCODE, need Xcode $MIN" >&2; exit 1; }
MSL_RELEASE_BASE_URL="https://github.com/$REPO/releases/download/$TAG" \
MSL_UPDATE_CHANNEL_URL="https://github.com/$REPO/releases/latest/download/update.json" \
MSL_BUILD_COMMIT="$(git rev-parse --short=7 HEAD)" \
  scripts/package.sh "$VERSION"
{
  echo "commit $HEAD"
  echo "version $VERSION"
  echo "$XCODE"
  swift --version 2>&1 | head -1
  echo "kernel $KTAG"
  echo "vscode $XTAG"
} > dist/build-info.txt
(cd dist && shasum -a 256 -c "$NAME.sha256" >/dev/null) || { echo "$NAME doesn't match its .sha256" >&2; exit 1; }
grep -q "$(cut -d' ' -f1 "dist/$NAME.sha256")" dist/update.json || { echo "update.json doesn't name $NAME's checksum" >&2; exit 1; }

# The bundled kernel and VS Code extension must be the published ones.
PKG=dist/unpacked && rm -rf "$PKG" && mkdir -p "$PKG"
tar -xzf "dist/$NAME" -C "$PKG" "msl-$VERSION/share/msl/Image" "msl-$VERSION/share/msl/msl.vsix" "msl-$VERSION/share/msl/kernel.version"
KSUM=$(awk '$2=="Image"{print $1}' kernel/release.sha256)
[ "$(shasum -a 256 "$PKG/msl-$VERSION/share/msl/Image" | cut -d' ' -f1)" = "$KSUM" ] \
  || { echo "the packaged kernel does not match Latest release $KTAG" >&2; exit 1; }
XSUM=$(cut -d' ' -f1 extensions/vscode/release.sha256)
[ "$(shasum -a 256 "$PKG/msl-$VERSION/share/msl/msl.vsix" | cut -d' ' -f1)" = "$XSUM" ] \
  || { echo "the packaged msl.vsix does not match Latest release $XTAG" >&2; exit 1; }

# Sign the checksum with the release key (see SECURITY.md) when it's available.
SIG=
if [ -n "${MSL_GPG_KEY:-}" ]; then
  gpg --batch --yes --local-user "$MSL_GPG_KEY" --armor --detach-sign -o "dist/$NAME.sha256.asc" "dist/$NAME.sha256"
  SIG=dist/$NAME.sha256.asc
else
  echo "note: MSL_GPG_KEY not set; publishing without a signature" >&2
fi

# GPL-2.0 BusyBox and e2fsprogs (in initrd.gz): ship their corresponding source with the release.
BUSYBOX_SRC=$(scripts/gpl-sources.sh busybox | tr '\n' ' ')
E2FS_SRC=$(scripts/gpl-sources.sh e2fsprogs | tr '\n' ' ')

set -- --repo "$REPO" --target "$(git rev-parse HEAD)" --title "$TAG"
if [ "$PRE" = --prerelease ]; then set -- "$@" --prerelease; else set -- "$@" --latest; fi
gh release create "$TAG" \
  "dist/$NAME" "dist/$NAME.sha256" $SIG dist/update.json $BUSYBOX_SRC $E2FS_SRC \
  "$@" --generate-notes
