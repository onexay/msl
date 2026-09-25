#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Build everything into build/:
#   build/bin/{msl,msld}            (msld signed with the virtualization entitlement)
#   build/share/msl/{Image,initrd.gz,kernel.version}
# Kernel: kernel/out/Image if present (kernel/fetch.sh downloads the release
# build, kernel/build.sh builds it), else Apple's `container` kernel.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=${CONFIG:-release}
export PATH=/opt/homebrew/opt/rustup/bin:$PATH
OUT="$ROOT/build"
mkdir -p "$OUT/bin" "$OUT/share/msl"

(cd "$ROOT/guest" && cargo build --release -q)
python3 "$ROOT/scripts/mkinitrd.py" "$ROOT/guest/target/aarch64-unknown-linux-musl/release/msl-guest" "$OUT/share/msl/initrd.gz" "$ROOT/guest/vendor/busybox"

# kernel/out/tag says which kernel is there: the published one (kernel/release.tag)
# or a local build of the current config (kernel/tag.sh). Anything else is stale.
KOUT=$(cat "$ROOT/kernel/out/tag" 2>/dev/null || true)
if [ ! -f "$ROOT/kernel/out/Image" ] || { [ "$KOUT" != "$(cat "$ROOT/kernel/release.tag")" ] && [ "$KOUT" != "$("$ROOT/kernel/tag.sh")" ]; }; then
  "$ROOT/kernel/fetch.sh" || echo "warning: could not fetch the MSL kernel; falling back to Apple's"
fi
[ "$(cat "$ROOT/kernel/release.tag")" = "$("$ROOT/kernel/tag.sh")" ] || echo "note: the kernel config changed since $(cat "$ROOT/kernel/release.tag"); kernel/build.sh, then kernel/publish.sh"
if [ -f "$ROOT/kernel/out/Image" ]; then
  cp "$ROOT/kernel/out/Image" "$OUT/share/msl/Image"
  sed 's/^kernel-//' "$ROOT/kernel/out/tag" > "$OUT/share/msl/kernel.version"   # e.g. 6.18.15-msl-3f2a9c1
else
  cp "$HOME/Library/Application Support/com.apple.container/kernels/default.kernel-arm64" "$OUT/share/msl/Image"
  echo "6.18.15-apple" > "$OUT/share/msl/kernel.version"
fi

# Stamp the commit into MSLBuild.commit for this build only (package.sh stamps the
# version the same way). Version.swift itself doesn't count as a change.
VFILE=$ROOT/Sources/MSLCore/Version.swift
COMMIT=$(git -C "$ROOT" rev-parse --short=7 HEAD 2>/dev/null || true)
if [ -n "$COMMIT" ] && ! git -C "$ROOT" diff --quiet HEAD -- . ':!Sources/MSLCore/Version.swift'; then COMMIT=$COMMIT.dirty; fi
cp "$VFILE" "$VFILE.build"
trap 'mv -f "$VFILE.build" "$VFILE"' EXIT
sed -i '' "s|static let commit = \".*\"|static let commit = \"$COMMIT\"|" "$VFILE"
(cd "$ROOT" && swift build -c "$CONFIG" --product msl -q && swift build -c "$CONFIG" --product msld -q)
mv -f "$VFILE.build" "$VFILE"; trap - EXIT
BIN=$(cd "$ROOT" && swift build -c "$CONFIG" --show-bin-path)
# Install atomically (new inode): overwriting a running msld in place breaks its
# code signature, and Virtualization.framework then refuses to start VMs.
install_bin() {  # install_bin <src> <name> [entitlements]
  tmp="$OUT/bin/.$2.new.$$"
  cp "$1" "$tmp"
  if [ -n "${3:-}" ]; then codesign -f -s - --entitlements "$3" "$tmp" 2>/dev/null; else codesign -f -s - "$tmp" 2>/dev/null; fi
  mv -f "$tmp" "$OUT/bin/$2"
}
install_bin "$BIN/msl" msl
install_bin "$BIN/msld" msld "$ROOT/Sources/msld/msld.entitlements"

# The VS Code extension (msl --manage-ide installs it), like the kernel: a local
# build for package.json's version (cd extensions/vscode && npm run package) if
# there is one, else the published release (extensions/vscode/fetch.sh).
EXT=$ROOT/extensions/vscode
EXTV=$(sed -n 's/^  "version": "\(.*\)",$/\1/p' "$EXT/package.json")
VSIX=$EXT/dist/msl-$EXTV.vsix
if [ ! -f "$VSIX" ]; then
  if [ "$(cat "$EXT/release.tag" 2>/dev/null)" = "vscode-$EXTV" ]; then
    "$EXT/fetch.sh" >/dev/null || echo "warning: could not fetch the VS Code extension $EXTV"
  else
    echo "warning: VS Code extension $EXTV isn't published; build it: (cd extensions/vscode && npm run package)"
  fi
fi
if [ -f "$VSIX" ]; then cp "$VSIX" "$OUT/share/msl/msl.vsix"; else rm -f "$OUT/share/msl/msl.vsix"; fi
echo "built: build/bin/{msl,msld} build/share/msl/{Image,initrd.gz,msl.vsix} (kernel $(cat "$OUT/share/msl/kernel.version"))"
