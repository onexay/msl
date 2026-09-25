#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Boron milestone end-to-end test: hostname/hosts, localhost forwarding, DNS tunneling, ~/.msl/distros file view.
#   Tests/e2e/boron.sh [path/to/msl]
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MSL=${1:-$ROOT/build/bin/msl}
export MSL_HOME=$(mktemp -d /tmp/msl-boron.XXXXXX)
export MSL_CONFIG=$MSL_HOME/cfg MSL_VIEW_DIR=$MSL_HOME/view
: > "$MSL_CONFIG"
MACNAME=$(scutil --get LocalHostName)
pass=0; fails=0
check() {
  if [[ "$3" == *"$2"* ]]; then echo "✔ $1"; pass=$((pass+1)); else echo "✘ $1"; echo "    expected: $2"; echo "    got:      $3"; fails=$((fails+1)); fi
}
check_not() {
  if [[ "$3" != *"$2"* ]]; then echo "✔ $1"; pass=$((pass+1)); else echo "✘ $1 (found: $2)"; fails=$((fails+1)); fi
}
$MSL --install Ubuntu-24.04 --no-launch >/dev/null
$MSL -u root -e sh -c 'id tester >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash tester'

# hostname / hosts
check "hostname = Mac name" "$MACNAME" "$($MSL hostname)"
check "/etc/hostname generated" "$MACNAME" "$($MSL cat /etc/hostname)"
check "/etc/hosts has 127.0.1.1 entry" "127.0.1.1	$MACNAME.	$MACNAME" "$($MSL cat /etc/hosts)"
check "/etc/hosts has host.internal" "host.internal" "$($MSL cat /etc/hosts)"
check_not "sudo: no 'unable to resolve host'" "unable to resolve host" "$($MSL -u tester sudo -n true 2>&1)"
$MSL -u root -e sh -c "printf '[boot]\nsystemd=true\n[network]\nhostname=custom-name\n' > /etc/wsl.conf"; $MSL -t Ubuntu-24.04 >/dev/null
check "[network] hostname" "custom-name" "$($MSL hostname)"

# localhost forwarding
$MSL -e sh -c 'mkdir -p /srv/www && head -c 1048576 /dev/urandom > /srv/www/blob && cd /srv/www && setsid nohup python3 -m http.server 18765 --bind 127.0.0.1 >/dev/null 2>&1 </dev/null &'
$MSL -e sh -c 'setsid nohup python3 -m http.server 18766 --bind :: >/dev/null 2>&1 </dev/null &'
sleep 2
check "forward 127.0.0.1 listener (IPv4)" "200" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:18765/)"
check "forward 127.0.0.1 listener (IPv6 ::1)" "200" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 'http://[::1]:18765/')"
check "forward :: listener" "200" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:18766/)"
check "1 MB through forwarding" "1048576" "$(curl -s --max-time 10 -o /dev/null -w '%{size_download}' http://127.0.0.1:18765/blob)"
$MSL -u root -e pkill -f "http.server 18765"
sleep 2
check "port released when the server exits" "000" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:18765/)"
check "NFS port is not forwarded" "no" "$(nc -z -G 1 127.0.0.1 21049 2>/dev/null && echo yes || echo no)"

# Flow control: a slow reader must not freeze the VM (Virtualization.framework
# vsock blocks if the host stops reading; see FramedBridge).
( $MSL -e sh -c 'head -c 100000000 /dev/zero' | (sleep 8; cat >/dev/null) ) &
sleep 2
check "VM responsive while a reader is paused" "alive" "$(perl -e 'alarm 5; exec @ARGV' $MSL -e echo alive 2>/dev/null)"
wait
check "paused reader still gets every byte" "50000000" "$($MSL -e sh -c 'head -c 50000000 /dev/zero' | (sleep 3; wc -c | tr -d ' '))"

empty=0; for i in $(seq 1 30); do [ -z "$($MSL cat /etc/hostname)" ] && empty=$((empty+1)); done
check "no lost output across 30 short sessions" "0" "$empty"

# DNS tunneling
check "resolv.conf → stub" "nameserver 10.255.255.254" "$($MSL cat /etc/resolv.conf)"
check "Mac-only .local name resolves" "$MACNAME.local" "$($MSL getent hosts $MACNAME.local)"
check_not ".local: no loopback answers" "::1 " "$($MSL getent hosts $MACNAME.local)"
check "public name resolves" "example.com" "$($MSL getent hosts example.com)"
check "NXDOMAIN" "not found" "$($MSL getent hosts no-such-host.invalid || echo 'not found')"
# #41: no AAAA record must answer at once, not after the 5 s resolver timeout.
check "IPv4-only name, A+AAAA under 2 s" "fast" "$($MSL -e sh -c 's=$(date +%s); getent ahosts github.com >/dev/null && [ $(( $(date +%s) - s )) -lt 2 ] && echo fast')"
# A CNAME chain must be flattened into address records for the question name.
check "CNAME name resolves (A)" "STREAM deb.debian.org" "$($MSL getent ahostsv4 deb.debian.org)"
check "CNAME name resolves (AAAA)" "STREAM deb.debian.org" "$($MSL getent ahostsv6 deb.debian.org)"
check "TCP DNS path (python getaddrinfo)" "ok" "$($MSL -e python3 -c 'import socket; socket.getaddrinfo("apple.com", 443); print("ok")')"

