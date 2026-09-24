#!/bin/sh
# Publish kernel/out/{Image,config} as the GitHub release named in
# kernel/release.tag (kernel-<linux version>-msl.<n>; bump n for config-only
# changes). Updates kernel/release.sha256; commit both files with the change.
# Kernel releases never become the repo's "Latest" (that's the msl v* release).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TAG=$(cat "$HERE/release.tag")
REPO=${MSL_REPO:-onexay/msl}
LINUX=$(sed -n 's/^# Linux\/arm64 \([^ ]*\) Kernel Configuration/\1/p' "$HERE/out/config")
case $TAG in "kernel-$LINUX-msl."*) ;; *) echo "release.tag ($TAG) doesn't match the built kernel ($LINUX)" >&2; exit 1 ;; esac
(cd "$HERE/out" && shasum -a 256 Image config) > "$HERE/release.sha256"
gh release create "$TAG" "$HERE/out/Image" "$HERE/out/config" "$HERE/release.sha256" --repo "$REPO" --latest=false \
  --title "MSL kernel $LINUX (${TAG##*-msl.})" \
  --notes "Linux $LINUX (arm64), built by kernel/build.sh from kernel/base.config + kernel/msl.fragment at $(git -C "$HERE" rev-parse --short HEAD). Used by scripts/build.sh via kernel/fetch.sh. GPL-2.0; source: kernel.org linux-$LINUX plus the config in this repository."
