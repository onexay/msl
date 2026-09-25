#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Build and publish the MSL VS Code extension as GitHub release vscode-<version>,
# where <version> is package.json's. Writes release.tag and release.sha256;
# commit both with the change. Like kernel releases, extension releases never
# become the repo's "Latest" (that's the msl v* release), and msl releases
# bundle the published .vsix (scripts/build.sh fetches it).
#   extensions/vscode/publish.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
REPO=${MSL_REPO:-onexay/msl}
VERSION=$(node -p 'require("./package.json").version')
TAG=vscode-$VERSION
FILE=msl-$VERSION.vsix
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "$TAG is already published: bump \"version\" in package.json" >&2; exit 1
fi
[ -z "$(git status --porcelain .)" ] || { echo "commit your extension changes first" >&2; exit 1; }
npm ci --no-audit --no-fund --loglevel=error
npm run -s compile
rm -f "dist/$FILE" && npm run -s package >/dev/null
[ -f "dist/$FILE" ] || { echo "packaging didn't produce dist/$FILE" >&2; exit 1; }
echo "$TAG" > release.tag
(cd dist && shasum -a 256 "$FILE") > release.sha256
gh release create "$TAG" "dist/$FILE" release.sha256 --repo "$REPO" --latest=false \
  --target "$(git rev-parse HEAD)" \
  --title "MSL VS Code extension $VERSION" \
  --notes "The MSL extension for VS Code and similar IDEs (VS Code Insiders, VSCodium, Cursor), built from extensions/vscode at $(git rev-parse --short HEAD). msl releases bundle it, and \`msl --manage-ide\` installs it. It uses VS Code's proposed \`resolvers\` API, so it isn't on the Marketplace.

\`$FILE\` SHA-256: \`$(cut -d' ' -f1 release.sha256)\`"
echo "published $TAG; commit extensions/vscode/release.tag and release.sha256"
