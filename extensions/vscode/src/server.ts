// SPDX-License-Identifier: Apache-2.0
// Install and start the VS Code Server inside a distro, listening on a Unix
// socket (never a TCP port). Runs as the distro's default user.

import * as vscode from 'vscode';
import { log, spawnInDistro } from './msl';

export interface Server {
    socket: string;
    token: string;
}

// $1 commit, $2 quality. Prints MSL_SOCKET=… and MSL_TOKEN=… on success;
// progress goes to stderr.
const SCRIPT = String.raw`
set -eu
commit=$1 quality=$2
case $(uname -m) in
  aarch64) arch=arm64 ;;
  x86_64) arch=x64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
exe=code-server; [ "$quality" = stable ] || exe=code-server-$quality
root=$HOME/.vscode-server
bin=$root/bin/$commit
run=$root/msl
sock=$run/$commit.sock tok=$run/$commit.token pidf=$run/$commit.pid
mkdir -p "$root/bin" "$run"
chmod 700 "$run"

if [ ! -x "$bin/bin/$exe" ]; then
  exec 9>"$run/install.lock"
  flock 9
  if [ ! -x "$bin/bin/$exe" ]; then
    url=https://update.code.visualstudio.com/commit:$commit/server-linux-$arch/$quality
    echo "downloading $url" >&2
    tmp=$(mktemp -d "$root/bin/.msl-XXXXXX")
    if command -v curl >/dev/null; then
      curl -fsSL --retry 3 -o "$tmp/server.tgz" "$url"
    elif command -v wget >/dev/null; then
      wget -q -O "$tmp/server.tgz" "$url"
    else
      echo "install curl or wget in this distro to download the VS Code Server" >&2; rm -rf "$tmp"; exit 1
    fi
    tar -xzf "$tmp/server.tgz" -C "$tmp" --strip-components 1
    rm -f "$tmp/server.tgz"
    rm -rf "$bin"
    mv "$tmp" "$bin"
  fi
  exec 9>&-
fi

if [ ! -s "$tok" ]; then
  (umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$tok")
fi

# Alive and ours: pids start over when the VM restarts, so a bare kill -0 on
# an old pidfile can hit an unrelated process.
running() {
  [ -S "$sock" ] && [ -s "$pidf" ] || return 1
  tr '\0' ' ' 2>/dev/null < "/proc/$(cat "$pidf")/cmdline" | grep -qF -- "--socket-path $sock "
}
# Both of a window's connections resolve at once; start one server.
exec 8>"$run/start.lock"
flock 8
if ! running; then
  echo "starting the VS Code Server" >&2
  rm -f "$sock"
  setsid "$bin/bin/$exe" --socket-path "$sock" --connection-token-file "$tok" \
    --accept-server-license-terms --enable-remote-auto-shutdown --telemetry-level off \
    </dev/null >"$run/$commit.log" 2>&1 8>&- &
  echo $! > "$pidf"
  i=0
  while [ ! -S "$sock" ]; do
    i=$((i + 1))
    if [ $i -gt 300 ] || ! kill -0 "$(cat "$pidf")" 2>/dev/null; then
      echo "the VS Code Server did not start; log:" >&2; tail -n 20 "$run/$commit.log" >&2; exit 1
    fi
    sleep 0.1
  done
fi
exec 8>&-
echo "MSL_SOCKET=$sock"
echo "MSL_TOKEN=$(cat "$tok")"
`;

export function ensureServer(distro: string, token?: vscode.CancellationToken): Promise<Server> {
    const commit = vscode.env.appCommit;
    const quality = vscode.env.appQuality ?? 'stable';
    if (!commit) {
        return Promise.reject(new Error('VS Code has no commit id (running from sources?)'));
    }
    return new Promise((resolve, reject) => {
        const child = spawnInDistro(distro, ['sh', '-c', SCRIPT, 'sh', commit, quality]);
        token?.onCancellationRequested(() => child.kill());
        let out = '';
        let err = '';
        child.stdout.setEncoding('utf8').on('data', (d: string) => (out += d));
        child.stderr.setEncoding('utf8').on('data', (d: string) => {
            err += d;
            for (const line of d.split('\n').filter(Boolean)) {
                log.info(`[${distro}] ${line}`);
            }
        });
        child.stdin.end();
        child.on('error', reject);
        child.on('close', (code) => {
            const socket = /^MSL_SOCKET=(.+)$/m.exec(out)?.[1];
            const tok = /^MSL_TOKEN=(.+)$/m.exec(out)?.[1];
            if (code === 0 && socket && tok) {
                resolve({ socket, token: tok });
            } else {
                reject(new Error(err.trim().split('\n').pop() || `server setup exited with ${code}`));
            }
        });
    });
}
