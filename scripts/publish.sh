#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Publish the immutable package from a successful MSLd main push run.
#   [MSL_GPG_KEY=<key id>] scripts/publish.sh <run-id> [--prerelease]
# No dependency resolution, compilation or version stamping takes place here.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec python3 "$ROOT/scripts/release-artifact.py" publish "$@"
