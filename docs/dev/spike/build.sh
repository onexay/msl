#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Build guest (arm64 musl), initrd, and the signed spike host.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
export PATH=/opt/homebrew/opt/rustup/bin:$PATH
mkdir -p "$HERE/out"
(cd "$ROOT/guest" && cargo build --release)
python3 "$ROOT/scripts/mkinitrd.py" "$ROOT/guest/target/aarch64-unknown-linux-musl/release/msl-guest" "$HERE/out/initrd.gz"
(cd "$HERE/host" && swift build -c release 2>&1 | tail -1)
BIN="$HERE/host/.build/release/msl-spike"
codesign -f -s - --entitlements "$HERE/entitlements.plist" "$BIN"
cp "$BIN" "$HERE/out/msl-spike"
codesign -f -s - --entitlements "$HERE/entitlements.plist" "$HERE/out/msl-spike"
echo "built: spike/out/{initrd.gz,msl-spike}"
