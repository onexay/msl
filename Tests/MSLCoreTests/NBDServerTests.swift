// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Testing
@testable import MSLCore

/// The NBD client side, as VZ speaks it: fixed newstyle, INFO then GO.
private final class Client {
    let fd: Int32
    var cookie: UInt64 = 0
    init(_ fd: Int32) { self.fd = fd }

    func read(_ n: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, n - got) }
            if r <= 0 { break }
            got += r
        }
        return Array(buf[0..<got])
    }

    func write(_ b: [UInt8]) { b.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, b.count) } }

    static func be<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.bigEndian) { Array($0) } }
    static func num<T: FixedWidthInteger>(_ b: ArraySlice<UInt8>) -> T { b.reduce(T(0)) { $0 << 8 | T($1) } }

    /// Sends an option; returns (reply type, payload) of the next reply.
    func option(_ opt: UInt32, _ data: [UInt8]) -> (UInt32, [UInt8]) {
        write(Array("IHAVEOPT".utf8) + Self.be(opt) + Self.be(UInt32(data.count)) + data)
        return optionReply()
    }

    func optionReply() -> (UInt32, [UInt8]) {
        let h = read(20)
        let len = Int(Self.num(h[16..<20]) as UInt32)
        return (Self.num(h[12..<16]), read(len))
    }

    static func goData(_ name: String) -> [UInt8] {
        let n = Array(name.utf8)
        return be(UInt32(n.count)) + n + be(UInt16(0))
    }

    /// One request; returns (error, payload for reads).
    func request(_ type: UInt16, offset: UInt64, length: Int, flags: UInt16 = 0, data: [UInt8] = []) -> (UInt32, [UInt8]) {
        cookie += 1
        write(Self.be(UInt32(0x2560_9513)) + Self.be(flags) + Self.be(type) + Self.be(cookie) + Self.be(offset) + Self.be(UInt32(length)) + data)
        let r = read(16)
        #expect(Self.num(r[0..<4]) as UInt32 == 0x6744_6698)
        #expect(Self.num(r[8..<16]) as UInt64 == cookie)
        let err: UInt32 = Self.num(r[4..<8])
        return (err, type == 0 && err == 0 ? read(length) : [])
    }
}

@Suite struct NBDServerTests {
    /// A server with `slots` slots and a connected client (handshake not done yet).
    private func connect(_ server: NBDServer) -> Client {
        var sv: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0)
        let s = sv[0]
        Thread.detachNewThread { server.serve(s); close(s) }
        return Client(sv[1])
    }

    private func image(_ size: Int, marker: String) throws -> (URL, Int32) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nbd-\(UUID().uuidString).img")
        var data = Data(marker.utf8)
        data.append(Data(count: size - data.count))
        try data.write(to: url)
        return (url, open(url.path, O_RDWR))
    }

    @Test func handshakeAndIO() throws {
        let server = NBDServer(socketPath: "", slots: 2, slotSize: 8 << 20)
        let c = connect(server)
        defer { close(c.fd) }
        let hello = c.read(18)
        #expect(String(decoding: hello[0..<16], as: UTF8.self) == "NBDMAGICIHAVEOPT")
        #expect(Client.num(hello[16..<18]) as UInt16 == 3)
        c.write(Client.be(UInt32(3)))  // FIXED_NEWSTYLE | NO_ZEROES

        // INFO, then GO: the export's fixed size and flags, then ACK.
        for opt: UInt32 in [6, 7] {
            let (type, info) = c.option(opt, Client.goData("slot1"))
            #expect(type == 3)
            #expect(Client.num(info[2..<10]) as UInt64 == 8 << 20)
            #expect(Client.num(info[10..<12]) as UInt16 == NBDServer.transmissionFlags)
            #expect(c.optionReply().0 == 1)
        }

        // Unbound: zeros, and writes fail with EIO.
        var (err, data) = c.request(0, offset: 0, length: 4096)
        #expect(err == 0 && data == [UInt8](repeating: 0, count: 4096))
        #expect(c.request(1, offset: 0, length: 4, data: Array("oops".utf8)).0 == 5)

        let (url, fd) = try image(1 << 20, marker: "MARK")
        defer { try? FileManager.default.removeItem(at: url) }
        try server.bind(slot: 1, fd: fd)
        #expect(server.isBound(1) && !server.isBound(0))
        #expect(throws: POSIXError.self) { try server.bind(slot: 1, fd: open(url.path, O_RDWR)) }

        (err, data) = c.request(0, offset: 0, length: 4)
        #expect(err == 0 && String(decoding: data, as: UTF8.self) == "MARK")
        #expect(c.request(1, offset: 4096, length: 5, data: Array("hello".utf8)).0 == 0)
        #expect(c.request(1, offset: 8192, length: 3, flags: 1, data: Array("fua".utf8)).0 == 0)  // FUA
        #expect(c.request(1, offset: 1 << 20, length: 4, data: Array("past".utf8)).0 == 28)  // past the image: ENOSPC
        #expect(c.request(3, offset: 0, length: 0).0 == 0)  // FLUSH
        (err, data) = c.request(0, offset: (1 << 20) - 2, length: 4)  // straddles the end: zeros after it
        #expect(err == 0 && data == [0, 0, 0, 0])
        #expect(c.request(6, offset: 4096, length: 5).0 == 0)  // WRITE_ZEROES
        #expect(c.request(4, offset: 16384, length: 16384).0 == 0)  // TRIM
        #expect(c.request(9, offset: 0, length: 0).0 == 22)  // unknown command

        server.unbind(slot: 1)
        let bytes = try Data(contentsOf: url)
        #expect(String(decoding: bytes[8192..<8195], as: UTF8.self) == "fua")
        #expect(bytes[4096..<4101].allSatisfy { $0 == 0 })
        #expect(c.request(1, offset: 0, length: 4, data: Array("gone".utf8)).0 == 5)
        c.write(Client.be(UInt32(0x2560_9513)) + Client.be(UInt16(0)) + Client.be(UInt16(2)) + [UInt8](repeating: 0, count: 20))  // DISC
    }

    @Test func unknownExportsAndList() {
        let server = NBDServer(socketPath: "", slots: 3, slotSize: 1 << 30)
        let c = connect(server)
        defer { close(c.fd) }
        _ = c.read(18)
        c.write(Client.be(UInt32(3)))
        #expect(c.option(7, Client.goData("slot3")).0 == 0x8000_0006)  // ERR_UNKNOWN
        #expect(c.option(7, Client.goData("disk")).0 == 0x8000_0006)
        #expect(c.option(8, []).0 == 0x8000_0001)  // STRUCTURED_REPLY: unsupported
        var (type, name) = c.option(3, [])  // LIST
        var names: [String] = []
        while type == 2 {
            names.append(String(decoding: name.dropFirst(4), as: UTF8.self))
            (type, name) = c.optionReply()
        }
        #expect(type == 1 && names == ["slot0", "slot1", "slot2"])
        #expect(c.option(2, []).0 == 1)  // ABORT
    }

    @Test func listensOnUnixSocket() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("nbd-\(getpid()).sock").path
        let server = NBDServer(socketPath: path, slots: 1, slotSize: 1 << 20)
        try server.start()
        var st = stat()
        #expect(stat(path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        server.stop()
        #expect(access(path, F_OK) != 0)
    }
}
