#!/bin/bash
# Milestone 1 end-to-end test. Uses a throwaway MSL_HOME and the WSL images in spike/cache/.
#   Tests/e2e/m1.sh [path/to/msl]
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MSL=${1:-$ROOT/build/bin/msl}
export MSL_HOME=$(mktemp -d /tmp/msl-e2e.XXXXXX)
export MSL_VIEW_DIR=$MSL_HOME/view   # never touch the real ~/MSL
CACHE=$ROOT/spike/cache
WORK=$(mktemp -d)
pass=0; fails=0
check() {  # check "description" <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then echo "✔ $1"; pass=$((pass+1)); else echo "✘ $1"; echo "    expected: $2"; echo "    got:      $3"; fails=$((fails+1)); fi
}
code() { "$@" >/dev/null 2>&1; echo $?; }

check "no distros: list fails with message" "has no installed distributions" "$($MSL -l)"
check "no distros: exit 255" "255" "$(code $MSL -l)"

check "install Debian --no-launch" "Distribution successfully installed. It can be launched via 'msl -d Debian'" \
  "$($MSL --install --from-file $CACHE/debian.wsl --no-launch)"
check "duplicate install rejected" "A distribution with the supplied name already exists" \
  "$($MSL --install --from-file $CACHE/debian.wsl --no-launch)"

# Ubuntu: install + launch runs Ubuntu's own OOBE (wsl-setup) through a real PTY.
check "install Ubuntu + OOBE + shell (PTY)" "'exit=3': True" \
  "$(python3 $ROOT/Tests/e2e/pty_session.py "account:" tester mslpass1 -- $MSL --install --from-file $CACHE/ubuntu-24.04.wsl --name Ubuntu 2>&1 | tr -d '\r' | tail -1)"
check "Ubuntu default user after OOBE" "tester" "$($MSL -d Ubuntu whoami)"
check "Ubuntu user groups from wsl-setup" "sudo" "$($MSL -d Ubuntu id)"

check "list -v" "* Debian" "$($MSL -l -v)"
check "list -v shows Ubuntu Running" "Running" "$($MSL -l -v | grep ' Ubuntu ')"
check "set default" "The operation completed successfully." "$($MSL -s Ubuntu)"
check "status" "Default Distribution: Ubuntu" "$($MSL --status)"
check "list quiet" $'Debian\nUbuntu' "$($MSL -l -q)"

check "exec mode" "Linux" "$($MSL -e uname -s)"
check "exit code passthrough" "7" "$(code $MSL -- exit 7)"
check "cwd translation" "/mnt/mac$(cd /tmp && pwd -P)" "$(cd /tmp && $MSL pwd)"
check "--cd ~" "/home/tester" "$($MSL --cd '~' pwd)"
check "msl ~" "/home/tester" "$($MSL '~' -- pwd)"
check "-u root" "root" "$($MSL -u root whoami)"
check "unknown user" "User not found." "$($MSL -u nobody-here true)"
check "stdin pipe" "3" "$(printf 'a\nb\nc\n' | $MSL wc -l | tr -d ' ')"
check "stderr separate" "err" "$($MSL echo out ';' echo err '>&2' 2>&1 >/dev/null)"
check "login shell type" "tester" "$($MSL --shell-type login -- echo '$USER')"

check "export tar.gz" "Export in progress, this may take a few minutes." "$($MSL --export Debian $WORK/debian.tgz --format tar.gz)"
check "export produced gzip" "gzip compressed" "$(file $WORK/debian.tgz)"
check "export to stdout" "etc/debian_version" "$($MSL --export Debian - | tar -t 2>/dev/null | grep -m1 debian_version)"
check "import from file" "The operation completed successfully." "$($MSL --import Debian2 $WORK/loc $WORK/debian.tgz)"
check "import from stdin" "The operation completed successfully." "$(cat $WORK/debian.tgz | $MSL --import Debian3 $WORK/loc3 -)"
check "imported distro runs" "13" "$($MSL -d Debian2 cat /etc/debian_version)"
check "export → import keeps setuid + ownership" "-rwsr-xr-x root" "$($MSL -d Debian2 stat -c '%A %U' /usr/bin/passwd)"
check "import rejects version 1" "only version 2" "$($MSL --import X $WORK/x $WORK/debian.tgz --version 1)"
check "unregister" $'Unregistering.\nThe operation completed successfully.' "$($MSL --unregister Debian3)"
check "unregistered is gone" "There is no distribution with the supplied name." "$($MSL -d Debian3 true)"

check "terminate" "The operation completed successfully." "$($MSL -t Ubuntu)"
check "terminated shows Stopped" "Stopped" "$($MSL -l -v | grep ' Ubuntu ')"
check "restart after terminate" "tester" "$($MSL -d Ubuntu whoami)"
$MSL --shutdown
check "shutdown: none running" "There are no running distributions." "$($MSL -l --running)"
check "after shutdown: runs again" "Linux" "$($MSL -e uname -s)"
check "shutdown --force" "" "$($MSL --shutdown --force)"

check "unsupported: --system" "not supported on macOS" "$($MSL --system)"
check "invalid argument" "Invalid command line argument: --nope" "$($MSL --nope)"

echo; echo "$pass passed, $fails failed  (MSL_HOME=$MSL_HOME)"
$MSL --shutdown --force >/dev/null 2>&1
pkill -f "msld" -U "$(id -u)" 2>/dev/null  # stop this test's msld
rm -rf "$WORK"
[ "$fails" -eq 0 ]
