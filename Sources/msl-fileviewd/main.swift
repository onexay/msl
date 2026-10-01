// SPDX-License-Identifier: Apache-2.0
// msl-fileviewd: the ~/.msl/distros view's relay. msld starts it with the view's
// listening socket (the 0600 Unix socket, or 127.0.0.1 with fileViewTransport
// = tcp) and, for each connection macOS's NFS client opens, passes it a vsock
// stream to the guest's NFS server (see RelayMessage). msl-fileviewd checks
// every RPC call (RPCFilter, #1) and copies the bytes, so msld never carries
// them; msld keeps mounting the distros and opens the MOUNT window for it.
import Foundation
import MSLCore

final class MountWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    var isOpen: Bool { lock.withLock { open } }
    func set(_ v: Bool) { lock.withLock { open = v } }
}

let window = MountWindow()
let owner = getuid()

/// Relay one NFS client connection to the guest, calls through RPCFilter.
/// Records (RFC 5531 record marking) are forwarded whole; a denied call is
/// answered here with AUTH_ERROR, between two of the guest's replies.
func filter(client c: Int32, bridge b: Int32) {
    let writeLock = NSLock()
    let done = DispatchGroup()
    let maxFragment = 16 << 20
    func readFull(_ fd: Int32, _ n: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: n), got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, n - got) }
            if r <= 0 { return nil }
            got += r
        }
        return buf
    }
    func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var put = 0
        while put < bytes.count {
            let r = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + put, bytes.count - put) }
            if r <= 0 { return false }
            put += r
        }
        return true
    }
    func mark(_ h: [UInt8]) -> (len: Int, last: Bool) {
        let m = UInt32(h[0]) << 24 | UInt32(h[1]) << 16 | UInt32(h[2]) << 8 | UInt32(h[3])
        return (Int(m & 0x7fff_ffff), m & 0x8000_0000 != 0)
    }
    done.enter()
    Thread.detachNewThread {  // macOS → guest: calls
        defer { shutdown(b, SHUT_WR); done.leave() }
        var verdict: RPCFilter.Verdict?
        var denied = 0
        while let h = readFull(c, 4) {
            let (len, last) = mark(h)
            guard len <= maxFragment, let frag = readFull(c, len) else { return }
            if verdict == nil {
                verdict = RPCFilter.check(frag, owner: owner, mountAllowed: window.isOpen)
            }
            if verdict == .allow, !writeAll(b, h + frag) { return }
            if last {
                if case .deny(let xid, let why) = verdict {
                    if denied < 5 { RelayHelper.log("files: refused an NFS call (\(why))") }
                    denied += 1
                    guard writeLock.withLock({ writeAll(c, RPCFilter.denial(xid: xid)) }) else { return }
                }
                verdict = nil
            }
        }
    }
    done.enter()
    Thread.detachNewThread {  // guest → macOS: replies, whole records under writeLock
        defer { shutdown(c, SHUT_WR); done.leave() }
        var holding = false
        defer { if holding { writeLock.unlock() } }
        while let h = readFull(b, 4) {
            let (len, last) = mark(h)
            guard len <= maxFragment, let frag = readFull(b, len) else { return }
            if !holding { writeLock.lock(); holding = true }
            guard writeAll(c, h + frag) else { return }
            if last { writeLock.unlock(); holding = false }
        }
    }
    done.notify(queue: .global()) { close(c); close(b) }
}

RelayHelper(bridge: { client, vsock, done in
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
        close(client); close(vsock); done()
        return
    }
    // client ⇄ RPC filter ⇄ pair ⇄ framed vsock bridge ⇄ guest NFS server
    FramedBridge(vsock: vsock, localIn: pair[1], localOut: pair[1], shutdownOnEOF: true, ownsLocal: true, onClose: done)
    filter(client: client, bridge: pair[0])
}, onMessage: { msg, helper in
    if case .mountWindow(let open) = msg {
        window.set(open)
        try? helper.control.send(RelayMessage.mountWindowSet(open: open))
    }
}).run()
