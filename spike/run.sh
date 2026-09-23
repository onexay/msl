#!/bin/sh
# Boot the spike VM in the foreground. Extra args pass through (e.g. --net nat).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
KERNEL="${MSL_KERNEL:-$HOME/Library/Application Support/com.apple.container/kernels/default.kernel-arm64}"
exec "$ROOT/spike/out/msl-spike" \
  --kernel "$KERNEL" \
  --initrd "$ROOT/spike/out/initrd.gz" \
  --disk "$ROOT/spike/out/data.img" \
  --share "$ROOT/spike/cache" \
  --run "$ROOT/spike/out/run" "$@"
