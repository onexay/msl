#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Phosphorus end-to-end test: a clean shutdown when macOS stops msld (#52).
# SIGTERM (logout, restart, shutdown) stops the distros, unmounts and flushes
# their disks and exits, so even unsynced writes survive; and msld as a
# LaunchAgent (MSL_LAUNCHD=1 here, with this test's own label): launchd starts
# it on the first connection, `launchctl bootout` shuts it down cleanly, and
# the next command loads it again.
#   tests/e2e/phosphorus.sh [path/to/msl]
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MSL=${1:-$ROOT/build/bin/msl}
export MSL_HOME=$(mktemp -d /tmp/msl-phosphorus.XXXXXX)
export MSL_CONFIG=$MSL_HOME/cfg MSL_VIEW_DIR=$MSL_HOME/view
: > "$MSL_CONFIG"
pass=0; fails=0
check() {
  if [[ "$3" == *"$2"* ]]; then echo "✔ $1"; pass=$((pass+1)); else echo "✘ $1"; echo "    expected: $2"; echo "    got:      $3"; fails=$((fails+1)); fi
}
msld_pid() {
  for pid in $(pgrep -f "$(dirname "$MSL")/msld"); do
    ps -E -ww -o command= -p "$pid" | grep -q "MSL_HOME=$MSL_HOME" && echo "$pid"
  done
}
wait_gone() {  # seconds until $1 exits (at most 40)
  local t=0
  while kill -0 "$1" 2>/dev/null && [ $t -lt 400 ]; do sleep 0.1; t=$((t+1)); done
  echo $((t / 10))
}

# msld started directly (as for a development build): SIGTERM
$MSL --install Debian --no-launch >/dev/null
$MSL -d Debian -u root -e sh -c 'echo unsynced > /root/nosync; sleep 1'
pid=$(msld_pid)
kill -TERM "$pid"
check "SIGTERM: msld exits within the grace period" "yes" "$(s=$(wait_gone "$pid"); [ "$s" -le 20 ] && echo yes || echo "no (${s}s)")"
check "SIGTERM: msld shut the VM down first" "SIGTERM: stopped; exiting" "$(cat "$MSL_HOME/msld.log")"
check "SIGTERM: the distro's disk was unmounted cleanly" "detached from" "$(cat "$MSL_HOME/console.log")"
check "SIGTERM: an unsynced write survived" "unsynced" "$($MSL -d Debian -u root -e cat /root/nosync)"
$MSL --shutdown
kill "$(msld_pid)" 2>/dev/null; sleep 1

# msld as a LaunchAgent
export MSL_LAUNCHD=1
check "launchd starts msld on the first connection" "0" "$($MSL -d Debian -e true; echo $?)"
plist=$(ls ~/Library/LaunchAgents/dev.msl.msld.*.plist | while read -r f; do grep -q "$MSL_HOME/msld.sock" "$f" && echo "$f"; done)
label=$(basename "$plist" .plist)
check "the agent's plist" "$MSL_HOME/msld.sock" "$(plutil -p "$plist")"
check "the agent's exit timeout" "\"ExitTimeOut\" => 30" "$(plutil -p "$plist")"
check "launchd runs msld" "state = running" "$(launchctl print "gui/$(id -u)/$label")"
check "msld uses launchd's socket" "(launchd)" "$(cat "$MSL_HOME/msld.log")"
$MSL -d Debian -u root -e sh -c 'echo again > /root/nosync2; sleep 1'
pid=$(msld_pid)
launchctl bootout "gui/$(id -u)/$label"
check "bootout: msld exits cleanly" "yes" "$(s=$(wait_gone "$pid"); [ "$s" -le 20 ] && echo yes || echo "no (${s}s)")"
check "bootout: an unsynced write survived, and the agent loads again" "again" "$($MSL -d Debian -u root -e cat /root/nosync2)"
check "launchd runs msld again" "state = running" "$(launchctl print "gui/$(id -u)/$label")"

$MSL --unregister Debian >/dev/null
launchctl bootout "gui/$(id -u)/$label"
sleep 3
rm -f "$plist"
kill "$(msld_pid)" 2>/dev/null
echo
echo "$pass passed, $fails failed  (MSL_HOME=$MSL_HOME)"
[ $fails -eq 0 ]
