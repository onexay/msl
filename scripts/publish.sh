#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Package and publish msl <version> as GitHub release v<version>, marked Latest:
# tarball + .sha256 (install.sh), update.json (msl --update).
#   [MSL_GPG_KEY=<key id>] scripts/publish.sh <version> [--prerelease]
# Requires a clean, pushed tree; the release is tagged at HEAD. With
# MSL_GPG_KEY, the tarball's .sha256 is signed (.sha256.asc) for install.sh.
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

export MSL_RELEASE_BASE_URL=https://github.com/$REPO/releases/download/$TAG
export MSL_UPDATE_CHANNEL_URL=${MSL_UPDATE_CHANNEL_URL:-https://github.com/$REPO/releases/latest/download/update.json}
scripts/package.sh "$VERSION"

# The bundled kernel must be the published one.
KSUM=$(awk '$2=="Image"{print $1}' kernel/release.sha256)
[ "$(shasum -a 256 build/share/msl/Image | cut -d' ' -f1)" = "$KSUM" ] \
  || { echo "build/share/msl/Image is not $KTAG (run kernel/fetch.sh or kernel/publish.sh)" >&2; exit 1; }

# So must the bundled VS Code extension.
XSUM=$(cut -d' ' -f1 extensions/vscode/release.sha256)
[ "$(shasum -a 256 build/share/msl/msl.vsix | cut -d' ' -f1)" = "$XSUM" ] \
  || { echo "build/share/msl/msl.vsix is not $XTAG (run extensions/vscode/publish.sh, or delete extensions/vscode/dist to fetch it)" >&2; exit 1; }

# Sign the checksum with the release key (see SECURITY.md) when it's available.
SIG=
if [ -n "${MSL_GPG_KEY:-}" ]; then
  gpg --batch --yes --local-user "$MSL_GPG_KEY" --armor --detach-sign -o "dist/$NAME.sha256.asc" "dist/$NAME.sha256"
  SIG=dist/$NAME.sha256.asc
else
  echo "note: MSL_GPG_KEY not set; publishing without a signature" >&2
fi

# GPL-2.0 BusyBox (in initrd.gz): ship its corresponding source with the release.
BUSYBOX_SRC=$(scripts/gpl-sources.sh busybox | tr '\n' ' ')

set -- --repo "$REPO" --target "$(git rev-parse HEAD)" --title "msl $VERSION"
if [ "$PRE" = --prerelease ]; then set -- "$@" --prerelease; else set -- "$@" --latest; fi
gh release create "$TAG" "dist/$NAME" "dist/$NAME.sha256" $SIG dist/update.json $BUSYBOX_SRC "$@" --notes "$(cat <<NOTES
$CHANGES

Install: \`sh install.sh\` (or \`sh install.sh --version $VERSION\`). Update an existing install with \`msl --update\`.

| | |
|---|---|
| Kernel | Linux $(cat build/share/msl/kernel.version), release [\`$KTAG\`](https://github.com/$REPO/releases/tag/$KTAG) |
| VS Code extension | release [\`$XTAG\`](https://github.com/$REPO/releases/tag/$XTAG), installed by \`msl --manage-ide\` |
| Commit | $(git rev-parse --short HEAD) |
| Requires | Apple silicon, macOS 26 or later |
| GPL sources | BusyBox: the attached Debian source package \`busybox_*\`. Kernel: attached to [\`$KTAG\`](https://github.com/$REPO/releases/tag/$KTAG). |
| Signing | $( [ -n "${MSL_SIGN_IDENTITY:-}" ] && echo "Developer ID" || echo "ad-hoc (not notarised)"); checksum $( [ -n "$SIG" ] && echo "PGP-signed (\`.sha256.asc\`, see SECURITY.md)" || echo "not PGP-signed") |

\`$NAME\` SHA-256: \`$(cut -d' ' -f1 "dist/$NAME.sha256")\`
NOTES
)"
