#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Fail if the version in VERSION, Version.swift, guest/Cargo.toml and guest/Cargo.lock disagree.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
V=$(cat "$ROOT/VERSION")
SWIFT=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' "$ROOT/Sources/MSLCore/Version.swift")
CARGO=$(sed -n '1,/^version = /s/^version = "\(.*\)"/\1/p' "$ROOT/guest/Cargo.toml")
LOCK=$(awk '/^name = "msl-guest"$/{getline; gsub(/version = |"/, ""); print}' "$ROOT/guest/Cargo.lock")
for x in "Version.swift:$SWIFT" "guest/Cargo.toml:$CARGO" "guest/Cargo.lock:$LOCK"; do
  [ "${x#*:}" = "$V" ] || { echo "version mismatch: VERSION is $V, ${x%%:*} has ${x#*:} (run scripts/set-version.sh $V)" >&2; exit 1; }
done
echo "version $V"
