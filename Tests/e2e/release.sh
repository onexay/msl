#!/bin/bash
# Release path: package 0.1.0 and 0.1.1, install the 0.1.0 tarball into a scratch
# prefix, run a distro from it, --update to 0.1.1 through dist/update.json, --uninstall.
#   Tests/e2e/release.sh
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
"$ROOT/scripts/package.sh" 0.1.0 >/dev/null 2>&1 && cp "$ROOT/dist/msl-0.1.0-macos-arm64.tar.gz" /tmp/msl-0.1.0.tgz
"$ROOT/scripts/package.sh" 0.1.1 >/dev/null 2>&1
P=/tmp/msl-prefix; rm -rf $P; mkdir -p $P
export MSL_HOME=$(mktemp -d /tmp/msl-rel.XXXXXX); export MSL_CONFIG=/dev/null MSL_VIEW_DIR=$MSL_HOME/view
tar -xzf /tmp/msl-0.1.0.tgz -C /tmp && cp -R /tmp/msl-0.1.0/* $P/ && rm -rf /tmp/msl-0.1.0
echo "\$ $P/bin/msl --version"; $P/bin/msl --version | head -1
$P/bin/msl --install Debian --no-launch | tail -1
echo "run from installed copy: $($P/bin/msl -d Debian -e cat /etc/debian_version)"
echo "msld path: $(ps -axo command | grep '[l]ibexec/msl/msld' | head -1)"
echo "\$ msl --update (channel = dist/update.json, 0.1.1)"
MSL_UPDATE_URL=file://$ROOT/dist/update.json $P/bin/msl --update
echo "\$ msl --version"; $P/bin/msl --version | head -1
echo "distro survives the update: $($P/bin/msl -d Debian -e cat /etc/debian_version)"
echo "msld now running: $(ps -axo command | grep '[l]ibexec/msl/msld' | head -1)"
echo "\$ msl --update again"; MSL_UPDATE_URL=file://$ROOT/dist/update.json $P/bin/msl --update
echo "\$ msl --uninstall"; $P/bin/msl --uninstall
echo "left in prefix: $(find $P -type f | wc -l | tr -d ' ') files"; ls $MSL_HOME | tr '\n' ' '; echo
pgrep -fl "msl-prefix/libexec" || echo "no msld left"
rm -rf $P /tmp/msl-0.1.0.tgz
"$ROOT/scripts/build.sh" >/dev/null 2>&1  # back to the development build (0.1.0)
