#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Beryllium milestone end-to-end test: cwd translation, mslpath, MSLENV, [automount] root.
#   Tests/e2e/beryllium.sh [path/to/msl]
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MSL=${1:-$ROOT/build/bin/msl}
export MSL_HOME=$(mktemp -d /tmp/msl-beryllium.XXXXXX)
export MSL_VIEW_DIR=$MSL_HOME/view   # never touch the real ~/.msl/distros
export MSL_CONFIG=$MSL_HOME/none.cfg
pass=0; fails=0
check() {
  if [[ "$3" == "$2" ]]; then echo "✔ $1"; pass=$((pass+1)); else echo "✘ $1"; echo "    expected: $2"; echo "    got:      $3"; fails=$((fails+1)); fi
}
$MSL --install Debian --no-launch >/dev/null
HOMEDIR=$(cd ~ && pwd -P)

check "cwd translation (default mount)" "/mnt/macos$HOMEDIR" "$(cd ~ && $MSL pwd)"
check "cwd with spaces" "/mnt/macos/private/tmp/msl m3 dir" "$(mkdir -p '/tmp/msl m3 dir' && cd '/tmp/msl m3 dir' && $MSL pwd)"
check "--cd overrides cwd" "/etc" "$($MSL --cd /etc pwd)"

check "mslpath on PATH" "/usr/bin/mslpath" "$($MSL command -v mslpath)"
check "mslpath -u (default)" "/mnt/macos/Users/x/Documents" "$($MSL mslpath /Users/x/Documents)"
check "mslpath -u keeps relative" "a/b" "$($MSL mslpath -u a/b)"
check "mslpath -a -u" "/mnt/macos/Users/x" "$($MSL mslpath -a /Users/y/../x)"
check "mslpath -w" "/Users/x/file.txt" "$($MSL mslpath -w /mnt/macos/Users/x/file.txt)"
check "mslpath -m" "/Users/x" "$($MSL mslpath -m /mnt/macos/Users/x)"
check "mslpath -w mount root" "/" "$($MSL mslpath -w /mnt/macos)"
check "mslpath -w Linux-only path" "$MSL_VIEW_DIR/Debian/etc/hosts" "$($MSL mslpath -w /etc/hosts)"
check "mslpath -wa relative" "$MSL_VIEW_DIR/Debian/etc/hosts" "$($MSL --cd /etc mslpath -wa hosts)"
check "mslpath round trip" "$HOMEDIR" "$($MSL -- mslpath -w '$(mslpath' $HOMEDIR')')"
check "mslpath bad flag" "mslpath: Invalid argument" "$($MSL mslpath -z x 2>&1 | head -1)"

check "MSLENV plain" "hello" "$(FOO=hello MSLENV=FOO $MSL -e printenv FOO)"
# The distro's locale reaches every session (VS Code's terminal would otherwise set
# LANG from its UI language, which the distro may not have).
$MSL -u root -e sh -c 'printf "LANG=C.UTF-8\nLC_TIME=\"C.UTF-8\"\n" > /etc/default/locale'
check "LANG from /etc/default/locale" "C.UTF-8 C.UTF-8" "$($MSL -e sh -c 'echo $LANG $LC_TIME')"
check "no locale warnings from bash" "clean" "$($MSL -e bash -c 'true' 2>&1 | grep -q setlocale && echo warned || echo clean)"
check "MSLENV /p path" "/mnt/macos/Users/x" "$(P=/Users/x MSLENV=P/p $MSL -e printenv P)"
check "MSLENV /l path list" "/mnt/macos/a:/mnt/macos/b" "$(L=/a:/b MSLENV=L/l $MSL -e printenv L)"
check "MSLENV /w not passed" "" "$(W=x MSLENV=W/w $MSL -e sh -c 'echo ${W:-}')"
check "unlisted vars not passed" "" "$(SECRET=x MSLENV=FOO $MSL -e sh -c 'echo ${SECRET:-}')"
check "MSLENV itself visible" "FOO:P/p" "$(MSLENV=FOO:P/p $MSL -e printenv MSLENV)"

# [automount] root changes the mount point, cwd translation and mslpath.
$MSL -u root -e sh -c "printf '[boot]\nsystemd=true\n[automount]\nroot=/\n' > /etc/wsl.conf"
$MSL -t Debian >/dev/null
check "automount root=/ cwd" "/macos$HOMEDIR" "$(cd ~ && $MSL pwd)"
check "automount root=/ mslpath -u" "/macos/Users/x" "$($MSL mslpath /Users/x)"
check "automount root=/ mslpath -w" "/Users/x" "$($MSL mslpath -w /macos/Users/x)"
check "automount root=/ MSLENV /p" "/macos/Users/x" "$(P=/Users/x MSLENV=P/p $MSL -e printenv P)"

echo; echo "$pass passed, $fails failed  (MSL_HOME=$MSL_HOME)"
$MSL --shutdown --force >/dev/null 2>&1
# Stop only this test's msld (the one started with our MSL_HOME), not yours.
for pid in $(pgrep -f "$ROOT/build/bin/msld"); do
  ps -E -ww -o command= -p "$pid" | grep -q "MSL_HOME=$MSL_HOME" && kill "$pid"
done
rm -rf '/tmp/msl m3 dir'
[ "$fails" -eq 0 ]
