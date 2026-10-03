// SPDX-License-Identifier: Apache-2.0
import Foundation
import GRPCCore
import MSLCore
import MSLProtocol

/// The distros' own disks (#50) while the VM runs.
///
/// Every registered distro's ext4.img is attached as virtio-blk when the VM
/// boots (up to DistroDisk.maxBootDisks), served by Virtualization.framework
/// with guest flushes turned into F_FULLFSYNC. virtio-blk can't be hot-plugged,
/// so a disk that appears while the VM runs (an install, an import, a move to
/// another volume, a resize) needs another way in:
/// - while no distro runs, msld restarts the VM so the disk is attached at boot;
/// - otherwise the guest mounts it through a loop device over the Mac share
///   (virtiofs) until the VM restarts. That path is slower, and virtiofs doesn't
///   flush to the SSD on a guest fsync, so msld does F_FULLFSYNC when the disk
///   is detached and when the VM stops.
/// msld itself never serves disk I/O. One lock serializes mounting and unmounting.
final class DistroDisks: @unchecked Sendable {
    enum Transport: Equatable {
        case boot(serial: String)
        case loop(path: String)
    }

    /// A disk attached at this boot, and the file it was: once the path holds
    /// another file or the size changed, the device is stale and never mounted again.
    private struct Boot {
        var serial: String
        var device: UInt64
        var inode: UInt64
        var size: UInt64
    }

    private let vm: VMHost
    private let guest: GuestClients
    private let lock = NSLock()
    private var boot: [String: Boot] = [:]          // distro id -> disk attached at boot
    private var planned: [String: String] = [:]     // serial -> distro id, for the boot in progress
    private var mounted: [String: Transport] = [:]  // distro id -> mounted in the VM
    /// Disks to attach at the next boot ahead of the others, and not to mount
    /// there: the caller mounts them itself (a new disk, or one being resized).
    private var pending: [String: DistroRecord] = [:]
    /// Called (with the distro id) before a disk is unmounted: unmount its files on the Mac.
    var beforeDetach: (String) -> Void = { _ in }
    /// Called after disks were mounted or unmounted (on another thread): resync the file view.
    var onChange: () -> Void = {}
    /// Whether the VM may be restarted now to attach a disk at boot (no distro running).
    var canRestartVM: () -> Bool = { false }
    /// Restart the VM; the next boot attaches the pending disks.
    var restartVM: () throws -> Void = {}

    private func changed() {
        let f = onChange
        DispatchQueue.global().async { f() }
    }

    init(vm: VMHost, guest: GuestClients) {
        self.vm = vm
        self.guest = guest
    }

    // MARK: boot

    /// The disks to attach at the next boot: pending ones first, then the
    /// default distro's, then the rest in registry order, up to the limit.
    func bootPlan(_ distros: [DistroRecord], defaultId: String?) -> [VMHost.BootDisk] {
        lock.withLock {
            var order = Array(pending.values)
            order += distros.filter { $0.id == defaultId && pending[$0.id] == nil }
            order += distros.filter { $0.id != defaultId && pending[$0.id] == nil }
            let plan = order.filter { $0.disk != nil }.prefix(DistroDisk.bootDiskLimit()).enumerated().map { i, d in
                VMHost.BootDisk(serial: "d\(i)", path: d.disk!.path)
            }
            planned = Dictionary(uniqueKeysWithValues: zip(plan.map(\.serial), order.filter { $0.disk != nil }.map(\.id)))
            return plan
        }
    }

    /// The VM booted with `attached`: remember which file each device is.
    func booted(_ attached: [VMHost.BootDisk]) {
        lock.withLock {
            boot = [:]
            for d in attached {
                guard let id = planned[d.serial], let st = Self.fileInfo(d.path) else { continue }
                boot[id] = Boot(serial: d.serial, device: st.device, inode: st.inode, size: st.size)
            }
            planned = [:]
        }
    }

    /// At boot: mount every distro disk attached at boot, so the Finder view
    /// shows it. A disk that can't be mounted is logged; using it reports the error.
    func attachAll(_ distros: [DistroRecord]) {
        let ids = lock.withLock { Set(boot.keys).subtracting(pending.keys) }
        for d in distros where ids.contains(d.id) {
            do { try ensureAttached(d, notify: false) } catch { log("disk of \(d.name): \(Self.describe(error))") }
        }
    }

    /// `d` is new (not registered yet): attach its disk at the next boot.
    func prepare(_ d: DistroRecord) {
        lock.withLock { pending[d.id] = d }
    }

