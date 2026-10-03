#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Build everything into build/:
#   build/bin/{msl,msld,msl-portd,msl-fileviewd}  (msld signed with the virtualization entitlement)
#   build/share/msl/{Image,initrd.gz,kernel.version}
# Kernel: the pinned msl-kernel release (kernel/release.tag, fetched by
# scripts/fetch-kernel.sh), or a local build with MSL_KERNEL_OUT=<msl-kernel>/out.
# Apple's `container` kernel if neither is available.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=${CONFIG:-release}
export PATH=/opt/homebrew/opt/rustup/bin:$PATH
OUT="$ROOT/build"
mkdir -p "$OUT/bin" "$OUT/share/msl"

(cd "$ROOT/guest" && cargo build --release -q)
python3 "$ROOT/scripts/mkinitrd.py" "$ROOT/guest/target/aarch64-unknown-linux-musl/release/msl-guest" "$OUT/share/msl/initrd.gz" \
  "$ROOT/guest/vendor/busybox" "$ROOT/guest/vendor/e2fsck" "$ROOT/guest/vendor/resize2fs"

KOUT=${MSL_KERNEL_OUT:-$ROOT/kernel/out}
if [ -n "${MSL_KERNEL_OUT:-}" ]; then
  [ -f "$KOUT/Image" ] && [ -f "$KOUT/kernel.version" ] || { echo "MSL_KERNEL_OUT=$KOUT has no Image and kernel.version (build.sh in msl-kernel writes them)" >&2; exit 1; }
elif [ ! -f "$KOUT/Image" ] || [ ! -f "$KOUT/kernel.version" ] || [ "$(cat "$KOUT/tag" 2>/dev/null)" != "$(cat "$ROOT/kernel/release.tag")" ]; then
  "$ROOT/scripts/fetch-kernel.sh" || echo "warning: could not fetch the MSL kernel; falling back to Apple's"
fi
if [ -f "$KOUT/Image" ] && [ -f "$KOUT/kernel.version" ]; then
  cp "$KOUT/Image" "$OUT/share/msl/Image"
  cp "$KOUT/kernel.version" "$OUT/share/msl/kernel.version"
else
  cp "$HOME/Library/Application Support/com.apple.container/kernels/default.kernel-arm64" "$OUT/share/msl/Image"
  echo "6.18.15-apple" > "$OUT/share/msl/kernel.version"
fi

# Stamp the commit into MSLBuild.commit for this build only (package.sh stamps the
# version the same way). Version.swift itself doesn't count as a change.
VFILE=$ROOT/core/MSLCore/Version.swift
COMMIT=${MSL_BUILD_COMMIT:-$(git -C "$ROOT" rev-parse --short=7 HEAD 2>/dev/null || true)}
if [ -z "${MSL_BUILD_COMMIT:-}" ] && [ -n "$COMMIT" ] && ! git -C "$ROOT" diff --quiet HEAD -- . ':!core/MSLCore/Version.swift'; then COMMIT=$COMMIT.dirty; fi
cp "$VFILE" "$VFILE.build"
trap 'mv -f "$VFILE.build" "$VFILE"' EXIT
sed -i '' "s|static let commit = \".*\"|static let commit = \"$COMMIT\"|" "$VFILE"
(cd "$ROOT" && swift build -c "$CONFIG" --product msl -q && swift build -c "$CONFIG" --product msld -q && swift build -c "$CONFIG" --product msl-portd -q && swift build -c "$CONFIG" --product msl-fileviewd -q)
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
install_bin "$BIN/msld" msld "$ROOT/host/msld/msld.entitlements"
install_bin "$BIN/msl-portd" msl-portd
install_bin "$BIN/msl-fileviewd" msl-fileviewd

# The VS Code extension (msl --manage-ide installs it), like the kernel: the
# pinned msl-vscode-extension release (extensions/vscode/release.tag, fetched by
# scripts/fetch-vscode.sh), or a local build with
# MSL_VSIX=<msl-vscode-extension>/dist/msl-<version>.vsix.
EXT=$ROOT/extensions/vscode
EXT_TAG=$(cat "$EXT/release.tag")
case $EXT_TAG in
  vscode-*) EXT_VERSION=${EXT_TAG#vscode-} ;; # legacy release tags
  v*) EXT_VERSION=${EXT_TAG#v} ;;
  *) echo "invalid VS Code extension release tag: $EXT_TAG" >&2; exit 1 ;;
esac
VSIX=${MSL_VSIX:-$EXT/dist/msl-$EXT_VERSION.vsix}
if [ -n "${MSL_VSIX:-}" ]; then
  [ -f "$VSIX" ] || { echo "MSL_VSIX=$VSIX doesn't exist" >&2; exit 1; }
elif ! (cd "$EXT/dist" 2>/dev/null && shasum -a 256 -c "$EXT/release.sha256" >/dev/null 2>&1); then
  "$ROOT/scripts/fetch-vscode.sh" >/dev/null || echo "warning: could not fetch the VS Code extension $(cat "$EXT/release.tag")"
fi
if [ -f "$VSIX" ]; then cp "$VSIX" "$OUT/share/msl/msl.vsix"; else rm -f "$OUT/share/msl/msl.vsix"; fi
echo "built: build/bin/{msl,msld,msl-portd,msl-fileviewd} build/share/msl/{Image,initrd.gz,kernel.version,msl.vsix} (kernel $(cat "$OUT/share/msl/kernel.version"))"
