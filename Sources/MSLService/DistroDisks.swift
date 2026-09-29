// SPDX-License-Identifier: Apache-2.0
import Foundation
import GRPCCore
import MSLCore
import MSLProtocol

/// Which distro's own disk (#50) is bound to which NBD slot while the VM runs.
///
/// Every disk-backed distro is attached when the VM boots (up to the number of
/// slots), so the Finder view shows it; others are attached when needed. With
/// every slot taken, the least recently used distro that isn't running gives
/// its slot up. One lock serializes attaching and detaching.
final class DistroDisks: @unchecked Sendable {
    private let vm: VMHost
    private let guest: GuestClients
    private let runningIds: () -> [String]
    private let lock = NSLock()
    private var slots: [String: Int] = [:]      // distro id -> slot
    private var lastUse: [String: Date] = [:]

    init(vm: VMHost, guest: GuestClients, runningIds: @escaping () -> [String]) {
        self.vm = vm
        self.guest = guest
        self.runningIds = runningIds
    }

    /// The VM stopped: every slot is gone (the server flushed them).
    func reset() {
        lock.withLock { slots.removeAll(); lastUse.removeAll() }
    }

    func slot(of id: String) -> Int? {
        lock.withLock { slots[id] }
    }

    /// At boot: attach every disk-backed distro there's a slot for. A distro
    /// whose disk can't be attached is logged; using it reports the error.
    func attachAll(_ distros: [DistroRecord]) {
        let count = vm.diskSlots?.slotCount ?? 0
        for d in distros.filter({ $0.disk != nil }).prefix(count) {
            do { try ensureAttached(d) } catch { log("disk of \(d.name): \(Self.describe(error))") }
        }
    }

    /// Make sure `d`'s disk is mounted in the VM (no-op for a distro on data.img).
    func ensureAttached(_ d: DistroRecord) throws {
        guard let disk = d.disk else { return }
        try lock.withLock {
            if slots[d.id] != nil {
                lastUse[d.id] = Date()
                return
            }
            guard let server = vm.diskSlots else {
                throw ServiceError("The virtual machine isn't running.", code: ErrorCode.vm)
            }
            let slot = try freeSlot(server)
            let fd = open(disk.path, O_RDWR | O_CLOEXEC)
            guard fd >= 0 else {
                throw ServiceError("Failed to attach the disk of '\(d.name)'.\n\(disk.path): \(String(cString: strerror(errno)))", code: ErrorCode.fileNotFound)
            }
            let size = UInt64(lseek(fd, 0, SEEK_END))
            try server.bind(slot: slot, fd: fd)
            do {
                let mini = try guest.miniInit
                let reply = try blocking {
                    try await mini.attachDisk(.with {
                        $0.id = d.id
                        $0.serial = NBDServer.exportName(slot)
                        $0.uuid = disk.uuid
                        $0.sizeBytes = size
                    })
                }
                if !reply.repaired.isEmpty { log("disk of \(d.name): \(reply.repaired)") }
            } catch {
                server.unbind(slot: slot)
                throw ServiceError("Failed to attach the disk of '\(d.name)'.\n\(Self.describe(error))", code: ErrorCode.service)
            }
            slots[d.id] = slot
            lastUse[d.id] = Date()
        }
    }

    /// Stop `d` and release its disk: unmounted in the VM, flushed to the Mac.
    func detach(_ d: DistroRecord) throws {
        try lock.withLock { try detachLocked(id: d.id, name: d.name) }
    }

    private func detachLocked(id: String, name: String) throws {
        guard let slot = slots[id] else { return }
        do {
            let mini = try guest.miniInit
            _ = try blocking { try await mini.detachDisk(.with { $0.id = id }) }
        } catch {
            // Still mounted in the VM: keep serving it.
            throw ServiceError("Failed to detach the disk of '\(name)'.\n\(Self.describe(error))", code: ErrorCode.service)
        }
        vm.diskSlots?.unbind(slot: slot)
        slots[id] = nil
        lastUse[id] = nil
    }

    /// A free slot, or the slot of the least recently used distro that isn't running.
    private func freeSlot(_ server: NBDServer) throws -> Int {
        let used = Set(slots.values)
        if let free = (0..<server.slotCount).first(where: { !used.contains($0) && !server.isBound($0) }) {
            return free
        }
        let running = Set(runningIds())
        guard let victim = slots.keys.filter({ !running.contains($0) }).min(by: { (lastUse[$0] ?? .distantPast) < (lastUse[$1] ?? .distantPast) }),
              let slot = slots[victim] else {
            throw ServiceError("All \(server.slotCount) disk slots are in use by running distributions.\nStop one with 'msl --terminate <Distro>' and try again.", code: ErrorCode.service)
        }
        log("disk slots full: detaching \(victim)")
        try detachLocked(id: victim, name: victim)
        return slot
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? ServiceError { return e.message }
        if let e = error as? RPCError { return e.message }
        return "\(error)"
    }
}
