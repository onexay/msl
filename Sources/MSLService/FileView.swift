// SPDX-License-Identifier: Apache-2.0
import Foundation
import MSLCore

/// `~/.msl/distros/<distro>`: the distros' files on the Mac (the `\\wsl.localhost` equivalent).
///
/// The guest serves NFSv3 on its loopback (port 21049) from /run/msl-view, which
/// holds one folder per distro *name*. msld exposes it on a 0600 Unix socket in
/// msl's folder (or, with `fileViewTransport = tcp`, a private 127.0.0.1 port),
/// relayed over vsock independently of localhost forwarding, and mounts **each
/// distro separately**, as the user, at `~/.msl/distros/<name>`. Every RPC call
/// passes RPCFilter first (#1): only the user's and the kernel's credentials,
/// and MOUNT only while msld is mounting. Finder names a network volume after the last component
/// of its export path, so every distro shows up in Finder's Locations under its
/// own name (and logo, see DistroIcon), like Explorer's "Linux" node. macOS
/// metadata (.DS_Store, ._*) stays in the guest's memory (nfsview.rs).
final class FileView: @unchecked Sendable {
    static let guestNFSPort: UInt16 = 21049

    private let vm: VMHost
    private let paths: Paths
    private let registry: Registry
    private let guest: GuestClients
    private let lock = NSLock()
    private var stop: StopFlag?
    /// Where the view is served: a Unix socket path, or a 127.0.0.1 port.
    private enum Endpoint { case unix(String), tcp(UInt16) }
    private var endpoint: Endpoint?
    /// > 0 while msld runs mount_nfs: the only time a MOUNT call is accepted.
    private var mounting = 0
    private let owner = getuid()

    init(vm: VMHost, paths: Paths, registry: Registry, guest: GuestClients) {
        self.vm = vm
        self.paths = paths
        self.registry = registry
        self.guest = guest
    }

    static var viewDir: URL {
        if let p = ProcessInfo.processInfo.environment["MSL_VIEW_DIR"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".msl/distros", isDirectory: true)
    }

    /// Earlier designs, all cleaned up on start: a hidden mount at <msl>/files
    /// with ~/MSL symlinks, one mount at ~/MSL itself, then one mount per distro
    /// at ~/MSL/<name> (before ~/.msl/distros).
    private var legacyMountPoint: URL { paths.root.appendingPathComponent("files", isDirectory: true) }
    private var legacyViewDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MSL", isDirectory: true) }

    var socketPath: String { paths.root.appendingPathComponent("nfs.sock").path }

