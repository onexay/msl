import Foundation

/// Flow-controlled byte stream over vsock: the host half of guest/src/framed.rs.
///
/// Virtualization.framework's vsock device blocks (freezing every vsock
/// connection and eventually a vCPU) when the host doesn't read a connection.
/// With framing, the peer can never send more than `window` bytes we haven't
/// delivered, so the receive thread always reads the socket immediately and
/// backpressure lands on the real consumer (a terminal, a pipe, a TCP client).
///
/// Frame: [kind u8][len u32 BE][payload]; kind 0 = data, 1 = credit (u32 BE
/// bytes delivered), 2 = eof. Both directions start with `window` credit.
final class FramedBridge: @unchecked Sendable {
    static let window = 1 << 20
    static let maxFrame = 64 << 10
    static let creditBatch = 128 << 10

    /// Everything read from `localIn` has been sent (eof sent).
    let sent = Completion()
    /// All of the peer's data has been written to `localOut` (peer eof reached).
    let delivered = Completion()

    private let vsock: Int32
    private let wlock = NSLock()
    private let creditCond = NSCondition()
    private var credit = FramedBridge.window
    private var dead = false
    private let queueCond = NSCondition()
    private var queue: [[UInt8]?] = []  // nil = peer eof
    private let stateLock = NSLock()
    private var lastFrame = Date()
    private var remaining = 2     // sender + local writer
    private var threadsLeft = 3   // + receiver; the socket is closed when all are done
    private var closed = false

    /// - localIn: read and send to the guest (nil: send eof at once). With
    ///   `stop`, reads poll so the sender can be abandoned (e.g. a client stdin).
    /// - localOut: receives the guest's bytes. At the guest's eof it is
    ///   `shutdown(SHUT_WR)` if `shutdownOnEOF` (sockets).
    /// - ownsLocal: close localIn/localOut when finished.
    init(vsock: Int32, localIn: Int32?, localOut: Int32?, stop: StopFlag? = nil,
         shutdownOnEOF: Bool = false, ownsLocal: Bool = false) {
        self.vsock = vsock
        let finishLocal: () -> Void = {
            guard ownsLocal else { return }
            if let i = localIn { close(i) }
            if let o = localOut, o != localIn { close(o) }
        }

        Thread.detachNewThread { [self] in  // sender
            if let input = localIn {
                var buf = [UInt8](repeating: 0, count: Self.maxFrame)
                outer: while true {
                    if let stop {
                        var p = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
                        let r = poll(&p, 1, 100)
                        if stop.isSet { break }
                        if r == 0 || (r < 0 && errno == EINTR) { continue }
                    }
                    let n = buf.withUnsafeMutableBytes { read(input, $0.baseAddress!, $0.count) }
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    var off = 0
                    while off < n {
                        guard let c = takeCredit(n - off) else { break outer }
                        guard writeFrame(0, Array(buf[off..<(off + c)])) else { break outer }
                        off += c
                    }
                }
            }
            _ = writeFrame(2, [])
            sent.signal()
            finishOne(finishLocal)
            threadDone()
        }

        Thread.detachNewThread { [self] in  // local writer: queue -> localOut, then credit
            var out = localOut
            var owed = 0
            while true {
                queueCond.lock()
                while queue.isEmpty { queueCond.wait() }
                let item = queue.removeFirst()
                let more = !queue.isEmpty
                queueCond.unlock()
                guard let data = item else {
                    if shutdownOnEOF, let o = out { shutdown(o, SHUT_WR) }
                    break
                }
                if let o = out, !writeAll(o, data) { out = nil }  // consumer gone: keep draining
                owed += data.count
                if owed >= Self.creditBatch || !more {
                    _ = writeFrame(1, Self.be32(UInt32(owed)))
                    owed = 0
                }
            }
            delivered.signal()
            finishOne(finishLocal)
            threadDone()
        }

        Thread.detachNewThread { [self] in  // receiver: always drains the socket
            var eof = false
            while let (kind, payload) = readFrame() {
                stateLock.withLock { lastFrame = Date() }
                switch kind {
                case 0: push(payload)
                case 1 where payload.count == 4:
                    creditCond.lock()
                    credit += Int(UInt32(payload[0]) << 24 | UInt32(payload[1]) << 16 | UInt32(payload[2]) << 8 | UInt32(payload[3]))
                    creditCond.broadcast()
                    creditCond.unlock()
                case 2 where !eof:
                    eof = true
                    push(nil)
                default: break
                }
            }
            creditCond.lock(); dead = true; creditCond.broadcast(); creditCond.unlock()
            if !eof { push(nil) }
            threadDone()
        }
    }

    /// Nothing from the guest for `seconds` and nothing left to write: the guest
    /// gave up on this stream (e.g. a background process holds the output open).
    func quiet(for seconds: TimeInterval) -> Bool {
        let idle = stateLock.withLock { Date().timeIntervalSince(lastFrame) > seconds }
        return idle && queueCond.withLock { queue.isEmpty }
    }

    /// Tear the connection down now.
    func abort() { shutdownSocket() }

    /// shutdown() only while we still own the fd (never on a reused number).
    private func shutdownSocket() {
        stateLock.withLock { if !closed { shutdown(vsock, SHUT_RDWR) } }
    }

    private func threadDone() {
        stateLock.withLock {
            threadsLeft -= 1
            if threadsLeft == 0 {
                closed = true
                close(vsock)
            }
        }
    }

    private func finishOne(_ finishLocal: () -> Void) {
        let last = stateLock.withLock { () -> Bool in remaining -= 1; return remaining == 0 }
        if last {
            shutdownSocket()
            finishLocal()
        }
    }

    private func push(_ item: [UInt8]?) {
        queueCond.lock()
        queue.append(item)
        queueCond.signal()
        queueCond.unlock()
    }

    private func takeCredit(_ want: Int) -> Int? {
        creditCond.lock()
        defer { creditCond.unlock() }
        while credit == 0 && !dead { creditCond.wait() }
        if credit == 0 { return nil }
        let n = min(want, credit)
        credit -= n
        return n
    }

    private func writeFrame(_ kind: UInt8, _ payload: [UInt8]) -> Bool {
        wlock.withLock { writeAll(vsock, [kind] + Self.be32(UInt32(payload.count)) + payload) }
    }

    private func readFrame() -> (UInt8, [UInt8])? {
        var hdr = [UInt8](repeating: 0, count: 5)
        guard readExactly(vsock, &hdr) else { return nil }
        let len = Int(UInt32(hdr[1]) << 24 | UInt32(hdr[2]) << 16 | UInt32(hdr[3]) << 8 | UInt32(hdr[4]))
        guard len <= max(Self.maxFrame, 4) else { return nil }
        var payload = [UInt8](repeating: 0, count: len)
        guard len == 0 || readExactly(vsock, &payload) else { return nil }
        return (hdr[0], payload)
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
}

func writeAll(_ fd: Int32, _ data: [UInt8]) -> Bool {
    var off = 0
    while off < data.count {
        let w = data.withUnsafeBytes { write(fd, $0.baseAddress! + off, $0.count - off) }
        if w < 0 && errno == EINTR { continue }
        if w <= 0 { return false }
        off += w
    }
    return true
}

func readExactly(_ fd: Int32, _ buf: inout [UInt8]) -> Bool {
    var got = 0
    while got < buf.count {
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, $0.count - got) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return false }
        got += n
    }
    return true
}