    /// `d` was registered, or its import failed.
    func forget(_ id: String) {
        _ = lock.withLock { pending.removeValue(forKey: id) }
    }

    /// The VM stopped: its devices are gone. Loop-mounted disks were only
    /// flushed to the Mac's cache by virtiofs, so flush them to the SSD.
    func reset() {
        let loops = lock.withLock { () -> [String] in
            defer { boot = [:]; mounted = [:]; planned = [:] }
            return mounted.values.compactMap { if case .loop(let p) = $0 { p } else { nil } }
        }
        loops.forEach(Self.fullSync)
    }

    func isAttached(_ id: String) -> Bool {
        lock.withLock { mounted[id] != nil }
    }

    func transport(of id: String) -> Transport? {
        lock.withLock { mounted[id] }
    }

    // MARK: mount

    /// Make sure `d`'s disk is mounted in the VM (no-op for a distro on data.img).
    /// Returns what the guest repaired or grew first, if anything.
    @discardableResult
    func ensureAttached(_ d: DistroRecord, notify: Bool = true) throws -> String {
        guard let disk = d.disk else { return "" }
        if isAttached(d.id) { return "" }
        if lock.withLock({ bootDevice(d.id, path: disk.path) }) == nil, canRestartVM() {
            log("disk of \(d.name) isn't attached to the VM: restarting the idle VM to attach it at boot")
            lock.withLock { pending[d.id] = d }
            try restartVM()
        }
        var mountedNow = false
        defer { if mountedNow && notify { changed() } }
        return try lock.withLock {
            if mounted[d.id] != nil { return "" }
            guard vm.isRunning else {
                throw ServiceError("The virtual machine isn't running.", code: ErrorCode.vm)
            }
            let transport: Transport = bootDevice(d.id, path: disk.path).map { .boot(serial: $0) } ?? .loop(path: disk.path)
            let size = Self.fileInfo(disk.path)?.size ?? 0
            let reply: Msl_V1_AttachDiskReply
            do {
                let mini = try guest.miniInit
                reply = try blocking {
                    try await mini.attachDisk(.with {
                        $0.id = d.id
                        switch transport {
                        case .boot(let serial): $0.serial = serial
                        case .loop(let path): $0.macPath = path
                        }
                        $0.uuid = disk.uuid
                        $0.sizeBytes = size
                    })
                }
            } catch {
                throw ServiceError("Failed to attach the disk of '\(d.name)'.\n\(Self.describe(error))", code: ErrorCode.service)
            }
            if !reply.repaired.isEmpty { log("disk of \(d.name): \(reply.repaired)") }
            if case .loop = transport {
                log("disk of \(d.name) mounted through \(reply.device) over the Mac share until the VM restarts (slower, and flushed to the SSD only when it's detached)")
            }
            mounted[d.id] = transport
            pending[d.id] = nil
            mountedNow = true
            return reply.repaired
        }
    }

    /// Stop `d` and unmount its disk, flushed to the Mac's SSD.
    func detach(_ d: DistroRecord) throws {
        let was = isAttached(d.id)
        defer { if was { changed() } }
        try lock.withLock {
            guard let transport = mounted[d.id] else { return }
            beforeDetach(d.id)
            do {
                let mini = try guest.miniInit
                _ = try blocking { try await mini.detachDisk(.with { $0.id = d.id }) }
            } catch {
                throw ServiceError("Failed to detach the disk of '\(d.name)'.\n\(Self.describe(error))", code: ErrorCode.service)
            }
            mounted[d.id] = nil
            // A boot disk's flushes were F_FULLFSYNC already; virtiofs' weren't.
            if case .loop(let path) = transport { Self.fullSync(path) }
        }
    }

    /// The boot device holding `path` for distro `id`, if it's still that file.
    private func bootDevice(_ id: String, path: String) -> String? {
        guard let b = boot[id], let st = Self.fileInfo(path), st.device == b.device, st.inode == b.inode, st.size == b.size else { return nil }
        return b.serial
    }

    private static func fileInfo(_ path: String) -> (device: UInt64, inode: UInt64, size: UInt64)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return (UInt64(bitPattern: Int64(st.st_dev)), UInt64(st.st_ino), UInt64(st.st_size))
    }

    /// F_FULLFSYNC: the file's data, and everything cached before it, reaches the SSD.
    static func fullSync(_ path: String) {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { log("flush \(path): \(String(cString: strerror(errno)))"); return }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) != 0 { log("flush \(path): \(String(cString: strerror(errno)))") }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? ServiceError { return e.message }
        if let e = error as? RPCError { return e.message }
        return "\(error)"
    }
}
