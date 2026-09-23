#!/bin/bash
# Milestone 5 end-to-end test: --debug-shell, --mount/--unmount, --manage --compact/--resize,
# --update/--uninstall on a development build, replaced-binary handling.
#   Tests/e2e/m5.sh [path/to/msl]
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MSL=${1:-$ROOT/build/bin/msl}
export MSL_HOME=$(mktemp -d /tmp/msl-e2e5.XXXXXX)
export MSL_CONFIG=/dev/null MSL_VIEW_DIR=$MSL_HOME/view
pass=0; fails=0
check() {
  if [[ "$3" == *"$2"* ]]; then echo "✔ $1"; pass=$((pass+1)); else echo "✘ $1"; echo "    expected: $2"; echo "    got:      $3"; fails=$((fails+1)); fi
}
check_not() {
  if [[ "$3" != *"$2"* ]]; then echo "✔ $1"; pass=$((pass+1)); else echo "✘ $1 (found: $2)"; fails=$((fails+1)); fi
}
$MSL --install Ubuntu-24.04 --no-launch >/dev/null
$MSL --install Debian --no-launch >/dev/null

# --debug-shell
check "debug shell: root in the VM's own namespace" "uid=0" "$(echo 'id; exit' | $MSL --debug-shell)"
check "debug shell: sees the distro store" "distros" "$(echo 'ls /var/lib/msl; exit' | $MSL --debug-shell)"
check "debug shell: exit code" "7" "$(echo 'exit 7' | $MSL --debug-shell; echo $?)"
check "debug shell: interactive (PTY)" "'exit=3': True" \
  "$(PTY_PROMPT='# ' python3 $ROOT/Tests/e2e/pty_session.py "no-oobe-prompt" "" "" -- $MSL --debug-shell 2>&1 | tr -d '\r' | tail -1)"

# --mount / --unmount
IMG=$MSL_HOME/disk.img; mkfile -n 256m $IMG
$MSL -d Debian -e true  # Debian is running *before* the mount
check "--mount --bare" "successfully attached as '/dev/sd" "$($MSL --mount $IMG --bare)"
$MSL -d Ubuntu-24.04 -u root -e mkfs.ext4 -q /dev/sda
$MSL --unmount $IMG
check "--mount (re-attach, named)" "successfully mounted as '/mnt/msl/data'" "$($MSL --mount $IMG --name data)"
$MSL -d Ubuntu-24.04 -u root -e sh -c 'echo shared > /mnt/msl/data/f'
check "already-running distro sees the mount" "shared" "$($MSL -d Debian cat /mnt/msl/data/f)"
check "debug shell sees the mount" "f" "$(echo 'ls /mnt/msl/data; exit' | $MSL --debug-shell)"
check "duplicate --mount rejected" "is already attached" "$($MSL --mount $IMG)"
check "--unmount (all)" "" "$($MSL --unmount)"
check_not "unmounted everywhere" "data" "$($MSL -d Debian ls /mnt/msl)"
check "data persists across attach" "shared" "$($MSL --mount $IMG --name data >/dev/null; $MSL cat /mnt/msl/data/f; $MSL --unmount $IMG)"
check "--unmount of an unknown disk" "is not attached" "$($MSL --unmount $MSL_HOME/nope.img)"
check "--mount of a missing file" "no such file or device" "$($MSL --mount /nonexistent.img)"
check "invalid mount name" "cannot be empty" "$($MSL --mount $IMG --name ../x)"
$MSL --unmount >/dev/null 2>&1

# --manage --compact / --resize
used() { du -k $MSL_HOME/data.img | awk '{print int($1/1024)}'; }
$MSL -d Debian -u root -e sh -c 'head -c 536870912 /dev/urandom > /big && sync && rm /big && sync'
before=$(used)
check "--manage --compact" "The operation completed successfully." "$($MSL --manage Debian --compact)"
after=$(used)
check "--compact returned >= 400 MB to the Mac" "yes" "$([ $((before - after)) -ge 400 ] && echo yes || echo "no ($before -> $after MB)")"
check "--manage --resize refused honestly" "can't be resized yet" "$($MSL --manage Debian --resize 300GB)"

# update / uninstall on a development build
check "--update without a channel" "not configured" "$($MSL --update)"
check "--uninstall on a development build" "development build" "$($MSL --uninstall)"

echo; echo "$pass passed, $fails failed  (MSL_HOME=$MSL_HOME)"
$MSL --shutdown --force >/dev/null 2>&1
pkill -f "$ROOT/build/bin/msld" 2>/dev/null
[ "$fails" -eq 0 ]
