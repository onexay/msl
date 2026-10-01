// SPDX-License-Identifier: Apache-2.0
import Foundation
import MSLCore

/// A running relay helper (msl-portd, msl-fileviewd; see RelayMessage) and its
/// control socket. For each connection the helper accepts, msld opens a framed
/// vsock stream to the guest forwarder, writes the port header, passes the
/// stream and keeps its own descriptor until the helper reports it closed.
/// Other messages go to `onMessage`. `ended` runs once the helper has exited.
final class RelayProcess: @unchecked Sendable {
    let conn: IPCConnection
    let pid: pid_t
    private let lock = NSLock()
    private var streams: [UInt64: Int32] = [:]  // our descriptors of the streams the helper has

    init(executable name: String, vm: VMHost, onMessage: @escaping @Sendable (RelayMessage) -> Void = { _ in },
         ended: @escaping @Sendable (RelayProcess) -> Void) throws {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw ServiceError("socketpair: \(String(cString: strerror(errno)))", code: ErrorCode.vm) }
        defer { close(pair[1]) }
        _ = fcntl(pair[0], F_SETFD, FD_CLOEXEC)
        let exe = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(name).path
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        posix_spawn_file_actions_adddup2(&actions, pair[1], relayControlFD)
        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))  // nothing else of msld's
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe), nil]
        defer { argv.forEach { free($0) } }
        let rc = posix_spawn(&pid, exe, &actions, &attr, argv, environ)
        guard rc == 0 else {
            close(pair[0])
            throw ServiceError("\(exe): \(String(cString: strerror(rc)))", code: ErrorCode.vm)
        }
        self.pid = pid
        conn = IPCConnection(fd: pair[0])
        Thread.detachNewThread { [self] in
            while let (msg, fds) = try? conn.receive(RelayMessage.self) {
                fds.forEach { Darwin.close($0) }
                switch msg {
                case .connect(let id, let port):
                    Thread.detachNewThread { [self] in
                        guard let v = Self.openGuestStream(vm: vm, port: port) else {
                            try? conn.send(RelayMessage.refused(id: id))
                            return
                        }
                        lock.withLock { streams[id] = v }  // see RelayMessage.closed
                        if (try? conn.send(RelayMessage.connected(id: id), fds: [v])) == nil { closeStream(id) }
                    }
                case .closed(let id):
                    closeStream(id)
                default:
                    onMessage(msg)
                }
            }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            lock.withLock { streams.values.forEach { Darwin.close($0) }; streams.removeAll() }
            ended(self)
        }
    }

    /// A framed stream to the guest forwarder for 127.0.0.1:`port` in the VM.
    static func openGuestStream(vm: VMHost, port: UInt16) -> Int32? {
        guard let v = try? vm.connect(port: PortForwarder.guestForwarderPort) else { return nil }
        var hdr = port.bigEndian
        guard write(v, &hdr, 2) == 2 else { close(v); return nil }
        return v
    }

    private func closeStream(_ id: UInt64) {
        if let v = lock.withLock({ streams.removeValue(forKey: id) }) { Darwin.close(v) }
    }

    /// End the control socket's msld -> helper direction: the helper stops
    /// accepting and exits after its last connection, still reporting the
    /// connections that end until then.
    func end() { shutdown(conn.fd, SHUT_WR) }
}
