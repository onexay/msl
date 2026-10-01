// SPDX-License-Identifier: Apache-2.0
// msl-portd: localhost forwarding's relay, like WSL's wslrelay.exe. msld starts
// it when the first port is forwarded and passes it each port's listening
// sockets and, for each connection it accepts, a vsock stream to the guest's
// forwarder. It copies the bytes, so msld never carries them, and it needs no
// entitlements. It exits once msld closes the control socket and its last
// connection has ended.
import Foundation
import MSLCore

signal(SIGPIPE, SIG_IGN)

final class Relay: @unchecked Sendable {
    let control = IPCConnection(fd: portRelayControlFD)
    private let lock = NSLock()
    private var ports: [UInt16: StopFlag] = [:]
    private var pending: [UInt64: Int32] = [:]  // accepted, waiting for a vsock stream
    private var nextID: UInt64 = 0
    private var active = 0
    private var controlOpen = true

    func run() {
        while let (msg, fds) = try? control.receive(PortRelayMessage.self) {
            switch msg {
            case .listen(let port):
                let stop = StopFlag()
                lock.withLock { ports.removeValue(forKey: port)?.set(); ports[port] = stop }
                for fd in fds { acceptLoop(fd, port: port, stop: stop) }
            case .unlisten(let port):
                lock.withLock { ports.removeValue(forKey: port) }?.set()
                fds.forEach { close($0) }
            case .connected(let id):
                let client = lock.withLock { pending.removeValue(forKey: id) }
                guard let client, let vsock = fds.first else {
                    fds.forEach { close($0) }
                    if let client { close(client) }
                    try? control.send(PortRelayMessage.closed(id: id))
                    continue
                }
                lock.withLock { active += 1 }
                FramedBridge(vsock: vsock, localIn: client, localOut: client, shutdownOnEOF: true, ownsLocal: true) { [self] in
                    try? control.send(PortRelayMessage.closed(id: id))
                    lock.withLock { active -= 1 }
                    exitIfDone()
                }
            case .refused(let id):
                if let c = lock.withLock({ pending.removeValue(forKey: id) }) { close(c) }
            case .connect, .closed:
                fds.forEach { close($0) }
            }
        }
        // msld closed the control socket (no ports left, the VM stopped, or
        // msld exited): stop accepting, finish the connections in progress.
        let (stops, waiting) = lock.withLock { () -> ([StopFlag], [Int32]) in
            controlOpen = false
            defer { ports.removeAll(); pending.removeAll() }
            return (Array(ports.values), Array(pending.values))
        }
        stops.forEach { $0.set() }
        waiting.forEach { close($0) }
        exitIfDone()
    }

    private func exitIfDone() {
        if lock.withLock({ !controlOpen && active == 0 }) { exit(0) }
    }

    private func acceptLoop(_ lfd: Int32, port: UInt16, stop: StopFlag) {
        Thread.detachNewThread { [self] in
            defer { close(lfd) }
            while stop.waitReadable(lfd) {
                let c = accept(lfd, nil, nil)
                if c < 0 { continue }
                var one: Int32 = 1
                setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                let id = lock.withLock { () -> UInt64? in
                    guard controlOpen else { return nil }
                    nextID += 1
                    pending[nextID] = c
                    return nextID
                }
                guard let id else { close(c); return }
                if (try? control.send(PortRelayMessage.connect(id: id, port: port))) == nil {
                    if let c = lock.withLock({ pending.removeValue(forKey: id) }) { close(c) }
                }
            }
        }
    }
}

Relay().run()
