#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Publish msl <version> as GitHub release v<version>, marked Latest: tarball +
# .sha256 (install.sh), update.json (msl --update).
#   [MSL_GPG_KEY=<key id>] scripts/publish.sh <version> [--prerelease]
# Requires a clean, pushed tree; the release is tagged at HEAD. The package is
# not built here: it's the "package" artifact of HEAD's successful CI run,
# built with the Xcode that matches msl's minimum macOS (a newer local Xcode
# produces binaries that don't start there). With MSL_GPG_KEY, the tarball's
# .sha256 is signed (.sha256.asc) for install.sh.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
VERSION=${1:?usage: scripts/publish.sh <version> [--prerelease]}
PRE=${2:-}
REPO=${MSL_REPO:-onexay/msl}
TAG=v$VERSION
NAME=msl-$VERSION-macos-arm64.tar.gz
KTAG=$(cat kernel/release.tag)
XTAG=$(cat extensions/vscode/release.tag)

# The tree must already be at this version (scripts/set-version.sh).
scripts/check-version.sh >/dev/null
[ "$(cat VERSION)" = "$VERSION" ] || { echo "VERSION is $(cat VERSION), not $VERSION: run scripts/set-version.sh $VERSION and commit" >&2; exit 1; }

# CHANGELOG.md must have a section for this version (moved out of Unreleased).
CHANGES=$(awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {s=1; next} /^## \[/ {s=0} /^\[.*\]: / {s=0} s' CHANGELOG.md)
[ -n "$(printf '%s' "$CHANGES" | tr -d '[:space:]')" ] || { echo "CHANGELOG.md has no section for $VERSION" >&2; exit 1; }

[ -z "$(git status --porcelain)" ] || { echo "commit your changes first" >&2; exit 1; }
git fetch -q origin && [ "$(git rev-parse HEAD)" = "$(git rev-parse "@{u}")" ] || { echo "push HEAD first" >&2; exit 1; }

# The package: CI's artifact for exactly this commit.
HEAD=$(git rev-parse HEAD)
RUN=$(gh run list --repo "$REPO" --workflow ci.yml --commit "$HEAD" --status success --json databaseId --jq '.[0].databaseId')
[ -n "$RUN" ] || { echo "no successful CI run for $HEAD yet (gh run list --workflow ci.yml)" >&2; exit 1; }
rm -rf dist/ci && gh run download "$RUN" --repo "$REPO" --name package --dir dist/ci
for f in "$NAME" "$NAME.sha256" update.json build-info.txt; do
  [ -f "dist/ci/$f" ] || { echo "CI run $RUN has no $f (was VERSION $VERSION when it ran?)" >&2; exit 1; }
done
grep -qx "commit $HEAD" dist/ci/build-info.txt || { echo "CI artifact is not from $HEAD" >&2; exit 1; }
MIN=$(sed -n 's/.*\.macOS("\([0-9]*\)\..*/\1/p' Package.swift)
grep -q "^Xcode $MIN\." dist/ci/build-info.txt || { echo "CI built with $(grep ^Xcode dist/ci/build-info.txt), not Xcode $MIN" >&2; exit 1; }
(cd dist/ci && shasum -a 256 -c "$NAME.sha256" >/dev/null) || { echo "$NAME doesn't match its .sha256" >&2; exit 1; }
grep -q "$(cut -d' ' -f1 "dist/ci/$NAME.sha256")" dist/ci/update.json || { echo "update.json doesn't name $NAME's checksum" >&2; exit 1; }
cp "dist/ci/$NAME" "dist/ci/$NAME.sha256" dist/ci/update.json dist/
echo "package from CI run $RUN: $(grep ^Xcode dist/ci/build-info.txt), $(grep -i swift dist/ci/build-info.txt | cut -c1-40)"

# The bundled kernel and VS Code extension must be the published ones.
PKG=dist/ci/unpacked && rm -rf "$PKG" && mkdir -p "$PKG"
tar -xzf "dist/$NAME" -C "$PKG" "msl-$VERSION/share/msl/Image" "msl-$VERSION/share/msl/msl.vsix" "msl-$VERSION/share/msl/kernel.version"
KSUM=$(awk '$2=="Image"{print $1}' kernel/release.sha256)
[ "$(shasum -a 256 "$PKG/msl-$VERSION/share/msl/Image" | cut -d' ' -f1)" = "$KSUM" ] \
  || { echo "the packaged kernel is not $KTAG (run kernel/publish.sh, commit, and let CI rebuild)" >&2; exit 1; }
XSUM=$(cut -d' ' -f1 extensions/vscode/release.sha256)
[ "$(shasum -a 256 "$PKG/msl-$VERSION/share/msl/msl.vsix" | cut -d' ' -f1)" = "$XSUM" ] \
  || { echo "the packaged msl.vsix is not $XTAG (run extensions/vscode/publish.sh)" >&2; exit 1; }

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

set -- --repo "$REPO" --target "$(git rev-parse HEAD)" --title "msl $VERSION"
if [ "$PRE" = --prerelease ]; then set -- "$@" --prerelease; else set -- "$@" --latest; fi
gh release create "$TAG" "dist/$NAME" "dist/$NAME.sha256" $SIG dist/update.json $BUSYBOX_SRC $E2FS_SRC "$@" --notes "$(cat <<NOTES
$CHANGES

Install: \`sh install.sh\` (or \`sh install.sh --version $VERSION\`). Update an existing install with \`msl --update\`.

| | |
|---|---|
| Kernel | Linux $(cat "$PKG/msl-$VERSION/share/msl/kernel.version"), release [\`$KTAG\`](https://github.com/$REPO/releases/tag/$KTAG) |
| VS Code extension | release [\`$XTAG\`](https://github.com/$REPO/releases/tag/$XTAG), installed by \`msl --manage-ide\` |
| Commit | $(git rev-parse --short HEAD) |
| Requires | Apple silicon, macOS 26 or later |
| GPL sources | BusyBox and e2fsprogs: the attached Debian source packages \`busybox_*\` and \`e2fsprogs_*\`. Kernel: attached to [\`$KTAG\`](https://github.com/$REPO/releases/tag/$KTAG). |
| Built by | CI run [$RUN](https://github.com/$REPO/actions/runs/$RUN), $(grep ^Xcode dist/ci/build-info.txt) |
| Signing | ad-hoc (not notarised); checksum $( [ -n "$SIG" ] && echo "PGP-signed (\`.sha256.asc\`, see SECURITY.md)" || echo "not PGP-signed") |

\`$NAME\` SHA-256: \`$(cut -d' ' -f1 "dist/$NAME.sha256")\`
NOTES
)"
