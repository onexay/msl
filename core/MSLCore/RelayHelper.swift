// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The helper side of RelayMessage (msl-portd, msl-fileviewd): accepts on the
/// listeners msld passes, gets a vsock stream from msld for each connection,
/// and hands both to `bridge`, which calls `done` once the connection has
/// ended. `run` returns never: the helper exits when msld has closed the
/// control socket (no listeners left, the VM stopped, or msld exited) and its
/// last connection has ended.
public final class RelayHelper: @unchecked Sendable {
    public typealias Bridge = (_ client: Int32, _ vsock: Int32, _ done: @escaping @Sendable () -> Void) -> Void

    public let control = IPCConnection(fd: relayControlFD)
    private let bridge: Bridge
    private let onMessage: (RelayMessage, RelayHelper) -> Void
    private let lock = NSLock()
    private var ports: [UInt16: StopFlag] = [:]
    private var pending: [UInt64: Int32] = [:]  // accepted, waiting for a vsock stream
    private var nextID: UInt64 = 0
    private var active = 0
    private var controlOpen = true

    public init(bridge: @escaping Bridge, onMessage: @escaping (RelayMessage, RelayHelper) -> Void = { _, _ in }) {
        signal(SIGPIPE, SIG_IGN)
        self.bridge = bridge
        self.onMessage = onMessage
    }

    /// A line for msld.log (the helper's stderr is msld's).
    public static func log(_ s: String) {
        let line = Array("\(ISO8601DateFormatter().string(from: Date())) \(s)\n".utf8)
        _ = line.withUnsafeBytes { write(2, $0.baseAddress!, $0.count) }
    }

    public func run() -> Never {
        while let (msg, fds) = try? control.receive(RelayMessage.self) {
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
                    try? control.send(RelayMessage.closed(id: id))
                    continue
                }
                lock.withLock { active += 1 }
                bridge(client, vsock) { [self] in
                    try? control.send(RelayMessage.closed(id: id))
                    lock.withLock { active -= 1 }
                    exitIfDone()
                }
            case .refused(let id):
                if let c = lock.withLock({ pending.removeValue(forKey: id) }) { close(c) }
            default:
                fds.forEach { close($0) }
                onMessage(msg, self)
            }
        }
        // msld closed the control socket: stop accepting, let the connections
        // in progress finish, then exit.
        let (stops, waiting) = lock.withLock { () -> ([StopFlag], [Int32]) in
            controlOpen = false
            defer { ports.removeAll(); pending.removeAll() }
            return (Array(ports.values), Array(pending.values))
        }
        stops.forEach { $0.set() }
        waiting.forEach { close($0) }
        exitIfDone()
        while true { pause() }
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
                setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))  // TCP clients only
                let id = lock.withLock { () -> UInt64? in
                    guard controlOpen else { return nil }
                    nextID += 1
                    pending[nextID] = c
                    return nextID
                }
                guard let id else { close(c); return }
                if (try? control.send(RelayMessage.connect(id: id, port: port))) == nil {
                    if let c = lock.withLock({ pending.removeValue(forKey: id) }) { close(c) }
                }
            }
        }
    }
}
