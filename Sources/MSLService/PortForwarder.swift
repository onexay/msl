// SPDX-License-Identifier: Apache-2.0
import Foundation
import MSLCore
import MSLProtocol

/// Localhost forwarding (WSL's `localhostForwarding`): every TCP port listening
/// on the guest's loopback/any address is bound on the Mac's 127.0.0.1 and ::1.
/// msld binds the ports and opens a vsock stream to the guest forwarder (which
/// connects to 127.0.0.1:<port> inside the VM) for each connection; msl-portd,
/// like WSL's wslrelay.exe, accepts the connections and copies their bytes.
final class PortForwarder: @unchecked Sendable {
    static let guestForwarderPort: UInt32 = 1025

    private let vm: VMHost
    private let guest: GuestClients
    private let lock = NSLock()
    private var ports: Set<UInt32> = []
    private var relay: Relay?
    private var task: Task<Void, Never>?

    init(vm: VMHost, guest: GuestClients) {
        self.vm = vm
        self.guest = guest
    }

    /// Follow the guest's listening ports until the VM stops.
    func start() {
        lock.withLock { task?.cancel() }
        guard let mini = try? guest.miniInit else { return }
        let t = Task.detached { [self] in
            do {
                try await mini.watchPorts(Msl_V1_Empty()) { response in
                    for try await update in response.messages {
                        self.reconcile(Set(update.ports))
                    }
                }
            } catch {}
            self.stopAll()
        }
        lock.withLock { task = t }
    }

    func stopAll() {
        let r = lock.withLock { () -> Relay? in
            ports.removeAll()
            defer { relay = nil }
            return relay
        }
        r?.end()
    }

    var forwarded: [UInt32] { lock.withLock { ports.sorted() } }

    private func reconcile(_ want: Set<UInt32>) {
        lock.lock()
        defer { lock.unlock() }
        for p in ports.subtracting(want) {
            ports.remove(p)
            try? relay?.conn.send(PortRelayMessage.unlisten(port: UInt16(p)))
            log("localhost forwarding: stopped port \(p)")
        }
        for p in want.subtracting(ports) where p > 0 && p < 65536 {
            let fds = [Self.listen(port: UInt16(p), v6: false), Self.listen(port: UInt16(p), v6: true)].compactMap { $0 }
            guard !fds.isEmpty else {
                log("localhost forwarding: port \(p) is in use on macOS; skipped")
                continue
            }
            defer { fds.forEach { close($0) } }
            if relay == nil {
                do { relay = try Relay(forwarder: self) } catch {
                    log("localhost forwarding: can't start msl-portd: \(error)")
                    return
                }
            }
            guard (try? relay?.conn.send(PortRelayMessage.listen(port: UInt16(p)), fds: fds)) != nil else { continue }
            ports.insert(p)
            log("localhost forwarding: port \(p)")
        }
        if ports.isEmpty, let r = relay {
            relay = nil
            r.end()  // msl-portd exits once its connections have ended
        }
    }

    /// msl-portd ended while it was still the relay: forward the ports again.
    fileprivate func relayEnded(_ r: Relay) {
        let again = lock.withLock { () -> Set<UInt32>? in
            guard relay === r else { return nil }
            relay = nil
            defer { ports.removeAll() }
            return ports
        }
        guard let again else { return }
        log("localhost forwarding: msl-portd ended; starting it again")
        reconcile(again)
    }

    /// A connection msl-portd accepted: a framed vsock stream to the guest
    /// forwarder, with the port header written.
    fileprivate func open(port: UInt16) -> Int32? {
        guard let v = try? vm.connect(port: Self.guestForwarderPort) else { return nil }
        var hdr = port.bigEndian
        guard write(v, &hdr, 2) == 2 else { close(v); return nil }
        return v
    }

    /// Listen on 127.0.0.1:port or [::1]:port; nil if unavailable (e.g. in use on the Mac).
    static func listen(port: UInt16, v6: Bool) -> Int32? {
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        let rc: Int32
        if v6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = port.bigEndian
            a.sin6_addr = in6addr_loopback
            rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            a.sin_addr.s_addr = inet_addr("127.0.0.1")
            rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard rc == 0, Darwin.listen(fd, 128) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }
}

/// A running msl-portd and its control socket.
private final class Relay: @unchecked Sendable {
    let conn: IPCConnection
    let pid: pid_t
    private let lock = NSLock()
    private var streams: [UInt64: Int32] = [:]  // our descriptors of the vsock streams msl-portd has

    init(forwarder: PortForwarder) throws {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw ServiceError("socketpair: \(String(cString: strerror(errno)))", code: ErrorCode.vm) }
        defer { close(pair[1]) }
        _ = fcntl(pair[0], F_SETFD, FD_CLOEXEC)
        let exe = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("msl-portd").path
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        posix_spawn_file_actions_adddup2(&actions, pair[1], portRelayControlFD)
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
        Thread.detachNewThread { [self, weak forwarder] in
            while let (msg, fds) = try? conn.receive(PortRelayMessage.self) {
                fds.forEach { Darwin.close($0) }
                switch msg {
                case .connect(let id, let port):
                    Thread.detachNewThread { [self] in
                        guard let v = forwarder?.open(port: port) else {
                            try? conn.send(PortRelayMessage.refused(id: id))
                            return
                        }
                        lock.withLock { streams[id] = v }  // see PortRelayMessage.closed
                        if (try? conn.send(PortRelayMessage.connected(id: id), fds: [v])) == nil { closeStream(id) }
                    }
                case .closed(let id):
                    closeStream(id)
                default:
                    break
                }
            }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            lock.withLock { streams.values.forEach { Darwin.close($0) }; streams.removeAll() }
            forwarder?.relayEnded(self)
        }
    }

    private func closeStream(_ id: UInt64) {
        if let v = lock.withLock({ streams.removeValue(forKey: id) }) { Darwin.close(v) }
    }

    /// End the control socket's msld -> msl-portd direction: msl-portd stops
    /// accepting and exits after its last connection, still reporting the
    /// connections that end until then.
    func end() { shutdown(conn.fd, SHUT_WR) }
}
