#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Publish kernel/out/{Image,config} as the GitHub release kernel/tag.sh names
# (kernel-<linux version>-msl-<hash of the config inputs>). Writes
# kernel/release.tag and kernel/release.sha256; commit both with the change.
# Kernel releases never become the repo's "Latest" (that's the msl v* release).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TAG=$("$HERE/tag.sh")
REPO=${MSL_REPO:-onexay/msl}
LINUX=$(sed -n 's/^# Linux\/arm64 \([^ ]*\) Kernel Configuration/\1/p' "$HERE/out/config")
case $TAG in "kernel-$LINUX-msl-"*) ;; *) echo "$TAG doesn't match the built kernel ($LINUX)" >&2; exit 1 ;; esac
[ "$(cat "$HERE/out/tag" 2>/dev/null)" = "$TAG" ] || { echo "kernel/out wasn't built from the current config ($TAG); run kernel/build.sh" >&2; exit 1; }
(cd "$HERE/out" && shasum -a 256 Image config) > "$HERE/release.sha256"
echo "$TAG" > "$HERE/release.tag"
SRC=$("$HERE/../scripts/gpl-sources.sh" kernel)  # GPL-2.0: ship the corresponding source
gh release create "$TAG" "$HERE/out/Image" "$HERE/out/config" "$HERE/release.sha256" "$SRC" --repo "$REPO" --latest=false \
  --title "MSL kernel $LINUX (${TAG##*-msl-})" \
  --notes "Linux $LINUX (arm64), built by kernel/build.sh from kernel/base.config + kernel/msl.fragment at $(git -C "$HERE" rev-parse --short HEAD). Used by scripts/build.sh via kernel/fetch.sh. GPL-2.0. Corresponding source: linux-$LINUX.tar.xz (attached, unmodified from kernel.org) plus the attached config; kernel/build.sh reproduces the build."
