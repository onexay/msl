// SPDX-License-Identifier: Apache-2.0
// Install and start the VS Code Server inside a distro, listening on a Unix
// socket (never a TCP port). Runs as the distro's default user. The server is
// downloaded on the Mac (cached across distros, and stock images such as
// Debian have neither curl nor wget) and piped into the distro.

import * as fs from 'fs';
import * as https from 'https';
import * as os from 'os';
import * as path from 'path';
import * as vscode from 'vscode';
import { log, spawnInDistro } from './msl';

export interface Server {
    socket: string;
    token: string;
}

// $1 commit, $2 quality, $3 "probe" or "install" (the server tarball on stdin).
// Prints MSL_SOCKET=… and MSL_TOKEN=… on success, or MSL_NEED_SERVER=<arch>
// when probing a distro that doesn't have this commit yet. Progress goes to stderr.
const SCRIPT = String.raw`
set -eu
commit=$1 quality=$2 mode=$3
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
  if [ "$mode" != install ]; then
    echo "MSL_NEED_SERVER=$arch"
    exit 0
  fi
  exec 9>"$run/install.lock"
  flock 9
  if [ ! -x "$bin/bin/$exe" ]; then
    echo "installing the VS Code Server" >&2
    tmp=$(mktemp -d "$root/bin/.msl-XXXXXX")
    tar -xzf - -C "$tmp" --strip-components 1
    rm -rf "$bin"
    mv "$tmp" "$bin"
  fi
  exec 9>&-
fi

if [ ! -s "$tok" ]; then
  (umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$tok")
fi

# Alive, ours, and accepting: pids start over when the VM restarts (a bare
# kill -0 on an old pidfile can hit an unrelated process), and a server that is
# auto-shutting down still exists but refuses connections.
running() {
  [ -S "$sock" ] && [ -s "$pidf" ] || return 1
  tr '\0' ' ' 2>/dev/null < "/proc/$(cat "$pidf")/cmdline" | grep -qF -- "--socket-path $sock " || return 1
  /run/msl/init msl-bridge "unix:$sock" </dev/null >/dev/null 2>&1
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

/** Run the setup script; `tarball` is piped to its stdin in install mode. */
function runScript(distro: string, mode: 'probe' | 'install', tarball?: string, token?: vscode.CancellationToken): Promise<string> {
    const commit = vscode.env.appCommit!;
    const quality = vscode.env.appQuality ?? 'stable';
    return new Promise((resolve, reject) => {
        const child = spawnInDistro(distro, ['sh', '-c', SCRIPT, 'sh', commit, quality, mode]);
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
        child.stdin.on('error', () => {}); // the script may not read all of it
        if (tarball) {
            fs.createReadStream(tarball).pipe(child.stdin);
        } else {
            child.stdin.end();
        }
        child.on('error', reject);
        child.on('close', (code) => {
            if (code === 0) {
                resolve(out);
            } else {
                reject(new Error(err.trim().split('\n').pop() || `server setup exited with ${code}`));
            }
        });
    });
}

/** GET with redirects into `dest` (written to a .part file, then renamed). */
function download(url: string, dest: string, redirects = 5): Promise<void> {
    return new Promise((resolve, reject) => {
        https
            .get(url, (res) => {
                const status = res.statusCode ?? 0;
                if (status >= 300 && status < 400 && res.headers.location && redirects > 0) {
                    res.resume();
                    download(new URL(res.headers.location, url).toString(), dest, redirects - 1).then(resolve, reject);
                    return;
                }
                if (status !== 200) {
                    res.resume();
                    reject(new Error(`download failed: HTTP ${status} for ${url}`));
                    return;
                }
                const part = `${dest}.part`;
                const file = fs.createWriteStream(part);
                res.pipe(file);
                file.on('finish', () => file.close(() => fs.rename(part, dest, (e) => (e ? reject(e) : resolve()))));
                file.on('error', reject);
                res.on('error', reject);
            })
            .on('error', reject);
    });
}

/** The server tarball for this VS Code and `arch`, cached on the Mac. */
async function serverTarball(arch: string, distro: string): Promise<string> {
    const commit = vscode.env.appCommit!;
    const quality = vscode.env.appQuality ?? 'stable';
    const dir = path.join(os.homedir(), 'Library/Caches/msl/vscode-server');
    const file = path.join(dir, `${commit}-${quality}-linux-${arch}.tar.gz`);
    if (!fs.existsSync(file)) {
        fs.mkdirSync(dir, { recursive: true });
        const url = `https://update.code.visualstudio.com/commit:${commit}/server-linux-${arch}/${quality}`;
        log.info(`[${distro}] downloading ${url}`);
        await download(url, file);
    }
    return file;
}

export async function ensureServer(distro: string, token?: vscode.CancellationToken): Promise<Server> {
    if (!vscode.env.appCommit) {
        throw new Error('VS Code has no commit id (running from sources?)');
    }
    let out = await runScript(distro, 'probe', undefined, token);
    const arch = /^MSL_NEED_SERVER=(.+)$/m.exec(out)?.[1];
    if (arch) {
        out = await runScript(distro, 'install', await serverTarball(arch, distro), token);
    }
    const socket = /^MSL_SOCKET=(.+)$/m.exec(out)?.[1];
    const tok = /^MSL_TOKEN=(.+)$/m.exec(out)?.[1];
    if (!socket || !tok) {
        throw new Error('server setup printed no socket');
    }
    return { socket, token: tok };
}