    func start(transport: MSLConfig.FileViewTransport) {
        let flag = StopFlag()
        lock.withLock { stop?.set(); stop = flag }
        let lfd: Int32, ep: Endpoint
        switch transport {
        case .unix:
            guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path),
                  let fd = try? listenUnix(socketPath, backlog: 16) else {
                log("files: could not listen on \(socketPath); set fileViewTransport = tcp in .mslconfig"); return
            }
            (lfd, ep) = (fd, .unix(socketPath))
        case .tcp:
            guard let (fd, port) = Self.listenEphemeral() else { log("files: could not open a bridge port"); return }
            (lfd, ep) = (fd, .tcp(port))
        }
        Thread.detachNewThread { [vm, weak self] in
            defer { close(lfd) }
            while !flag.isSet {
                var p = pollfd(fd: lfd, events: Int16(POLLIN), revents: 0)
                if poll(&p, 1, 200) <= 0 { continue }
                let c = accept(lfd, nil, nil)
                if c < 0 { continue }
                guard let self, let v = try? vm.connect(port: PortForwarder.guestForwarderPort) else { close(c); continue }
                var hdr = Self.guestNFSPort.bigEndian
                var pair: [Int32] = [0, 0]
                guard write(v, &hdr, 2) == 2, socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { close(c); close(v); continue }
                // client ⇄ RPC filter ⇄ pair ⇄ framed vsock bridge ⇄ guest NFS server
                _ = FramedBridge(vsock: v, localIn: pair[1], localOut: pair[1], shutdownOnEOF: true, ownsLocal: true)
                self.filter(client: c, bridge: pair[0])
            }
            if case .unix(let path) = ep { unlink(path) }
        }
        lock.withLock { endpoint = ep }
        cleanupLegacy()
        syncLinks()
    }

    func shutdown() {
        lock.withLock { stop?.set(); stop = nil; endpoint = nil }
        for (name, url) in mountedDistros() {
            unmount(url)
            log("files: unmounted \(name)")
        }
    }

    /// Bring guest view and Mac mounts in line with the registry. Call on
    /// start and after every registry change.
    func syncLinks() {
        guard vm.isRunning, let mini = try? guest.miniInit, let ep = lock.withLock({ endpoint }) else { return }
        let map = Dictionary(registry.all.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
        _ = try? blocking { try await mini.setFileView(.with { $0.distros = map }) }

        let fm = FileManager.default
        try? fm.createDirectory(at: Self.viewDir, withIntermediateDirectories: true)
        for (name, url) in mountedDistros() where map[name] == nil {
            unmount(url)
        }
        for name in map.keys.sorted() {
            let url = Self.viewDir.appendingPathComponent(name, isDirectory: true)
            if isNFS(url) { continue }
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            // Never mount over someone's files.
            let contents = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0 != ".DS_Store" }
            guard contents.isEmpty else {
                log("files: \(url.path) is not empty; not mounting \(name) there")
                continue
            }
            try? fm.removeItem(at: url.appendingPathComponent(".DS_Store"))
            let common = "nolocks,vers=3,soft,retrans=2,timeo=10,actimeo=1,nfc"
            let (opts, source): (String, String) = switch ep {
            // Undocumented in mount_nfs(8), implemented in Apple's NFS source:
            // a host "<path>" is an AF_LOCAL address, and mountport= takes a path.
            case .unix(let path): ("\(common),mountport=\(path)", "<\(path)>:/\(name)")
            case .tcp(let port): ("\(common),tcp,port=\(port),mountport=\(port)", "127.0.0.1:/\(name)")
            }
            var ok = false
            lock.withLock { mounting += 1 }
            for _ in 0..<30 {  // the guest server may still be starting
                if run("/sbin/mount_nfs", ["-o", opts, source, url.path]) == 0 { ok = true; break }
                usleep(100_000)
            }
            lock.withLock { mounting -= 1 }
            if ok {
                log("files: mounted \(name) at \(url.path)")
                if let rec = registry.find(name: name) { DistroIcon.apply(record: rec, volume: url) }
            } else {
                try? fm.removeItem(at: url)  // only an empty mount point
                log("files: mount_nfs failed for \(name)")
            }
        }
    }

    /// Our NFS mounts directly under the view dir, from the kernel's mount table
    /// (getmntinfo never touches the mount, so a stale one can't hang or hide).
    private func mountedDistros() -> [(String, URL)] {
        let base = Self.realPath(Self.viewDir.path) + "/"
        return Self.nfsMountPoints().compactMap { on in
            guard on.hasPrefix(base) else { return nil }
            let name = String(on.dropFirst(base.count))
            return name.isEmpty || name.contains("/") ? nil : (name, Self.viewDir.appendingPathComponent(name, isDirectory: true))
        }
    }

    static func nfsMountPoints() -> [String] {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return [] }
        return (0..<Int(n)).compactMap { i in
            var m = buf[i]
            let type = withUnsafeBytes(of: &m.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let on = withUnsafeBytes(of: &m.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return type == "nfs" ? on : nil
        }
    }

    /// Unmount one distro (before its export disappears in the guest).
    func unmount(name: String) {
        if let (_, url) = mountedDistros().first(where: { $0.0 == name }) { unmount(url) }
    }

    /// Unmount and remove the (now empty) mount point, so nothing can be
    /// written to the Mac disk underneath it while the distro isn't mounted.
    private func unmount(_ url: URL) {
        _ = run("/sbin/umount", ["-f", url.path])
        if !isNFS(url) { rmdir(url.path) }
    }

    private func cleanupLegacy() {
        let fm = FileManager.default
        if isNFS(legacyMountPoint) { _ = run("/sbin/umount", ["-f", legacyMountPoint.path]) }
        try? fm.removeItem(at: legacyMountPoint)
        let old = legacyViewDir
        guard Self.realPath(old.path) != Self.realPath(Self.viewDir.path) else { return }  // MSL_VIEW_DIR=~/MSL
        if isNFS(old) { _ = run("/sbin/umount", ["-f", old.path]) }  // single-mount design
        for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] {
            let url = old.appendingPathComponent(name)
            if let t = try? fm.destinationOfSymbolicLink(atPath: url.path), t.hasPrefix(legacyMountPoint.path) {
                try? fm.removeItem(at: url)
            } else if isNFS(url) {
                unmount(url)  // per-distro design; removes the empty mount point
            }
        }
        try? fm.removeItem(at: old.appendingPathComponent(".DS_Store"))
        if rmdir(old.path) == 0 { log("files: removed the old ~/MSL folder (now \(Self.viewDir.path))") }  // only when empty
    }

    private func isNFS(_ url: URL) -> Bool {
        Self.nfsMountPoints().contains(Self.realPath(url.path))
    }

    /// The kernel reports mount points with symlinks resolved (/tmp is
    /// /private/tmp); URL.resolvingSymlinksInPath strips /private, so use realpath.
    static func realPath(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Relay one NFS client connection to the guest, calls through RPCFilter.
    /// Records (RFC 5531 record marking) are forwarded whole; a denied call is
    /// answered here with AUTH_ERROR, between two of the guest's replies.
    private func filter(client c: Int32, bridge b: Int32) {
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
        Thread.detachNewThread { [self] in  // macOS → guest: calls
            defer { Darwin.shutdown(b, SHUT_WR); done.leave() }
            var verdict: RPCFilter.Verdict?
            var denied = 0
            while let h = readFull(c, 4) {
                let (len, last) = mark(h)
                guard len <= maxFragment, let frag = readFull(c, len) else { return }
                if verdict == nil {
                    verdict = RPCFilter.check(frag, owner: owner, mountAllowed: lock.withLock { mounting > 0 })
                }
                if verdict == .allow, !writeAll(b, h + frag) { return }
                if last {
                    if case .deny(let xid, let why) = verdict {
                        if denied < 5 { log("files: refused an NFS call (\(why))") }
                        denied += 1
                        guard writeLock.withLock({ writeAll(c, RPCFilter.denial(xid: xid)) }) else { return }
                    }
                    verdict = nil
                }
            }
        }
        done.enter()
        Thread.detachNewThread {  // guest → macOS: replies, whole records under writeLock
            defer { Darwin.shutdown(c, SHUT_WR); done.leave() }
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

    private static func listenEphemeral() -> (Int32, UInt16)? {
        guard let fd = PortForwarder.listen(port: 0, v6: false) else { return nil }
        var a = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return (fd, UInt16(bigEndian: a.sin_port))
    }
}
