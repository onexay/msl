#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Magnesium end-to-end test: data.img sizing and growth (#3).
# [msl2] defaultVhdSize for a new disk, --status disk rows, and
# --manage --resize (refused while distros run, grow only, up to the Mac's
# capacity; the data survives and the distros see the new size).
#   Tests/e2e/magnesium.sh [path/to/msl]
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MSL=${1:-$ROOT/build/bin/msl}
export MSL_HOME=$(mktemp -d /tmp/msl-magnesium.XXXXXX)
export MSL_CONFIG=$MSL_HOME/cfg MSL_VIEW_DIR=$MSL_HOME/view
printf '[msl2]\ndefaultVhdSize = 8GB\n' > "$MSL_CONFIG"
D=Debian
pass=0; fails=0
check() {
  if [[ "$3" == *"$2"* ]]; then echo "✔ $1"; pass=$((pass+1)); else echo "✘ $1"; echo "    expected: $2"; echo "    got:      $3"; fails=$((fails+1)); fi
}
gib() { $MSL -d $D -u root -e sh -c "df -BG --output=size / | tail -1 | tr -dc 0-9"; }

$MSL --install $D --no-launch >/dev/null
# The formatter rounds up to whole block groups (8 GiB becomes 8 GiB + 128 MiB).
check "defaultVhdSize: data.img is about 8 GiB" "8.1" "$(stat -f %z "$MSL_HOME/data.img" | awk '{printf "%.1f", $1/2^30}')"
check "distro sees about 8 GiB" "8" "$(gib)"
sum=$($MSL -d $D -u root -e sh -c 'dd if=/dev/urandom of=/root/marker bs=1M count=64 status=none && sha256sum /root/marker')
check "--status shows the disk" "8.1 GB max" "$($MSL --status)"
check "--status shows free space in the VM" "Disk free:" "$($MSL --status)"

check "resize refused while a distro runs" "must all be stopped" "$($MSL -d $D -e sh -c "sleep 30" & sleep 3; $MSL --manage $D --resize 16GB 2>&1)"
$MSL --shutdown
check "shrink refused" "can only grow" "$($MSL --manage $D --resize 4GB 2>&1)"
check "more than macOS holds refused" "more than the macOS disk holds" "$($MSL --manage $D --resize 100TB 2>&1)"
check "invalid size refused" "Invalid size" "$($MSL --manage $D --resize lots 2>&1)"

out=$($MSL --manage $D --resize 16GB 2>&1); rc=$?
check "grow to 16 GiB succeeds" "0 The operation completed successfully." "$rc $out"
check "data.img is 16 GiB" "17179869184" "$(stat -f %z "$MSL_HOME/data.img")"
check "msld logged the grow" "data disk: grew 8.1 GiB → 16.0 GiB" "$(cat "$MSL_HOME/msld.log")"
check "distro sees about 16 GiB" "16" "$(gib)"
check "data survived the grow" "$sum" "$($MSL -d $D -u root -e sha256sum /root/marker)"
$MSL --shutdown; $MSL -d $D -e true
check "second boot: nothing to grow" "1" "$(grep -c 'data disk: grew' "$MSL_HOME/msld.log")"
check "same size is a no-op" "0" "$($MSL --manage $D --resize 16GB >/dev/null 2>&1; echo $?)"

printf '[msl2]\ndefaultVhdSize = 1GB\n' > "$MSL_CONFIG"
check "defaultVhdSize below 4GB warns" "Invalid size '1GB' for .mslconfig entry 'msl2.defaultvhdsize'" "$($MSL -d $D -e true 2>&1)"

$MSL --unregister $D >/dev/null
$MSL --shutdown
# Stop only this test's msld (the one started with our MSL_HOME), not yours.
for pid in $(pgrep -f "$ROOT/build/bin/msld"); do
  ps -E -ww -o command= -p "$pid" | grep -q "MSL_HOME=$MSL_HOME" && kill "$pid"
done
echo
echo "$pass passed, $fails failed  (MSL_HOME=$MSL_HOME)"
[ $fails -eq 0 ]
