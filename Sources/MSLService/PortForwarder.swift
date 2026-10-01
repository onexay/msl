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
    private var relay: RelayProcess?
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
        let r = lock.withLock { () -> RelayProcess? in
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
            try? relay?.conn.send(RelayMessage.unlisten(port: UInt16(p)))
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
                do {
                    relay = try RelayProcess(executable: "msl-portd", vm: vm, ended: { [weak self] r in self?.relayEnded(r) })
                } catch {
                    log("localhost forwarding: can't start msl-portd: \(error)")
                    return
                }
            }
            guard (try? relay?.conn.send(RelayMessage.listen(port: UInt16(p)), fds: fds)) != nil else { continue }
            ports.insert(p)
            log("localhost forwarding: port \(p)")
        }
        if ports.isEmpty, let r = relay {
            relay = nil
            r.end()  // msl-portd exits once its connections have ended
        }
    }

    /// msl-portd ended while it was still the relay: forward the ports again.
    private func relayEnded(_ r: RelayProcess) {
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

