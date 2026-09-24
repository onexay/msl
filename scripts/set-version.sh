#!/bin/sh
# Set msl's version everywhere: VERSION (the source of truth), the Swift
# constant (MSLBuild.version) and the guest crate (Cargo.toml + Cargo.lock).
#   scripts/set-version.sh 0.2.0
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
V=${1:?usage: scripts/set-version.sh <x.y.z>}
echo "$V" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' || { echo "not a semantic version: $V" >&2; exit 2; }
echo "$V" > "$ROOT/VERSION"
sed -i '' "s|static let version = \".*\"|static let version = \"$V\"|" "$ROOT/Sources/MSLCore/Version.swift"
sed -i '' "1,/^version = /s|^version = \".*\"|version = \"$V\"|" "$ROOT/guest/Cargo.toml"
awk -v v="$V" '/^name = "msl-guest"$/{print; getline; sub(/".*"/, "\"" v "\"")} {print}' "$ROOT/guest/Cargo.lock" > "$ROOT/guest/Cargo.lock.new" \
  && mv "$ROOT/guest/Cargo.lock.new" "$ROOT/guest/Cargo.lock"
"$ROOT/scripts/check-version.sh"
