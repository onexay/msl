import Foundation
import MSLCore

/// `~/MSL/<distro>`: the distros' files on the Mac (the `\\wsl.localhost` equivalent).
///
/// The guest serves NFSv3 on its loopback (port 21049) from /run/msl-view, which
/// holds one folder per distro *name*. msld exposes it on a private 127.0.0.1
/// port (relayed over vsock, independent of localhost forwarding) and mounts
/// **each distro separately**, as the user, at `~/MSL/<name>` from
/// `127.0.0.1:/<name>`. Finder names a network volume after the last component
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
    private var port: UInt16?

    init(vm: VMHost, paths: Paths, registry: Registry, guest: GuestClients) {
        self.vm = vm
        self.paths = paths
        self.registry = registry
        self.guest = guest
    }

    static var viewDir: URL {
        if let p = ProcessInfo.processInfo.environment["MSL_VIEW_DIR"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MSL", isDirectory: true)
    }

    /// Earlier designs: a hidden mount at <msl>/files with ~/MSL symlinks, then
    /// one mount at ~/MSL itself. Both are cleaned up on start.
    private var legacyMountPoint: URL { paths.root.appendingPathComponent("files", isDirectory: true) }

    func start() {
        let flag = StopFlag()
        lock.withLock { stop?.set(); stop = flag }
        guard let (lfd, port) = Self.listenEphemeral() else { log("files: could not open a bridge port"); return }
        Thread.detachNewThread { [vm] in
            defer { close(lfd) }
            while !flag.isSet {
                var p = pollfd(fd: lfd, events: Int16(POLLIN), revents: 0)
                if poll(&p, 1, 200) <= 0 { continue }
                let c = accept(lfd, nil, nil)
                if c < 0 { continue }
                guard let v = try? vm.connect(port: PortForwarder.guestForwarderPort) else { close(c); continue }
                var hdr = Self.guestNFSPort.bigEndian
                guard write(v, &hdr, 2) == 2 else { close(c); close(v); continue }
                _ = FramedBridge(vsock: v, localIn: c, localOut: c, shutdownOnEOF: true, ownsLocal: true)
            }
        }
        lock.withLock { self.port = port }
        cleanupLegacy()
        syncLinks()
    }

    func shutdown() {
        lock.withLock { stop?.set(); stop = nil; port = nil }
        for (name, url) in mountedDistros() {
            unmount(url)
            log("files: unmounted \(name)")
        }
    }

    /// Bring guest view and Mac mounts in line with the registry. Call on
    /// start and after every registry change.
    func syncLinks() {
        guard vm.isRunning, let mini = try? guest.miniInit, let port = lock.withLock({ port }) else { return }
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
            let opts = "nolocks,vers=3,tcp,port=\(port),mountport=\(port),soft,retrans=2,timeo=10,actimeo=1,nfc"
            var ok = false
            for _ in 0..<30 {  // the guest server may still be starting
                if run("/sbin/mount_nfs", ["-o", opts, "127.0.0.1:/\(name)", url.path]) == 0 { ok = true; break }
                usleep(100_000)
            }
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
        if isNFS(Self.viewDir) { _ = run("/sbin/umount", ["-f", Self.viewDir.path]) }  // single-mount design
        for name in (try? fm.contentsOfDirectory(atPath: Self.viewDir.path)) ?? [] {
            let p = Self.viewDir.appendingPathComponent(name).path
            if let t = try? fm.destinationOfSymbolicLink(atPath: p), t.hasPrefix(legacyMountPoint.path) {
                try? fm.removeItem(atPath: p)
            }
        }
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

    private static func listenEphemeral() -> (Int32, UInt16)? {
        guard let fd = PortForwarder.listen(port: 0, v6: false) else { return nil }
        var a = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return (fd, UInt16(bigEndian: a.sin_port))
    }
}
