#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Silicon end-to-end test: each distro on its own disk (#50). ext4.img in the
# install location, attached as virtio-blk at boot; a disk added while the VM
# idles restarts it, one added while a distro runs goes on a loop device over
# the Mac share until the next boot; unregister deleting the image, --manage --move (including a distro on the
# shared data.img), per-distro --resize, --export/--import --vhd,
# --import-in-place, --compact, --status rows, and an msld crash mid-write.
#   tests/e2e/silicon.sh [path/to/msl]
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MSL=${1:-$ROOT/build/bin/msl}
export MSL_HOME=$(mktemp -d /tmp/msl-silicon.XXXXXX)
export MSL_CONFIG=$MSL_HOME/cfg MSL_VIEW_DIR=$MSL_HOME/view
W=$MSL_HOME/work
mkdir -p "$W"
: > "$MSL_CONFIG"
pass=0; fails=0
check() {
  if [[ "$3" == *"$2"* ]]; then echo "✔ $1"; pass=$((pass+1)); else echo "✘ $1"; echo "    expected: $2"; echo "    got:      $3"; fails=$((fails+1)); fi
}
check_not() {
  if [[ "$3" != *"$2"* ]]; then echo "✔ $1"; pass=$((pass+1)); else echo "✘ $1"; echo "    unexpected: $2"; echo "    got:        $3"; fails=$((fails+1)); fi
}
ok="The operation completed successfully."
# Stop this test's msld only (the one started with our MSL_HOME), not yours.
stop_msld() {
  $MSL --shutdown
  for pid in $(pgrep -f "$(dirname "$MSL")/msld"); do
    ps -E -ww -o command= -p "$pid" | grep -q "MSL_HOME=$MSL_HOME" && kill "$pid"
  done
  sleep 1
}
disk_of() {  # registry field of a distro's disk: path or uuid
  python3 -c "import json,sys; print([d.get('disk',{}).get(sys.argv[3],'') for d in json.load(open(sys.argv[1]))['distros'] if d['name']==sys.argv[2]][0])" "$MSL_HOME/registry.json" "$1" "$2"
}
fs_uuid() {  # ext4 UUID from the superblock (offset 1024 + 0x68)
  python3 -c "import sys,uuid; f=open(sys.argv[1],'rb'); f.seek(1024+0x68); print(uuid.UUID(bytes=f.read(16)))" "$1"
}
gib() { $MSL -d "$1" -u root -e sh -c "df -BG --output=size / | tail -1 | tr -dc 0-9"; }
marker() { $MSL -d "$1" -u root -e cat /root/marker; }
root_dev() { $MSL -d "$1" -e sh -c 'df --output=source / | tail -1'; }
restarts() { grep -c "restarting the idle VM" "$MSL_HOME/msld.log"; }

# A distro on the shared data.img, as installed by earlier versions.
MSL_LEGACY_STORE=1 $MSL --install Debian --name Legacy --no-launch >/dev/null
$MSL -d Legacy -u root -e sh -c 'echo legacy > /root/marker'
$MSL --export Legacy "$W/debian.tar" >/dev/null
stop_msld

# Install onto its own disk.
check "--install --location --vhd-size" "successfully installed" "$($MSL --install Debian --no-launch --location "$W/deb" --vhd-size 8GB)"
img=$(disk_of Debian path)
check "ext4.img is in the install location" "$W/deb/ext4.img" "$img"
check "registry holds the disk's ext4 UUID" "$(fs_uuid "$img")" "$(disk_of Debian uuid)"
check "the image is about 8 GiB" "8.1" "$(stat -f %z "$img" | awk '{printf "%.1f", $1/2^30}')"
check "the distro's / is its own disk" "/dev/vd" "$($MSL -d Debian -e sh -c 'df --output=source / | tail -1')"
check "the distro sees about 8 GiB" "8" "$(gib Debian)"
$MSL -d Debian -u root -e sh -c 'echo own > /root/marker'
check "--status: distribution disks" "Distribution disks:" "$($MSL --status)"
check "--status: data.img while a distro is on it" "Shared disk:" "$($MSL --status)"

# A disk added while the VM idles: the VM restarts so it's attached at boot.
$MSL --terminate Debian
$MSL --import A "$W/a" "$W/debian.tar" >/dev/null
check "the idle VM restarted to attach A's disk" "1" "$(restarts)"
check "A's / is a disk attached at boot" "/dev/vd" "$(root_dev A)"
check "so is Debian's, after the restart" "/dev/vd" "$(root_dev Debian)"
check "Debian's data is there" "own" "$(marker Debian)"
# One added while a distro runs: a loop device over the Mac share, until the next boot.
$MSL --terminate Debian
$MSL -d A -e sleep 60 & a=$!
sleep 4
$MSL --import B "$W/b" "$W/debian.tar" >/dev/null
check "no restart while A runs" "1" "$(restarts)"
check "B's / is a loop device" "/dev/loop" "$(root_dev B)"
check "B runs" "legacy" "$(marker B)"
check "msld logged the loop device" "over the Mac share until the VM restarts" "$(cat "$MSL_HOME/msld.log")"
$MSL -d B -u root -e sh -c 'echo loop > /root/marker2 && sync'
$MSL --terminate B
check "B remounts on its loop device" "loop" "$($MSL -d B -u root -e cat /root/marker2)"
kill $a 2>/dev/null; wait $a 2>/dev/null
$MSL --shutdown
check "after the VM restarts, B is on a disk attached at boot" "/dev/vd" "$(root_dev B)"
check "what B wrote on the loop device is there" "loop" "$($MSL -d B -u root -e cat /root/marker2)"
$MSL --terminate A; $MSL --terminate B
check "--unregister" "$ok" "$($MSL --unregister B)"
check "--unregister deleted the image and folder" "No such file" "$(ls "$W/b" 2>&1)"

