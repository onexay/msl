#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Boot the spike VM in the foreground. Extra args pass through (e.g. --net nat).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
KERNEL="${MSL_KERNEL:-$HOME/Library/Application Support/com.apple.container/kernels/default.kernel-arm64}"
exec "$HERE/out/msl-spike" \
  --kernel "$KERNEL" \
  --initrd "$HERE/out/initrd.gz" \
  --disk "$HERE/out/data.img" \
  --share "$HERE/cache" \
  --run "$HERE/out/run" "$@"
