#!/bin/bash
# Milestone 3 end-to-end test: cwd translation, mslpath, MSLENV, [automount] root.
#   Tests/e2e/m3.sh [path/to/msl]
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MSL=${1:-$ROOT/build/bin/msl}
export MSL_HOME=$(mktemp -d /tmp/msl-e2e3.XXXXXX)
export MSL_VIEW_DIR=$MSL_HOME/view   # never touch the real ~/MSL
export MSL_CONFIG=$MSL_HOME/none.cfg
pass=0; fails=0
check() {
  if [[ "$3" == "$2" ]]; then echo "✔ $1"; pass=$((pass+1)); else echo "✘ $1"; echo "    expected: $2"; echo "    got:      $3"; fails=$((fails+1)); fi
}
$MSL --install Debian --no-launch >/dev/null
HOMEDIR=$(cd ~ && pwd -P)

check "cwd translation (default mount)" "/mnt/mac$HOMEDIR" "$(cd ~ && $MSL pwd)"
check "cwd with spaces" "/mnt/mac/private/tmp/msl m3 dir" "$(mkdir -p '/tmp/msl m3 dir' && cd '/tmp/msl m3 dir' && $MSL pwd)"
check "--cd overrides cwd" "/etc" "$($MSL --cd /etc pwd)"

check "mslpath on PATH" "/usr/bin/mslpath" "$($MSL command -v mslpath)"
check "mslpath -u (default)" "/mnt/mac/Users/x/Documents" "$($MSL mslpath /Users/x/Documents)"
check "mslpath -u keeps relative" "a/b" "$($MSL mslpath -u a/b)"
check "mslpath -a -u" "/mnt/mac/Users/x" "$($MSL mslpath -a /Users/y/../x)"
check "mslpath -w" "/Users/x/file.txt" "$($MSL mslpath -w /mnt/mac/Users/x/file.txt)"
check "mslpath -m" "/Users/x" "$($MSL mslpath -m /mnt/mac/Users/x)"
check "mslpath -w mount root" "/" "$($MSL mslpath -w /mnt/mac)"
check "mslpath -w Linux-only path" "$MSL_VIEW_DIR/Debian/etc/hosts" "$($MSL mslpath -w /etc/hosts)"
check "mslpath -wa relative" "$MSL_VIEW_DIR/Debian/etc/hosts" "$($MSL --cd /etc mslpath -wa hosts)"
check "mslpath round trip" "$HOMEDIR" "$($MSL -- mslpath -w '$(mslpath' $HOMEDIR')')"
check "mslpath bad flag" "mslpath: Invalid argument" "$($MSL mslpath -z x 2>&1 | head -1)"

check "MSLENV plain" "hello" "$(FOO=hello MSLENV=FOO $MSL -e printenv FOO)"
check "MSLENV /p path" "/mnt/mac/Users/x" "$(P=/Users/x MSLENV=P/p $MSL -e printenv P)"
check "MSLENV /l path list" "/mnt/mac/a:/mnt/mac/b" "$(L=/a:/b MSLENV=L/l $MSL -e printenv L)"
check "MSLENV /w not passed" "" "$(W=x MSLENV=W/w $MSL -e sh -c 'echo ${W:-}')"
check "unlisted vars not passed" "" "$(SECRET=x MSLENV=FOO $MSL -e sh -c 'echo ${SECRET:-}')"
check "MSLENV itself visible" "FOO:P/p" "$(MSLENV=FOO:P/p $MSL -e printenv MSLENV)"

# [automount] root changes the mount point, cwd translation and mslpath.
$MSL -u root -e sh -c "printf '[boot]\nsystemd=true\n[automount]\nroot=/\n' > /etc/wsl.conf"
$MSL -t Debian >/dev/null
check "automount root=/ cwd" "/mac$HOMEDIR" "$(cd ~ && $MSL pwd)"
check "automount root=/ mslpath -u" "/mac/Users/x" "$($MSL mslpath /Users/x)"
check "automount root=/ mslpath -w" "/Users/x" "$($MSL mslpath -w /mac/Users/x)"
check "automount root=/ MSLENV /p" "/mac/Users/x" "$(P=/Users/x MSLENV=P/p $MSL -e printenv P)"

echo; echo "$pass passed, $fails failed  (MSL_HOME=$MSL_HOME)"
$MSL --shutdown --force >/dev/null 2>&1
pkill -f "$ROOT/build/bin/msld" 2>/dev/null
rm -rf '/tmp/msl m3 dir'
[ "$fails" -eq 0 ]
