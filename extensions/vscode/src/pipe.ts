// SPDX-License-Identifier: Apache-2.0
// Managed pipes: a byte stream to a Unix socket or localhost port inside a
// distro. Each pipe is one connection to msld's connect socket
// (`CONNECT distro=<name> unix=<path>|tcp=<port>`, then `OK` and the stream).
// With an older msld that has no connect socket, it falls back to
// `msl -e /run/msl/init msl-bridge <target>` with its stdio as the stream.

import { once } from 'events';
import * as fs from 'fs';
import * as net from 'net';
import * as path from 'path';
import * as vscode from 'vscode';
import { log, mslHome, spawnInDistro } from './msl';

export type Target = { unix: string } | { tcp: number };

/** A managed pipe that can also stop reading, for backpressure in tunnels. */
export interface Pipe extends vscode.ManagedMessagePassing {
    pause(): void;
    resume(): void;
}

function describe(t: Target): string {
    return 'unix' in t ? `unix:${t.unix}` : `tcp:${t.tcp}`;
}

function connectSocket(): string {
    return path.join(mslHome(), 'connect.sock');
}

export function openPipe(distro: string, target: Target): Promise<Pipe> {
    const sock = connectSocket();
    return fs.existsSync(sock) ? openConnectPipe(sock, distro, target) : openBridgePipe(distro, target);
}

function openConnectPipe(sock: string, distro: string, target: Target): Promise<Pipe> {
    return new Promise((resolve, reject) => {
        const s = net.connect(sock);
        const onDidReceiveMessage = new vscode.EventEmitter<Uint8Array>();
        const onDidClose = new vscode.EventEmitter<Error | undefined>();
        const onDidEnd = new vscode.EventEmitter<void>();
        let header = Buffer.alloc(0);
        let ready = false;
        let closed = false;

        const arg = 'unix' in target ? `unix=${target.unix}` : `tcp=${target.tcp}`;
        s.write(`CONNECT distro=${distro} ${arg}\n`);
        s.on('data', (d: Buffer) => {
            if (ready) {
                onDidReceiveMessage.fire(d);
                return;
            }
            header = Buffer.concat([header, d]);
            const nl = header.indexOf(0x0a);
            if (nl < 0) {
                return;
            }
            const line = header.subarray(0, nl).toString('utf8');
            const rest = header.subarray(nl + 1);
            if (line !== 'OK') {
                const err = new Error(line.replace(/^ERR /, ''));
                log.warn(`[${distro}] pipe ${describe(target)}: ${err.message}`);
                s.destroy();
                reject(err);
                return;
            }
            ready = true;
            resolve({
                onDidReceiveMessage: onDidReceiveMessage.event,
                onDidClose: onDidClose.event,
                onDidEnd: onDidEnd.event,
                send: (data: Uint8Array) => {
                    if (!closed) {
                        s.write(data);
                    }
                },
                end: () => s.end(),
                drain: async () => {
                    if (s.writableNeedDrain) {
                        await Promise.race([once(s, 'drain'), once(s, 'close')]);
                    }
                },
                pause: () => s.pause(),
                resume: () => s.resume(),
            });
            if (rest.length) {
                setImmediate(() => onDidReceiveMessage.fire(rest));
            }
        });
        s.on('end', () => ready && onDidEnd.fire());
        s.on('error', (e) => {
            if (!ready) {
                reject(e);
            } else if (!closed) {
                closed = true;
                onDidClose.fire(e);
            }
        });
        s.on('close', () => {
            if (!ready) {
                reject(new Error('msld closed the connection'));
            } else if (!closed) {
                closed = true;
                onDidClose.fire(undefined);
            }
        });
    });
}

function openBridgePipe(distro: string, target: Target): Promise<Pipe> {
    const child = spawnInDistro(distro, ['/run/msl/init', 'msl-bridge', describe(target)]);
    const onDidReceiveMessage = new vscode.EventEmitter<Uint8Array>();
    const onDidClose = new vscode.EventEmitter<Error | undefined>();
    const onDidEnd = new vscode.EventEmitter<void>();
    let stderr = '';
    let closed = false;

    child.stdout.on('data', (d: Buffer) => onDidReceiveMessage.fire(d));
    child.stdout.on('end', () => onDidEnd.fire());
    child.stderr.setEncoding('utf8').on('data', (d: string) => (stderr += d));
    child.stdin.on('error', () => {}); // EPIPE after the bridge exits; reported by 'close'
    const close = (err: Error | undefined) => {
        if (!closed) {
            closed = true;
            onDidClose.fire(err);
        }
    };
    child.on('error', (e) => close(e));
    child.on('close', (code) => {
        if (code !== 0 && stderr) {
            log.warn(`[${distro}] pipe ${describe(target)}: ${stderr.trim()}`);
        }
        close(code === 0 ? undefined : new Error(stderr.trim() || `pipe exited with ${code}`));
    });

    return Promise.resolve({
        onDidReceiveMessage: onDidReceiveMessage.event,
        onDidClose: onDidClose.event,
        onDidEnd: onDidEnd.event,
        send: (data: Uint8Array) => {
            if (!closed) {
                child.stdin.write(data);
            }
        },
        end: () => child.stdin.end(),
        drain: async () => {
            if (child.stdin.writableNeedDrain) {
                await Promise.race([once(child.stdin, 'drain'), once(child, 'close')]);
            }
        },
        pause: () => child.stdout.pause(),
        resume: () => child.stdout.resume(),
    });
}
