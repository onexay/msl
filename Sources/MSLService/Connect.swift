// SPDX-License-Identifier: Apache-2.0
import Foundation
import MSLCore

/// msld's connect socket (`connect.sock`, next to msld.sock): byte streams into
/// a distro for VS Code managed pipes (#32), one connection per pipe, with no
/// `msl` process and no TCP port on the Mac.
///
/// A client sends one line and reads one back:
///
///     CONNECT distro=<name> unix=<path>   -> guest vsock 1026 (connect.rs)
///     CONNECT distro=<name> tcp=<port>    -> guest vsock 1025 (the localhost forwarder)
///     OK | ERR <message>
///
/// After OK the connection is the stream. The distro is started if needed, and
/// each open stream counts as a session, so idle timeouts don't stop it.
extension Service {
    static let guestConnectPort: UInt32 = 1026

    func serveConnect() {
        let path = paths.connectSocket.path
        let lfd: Int32
        do { lfd = try listenUnix(path) } catch {
            log("connect: could not listen on \(path): \(error)")
            return
        }
        log("connect socket on \(path)")
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(lfd, nil, nil)
                if c < 0 { continue }
                Thread.detachNewThread { self.handleConnect(c) }
            }
        }
    }

    private func handleConnect(_ c: Int32) {
        guard let line = Self.readLine(c), let req = ConnectRequest(line: line) else {
            reject(c, "expected: CONNECT distro=<name> unix=<path> | tcp=<port>")
            return
        }
        do {
            let d = try find(req.distro)
            _ = try startDistro(d)
            let v = try openGuest(d, req.target)
            guard writeAll(c, Array("OK\n".utf8)) else { close(v); close(c); return }
            idle.beginSession(distro: d.id)
            let bridge = FramedBridge(vsock: v, localIn: c, localOut: c, shutdownOnEOF: true, ownsLocal: true)
            Task.detached { [idle] in
                await bridge.sent.wait()
                await bridge.delivered.wait()
                idle.endSession(distro: d.id)
            }
        } catch let e as ServiceError {
            reject(c, e.message)
        } catch {
            reject(c, "\(error)")
        }
    }

    /// A vsock connection to the target, past its header (and, for Unix
    /// sockets, the guest's status reply).
    private func openGuest(_ d: DistroRecord, _ target: ConnectRequest.Target) throws -> Int32 {
        switch target {
        case .tcp(let port):
            let v = try vm.connect(port: PortForwarder.guestForwarderPort)
            guard writeAll(v, withUnsafeBytes(of: port.bigEndian) { Array($0) }) else {
                close(v)
                throw ServiceError("connect: vsock write failed", code: ErrorCode.vm)
            }
            return v
        case .unix(let path):
            let v = try vm.connect(port: Self.guestConnectPort)
            var req: [UInt8] = [1]
            req += withUnsafeBytes(of: d.defaultUid.bigEndian) { Array($0) }
            for s in [d.id, path] {
                let b = Array(s.utf8)
                req += withUnsafeBytes(of: UInt16(b.count).bigEndian) { Array($0) } + b
            }
            var status = [UInt8](repeating: 0, count: 1)
            guard writeAll(v, req), readExactly(v, &status) else {
                close(v)
                throw ServiceError("connect: the guest closed the connection", code: ErrorCode.vm)
            }
            if status[0] != 0 {
                var len = [UInt8](repeating: 0, count: 2)
                var msg = "refused"
                if readExactly(v, &len) {
                    var m = [UInt8](repeating: 0, count: Int(UInt16(len[0]) << 8 | UInt16(len[1])))
                    if readExactly(v, &m) { msg = String(decoding: m, as: UTF8.self) }
                }
                close(v)
                throw ServiceError(msg, code: ErrorCode.service)
            }
            return v
        }
    }

    private func reject(_ c: Int32, _ message: String) {
        let one = message.replacingOccurrences(of: "\n", with: " ")
        _ = writeAll(c, Array("ERR \(one)\n".utf8))
        close(c)
    }

    /// One header line (up to 4 KiB), read a byte at a time so nothing past
    /// the newline is consumed.
    static func readLine(_ fd: Int32) -> String? {
        var line: [UInt8] = []
        var b: UInt8 = 0
        while line.count < 4096 {
            let n = read(fd, &b, 1)
            if n < 0 && errno == EINTR { continue }
            if n != 1 { return nil }
            if b == UInt8(ascii: "\n") { return String(decoding: line, as: UTF8.self) }
            line.append(b)
        }
        return nil
    }
}
