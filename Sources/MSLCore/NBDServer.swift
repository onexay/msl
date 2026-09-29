// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// The NBD server behind the distros' own disks (#50).
///
/// Virtualization.framework can't hot-plug virtio-blk disks, so the VM starts
/// with a fixed set of slots: virtio-blk devices backed by
/// VZNetworkBlockDeviceStorageDeviceAttachment, each connected to one export
/// (`slot0`, `slot1`, ...) of this server on a Unix socket. msld binds a
/// distro's ext4.img to a free slot at runtime and unbinds it later. Every slot
/// advertises the same fixed size (VZ disables a slot whose size changes on
/// reconnect); the filesystem in the image carries its real size.
///
/// Durability follows qemu-nbd's default (`--cache=writeback`): a WRITE is
/// acknowledged once it's in the macOS page cache, and FLUSH/FUA run
/// F_FULLFSYNC. VZ presents NBD disks as write-through and never sends FLUSH or
/// FUA, so the server also runs F_FULLFSYNC whenever a slot is unbound; a
/// macOS crash or power loss can still lose recent writes (https://onexay.github.io/msl-docs/docs/how-to/disk-space/#durability).
///
/// An unbound slot reads as zeros and fails writes with EIO. Requests are
/// served concurrently and answered out of order, as NBD allows.
public final class NBDServer: @unchecked Sendable {
    public let socketPath: String
    public let slotCount: Int
    public let slotSize: UInt64

    /// A bound image. Requests hold a reference, so the fd stays open until the
    /// last in-flight request on it is done, even after an unbind.
    final class Backing: @unchecked Sendable {
        let fd: Int32
        let size: UInt64
        init(fd: Int32, size: UInt64) { self.fd = fd; self.size = size }
        deinit { close(fd) }
    }

    private let lock = NSLock()
    private var backings: [Backing?]
    private var listenFD: Int32 = -1
    private var connections: Set<Int32> = []
    private let io = DispatchQueue(label: "msl.nbd.io", attributes: .concurrent)

    public init(socketPath: String, slots: Int, slotSize: UInt64) {
        self.socketPath = socketPath
        self.slotCount = slots
        self.slotSize = slotSize
        self.backings = Array(repeating: nil, count: slots)
    }

    public static func exportName(_ slot: Int) -> String { "slot\(slot)" }

    // MARK: slots

    /// Serve `fd` (read-write, owned by the server from now on) as `slot`.
    public func bind(slot: Int, fd: Int32) throws {
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let e = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        let b = Backing(fd: fd, size: UInt64(st.st_size))
        try lock.withLock {
            guard slot >= 0, slot < slotCount, backings[slot] == nil else { throw POSIXError(.EBUSY) }
            backings[slot] = b
        }
    }

    /// Stop serving `slot` and flush its image to permanent storage.
    public func unbind(slot: Int) {
        let b: Backing? = lock.withLock {
            guard slot >= 0, slot < slotCount else { return nil }
            defer { backings[slot] = nil }
            return backings[slot]
        }
        if let b { _ = fcntl(b.fd, F_FULLFSYNC) }
    }

    public func isBound(_ slot: Int) -> Bool {
        lock.withLock { slot >= 0 && slot < slotCount && backings[slot] != nil }
    }

    func backing(_ slot: Int) -> Backing? {
        lock.withLock { backings[slot] }
    }

    // MARK: listener

