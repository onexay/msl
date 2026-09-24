// SPDX-License-Identifier: Apache-2.0
import Foundation
import dnssd

/// DNS tunneling (WSL's `dnsTunneling`): answers the guest stub's queries with
/// macOS's own resolver (mDNSResponder), so VPN scoped resolvers, /etc/resolver,
/// .local names and the Mac's /etc/hosts all work inside distros.
///
/// Wire format (one query per vsock connection): 2-byte BE length + DNS message.
enum DNSProxy {
    static let vsockPort: UInt32 = 53

    static func handle(_ fd: Int32) {
        defer { close(fd) }
        var lenBuf = [UInt8](repeating: 0, count: 2)
        guard readExactly(fd, &lenBuf) else { return }
        var query = [UInt8](repeating: 0, count: Int(UInt16(lenBuf[0]) << 8 | UInt16(lenBuf[1])))
        guard readExactly(fd, &query) else { return }
        let response = answer(query)
        var out = [UInt8(response.count >> 8), UInt8(response.count & 0xff)] + response
        _ = out.withUnsafeMutableBytes { write(fd, $0.baseAddress!, $0.count) }
    }

    static func readExactly(_ fd: Int32, _ buf: inout [UInt8]) -> Bool {
        var got = 0
        while got < buf.count {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, $0.count - got) }
            if n <= 0 { return false }
            got += n
        }
        return true
    }

    struct Question {
        var name: String
        var type: UInt16
        var cls: UInt16
        var end: Int  // offset just past the question section
    }

    static func parseQuestion(_ q: [UInt8]) -> Question? {
        guard q.count >= 12, (UInt16(q[4]) << 8 | UInt16(q[5])) >= 1 else { return nil }
        var i = 12
        var labels: [String] = []
        while i < q.count {
            let len = Int(q[i])
            if len == 0 { i += 1; break }
            guard len < 64, i + 1 + len <= q.count else { return nil }
            labels.append(String(decoding: q[(i + 1)..<(i + 1 + len)], as: UTF8.self))
            i += 1 + len
        }
        guard i + 4 <= q.count else { return nil }
        let type = UInt16(q[i]) << 8 | UInt16(q[i + 1])
        let cls = UInt16(q[i + 2]) << 8 | UInt16(q[i + 3])
        return Question(name: labels.joined(separator: ".") + ".", type: type, cls: cls, end: i + 4)
    }

    struct Record {
        var type: UInt16
        var cls: UInt16
        var ttl: UInt32
        var rdata: [UInt8]
    }

    final class Collector {
        var records: [Record] = []
        var done = false
        var error: DNSServiceErrorType = DNSServiceErrorType(kDNSServiceErr_NoError)
    }

    /// Resolve with mDNSResponder. nil = timeout / failure (SERVFAIL).
    static func resolve(_ q: Question, timeout: TimeInterval = 5) -> (records: [Record], nodata: Bool)? {
        let collector = Collector()
        let ctx = Unmanaged.passRetained(collector)
        defer { ctx.release() }
        var ref: DNSServiceRef?
        let callback: DNSServiceQueryRecordReply = { _, flags, _, err, _, rrtype, rrclass, rdlen, rdata, ttl, context in
            let c = Unmanaged<Collector>.fromOpaque(context!).takeUnretainedValue()
            if err == DNSServiceErrorType(kDNSServiceErr_NoError) {
                if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let rdata {
                    let bytes = Array(UnsafeBufferPointer(start: rdata.assumingMemoryBound(to: UInt8.self), count: Int(rdlen)))
                    c.records.append(Record(type: rrtype, cls: rrclass, ttl: ttl, rdata: bytes))
                }
            } else {
                c.error = err
            }
            if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { c.done = true }
        }
        let flags = DNSServiceFlags(kDNSServiceFlagsTimeout)
        guard DNSServiceQueryRecord(&ref, flags, 0, q.name, q.type, q.cls, callback, ctx.toOpaque()) == kDNSServiceErr_NoError,
              let ref else { return nil }
        defer { DNSServiceRefDeallocate(ref) }
        let fd = DNSServiceRefSockFD(ref)
        let deadline = Date().addingTimeInterval(timeout)
        while !collector.done {
            let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            if left == 0 { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, left) > 0 {
                if DNSServiceProcessResult(ref) != kDNSServiceErr_NoError { return nil }
            }
        }
        if collector.error == DNSServiceErrorType(kDNSServiceErr_NoSuchRecord) || collector.error == DNSServiceErrorType(kDNSServiceErr_NoSuchName) {
            return ([], true)
        }
        if collector.error != DNSServiceErrorType(kDNSServiceErr_NoError) && collector.records.isEmpty { return nil }
        // Loopback and link-local addresses (e.g. the Mac's own name -> ::1) mean
        // something else inside the VM: drop them.
        let usable = collector.records.filter { !isLocalOnly($0) }
        return (usable, usable.isEmpty)
    }

    static func isLocalOnly(_ r: Record) -> Bool {
        switch (r.type, r.rdata.count) {
        case (1, 4): return r.rdata[0] == 127 || (r.rdata[0] == 169 && r.rdata[1] == 254)
        case (28, 16):
            let loopback = r.rdata.prefix(15).allSatisfy { $0 == 0 } && r.rdata[15] == 1
            let linkLocal = r.rdata[0] == 0xfe && (r.rdata[1] & 0xc0) == 0x80
            return loopback || linkLocal
        default: return false
        }
    }

    static func answer(_ query: [UInt8]) -> [UInt8] {
        guard let q = parseQuestion(query) else { return header(query, rcode: 1, an: 0) + [] }  // FORMERR
        guard let result = resolve(q) else { return header(query, rcode: 2, an: 0) + Array(query[12..<q.end]) }  // SERVFAIL
        var out = header(query, rcode: 0, an: UInt16(result.records.count)) + Array(query[12..<q.end])
        for r in result.records {
            out += [0xC0, 0x0C]  // pointer to the question name
            out += be16(r.type) + be16(r.cls) + be32(r.ttl) + be16(UInt16(r.rdata.count)) + r.rdata
        }
        return out
    }

    static func header(_ query: [UInt8], rcode: UInt8, an: UInt16) -> [UInt8] {
        guard query.count >= 12 else { return [] }
        let flags1 = 0x80 | (query[2] & 0x79)  // QR, opcode, RD
        let flags2 = 0x80 | rcode  // RA
        return [query[0], query[1], flags1, flags2] + be16(1) + be16(an) + be16(0) + be16(0)
    }

    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
}
