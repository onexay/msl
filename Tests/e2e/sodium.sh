#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Sodium end-to-end test: byte streams into a distro for the VS Code extension:
# msl --connect (two streams the guest dials back, one per direction), its
# allowlist and permission checks, and idle-timeout sessions.
# Uses a throwaway MSL_HOME, so it has its own msld.
#   Tests/e2e/sodium.sh [path/to/msl]
# The extension itself is checked by hand: see the README in
# github.com/onexay/msl-vscode-extension.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MSL=${1:-$ROOT/build/bin/msl}
export MSL_HOME=$(mktemp -d /tmp/msl-sodium.XXXXXX)
export MSL_VIEW_DIR=$MSL_HOME/view MSL_CONFIG=$MSL_HOME/cfg
printf '[general]\ninstanceIdleTimeout=2000\n' > "$MSL_CONFIG"
D=Ubuntu-24.04
SOCKDIR=/home/tester/.vscode-server/msl
pass=0; fails=0
check() {
  if [[ "$3" == *"$2"* ]]; then echo "✔ $1"; pass=$((pass+1)); else echo "✘ $1"; echo "    expected: $2"; echo "    got:      $3"; fails=$((fails+1)); fi
}

# Echo server: reads to EOF, then writes everything back (needs half-close).
cat > "$MSL_HOME/echo.py" <<'EOF'
import os, socket, sys, threading
p = sys.argv[1]
try: os.unlink(p)
except FileNotFoundError: pass
l = socket.socket(socket.AF_UNIX); l.bind(p); l.listen()
def serve(c):
    buf = bytearray()
    while (d := c.recv(1 << 16)): buf += d
    c.sendall(buf); c.close()
while True:
    c, _ = l.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
EOF

$MSL --install $D --no-launch >/dev/null
$MSL -d $D -u root -e sh -c 'id tester >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash tester'
$MSL --manage $D --set-default-user tester >/dev/null
# instanceIdleTimeout is 2 s here: hold a session open while the echo server is
# needed, or the distro can stop (taking the server and its tmpfs /tmp with it).
$MSL -d $D -e sleep 600 & KEEP=$!
sleep 1
$MSL -d $D -e sh -c "mkdir -p $SOCKDIR && cat > /tmp/echo.py" < "$MSL_HOME/echo.py"
$MSL -d $D -e sh -c "setsid python3 /tmp/echo.py $SOCKDIR/echo.sock >/dev/null 2>&1 </dev/null & sleep 1"

head -c 100000000 /dev/urandom > "$MSL_HOME/in.bin"
want=$(shasum -a 256 < "$MSL_HOME/in.bin" | cut -c1-64)
$MSL -d $D -e sh -c 'setsid python3 -m http.server 18780 --bind 127.0.0.1 -d /etc >/dev/null 2>&1 </dev/null & sleep 1'
$MSL -d $D -u root -e sh -c "setsid python3 /tmp/echo.py /root/rootonly.sock >/dev/null 2>&1 </dev/null & sleep 1"
$MSL -d $D -e sh -c "ln -sf /root/rootonly.sock $SOCKDIR/to-root.sock && ln -sf /run/msl-view $SOCKDIR/to-vm.sock"

# msl --connect: msl itself carries the streams, dialed back by the guest.
connect() { $MSL --connect "$@" 2>&1 < /dev/null; }
check "msl --connect: 100 MB echo with half-close" "$want" "$($MSL --connect $D unix=$SOCKDIR/echo.sock < "$MSL_HOME/in.bin" | shasum -a 256 | cut -c1-64)"
check "msl --connect: distro name is case-insensitive" "200 OK" "$(printf 'GET /hostname HTTP/1.0\r\n\r\n' | $MSL --connect ubuntu-24.04 tcp=18780 | head -1 | tr -d '\r')"
check "msl --connect: tcp target" "200 OK" "$(printf 'GET /hostname HTTP/1.0\r\n\r\n' | $MSL --connect $D tcp=18780 | head -1 | tr -d '\r')"
for bad in /var/run/docker.sock /run/systemd/private $SOCKDIR/../msl/echo.sock $SOCKDIR/sub/x.sock /root/.vscode-server/msl/x.sock $SOCKDIR/.hidden.sock; do
  check "msl --connect: refuses $bad" "not allowed" "$(connect $D unix=$bad)"
done
check "msl --connect: symlink to a root-only socket (runs as the user)" "Permission denied" "$(connect $D unix=$SOCKDIR/to-root.sock)"
check "msl --connect: symlink to a VM-only path (resolves in the distro)" "No such file" "$(connect $D unix=$SOCKDIR/to-vm.sock)"
check "msl --connect: unknown distro" "There is no distribution" "$(connect Nope unix=$SOCKDIR/echo.sock)"
check "msl --connect: nothing listening" "Connection refused" "$(connect $D tcp=1)"
check "msl --connect: malformed target" "Invalid command line argument" "$(connect $D path=/x)"

kill $KEEP 2>/dev/null; wait $KEEP 2>/dev/null  # from here on, only the pipe keeps the distro running
# Sessions: an open pipe keeps the distro past instanceIdleTimeout (2 s here),
# and connecting starts a stopped distro.
sleep 4
check "msl --connect: starts a stopped distro" "Running" "$(connect $D unix=$SOCKDIR/missing.sock >/dev/null; $MSL -l -v | grep $D)"
# The servers went with the distro's earlier stop: start one to hold a pipe to.
$MSL -d $D -e sh -c "setsid python3 -m http.server 18781 >/dev/null 2>&1 </dev/null & sleep 1"
(sleep 6) | $MSL --connect $D tcp=18781 >/dev/null 2>&1 &
sleep 5
check "msl --connect: an open pipe keeps the distro running" "Running" "$($MSL -l -v | grep $D)"
wait
sleep 4
check "msl --connect: distro stops after the pipe closes" "Stopped" "$($MSL -l -v | grep $D)"

echo; echo "$pass passed, $fails failed  (MSL_HOME=$MSL_HOME)"
$MSL --shutdown --force >/dev/null 2>&1
# Stop only this test's msld (the one started with our MSL_HOME), not yours.
for pid in $(pgrep -f "$ROOT/build/bin/msld"); do
  ps -E -ww -o command= -p "$pid" | grep -q "MSL_HOME=$MSL_HOME" && kill "$pid"
done
[ "$fails" -eq 0 ]
