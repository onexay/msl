#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Sodium end-to-end test: byte streams into a distro for the VS Code extension.
# msl-bridge (stdio relay), msld's connect socket (vsock 1026 and the 1025
# forwarder), its allowlist and permission checks, and idle-timeout sessions.
# Uses a throwaway MSL_HOME, so it has its own msld and connect.sock.
#   Tests/e2e/sodium.sh [path/to/msl]
# The extension itself is checked by hand: see extensions/vscode/README.md.
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
# connect.sock client: client.py <distro> <target> [bytes] [hold-seconds]
cat > "$MSL_HOME/client.py" <<'EOF'
import hashlib, os, socket, sys, threading, time
s = socket.socket(socket.AF_UNIX); s.connect(os.path.join(os.environ["MSL_HOME"], "connect.sock"))
s.sendall(f"CONNECT distro={sys.argv[1]} {sys.argv[2]}\n".encode())
line = b""
while not line.endswith(b"\n"):
    b = s.recv(1)
    if not b: break
    line += b
line = line.decode().strip()
n = int(sys.argv[3]) if len(sys.argv) > 3 else 0
if not line.startswith("OK") or n == 0:
    if len(sys.argv) > 4: time.sleep(float(sys.argv[4]))
    print(line); sys.exit(0)
data = os.urandom(n)
threading.Thread(target=lambda: (s.sendall(data), s.shutdown(socket.SHUT_WR))).start()
got = bytearray()
while (d := s.recv(1 << 20)): got += d
print(line, "match" if hashlib.sha256(got).digest() == hashlib.sha256(data).digest() else f"MISMATCH {len(got)}")
EOF
client() { python3 "$MSL_HOME/client.py" "$@"; }

$MSL --install $D --no-launch >/dev/null
$MSL -d $D -u root -e sh -c 'id tester >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash tester'
$MSL --manage $D --set-default-user tester >/dev/null
# instanceIdleTimeout is 2 s here: hold a session open while the echo server is
# needed, or the distro can stop (taking the server and its tmpfs /tmp with it).
$MSL -d $D -e sleep 600 & KEEP=$!
sleep 1
$MSL -d $D -e sh -c "mkdir -p $SOCKDIR && cat > /tmp/echo.py" < "$MSL_HOME/echo.py"
$MSL -d $D -e sh -c "setsid python3 /tmp/echo.py $SOCKDIR/echo.sock >/dev/null 2>&1 </dev/null & sleep 1"

# msl-bridge (the extension's fallback)
head -c 100000000 /dev/urandom > "$MSL_HOME/in.bin"
want=$(shasum -a 256 < "$MSL_HOME/in.bin" | cut -c1-64)
check "msl-bridge: 100 MB echo with half-close" "$want" "$($MSL -d $D -e /run/msl/init msl-bridge unix:$SOCKDIR/echo.sock < "$MSL_HOME/in.bin" | shasum -a 256 | cut -c1-64)"
$MSL -d $D -e sh -c 'setsid python3 -m http.server 18780 --bind 127.0.0.1 -d /etc >/dev/null 2>&1 </dev/null & sleep 1'
check "msl-bridge: tcp target" "200 OK" "$(printf 'GET /hostname HTTP/1.0\r\n\r\n' | $MSL -d $D -e /run/msl/init msl-bridge tcp:18780 | head -1)"
$MSL -d $D -e /run/msl/init msl-bridge unix:/nope 2>/dev/null; check "msl-bridge: connect error exits 1" "1" "$?"
$MSL -d $D -e /run/msl/init msl-bridge bogus 2>/dev/null; check "msl-bridge: usage error exits 2" "2" "$?"

# connect.sock
check "connect.sock is 0600" "600" "$(stat -f %Lp "$MSL_HOME/connect.sock")"
check "connect: 100 MB echo over vsock 1026" "OK match" "$(client $D unix=$SOCKDIR/echo.sock 100000000)"
check "connect: distro name is case-insensitive" "OK match" "$(client ubuntu-24.04 unix=$SOCKDIR/echo.sock 1000)"
check "connect: tcp target (1025 forwarder)" "OK
HTTP/1.0 200 OK" "$(printf "CONNECT distro=$D tcp=18780\nGET /hostname HTTP/1.0\r\n\r\n" | nc -U "$MSL_HOME/connect.sock" | head -2 | tr -d '\r')"
for bad in /var/run/docker.sock /run/systemd/private $SOCKDIR/../msl/echo.sock $SOCKDIR/sub/x.sock /root/.vscode-server/msl/x.sock $SOCKDIR/.hidden.sock; do
  check "connect: refuses $bad" "not allowed" "$(client $D unix=$bad)"
done
$MSL -d $D -u root -e sh -c "setsid python3 /tmp/echo.py /root/rootonly.sock >/dev/null 2>&1 </dev/null & sleep 1"
$MSL -d $D -e sh -c "ln -sf /root/rootonly.sock $SOCKDIR/to-root.sock && ln -sf /run/msl-view $SOCKDIR/to-vm.sock"
check "connect: symlink to a root-only socket (runs as the user)" "Permission denied" "$(client $D unix=$SOCKDIR/to-root.sock)"
check "connect: symlink to a VM-only path (resolves in the distro)" "No such file" "$(client $D unix=$SOCKDIR/to-vm.sock)"
check "connect: unknown distro" "ERR There is no distribution" "$(client Nope unix=$SOCKDIR/echo.sock)"
check "connect: malformed line" "ERR expected: CONNECT" "$(printf 'HELLO\n' | nc -U "$MSL_HOME/connect.sock")"

kill $KEEP 2>/dev/null; wait $KEEP 2>/dev/null  # from here on, only the pipe keeps the distro running
# Sessions: an open pipe keeps the distro past instanceIdleTimeout (2 s here),
# and connecting starts a stopped distro.
client $D unix=$SOCKDIR/echo.sock 0 6 >/dev/null &
sleep 5
check "connect: open pipe keeps the distro running" "Running" "$($MSL -l -v | grep $D)"
wait
sleep 4
check "connect: distro stops after the pipe closes" "Stopped" "$($MSL -l -v | grep $D)"
check "connect: starts a stopped distro" "Running" "$(client $D unix=$SOCKDIR/missing.sock >/dev/null; $MSL -l -v | grep $D)"

# Extension builds (only when its dev dependencies are installed)
if [ -d "$ROOT/extensions/vscode/node_modules" ]; then
  check "extension compiles" "ok" "$(cd "$ROOT/extensions/vscode" && npx tsc -p . && echo ok)"
fi

echo; echo "$pass passed, $fails failed  (MSL_HOME=$MSL_HOME)"
$MSL --shutdown --force >/dev/null 2>&1
# Stop only this test's msld (the one started with our MSL_HOME), not yours.
for pid in $(pgrep -f "$ROOT/build/bin/msld"); do
  ps -E -ww -o command= -p "$pid" | grep -q "MSL_HOME=$MSL_HOME" && kill "$pid"
done
[ "$fails" -eq 0 ]
