#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Reset msl to a clean slate for testing: terminate and unregister every distro
# (retrying a failed unregister once, see #34), shut down the VM, remove stale
# vsock bridge sockets, optionally stop msld, then report what is left.
#
#   scripts/clean-slate.sh [--stop-msld] [--reset-disk]
#
# --reset-disk: for a data disk the VM can't boot from (e.g. ext4 corruption).
#   After the shutdown it stops msld, moves data.img and registry.json aside as
#   *.reset-<timestamp> (delete them once you don't need them), and msld creates a
#   fresh disk on its next start. Implies --stop-msld.
# msl commands time out after MSL_TIMEOUT seconds (default 120), so a VM that
# can't boot doesn't hang the script.
#
# Uses build/bin/msl unless MSL is set. Everything is also written to
# build/logs/clean-slate-<timestamp>.log. DELETES ALL DISTROS AND THEIR FILES.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MSL=${MSL:-$ROOT/build/bin/msl}
DATA="$HOME/Library/Application Support/msl"
STOP_MSLD=0
RESET_DISK=0
TIMEOUT=${MSL_TIMEOUT:-120}
for a in "$@"; do
  case $a in
    --stop-msld) STOP_MSLD=1 ;;
    --reset-disk) RESET_DISK=1; STOP_MSLD=1 ;;
    -h|--help) sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

mkdir -p "$ROOT/build/logs"
LOG="$ROOT/build/logs/clean-slate-$(date '+%Y%m%d-%H%M%S').log"

step() { printf '\n== %s %s\n' "$(date '+%H:%M:%S')" "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; rc=$?; [ $rc -eq 0 ] || printf '(exit %s)\n' "$rc"; return $rc; }
# An msl command with a timeout (perl alarm: exit 142 when it fires).
msl() {
  printf '$ msl %s\n' "$*"
  perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$MSL" "$@"; rc=$?
  [ $rc -eq 142 ] && printf '(timed out after %s s)\n' "$TIMEOUT" || { [ $rc -eq 0 ] || printf '(exit %s)\n' "$rc"; }
  return $rc
}

# Registered distro names, one per line (empty when none).
distros() {
  perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$MSL" --list --json 2>/dev/null | /usr/bin/python3 -c '
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
  msl --terminate "$n"
  msl --unregister "$n"; rc=$?
  if [ $rc -ne 0 ] && [ $rc -ne 142 ]; then
    echo "unregister failed; retrying once (#34)"
    sleep 2
    msl --unregister "$n"
  fi
done

step "shutdown"
msl --shutdown

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
if [ $RESET_DISK -eq 0 ]; then
  step "distros after"
  names=$(distros); [ -n "$names" ] && echo "$names" || echo "(none)"
fi

if [ $STOP_MSLD -eq 1 ]; then
  step "stop msld"
  if pgrep -f "$ROOT/build/bin/msld" >/dev/null; then
    run pkill -f "$ROOT/build/bin/msld"
    sleep 1
  else
    echo "(not running)"
  fi
fi

if [ $RESET_DISK -eq 1 ]; then
  step "reset data disk"
  if pgrep -f 'bin/msld|libexec/msl/msld' >/dev/null; then
    echo "an msld is still running (another install?); not touching data.img:"; pgrep -lf 'bin/msld|libexec/msl/msld'
  else
    ts=$(date '+%Y%m%d-%H%M%S')
    [ -e "$DATA/data.img" ] && run mv "$DATA/data.img" "$DATA/data.img.reset-$ts"
    [ -e "$DATA/registry.json" ] && run mv "$DATA/registry.json" "$DATA/registry.json.reset-$ts"
    # Finder-view mount points of the old distros (rmdir only removes empty, unmounted ones).
    for d in "$HOME/.msl/distros"/*; do [ -d "$d" ] && ! mount | grep -q " on $d " && run rmdir "$d"; done
    echo "msld creates a fresh data.img on its next start; delete the *.reset-$ts files when you no longer need them."
  fi
fi

step "what is left"
echo "-- registry.json:"; cat "$DATA/registry.json" 2>/dev/null; echo
echo "-- data dir:"; ls -la "$DATA"
echo "-- run dir:"; ls -A "$DATA/run" 2>/dev/null | sed 's/^/  /'; [ -n "$(ls -A "$DATA/run" 2>/dev/null)" ] || echo "  (empty)"
echo "-- data.img on disk:"; du -h "$DATA/data.img" 2>/dev/null | cut -f1
echo "-- msl mounts:"; mount | grep -iE 'msl|127\.0\.0\.1:/' || echo "(none)"
for d in "$HOME/.msl/distros" "$HOME/MSL"; do
  echo "-- ${d#$HOME/}:"
  if [ -d "$d" ]; then ls -A "$d" | sed 's/^/  /'; [ -n "$(ls -A "$d")" ] || echo "  (empty)"; else echo "  (missing)"; fi
done
echo "-- processes:"; pgrep -lf 'bin/msld|msl-bridge' || echo "(no msld)"

step "done; log: $LOG"
}

main 2>&1 | tee -a "$LOG"
