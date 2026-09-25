// SPDX-License-Identifier: Apache-2.0
// MSL remote authority: vscode-remote://msl+<distro>/<path>. VS Code reaches
// the server in the distro through managed pipes, with no SSH and no TCP port
// on the Mac.

import * as vscode from 'vscode';
import { listDistros, log } from './msl';
import { openPipe } from './pipe';
import { ensureServer } from './server';
import { tunnelFactory } from './tunnel';

const PREFIX = 'msl';

function distroOf(authority: string): string {
    const plus = authority.indexOf('+');
    return decodeURIComponent(authority.slice(plus + 1));
}

async function pickDistro(): Promise<string | undefined> {
    const distros = await listDistros();
    if (distros.length === 0) {
        vscode.window.showErrorMessage('No msl distros are installed. Run `msl --install` first.');
        return undefined;
    }
    const pick = await vscode.window.showQuickPick(
        distros.map((d) => ({ label: d.name, description: [d.default ? 'default' : '', d.state].filter(Boolean).join(' · ') })),
        { placeHolder: 'Select a distro' },
    );
    return pick?.label;
}

async function connect(newWindow: boolean) {
    const distro = await pickDistro();
    if (distro) {
        await vscode.commands.executeCommand('vscode.newWindow', {
            remoteAuthority: `${PREFIX}+${encodeURIComponent(distro)}`,
            reuseWindow: !newWindow,
        });
    }
}

export function activate(context: vscode.ExtensionContext) {
    let resolved: string | undefined; // this window's distro
    context.subscriptions.push(
        log,
        vscode.commands.registerCommand('msl.connect', () => connect(false)),
        vscode.commands.registerCommand('msl.connectInNewWindow', () => connect(true)),
        vscode.workspace.registerRemoteAuthorityResolver(PREFIX, {
            async resolve(authority, ctx) {
                const distro = distroOf(authority);
                log.info(`[${distro}] resolving (attempt ${ctx.resolveAttempt})`);
                if (!resolved) {
                    context.subscriptions.push(
                        vscode.workspace.registerResourceLabelFormatter({
                            scheme: 'vscode-remote',
                            authority: `${PREFIX}+*`,
                            formatting: { label: '${path}', separator: '/', tildify: true, workspaceSuffix: `MSL: ${distro}` },
                        }),
                    );
                }
                resolved = distro;
                try {
                    const server = await vscode.window.withProgress(
                        { location: vscode.ProgressLocation.Notification, title: `MSL: starting ${distro}` },
                        () => ensureServer(distro),
                    );
                    log.info(`[${distro}] server at ${server.socket}`);
                    return new vscode.ManagedResolvedAuthority(() => openPipe(distro, { unix: server.socket }), server.token);
                } catch (e) {
                    log.error(`[${distro}] ${e}`);
                    throw vscode.RemoteAuthorityResolverError.NotAvailable(`MSL: ${(e as Error).message}`, false);
                }
            },
            tunnelFactory: tunnelFactory(() => resolved),
        }),
    );
}

export function deactivate() {}
