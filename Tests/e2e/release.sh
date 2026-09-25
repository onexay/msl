#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Release path: package 0.1.0 and 0.1.1, install the 0.1.0 tarball into a scratch
# prefix with install.sh (IDE setup in a throwaway HOME), run a distro from it,
# --update to 0.1.1 through dist/update.json, --uninstall.
#   Tests/e2e/release.sh
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
"$ROOT/scripts/package.sh" 0.1.0 >/dev/null 2>&1 && cp "$ROOT/dist/msl-0.1.0-macos-arm64.tar.gz" /tmp/msl-0.1.0-macos-arm64.tar.gz
"$ROOT/scripts/package.sh" 0.1.1 >/dev/null 2>&1
P=/tmp/msl-prefix; rm -rf $P; mkdir -p $P
export MSL_HOME=$(mktemp -d /tmp/msl-rel.XXXXXX); export MSL_CONFIG=/dev/null MSL_VIEW_DIR=$MSL_HOME/view
# IDE setup goes to a throwaway HOME with VS Code's stock argv.json (VS Code must be in /Applications).
IH=$(mktemp -d /tmp/msl-ide.XXXXXX); mkdir -p $IH/.vscode
printf '// VS Code argv.json\n{\n\t// "disable-hardware-acceleration": true,\n\t"enable-crash-reporter": true\n}\n' > $IH/.vscode/argv.json
cp $IH/.vscode/argv.json $IH/argv.orig
echo "tarball ships the extension: $(tar -tzf /tmp/msl-0.1.0-macos-arm64.tar.gz | grep -c 'share/msl/msl.vsix')"
echo "\$ install.sh --from msl-0.1.0-macos-arm64.tar.gz --prefix $P --yes --no-path   (HOME=$IH)"
HOME=$IH sh "$ROOT/install.sh" --from /tmp/msl-0.1.0-macos-arm64.tar.gz --prefix $P --yes --no-path 2>&1 | grep -E "error|Installed|Visual Studio Code|✔ (installed|added)"
echo "argv.json enables onexay.msl: $(grep -c '"enable-proposed-api": \["onexay.msl"\]' $IH/.vscode/argv.json)"
echo "extension listed: $(grep -c '"onexay.msl"' $IH/.vscode/extensions/extensions.json)"
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
echo "\$ msl --uninstall   (HOME=$IH)"; HOME=$IH $P/bin/msl --uninstall
echo "argv.json restored: $(cmp -s $IH/argv.orig $IH/.vscode/argv.json && echo yes || echo NO)"
echo "extension listed after uninstall: $(grep -c '"onexay.msl"' $IH/.vscode/extensions/extensions.json)"
rm -rf $IH
echo "left in prefix: $(find $P -type f | wc -l | tr -d ' ') files"; ls $MSL_HOME | tr '\n' ' '; echo
pgrep -fl "msl-prefix/libexec" || echo "no msld left"
rm -rf $P /tmp/msl-0.1.0-macos-arm64.tar.gz
"$ROOT/scripts/build.sh" >/dev/null 2>&1  # back to the development build
