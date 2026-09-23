#!/bin/sh
# Build guest (arm64 musl), initrd, and the signed spike host.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PATH=/opt/homebrew/opt/rustup/bin:$PATH
mkdir -p "$ROOT/spike/out"
(cd "$ROOT/guest" && cargo build --release)
python3 "$ROOT/scripts/mkinitrd.py" "$ROOT/guest/target/aarch64-unknown-linux-musl/release/msl-guest" "$ROOT/spike/out/initrd.gz"
(cd "$ROOT/spike/host" && swift build -c release 2>&1 | tail -1)
BIN="$ROOT/spike/host/.build/release/msl-spike"
codesign -f -s - --entitlements "$ROOT/spike/entitlements.plist" "$BIN"
cp "$BIN" "$ROOT/spike/out/msl-spike"
codesign -f -s - --entitlements "$ROOT/spike/entitlements.plist" "$ROOT/spike/out/msl-spike"
echo "built: spike/out/{initrd.gz,msl-spike}"
