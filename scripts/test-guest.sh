#!/bin/sh
# Run the guest's unit tests natively on Linux, inside a container (Apple `container`).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
container system start >/dev/null 2>&1 || true
exec container run --rm -v "$ROOT:/msl" -w /msl/guest docker.io/library/rust:1-slim bash -c '
  apt-get update -qq >/dev/null && apt-get install -y -qq protobuf-compiler >/dev/null 2>&1
  CARGO_TARGET_DIR=/tmp/t cargo test --target aarch64-unknown-linux-gnu --config "build.target=\"aarch64-unknown-linux-gnu\"" "$@"'
