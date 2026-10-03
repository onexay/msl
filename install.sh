#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Keep the public curl | sh URL working while the installer lives in scripts/.
set -eu
case $0 in
  */install.sh|install.sh)
    HERE=$(CDPATH='' cd "$(dirname "$0")" 2>/dev/null && pwd || true)
    if [ -n "$HERE" ] && [ -f "$HERE/scripts/install.sh" ]; then
      exec sh "$HERE/scripts/install.sh" "$@"
    fi
    ;;
esac
curl -fsSL https://raw.githubusercontent.com/onexay/msl/main/scripts/install.sh | sh -s -- "$@"
