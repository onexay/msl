#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Lithium milestone end-to-end test: online install, compat layer, built-in OOBE,
# wsl.conf keys, .mslconfig, --manage, idle timeouts.
#   Tests/e2e/lithium.sh [path/to/msl]
# Downloads come from Microsoft's distribution list (cached in ~/Library/Caches/msl).
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MSL=${1:-$ROOT/build/bin/msl}
export MSL_HOME=$(mktemp -d /tmp/msl-lithium.XXXXXX)
export MSL_VIEW_DIR=$MSL_HOME/view   # never touch the real ~/.msl/distros
WORK=$(mktemp -d)
export MSL_CONFIG=$WORK/mslconfig
pass=0; fails=0
check() {
  if [[ "$3" == *"$2"* ]]; then echo "✔ $1"; pass=$((pass+1)); else echo "✘ $1"; echo "    expected: $2"; echo "    got:      $3"; fails=$((fails+1)); fi
}
check_not() {
  if [[ "$3" != *"$2"* ]]; then echo "✔ $1"; pass=$((pass+1)); else echo "✘ $1 (found: $2)"; fails=$((fails+1)); fi
}
cat > "$MSL_CONFIG" <<'CFG'
[msl2]
memory = lots
memory = 3GB
processors = 2
[general]
instanceIdleTimeout = -1
CFG

check "list --online" "Debian GNU/Linux" "$($MSL --list --online | grep -E '^Debian +Debian GNU/Linux$')"

# Online install of Debian: msl's built-in OOBE replaces Debian's oobe.sh.
OOBE=$(python3 $ROOT/Tests/e2e/pty_session.py "Linux username" "" mslpass1 -- $MSL --install Debian 2>&1 | tr -d '\r')
check "online install + built-in OOBE + shell (PTY)" "'exit=3': True" "$(echo "$OOBE" | tail -1)"
check "OOBE suggests the Mac user name" "Enter new Linux username [$(id -un)]" "$OOBE"
check_not "no Windows wording during install/OOBE" "Windows" "$OOBE"
check "default user from OOBE" "$(id -un)" "$($MSL whoami)"
check "OOBE groups" "sudo" "$($MSL id)"

check "Debian no longer degraded" "running" "$($MSL -u root systemctl is-system-running --wait)"
check "console getty runtime-masked" "masked-runtime" "$($MSL -u root systemctl is-enabled console-getty.service)"
check "image untouched by masks" "No such file" "$($MSL -u root ls /etc/systemd/system/console-getty.service 2>&1)"

check ".mslconfig processors" "2" "$($MSL nproc)"
check ".mslconfig memory (~3 GiB)" "3" "$($MSL -e awk '/MemTotal/{print int($2/1048576+0.5)}' /proc/meminfo)"
check ".mslconfig warning printed" "msl: Invalid memory string 'lots' for .mslconfig entry 'msl2.memory'" "$($MSL true 2>&1)"

check "--manage --set-default-user root" "The operation completed successfully." "$($MSL --manage Debian --set-default-user root)"
check "default user is now root" "root" "$($MSL whoami)"
$MSL --manage Debian --set-default-user "$(id -un)" >/dev/null
check "--manage unknown user" "User not found." "$($MSL --manage Debian --set-default-user nobody-here)"
check "--manage --move records location" "The operation completed successfully." "$($MSL --manage Debian --move $WORK/elsewhere)"
check "--manage --resize refused honestly" "can't be resized yet" "$($MSL --manage Debian --resize 10GB)"

# wsl.conf: boot.command, automount.root, generateResolvConf
$MSL -u root -e sh -c "printf '[boot]\nsystemd=true\ncommand=touch /run/msl-bootcmd\n[automount]\nroot=/\n[network]\ngenerateResolvConf=false\n' > /etc/wsl.conf; rm -f /etc/resolv.conf; echo 'nameserver 9.9.9.9' > /etc/resolv.conf"
$MSL -t Debian >/dev/null
check "wsl.conf [boot] command ran" "yes" "$($MSL -e sh -c 'test -e /run/msl-bootcmd && echo yes')"
check "wsl.conf [automount] root=/ → /mac" "Users" "$($MSL ls /mac)"
check "wsl.conf generateResolvConf=false respected" "9.9.9.9" "$($MSL cat /etc/resolv.conf)"

check "online install by exact name (--no-launch)" "Distribution successfully installed. It can be launched via 'msl -d Ubuntu-24.04'" \
  "$($MSL --install Ubuntu-24.04 --no-launch)"
check "online install duplicate rejected" "A distribution with the supplied name already exists" "$($MSL --install Ubuntu-24.04 --no-launch)"

# Idle timeouts apply at the next VM start.
printf '[msl2]\nvmIdleTimeout = 3000\n[general]\ninstanceIdleTimeout = 2000\n' > "$MSL_CONFIG"
$MSL --shutdown
$MSL true
check "distro running right after a command" "Debian" "$($MSL -l --running)"
sleep 8
check "instanceIdleTimeout stopped the distro" "There are no running distributions." "$($MSL -l --running)"
check "vmIdleTimeout shut the VM down" "vm idle timeout" "$(cat $MSL_HOME/msld.log)"

echo; echo "$pass passed, $fails failed  (MSL_HOME=$MSL_HOME)"
$MSL --shutdown --force >/dev/null 2>&1
pkill -f "$ROOT/build/bin/msld" 2>/dev/null
rm -rf "$WORK"
[ "$fails" -eq 0 ]
