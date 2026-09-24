#!/bin/sh
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

if [ ! -f "$ROOT/kernel/out/Image" ]; then
  "$ROOT/kernel/fetch.sh" || echo "warning: could not fetch the MSL kernel; falling back to Apple's"
fi
if [ -f "$ROOT/kernel/out/Image" ]; then
  cp "$ROOT/kernel/out/Image" "$OUT/share/msl/Image"
  sed -n 's/^# Linux\/arm64 \([^ ]*\) Kernel Configuration/\1-msl/p' "$ROOT/kernel/out/config" > "$OUT/share/msl/kernel.version"
else
  cp "$HOME/Library/Application Support/com.apple.container/kernels/default.kernel-arm64" "$OUT/share/msl/Image"
  echo "6.18.15-apple" > "$OUT/share/msl/kernel.version"
fi

(cd "$ROOT" && swift build -c "$CONFIG" --product msl -q && swift build -c "$CONFIG" --product msld -q)
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
install_bin "$BIN/msld" msld "$ROOT/msld.entitlements"
echo "built: build/bin/{msl,msld} build/share/msl/{Image,initrd.gz} (kernel $(cat "$OUT/share/msl/kernel.version"))"
