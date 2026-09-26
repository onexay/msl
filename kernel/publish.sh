#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Publish the kernel CI built for the current config (.github/workflows/kernel.yml,
# artifact named after kernel/tag.sh's tag: kernel-<linux>-msl-<config hash>) as
# that GitHub release. Downloads it into kernel/out. Writes kernel/release.tag and
# kernel/release.sha256; commit both with the change.
# Kernel releases never become the repo's "Latest" (that's the msl v* release).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TAG=$("$HERE/tag.sh")
REPO=${MSL_REPO:-onexay/msl}
RUN=$(gh api "repos/$REPO/actions/artifacts?name=$TAG&per_page=20" --jq '[.artifacts[] | select(.expired | not)][0].workflow_run.id // empty')
[ -n "$RUN" ] || { echo "CI hasn't built $TAG yet: push the config change and wait for the Kernel workflow" >&2; exit 1; }
rm -rf "$HERE/out" && gh run download "$RUN" --repo "$REPO" --name "$TAG" --dir "$HERE/out"
echo "kernel from CI run $RUN ($(cat "$HERE/out/build-info.txt"))"
LINUX=$(sed -n 's/^# Linux\/arm64 \([^ ]*\) Kernel Configuration/\1/p' "$HERE/out/config")
case $TAG in "kernel-$LINUX-msl-"*) ;; *) echo "$TAG doesn't match the built kernel ($LINUX)" >&2; exit 1 ;; esac
[ "$(cat "$HERE/out/tag" 2>/dev/null)" = "$TAG" ] || { echo "the CI artifact's tag isn't $TAG" >&2; exit 1; }
(cd "$HERE/out" && shasum -a 256 Image config) > "$HERE/release.sha256"
echo "$TAG" > "$HERE/release.tag"
SRC=$("$HERE/../scripts/gpl-sources.sh" kernel)  # GPL-2.0: ship the corresponding source
gh release create "$TAG" "$HERE/out/Image" "$HERE/out/config" "$HERE/release.sha256" "$SRC" --repo "$REPO" --latest=false \
  --title "MSL kernel $LINUX (${TAG##*-msl-})" \
  --notes "Linux $LINUX (arm64), built by CI run $RUN (kernel/build-linux.sh on ubuntu-24.04-arm) from kernel/base.config + kernel/msl.fragment, $(cat "$HERE/out/build-info.txt"). Used by scripts/build.sh via kernel/fetch.sh. GPL-2.0. Corresponding source: linux-$LINUX.tar.xz (attached, unmodified from kernel.org) plus the attached config; kernel/build-linux.sh reproduces the build."
