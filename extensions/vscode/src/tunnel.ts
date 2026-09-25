// SPDX-License-Identifier: Apache-2.0
// tunnelFactory: forwarded ports listen on the Mac's 127.0.0.1 and each
// connection gets its own pipe to localhost:<port> in the distro, instead of
// being multiplexed through the VS Code Server.

import * as net from 'net';
import * as vscode from 'vscode';
import { log } from './msl';
import { openPipe } from './pipe';

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '::1', '0.0.0.0', '::']);

function listen(port: number): Promise<net.Server> {
    return new Promise((resolve, reject) => {
        const server = net.createServer();
        server.once('error', reject);
        server.listen(port, '127.0.0.1', () => {
            server.off('error', reject);
            resolve(server);
        });
    });
}

async function relay(distro: string, port: number, sock: net.Socket) {
    sock.pause();
    const pipe = await openPipe(distro, { tcp: port });
    pipe.onDidReceiveMessage((d) => sock.write(d));
    pipe.onDidEnd(() => sock.end());
    pipe.onDidClose(() => sock.destroy());
    sock.on('data', (d: Buffer) => {
        pipe.send(d);
        sock.pause();
        void pipe.drain!().then(() => sock.resume());
    });
    sock.on('end', () => pipe.end());
    sock.on('error', () => pipe.end());
    sock.resume();
}

export function tunnelFactory(currentDistro: () => string | undefined) {
    return (options: vscode.TunnelOptions): Thenable<vscode.Tunnel> | undefined => {
        const distro = currentDistro();
        if (!distro || !LOCAL_HOSTS.has(options.remoteAddress.host)) {
            return undefined; // let VS Code forward it through the server
        }
        return open(distro, options);
    };
}

async function open(distro: string, options: vscode.TunnelOptions): Promise<vscode.Tunnel> {
    const { host, port } = options.remoteAddress;
    let server: net.Server;
    try {
        server = await listen(options.localAddressPort ?? port);
    } catch {
        server = await listen(0); // taken, e.g. by msl's own localhost forwarding
    }
    server.on('connection', (sock) => {
        relay(distro, port, sock).catch((e) => {
            log.warn(`[${distro}] tunnel ${port}: ${e}`);
            sock.destroy();
        });
    });
    const local = (server.address() as net.AddressInfo).port;
    log.info(`[${distro}] forwarding localhost:${port} -> 127.0.0.1:${local}`);
    const onDidDispose = new vscode.EventEmitter<void>();
    return {
        remoteAddress: { host, port },
        localAddress: { host: '127.0.0.1', port: local },
        privacy: 'private',
        protocol: options.protocol,
        onDidDispose: onDidDispose.event,
        dispose: () => {
            server.close();
            onDidDispose.fire();
        },
    };
}
