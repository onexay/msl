// SPDX-License-Identifier: Apache-2.0
// Managed pipes: a byte stream to a Unix socket or localhost port inside a
// distro. For now each pipe is `msl -e /run/msl/init msl-bridge <target>`
// with its stdio as the stream; msld's connect socket will replace it (#32).

import { once } from 'events';
import * as vscode from 'vscode';
import { log, spawnInDistro } from './msl';

export type Target = { unix: string } | { tcp: number };

function targetArg(t: Target): string {
    return 'unix' in t ? `unix:${t.unix}` : `tcp:${t.tcp}`;
}

export function openPipe(distro: string, target: Target): Promise<vscode.ManagedMessagePassing> {
    const child = spawnInDistro(distro, ['/run/msl/init', 'msl-bridge', targetArg(target)]);
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
            log.warn(`[${distro}] pipe ${targetArg(target)}: ${stderr.trim()}`);
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
    });
}
