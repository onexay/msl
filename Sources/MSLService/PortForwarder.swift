// SPDX-License-Identifier: Apache-2.0
import Foundation
import MSLProtocol

/// Localhost forwarding (WSL's `localhostForwarding`): every TCP port listening
/// on the guest's loopback/any address is bound on the Mac's 127.0.0.1 and ::1,
/// and each connection is relayed over vsock to the guest forwarder, which
/// connects to 127.0.0.1:<port> inside the VM.
final class PortForwarder: @unchecked Sendable {
    static let guestForwarderPort: UInt32 = 1025

    private let vm: VMHost
    private let guest: GuestClients
    private let lock = NSLock()
    private var listeners: [UInt32: (fds: [Int32], stop: StopFlag)] = [:]
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
        let all = lock.withLock { () -> [(fds: [Int32], stop: StopFlag)] in
            defer { listeners.removeAll() }
            return Array(listeners.values)
        }
        for l in all { l.stop.set() }
    }

    var forwarded: [UInt32] { lock.withLock { listeners.keys.sorted() } }

    private func reconcile(_ want: Set<UInt32>) {
        let (add, remove) = lock.withLock { () -> (Set<UInt32>, [UInt32]) in
            let have = Set(listeners.keys)
            return (want.subtracting(have), Array(have.subtracting(want)))
        }
        for p in remove {
            if let l = lock.withLock({ listeners.removeValue(forKey: p) }) {
                l.stop.set()
                log("localhost forwarding: stopped port \(p)")
            }
        }
        for p in add where p > 0 && p < 65536 {
            let fds = [Self.listen(port: UInt16(p), v6: false), Self.listen(port: UInt16(p), v6: true)].compactMap { $0 }
            guard !fds.isEmpty else {
                log("localhost forwarding: port \(p) is in use on macOS; skipped")
                continue
            }
            let stop = StopFlag()
            lock.withLock { listeners[p] = (fds, stop) }
            for fd in fds { acceptLoop(fd, port: UInt16(p), stop: stop) }
            log("localhost forwarding: port \(p)")
        }
    }

    private func acceptLoop(_ lfd: Int32, port: UInt16, stop: StopFlag) {
        Thread.detachNewThread { [self] in
            defer { close(lfd) }
            while !stop.isSet {
                var p = pollfd(fd: lfd, events: Int16(POLLIN), revents: 0)
                if poll(&p, 1, 200) <= 0 { continue }
                let c = accept(lfd, nil, nil)
                if c < 0 { continue }
                var one: Int32 = 1
                setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { [self] in
                    guard let v = try? vm.connect(port: Self.guestForwarderPort) else { close(c); return }
                    var hdr = port.bigEndian
                    guard write(v, &hdr, 2) == 2 else { close(c); close(v); return }
                    _ = FramedBridge(vsock: v, localIn: c, localOut: c, shutdownOnEOF: true, ownsLocal: true)
                }
            }
        }
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
