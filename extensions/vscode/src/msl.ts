// SPDX-License-Identifier: Apache-2.0
// Running the msl CLI from the local extension host.

import { ChildProcessWithoutNullStreams, spawn } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import * as vscode from 'vscode';

export const log = vscode.window.createOutputChannel('MSL', { log: true });

/** The `msl` binary: the setting, then the usual install locations, then PATH. */
export function mslPath(): string {
    const configured = vscode.workspace.getConfiguration('msl').get<string>('path');
    if (configured) {
        return configured.replace(/^~(?=\/)/, os.homedir());
    }
    for (const p of [path.join(os.homedir(), '.local/bin/msl'), '/usr/local/bin/msl']) {
        if (fs.existsSync(p)) {
            return p;
        }
    }
    return 'msl';
}

/** `msl -d <distro> -e <argv...>` with piped stdio (no tty). */
export function spawnInDistro(distro: string, argv: string[]): ChildProcessWithoutNullStreams {
    return spawn(mslPath(), ['-d', distro, '-e', ...argv], { stdio: 'pipe' });
}

/** Run `msl <args>` to completion; rejects with stderr on a non-zero exit. */
export function run(args: string[], input?: string): Promise<string> {
    return new Promise((resolve, reject) => {
        const child = spawn(mslPath(), args, { stdio: 'pipe' });
        let out = '';
        let err = '';
        child.stdout.setEncoding('utf8').on('data', (d: string) => (out += d));
        child.stderr.setEncoding('utf8').on('data', (d: string) => (err += d));
        child.on('error', reject);
        child.on('close', (code) => {
            if (code === 0) {
                resolve(out);
            } else {
                reject(new Error(err.trim() || `msl ${args.join(' ')} exited with ${code}`));
            }
        });
        child.stdin.end(input);
    });
}

export interface Distro {
    name: string;
    state: string;
    default: boolean;
}

export async function listDistros(): Promise<Distro[]> {
    const json = JSON.parse(await run(['--list', '--verbose', '--json']));
    return json.distributions as Distro[];
}