    public func start() throws {
        unlink(socketPath)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(s)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, chmod(socketPath, 0o600) == 0, listen(s, 16) == 0 else {
            let e = errno
            close(s)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        lock.withLock { listenFD = s }
        Thread.detachNewThread { [weak self] in self?.acceptLoop(s) }
    }

    /// Close the listener and every connection, and unbind (flush) every slot.
    public func stop() {
        let (s, conns) = lock.withLock { () -> (Int32, Set<Int32>) in
            defer { listenFD = -1; connections = [] }
            return (listenFD, connections)
        }
        if s >= 0 { shutdown(s, SHUT_RDWR); close(s) }
        for c in conns { shutdown(c, SHUT_RDWR) }
        for slot in 0..<slotCount { unbind(slot: slot) }
        unlink(socketPath)
    }

    private func acceptLoop(_ s: Int32) {
        while true {
            let c = accept(s, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                return  // listener closed
            }
            lock.withLock { connections.insert(c) }
            Thread.detachNewThread { [weak self] in
                self?.serve(c)
                self?.lock.withLock { _ = self?.connections.remove(c) }
                close(c)
            }
        }
    }

    // MARK: protocol (https://github.com/NetworkBlockDevice/nbd/blob/master/doc/proto.md)

    static let optMagic: UInt64 = 0x3E88_9045_565A9  // option replies (requests start with "IHAVEOPT")
    static let requestMagic: UInt32 = 0x2560_9513
    static let replyMagic: UInt32 = 0x6744_6698
    // HAS_FLAGS, SEND_FLUSH, SEND_FUA, SEND_TRIM, SEND_WRITE_ZEROES
    static let transmissionFlags: UInt16 = 1 | 4 | 8 | 0x20 | 0x40

    enum Command: UInt16 { case read = 0, write = 1, disc = 2, flush = 3, trim = 4, writeZeroes = 6 }
    static let flagFUA: UInt16 = 1

    /// Handshake, then serve requests until the client disconnects. Public for tests.
    public func serve(_ c: Int32) {
        var size: Int32 = 4 << 20
        setsockopt(c, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(c, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var nosig: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        guard let slot = handshake(c) else { return }
        transmit(c, slot: slot)
    }

    /// Fixed-newstyle negotiation; returns the slot the client chose.
    private func handshake(_ c: Int32) -> Int? {
        var hello = Array("NBDMAGICIHAVEOPT".utf8)
        hello += be(UInt16(1 | 2))  // FIXED_NEWSTYLE, NO_ZEROES
        guard writeAll(c, hello), let cf = readExact(c, 4) else { return nil }
        let noZeroes = u32(cf, 0) & 2 != 0
        while true {
            guard let h = readExact(c, 16), h[0..<8].elementsEqual("IHAVEOPT".utf8) else { return nil }
            let opt = u32(h, 8), len = Int(u32(h, 12))
            guard len <= 1 << 16, let data = readExact(c, len) else { return nil }
            func reply(_ type: UInt32, _ payload: [UInt8] = []) -> Bool {
                writeAll(c, be(Self.optMagic) + be(opt) + be(type) + be(UInt32(payload.count)) + payload)
            }
            switch opt {
            case 1:  // EXPORT_NAME: no error reply possible, just close
                guard let slot = slot(named: String(decoding: data, as: UTF8.self)) else { return nil }
                guard writeAll(c, be(slotSize) + be(Self.transmissionFlags) + (noZeroes ? [] : [UInt8](repeating: 0, count: 124))) else { return nil }
                return slot
            case 6, 7:  // INFO, GO
                let n = data.count >= 4 ? Int(u32(data, 0)) : -1
                guard n >= 0, data.count >= 4 + n else {
                    guard reply(0x8000_0003) else { return nil }  // ERR_INVALID
                    continue
                }
                guard let slot = slot(named: String(decoding: data[4..<(4 + n)], as: UTF8.self)) else {
                    guard reply(0x8000_0006) else { return nil }  // ERR_UNKNOWN
                    continue
                }
                guard reply(3, be(UInt16(0)) + be(slotSize) + be(Self.transmissionFlags)),  // INFO_EXPORT
                      reply(1) else { return nil }  // ACK
                if opt == 7 { return slot }
            case 2:  // ABORT
                _ = reply(1)
                return nil
            case 3:  // LIST
                for i in 0..<slotCount {
                    let name = Array(Self.exportName(i).utf8)
                    guard reply(2, be(UInt32(name.count)) + name) else { return nil }  // SERVER
                }
                guard reply(1) else { return nil }
            default:
                guard reply(0x8000_0001) else { return nil }  // ERR_UNSUP
            }
        }
    }

    private func slot(named name: String) -> Int? {
        guard name.hasPrefix("slot"), let n = Int(name.dropFirst(4)), n >= 0, n < slotCount else { return nil }
        return n
    }

    private func transmit(_ c: Int32, slot: Int) {
        let sendLock = NSLock()
        let inflight = DispatchGroup()
        func send(_ err: UInt32, _ cookie: [UInt8], _ data: UnsafeRawBufferPointer? = nil) {
            let header = be(Self.replyMagic) + be(err) + cookie
            sendLock.lock()
            defer { sendLock.unlock() }
            guard writeAll(c, header), let data, data.count > 0 else { return }
            _ = writeAll(c, data)
        }
        defer { inflight.wait() }
        while true {
            guard let r = readExact(c, 28), u32(r, 0) == Self.requestMagic else { return }
            let flags = u16(r, 4), type = u16(r, 6), cookie = Array(r[8..<16])
            let off = u64(r, 16), len = Int(u32(r, 24))
            switch Command(rawValue: type) {
            case .read:
                guard len <= 32 << 20 else { send(22, cookie); continue }
                let b = backing(slot)
                inflight.enter()
                io.async {
                    defer { inflight.leave() }
                    let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: max(len, 1), alignment: 16384)
                    defer { buf.deallocate() }
                    var got = 0
                    if let b, off < b.size {
                        let want = Int(min(UInt64(len), b.size - off))
                        while got < want {
                            let n = pread(b.fd, buf.baseAddress! + got, want - got, off_t(off) + off_t(got))
                            if n <= 0 { break }
                            got += n
                        }
                    }
                    if got < len { memset(buf.baseAddress! + got, 0, len - got) }
                    send(0, cookie, UnsafeRawBufferPointer(rebasing: buf[0..<len]))
                }
            case .write:
                guard len <= 32 << 20, let data = readExact(c, len) else { return }
                let b = backing(slot)
                inflight.enter()
                io.async {
                    defer { inflight.leave() }
                    send(Self.write(b, data, at: off, fua: flags & Self.flagFUA != 0), cookie)
                }
            case .writeZeroes:
                let b = backing(slot)
                inflight.enter()
                io.async {
                    defer { inflight.leave() }
                    guard len <= 32 << 20 else { send(22, cookie); return }
                    send(Self.write(b, [UInt8](repeating: 0, count: len), at: off, fua: flags & Self.flagFUA != 0), cookie)
                }
            case .flush:
                // Covers every write already answered: wait for those in flight.
                inflight.wait()
                if let b = backing(slot) { _ = fcntl(b.fd, F_FULLFSYNC) }
                send(0, cookie)
            case .trim:
                if let b = backing(slot) { Self.punchHole(b, off: off, len: UInt64(len)) }
                send(0, cookie)
            case .disc:
                return
            case nil:
                send(22, cookie)  // EINVAL
            }
        }
    }

    /// NBD error for a write: 0, EIO (5) when unbound or failed, ENOSPC (28) past the image's end.
    static func write(_ b: Backing?, _ data: [UInt8], at off: UInt64, fua: Bool) -> UInt32 {
        guard let b else { return 5 }
        guard off + UInt64(data.count) <= b.size else { return 28 }
        let n = data.withUnsafeBytes { pwrite(b.fd, $0.baseAddress, data.count, off_t(off)) }
        if n != data.count { return 5 }
        if fua { _ = fcntl(b.fd, F_FULLFSYNC) }
        return 0
    }

    /// Give trimmed blocks back to APFS (whole 4 KiB blocks only).
    static func punchHole(_ b: Backing, off: UInt64, len: UInt64) {
        let start = (off + 4095) & ~4095, end = min(off + len, b.size) & ~4095
        guard end > start else { return }
        var arg = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(start), fp_length: off_t(end - start))
        _ = fcntl(b.fd, F_PUNCHHOLE, &arg)
    }
}

// MARK: - byte helpers

private func be(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
private func be(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * UInt32($0))) } }
private func be(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (56 - 8 * UInt64($0))) } }
private func u16(_ b: [UInt8], _ o: Int) -> UInt16 { b[o..<(o + 2)].reduce(0) { $0 << 8 | UInt16($1) } }
private func u32(_ b: [UInt8], _ o: Int) -> UInt32 { b[o..<(o + 4)].reduce(0) { $0 << 8 | UInt32($1) } }
private func u64(_ b: [UInt8], _ o: Int) -> UInt64 { b[o..<(o + 8)].reduce(0) { $0 << 8 | UInt64($1) } }

private func readExact(_ fd: Int32, _ n: Int) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: n)
    var got = 0
    while got < n {
        let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, n - got) }
        if r < 0 && errno == EINTR { continue }
        if r <= 0 { return nil }
        got += r
    }
    return buf
}

@discardableResult
private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    bytes.withUnsafeBytes { writeAll(fd, $0) }
}

@discardableResult
private func writeAll(_ fd: Int32, _ buf: UnsafeRawBufferPointer) -> Bool {
    var off = 0
    while off < buf.count {
        let r = write(fd, buf.baseAddress! + off, buf.count - off)
        if r < 0 && errno == EINTR { continue }
        if r <= 0 { return false }
        off += r
    }
    return true
}
