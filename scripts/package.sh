#!/bin/sh
# Build a release: dist/msl-<version>-macos-arm64.tar.gz (+ .sha256, for
# install.sh), dist/msl-<version>.pkg and dist/update.json (for `msl --update`).
#
#   scripts/package.sh [version]
#
# Environment (all optional):
#   MSL_SIGN_IDENTITY       "Developer ID Application: …" (else ad-hoc signing)
#   MSL_INSTALLER_IDENTITY  "Developer ID Installer: …" to sign the .pkg
#   MSL_RELEASE_BASE_URL    where the tarball will be hosted (default: file://$PWD/dist)
#   MSL_UPDATE_CHANNEL_URL  URL of update.json, baked into msl for `msl --update`
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
VFILE=Sources/MSLCore/Version.swift
VERSION=${1:-$(sed -n 's/.*static let version = "\(.*\)"/\1/p' "$VFILE")}
BASE_URL=${MSL_RELEASE_BASE_URL:-file://$ROOT/dist}
CHANNEL=${MSL_UPDATE_CHANNEL_URL:-}

# Stamp version and update channel for this build only.
cp "$VFILE" "$VFILE.orig"
trap 'mv -f "$VFILE.orig" "$VFILE"' EXIT
sed -i '' -e "s|static let version = \".*\"|static let version = \"$VERSION\"|" \
          -e "s|static let updateURL = \".*\"|static let updateURL = \"$CHANNEL\"|" "$VFILE"
scripts/build.sh

NAME=msl-$VERSION
STAGE=dist/stage/$NAME
rm -rf "$STAGE" && mkdir -p "$STAGE/bin" "$STAGE/libexec/msl" "$STAGE/share/msl" "$STAGE/share/doc/msl"
cp build/bin/msl "$STAGE/bin/msl"
cp build/bin/msld "$STAGE/libexec/msl/msld"
cp build/share/msl/Image build/share/msl/initrd.gz build/share/msl/kernel.version "$STAGE/share/msl/"
cp LICENSE NOTICE docs/THIRD_PARTY_NOTICES.md guest/vendor/busybox.COPYRIGHT "$STAGE/share/doc/msl/"

if [ -n "${MSL_SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp -s "$MSL_SIGN_IDENTITY" "$STAGE/bin/msl"
  codesign --force --options runtime --timestamp --entitlements msld.entitlements -s "$MSL_SIGN_IDENTITY" "$STAGE/libexec/msl/msld"
fi
codesign -v "$STAGE/bin/msl" "$STAGE/libexec/msl/msld"

# No extended attributes (e.g. com.apple.provenance) in the payload: they'd turn
# into AppleDouble ._ files in the tarball and the .pkg.
xattr -cr "$STAGE"
export COPYFILE_DISABLE=1

TARBALL=dist/$NAME-macos-arm64.tar.gz
tar -C dist/stage -czf "$TARBALL" "$NAME"
SHA=$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)
echo "$SHA  $NAME-macos-arm64.tar.gz" > "$TARBALL.sha256"

PKG=dist/$NAME.pkg
set -- --root "$STAGE" --identifier dev.msl.msl --version "$VERSION" --install-location /usr/local
[ -n "${MSL_INSTALLER_IDENTITY:-}" ] && set -- "$@" --sign "$MSL_INSTALLER_IDENTITY"
pkgbuild "$@" "$PKG" >/dev/null

cat > dist/update.json <<JSON
{
  "channels": {
    "stable": { "version": "$VERSION", "url": "$BASE_URL/$NAME-macos-arm64.tar.gz", "sha256": "$SHA" }
  }
}
JSON


echo "version  $VERSION"
echo "tarball  $TARBALL  sha256 $SHA (+ .sha256)"
echo "pkg      $PKG"
echo "update   dist/update.json"
[ -z "${MSL_SIGN_IDENTITY:-}" ] && echo "note     ad-hoc signed; set MSL_SIGN_IDENTITY and run scripts/notarize.sh for distribution"
exit 0