# --move
n=$(restarts)
check "--manage --move" "$ok" "$($MSL --manage Debian --move "$W/moved")"
check "the image moved" "$W/moved/ext4.img" "$(disk_of Debian path)"
check "the old folder is gone" "No such file" "$(ls "$W/deb" 2>&1)"
check "data survived the move" "own" "$(marker Debian)"
check "a move on the same volume keeps the disk attached at boot" "/dev/vd" "$(root_dev Debian)"
check "... without a VM restart" "$n" "$(restarts)"
check "--move of a distro on data.img" "$ok" "$($MSL --manage Legacy --move "$W/legacy")"
check "it now has its own disk" "$W/legacy/ext4.img" "$(disk_of Legacy path)"
check "data survived the migration" "legacy" "$(marker Legacy)"
check "it's gone from data.img" "" "$(echo 'ls /var/lib/msl/distros; exit' | $MSL --debug-shell | tr -d '\r\n')"
check_not "--status: no data.img row once no distro is on it" "Shared disk" "$($MSL --status)"

# --resize
$MSL -d Debian -e sleep 15 & r=$!
sleep 3
check "--resize refused while the distro runs" "is running" "$($MSL --manage Debian --resize 12GB 2>&1)"
kill $r 2>/dev/null; wait $r 2>/dev/null
$MSL --terminate Debian; $MSL --terminate Legacy
check "--resize to 12 GiB" "$ok" "$($MSL --manage Debian --resize 12GB)"
check "the resized disk is attached at boot again (the idle VM restarted)" "/dev/vd" "$(root_dev Debian)"
check "the image is 12 GiB" "12884901888" "$(stat -f %z "$(disk_of Debian path)")"
check "the distro sees about 12 GiB" "12" "$(gib Debian)"
check "data survived the resize" "own" "$(marker Debian)"
check "--resize can't shrink" "can only grow" "$($MSL --manage Debian --resize 10GB 2>&1)"
check "--resize: no larger than the macOS disk" "more than the macOS disk holds" "$($MSL --manage Debian --resize 100TB 2>&1)"

# Disk images
check "--export --vhd" "$ok" "$($MSL --export Debian "$W/debian.img" --vhd)"
check "the export is the whole disk" "12884901888" "$(stat -f %z "$W/debian.img")"
check "--export --vhd to stdout refused" "standard output" "$($MSL --export Debian - --vhd 2>&1)"
check "--import --vhd" "$ok" "$($MSL --import Copy "$W/copy" "$W/debian.img" --vhd)"
check "the import is a copy in the location" "$W/copy/ext4.img" "$(disk_of Copy path)"
check "the copy runs with the data" "own" "$(marker Copy)"
$MSL --terminate Copy
cp -c "$W/debian.img" "$W/inplace.img"
check "--import-in-place" "$ok" "$($MSL --import-in-place InPlace "$W/inplace.img")"
check "the image is used where it is" "$W/inplace.img" "$(disk_of InPlace path)"
check "it runs with the data" "own" "$(marker InPlace)"
check "an image already in use is refused" "already a distribution's disk" "$($MSL --import-in-place Again "$W/inplace.img" 2>&1)"
check "a file that isn't ext4 is refused" "not an ext4 disk image" "$($MSL --import-in-place Tar "$W/debian.tar" 2>&1)"
check "a missing file is refused" "No such file" "$($MSL --import-in-place None "$W/none.img" 2>&1)"
$MSL --unregister InPlace >/dev/null
check "--unregister deletes an in-place image too" "No such file" "$(ls "$W/inplace.img" 2>&1)"
$MSL --unregister Copy >/dev/null

# --compact: trims in the distro punch holes in its ext4.img.
img=$(disk_of Debian path)
used() { du -k "$img" | awk '{print int($1/1024)}'; }
$MSL -d Debian -u root -e sh -c 'head -c 536870912 /dev/urandom > /big && sync && rm /big && sync'
before=$(used)
check "--manage --compact" "$ok" "$($MSL --manage Debian --compact)"
after=$(used)
check "--compact returned >= 400 MB to the Mac" "yes" "$([ $((before - after)) -ge 400 ] && echo yes || echo "no ($before -> $after MB)")"

# An msld crash in the middle of writes (the VM dies with it): what the distro
# synced is kept (flushed with F_FULLFSYNC), and the next attach finds a
# consistent filesystem.
$MSL -d Debian -u root -e sh -c 'for i in $(seq 1 200); do head -c 1048576 /dev/urandom > /root/f$i; done; echo done > /root/synced; sync; while true; do head -c 1048576 /dev/urandom > /root/busy; done' &
w=$!
sleep 12
for pid in $(pgrep -f "$(dirname "$MSL")/msld"); do
  ps -E -ww -o command= -p "$pid" | grep -q "MSL_HOME=$MSL_HOME" && kill -9 "$pid"
done
wait $w 2>/dev/null
sleep 2
check "after an msld crash: the distro starts" "done" "$($MSL -d Debian -u root -e cat /root/synced)"
check "after an msld crash: synced files are intact" "200" "$($MSL -d Debian -u root -e sh -c 'ls /root/f* | wc -l')"
check_not "after an msld crash: no unfixable filesystem errors" "can't fix" "$(cat "$MSL_HOME/msld.log")"

$MSL --unregister Debian >/dev/null
$MSL --unregister Legacy >/dev/null
check "every image is gone" "" "$(find "$W" -name ext4.img)"
stop_msld
echo
echo "$pass passed, $fails failed  (MSL_HOME=$MSL_HOME)"
[ $fails -eq 0 ]
