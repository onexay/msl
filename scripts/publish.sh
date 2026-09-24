#!/bin/sh
# Package and publish msl <version> as GitHub release v<version>, marked Latest:
# tarball + .sha256 (install.sh), .pkg, update.json (msl --update).
#   scripts/publish.sh <version> [--prerelease]
# Requires a clean, pushed tree; the release is tagged at HEAD.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
VERSION=${1:?usage: scripts/publish.sh <version> [--prerelease]}
PRE=${2:-}
REPO=${MSL_REPO:-onexay/msl}
TAG=v$VERSION
NAME=msl-$VERSION-macos-arm64.tar.gz
KTAG=$(cat kernel/release.tag)

[ -z "$(git status --porcelain)" ] || { echo "commit your changes first" >&2; exit 1; }
git fetch -q origin && [ "$(git rev-parse HEAD)" = "$(git rev-parse @{u})" ] || { echo "push HEAD first" >&2; exit 1; }

export MSL_RELEASE_BASE_URL=https://github.com/$REPO/releases/download/$TAG
export MSL_UPDATE_CHANNEL_URL=${MSL_UPDATE_CHANNEL_URL:-https://github.com/$REPO/releases/latest/download/update.json}
scripts/package.sh "$VERSION"

# The bundled kernel must be the published one.
KSUM=$(awk '$2=="Image"{print $1}' kernel/release.sha256)
[ "$(shasum -a 256 build/share/msl/Image | cut -d' ' -f1)" = "$KSUM" ] \
  || { echo "build/share/msl/Image is not $KTAG (run kernel/fetch.sh or kernel/publish.sh)" >&2; exit 1; }

set -- --repo "$REPO" --target "$(git rev-parse HEAD)" --title "msl $VERSION"
if [ "$PRE" = --prerelease ]; then set -- "$@" --prerelease; else set -- "$@" --latest; fi
gh release create "$TAG" "dist/$NAME" "dist/$NAME.sha256" "dist/msl-$VERSION.pkg" dist/update.json "$@" --notes "$(cat <<NOTES
Install: \`sh install.sh\` (or \`sh install.sh --version $VERSION\`). Update an existing install with \`msl --update\`.

| | |
|---|---|
| Kernel | Linux $(cat build/share/msl/kernel.version), release [\`$KTAG\`](https://github.com/$REPO/releases/tag/$KTAG) |
| Commit | $(git rev-parse --short HEAD) |
| Requires | Apple silicon, macOS 26 or later |
| Signing | $( [ -n "${MSL_SIGN_IDENTITY:-}" ] && echo "Developer ID" || echo "ad-hoc (not notarised)") |

\`$NAME\` SHA-256: \`$(cut -d' ' -f1 "dist/$NAME.sha256")\`
NOTES
)"