# ~/.msl/distros file view
check "~/.msl/distros/<distro> folder by name" "Ubuntu-24.04" "$(ls $MSL_VIEW_DIR)"
check "read distro file from the Mac" "Ubuntu 24.04" "$(cat $MSL_VIEW_DIR/Ubuntu-24.04/etc/os-release)"
echo from-mac > "$MSL_VIEW_DIR/Ubuntu-24.04/home/tester/note.txt"
check "write from the Mac, owner inherited" "tester:tester from-mac" "$($MSL -e sh -c 'stat -c %U:%G /home/tester/note.txt | tr -d "\n"; echo -n " "; cat /home/tester/note.txt')"
mkdir "$MSL_VIEW_DIR/Ubuntu-24.04/home/tester/newdir"
check "mkdir from the Mac, owner inherited" "tester" "$($MSL stat -c %U /home/tester/newdir)"
$MSL -u tester -e sh -c 'echo from-linux > /home/tester/fromlinux.txt'
check "Linux write visible on the Mac" "from-linux" "$(cat $MSL_VIEW_DIR/Ubuntu-24.04/home/tester/fromlinux.txt)"
check "mslpath -w points into the view" "$MSL_VIEW_DIR/Ubuntu-24.04/etc/hosts" "$($MSL mslpath -w /etc/hosts)"
VIEWMNT=$(mount | grep "$(basename $MSL_HOME)/view/Ubuntu-24.04 ")  # the mount table shows /private/tmp/…
check "per-distro mount of 127.0.0.1:/<name>" "127.0.0.1:/Ubuntu-24.04 on" "$VIEWMNT"
check "mounted by the user" "mounted by $(id -un)" "$VIEWMNT"
check_not "browsable (Finder Locations, like Explorer's 'Linux' node)" "nobrowse" "${VIEWMNT:-nobrowse (not mounted)}"
check "Finder lists the distro by name" "Ubuntu-24.04" "$(osascript -e 'tell application "Finder" to get name of every disk')"
check "distro logo as the volume icon" "512" "$(sips -g pixelWidth $MSL_VIEW_DIR/Ubuntu-24.04/.VolumeIcon.icns 2>/dev/null | tail -1)"
check "custom-icon flag set" "04 00" "$(xattr -px com.apple.FinderInfo $MSL_VIEW_DIR/Ubuntu-24.04 2>/dev/null | head -1)"
check "icon kept out of the distro image" "0" "$($MSL -e sh -c 'ls -a / | grep -c -E "VolumeIcon|^\._"')"
# macOS metadata stays on the Mac: copies with xattrs work, Linux never sees ._* or .DS_Store
echo data > $MSL_HOME/x.txt; xattr -w com.apple.quarantine '0083;0;msl;' $MSL_HOME/x.txt; xattr -w com.example.tag hi $MSL_HOME/x.txt
check "cp of a file with xattrs" "ok" "$(cp $MSL_HOME/x.txt $MSL_VIEW_DIR/Ubuntu-24.04/home/tester/ && echo ok)"
check "ditto (Finder's copy engine) with xattrs" "ok" "$(ditto $MSL_HOME/x.txt $MSL_VIEW_DIR/Ubuntu-24.04/home/tester/x2.txt && echo ok)"
check "xattrs readable on the Mac" "com.example.tag: hi" "$(xattr -l $MSL_VIEW_DIR/Ubuntu-24.04/home/tester/x.txt)"
touch $MSL_VIEW_DIR/Ubuntu-24.04/home/tester/.DS_Store
check_not "no AppleDouble or .DS_Store files in Linux" "._" "$($MSL -e ls -a /home/tester | tr '\n' ' ')$($MSL -e ls -a /home/tester | grep -c DS_Store | sed 's/^0$//;s/.*[1-9].*/._DS_Store/')"
check "file content intact in Linux" "data" "$($MSL cat /home/tester/x.txt)"
$MSL --import Second $MSL_HOME/loc - < <($MSL --export Ubuntu-24.04 - --format tar) >/dev/null
check "new distro appears in the view" "Second" "$(ls $MSL_VIEW_DIR)"
$MSL --unregister Second >/dev/null
sleep 2  # the Mac's NFS client caches directory listings (actimeo=1)
check_not "unregistered distro removed from the view" "Second" "$(ls $MSL_VIEW_DIR)"
$MSL --shutdown
check_not "shutdown unmounts every distro" "$(basename $MSL_HOME)/view/" "$(mount)"
check "no mount points left behind" "" "$(ls -A $MSL_VIEW_DIR)"

# Switches
printf '[msl2]\nlocalhostForwarding=false\ndnsTunneling=false\n' > "$MSL_CONFIG"
$MSL -e sh -c 'setsid nohup python3 -m http.server 18767 --bind 127.0.0.1 >/dev/null 2>&1 </dev/null &'
sleep 2
check "localhostForwarding=false" "000" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:18767/)"
check_not "dnsTunneling=false → vmnet DNS" "10.255.255.254" "$($MSL cat /etc/resolv.conf)"

echo; echo "$pass passed, $fails failed  (MSL_HOME=$MSL_HOME)"
$MSL --shutdown --force >/dev/null 2>&1
pkill -f "$ROOT/build/bin/msld" 2>/dev/null
[ "$fails" -eq 0 ]
