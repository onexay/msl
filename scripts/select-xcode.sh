#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Keep packaged binaries compatible with the minimum supported macOS runtime.
set -eu
MIN=$(sed -n 's/.*\.macOS("\([0-9]*\)\..*/\1/p' Package.swift)
XC=$(for x in /Applications/Xcode_"$MIN"*.app; do
  readlink -f "$x" | grep -q beta || echo "$x"
done | sort -V | tail -1)
[ -n "$XC" ] || { echo "no released Xcode $MIN on this runner" >&2; exit 1; }
sudo xcode-select -s "$XC"
xcodebuild -version | head -1 | grep -q "^Xcode $MIN\." || { echo "need Xcode $MIN" >&2; exit 1; }
xcodebuild -version
swift --version
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "build=$(xcodebuild -version | tail -1 | awk '{print $NF}')" >> "$GITHUB_OUTPUT"
fi
