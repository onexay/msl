#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Neon end-to-end test: --json for the query commands (--list, --list --online,
# --status, --version), JSON errors with wsl.exe's exit codes, and rejection
# of --json everywhere else. Uses a throwaway MSL_HOME.
#   Tests/e2e/neon.sh [path/to/msl]
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MSL=${1:-$ROOT/build/bin/msl}
export MSL_HOME=$(mktemp -d /tmp/msl-neon.XXXXXX)
export MSL_VIEW_DIR=$MSL_HOME/view
export MSL_CONFIG=$MSL_HOME/mslconfig
pass=0; fails=0
check() {  # check "description" <expected> <actual>
  if [[ "$3" == "$2" ]]; then echo "✔ $1"; pass=$((pass+1)); else echo "✘ $1"; echo "    expected: $2"; echo "    got:      $3"; fails=$((fails+1)); fi
}
# q '<python expression over d>' : evaluate against JSON read from stdin
q() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

# Nothing installed: an error, as in wsl.exe, but as JSON on stderr.
out=$($MSL --list --json 2>"$MSL_HOME/err"); rc=$?
check "empty --list exits like wsl.exe" "255" "$rc"
check "empty --list: nothing on stdout" "" "$out"
check "empty --list: JSON error on stderr" "Msl/Service/MSL_E_DEFAULT_DISTRO_NOT_FOUND" "$(q 'd["error"]["code"]' < "$MSL_HOME/err")"
check "empty --status: JSON error" "1" "$($MSL --status --json 2>&1 >/dev/null | q 'd["schema"]')"

check "--version --json" "$(cat "$ROOT/VERSION")" "$($MSL --version --json | q 'd["msl"]')"
check "--version --json: commit" "$(git -C "$ROOT" rev-parse --short=7 HEAD)" "$($MSL --version --json | q 'd.get("commit", "").split(".")[0]')"
check "--version --json: kernel" "True" "$($MSL -v --json | q 'd["kernel"].startswith("6.")')"

CACHE=$HOME/Library/Caches/msl/downloads
DEB=$(ls "$CACHE"/09120df4fadc36fb2a0f7298e197785e6f599f12aaf95d43cba07a8ac7fb316b.wsl 2>/dev/null)
if [ -z "$DEB" ]; then
  $MSL --install Debian --no-launch >/dev/null
else
  $MSL --install --from-file "$DEB" --name Debian --no-launch >/dev/null
fi
$MSL -t Debian >/dev/null 2>&1

check "-l --json" "Debian Stopped True 2" "$($MSL -l --json | q '" ".join(str(x) for x in (d["distributions"][0]["name"], d["distributions"][0]["state"], d["distributions"][0]["default"], d["distributions"][0]["version"]))')"
check "-l -v --json is the same data" "$($MSL -l --json)" "$($MSL -l -v --json)"
check "--json -l --running, none running: empty list, exit 0" "[] 0" "$($MSL --json -l --running | q 'd["distributions"]') $?"
$MSL -d Debian -e true
check "-l --running --json" "Running" "$($MSL -l --running --json | q 'd["distributions"][0]["state"]')"

st=$($MSL --status --json)
check "--status --json: default distro" "Debian" "$(echo "$st" | q 'd["defaultDistribution"]')"
check "--status --json: running VM with raw numbers" "True True True" "$(echo "$st" | q '" ".join(str(x) for x in (d["vm"]["running"], isinstance(d["vm"]["settings"]["memoryBytes"], int), d["vm"]["uptimeMs"] >= 0))')"
printf '[msl2]\nprocessors = 1\nmemory = lots\n' > "$MSL_CONFIG"
st=$($MSL --status --json 2>"$MSL_HOME/err")
check "--status --json: pending change" "processors" "$(echo "$st" | q 'd["vm"]["pendingChanges"][0]["setting"]')"
check "--status --json: warnings in JSON, not stderr" "1 0" "$(echo "$st" | q 'len(d["warnings"])') $(wc -c < "$MSL_HOME/err" | tr -d ' ')"
rm -f "$MSL_CONFIG"

check "--list --online --json" "True" "$($MSL --list --online --json | q 'any(x["name"]=="Debian" and "arm64" in x["architectures"] for x in d["distributions"])')"

# Other commands reject --json; inside a Linux command line it's the program's.
out=$($MSL --terminate Debian --json 2>&1 >/dev/null); rc=$?
check "--terminate --json rejected" "255 Msl/E_INVALIDARG" "$rc $(echo "$out" | q 'd["error"]["code"]')"
check "--json -e rejected" "255" "$($MSL --json -e ls >/dev/null 2>&1; echo $?)"
check "--json in a Linux command line is passed through" "--json" "$($MSL -d Debian -e echo --json)"
check "text output unchanged without --json" "  NAME" "$($MSL -l -v | head -1 | cut -c1-6)"

$MSL --shutdown >/dev/null 2>&1
# Stop only this test's msld (the one started with our MSL_HOME), not yours.
for pid in $(pgrep -f "$ROOT/build/bin/msld"); do
  ps -E -ww -o command= -p "$pid" | grep -q "MSL_HOME=$MSL_HOME" && kill "$pid"
done
echo; echo "$pass passed, $fails failed  (MSL_HOME=$MSL_HOME)"
[ "$fails" = 0 ]
