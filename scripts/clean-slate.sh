#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Reset msl to a clean slate for testing: terminate and unregister every distro
# (retrying a failed unregister once, see #34), shut down the VM, remove stale
# vsock bridge sockets, optionally stop msld, then report what is left.
#
#   scripts/clean-slate.sh [--stop-msld]
#
# Uses build/bin/msl unless MSL is set. Everything is also written to
# build/logs/clean-slate-<timestamp>.log. DELETES ALL DISTROS AND THEIR FILES.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MSL=${MSL:-$ROOT/build/bin/msl}
DATA="$HOME/Library/Application Support/msl"
STOP_MSLD=0
for a in "$@"; do
  case $a in
    --stop-msld) STOP_MSLD=1 ;;
    -h|--help) sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

mkdir -p "$ROOT/build/logs"
LOG="$ROOT/build/logs/clean-slate-$(date '+%Y%m%d-%H%M%S').log"

step() { printf '\n== %s %s\n' "$(date '+%H:%M:%S')" "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; rc=$?; [ $rc -eq 0 ] || printf '(exit %s)\n' "$rc"; return $rc; }

# Registered distro names, one per line (empty when none).
distros() {
  "$MSL" --list --json 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for x in d.get("distributions", []):
    print(x["name"])'
}

main() {
step "msl: $MSL"
[ -x "$MSL" ] || { echo "not executable: $MSL (run scripts/build.sh)"; exit 1; }

step "distros before"
names=$(distros)
[ -n "$names" ] && echo "$names" || echo "(none)"

echo "$names" | while IFS= read -r n; do
  [ -n "$n" ] || continue
  step "remove $n"
  run "$MSL" --terminate "$n"
  if ! run "$MSL" --unregister "$n"; then
    echo "unregister failed; retrying once (#34)"
    sleep 2
    run "$MSL" --unregister "$n"
  fi
done

step "shutdown"
run "$MSL" --shutdown

step "stale sockets"
# The VM is stopped, so no vsock bridge is listening.
found=0
for s in "$DATA"/run/vsock-*.sock; do
  [ -e "$s" ] || continue
  found=1
  run rm -f "$s"
done
[ $found -eq 1 ] || echo "(none)"

# Ask msl before msld is stopped: any msl command starts msld again.
step "distros after"
names=$(distros); [ -n "$names" ] && echo "$names" || echo "(none)"

if [ $STOP_MSLD -eq 1 ]; then
  step "stop msld"
  if pgrep -f "$ROOT/build/bin/msld" >/dev/null; then
    run pkill -f "$ROOT/build/bin/msld"
    sleep 1
  else
    echo "(not running)"
  fi
fi

step "what is left"
echo "-- registry.json:"; cat "$DATA/registry.json" 2>/dev/null; echo
echo "-- data dir:"; ls -la "$DATA"
echo "-- run dir:"; ls -A "$DATA/run" 2>/dev/null | sed 's/^/  /'; [ -n "$(ls -A "$DATA/run" 2>/dev/null)" ] || echo "  (empty)"
echo "-- data.img on disk:"; du -h "$DATA/data.img" 2>/dev/null | cut -f1
echo "-- msl mounts:"; mount | grep -iE 'msl|127\.0\.0\.1:/' || echo "(none)"
echo "-- ~/MSL:"; if [ -d "$HOME/MSL" ]; then ls -A "$HOME/MSL" | sed 's/^/  /'; [ -n "$(ls -A "$HOME/MSL")" ] || echo "  (empty)"; else echo "  (missing)"; fi
echo "-- processes:"; pgrep -lf 'bin/msld|msl-bridge' || echo "(no msld)"

step "done; log: $LOG"
}

main 2>&1 | tee -a "$LOG"
