#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Publish the MSL VS Code extension CI built (.github/workflows/vscode.yml,
# artifact vscode-<version>) as GitHub release vscode-<version>, where <version>
# is package.json's. The artifact must come from a commit whose extensions/vscode
# is identical to HEAD's. Writes release.tag and release.sha256;
# commit both with the change. Like kernel releases, extension releases never
# become the repo's "Latest" (that's the msl v* release), and msl releases
# bundle the published .vsix (scripts/build.sh fetches it).
#   extensions/vscode/publish.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
REPO=${MSL_REPO:-onexay/msl}
VERSION=$(sed -n 's/^  "version": "\(.*\)",$/\1/p' package.json)
TAG=vscode-$VERSION
FILE=msl-$VERSION.vsix
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "$TAG is already published: bump \"version\" in package.json" >&2; exit 1
fi
[ -z "$(git status --porcelain .)" ] || { echo "commit your extension changes first" >&2; exit 1; }
git fetch -q origin && [ "$(git rev-parse HEAD)" = "$(git rev-parse "@{u}")" ] || { echo "push HEAD first" >&2; exit 1; }
RUN=$(gh api "repos/$REPO/actions/artifacts?name=$TAG&per_page=20" --jq '[.artifacts[] | select(.expired | not)][0].workflow_run.id // empty')
[ -n "$RUN" ] || { echo "CI hasn't built $TAG yet: push the change and wait for the VS Code extension workflow" >&2; exit 1; }
rm -rf dist/ci && gh run download "$RUN" --repo "$REPO" --name "$TAG" --dir dist/ci
BUILT=$(sed -n 's/^commit //p' dist/ci/build-info.txt)
[ "$(git rev-parse "$BUILT:extensions/vscode")" = "$(git rev-parse HEAD:extensions/vscode)" ] \
  || { echo "CI run $RUN built $TAG from $BUILT, whose extensions/vscode differs from HEAD's" >&2; exit 1; }
mkdir -p dist && cp "dist/ci/$FILE" "dist/$FILE"
echo "$TAG" > release.tag
(cd dist && shasum -a 256 "$FILE") > release.sha256
gh release create "$TAG" "dist/$FILE" release.sha256 --repo "$REPO" --latest=false \
  --target "$(git rev-parse HEAD)" \
  --title "MSL VS Code extension $VERSION" \
  --notes "The MSL extension for VS Code and similar IDEs (VS Code Insiders, VSCodium, Cursor), built by CI run $RUN from extensions/vscode at $(git rev-parse --short "$BUILT"). msl releases bundle it, and \`msl --manage-ide\` installs it. It uses VS Code's proposed \`resolvers\` API, so it isn't on the Marketplace.

\`$FILE\` SHA-256: \`$(cut -d' ' -f1 release.sha256)\`"
echo "published $TAG; commit extensions/vscode/release.tag and release.sha256"
