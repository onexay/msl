// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import GRPCCore
import MSLCore
import MSLProtocol

/// WSL's disk operations on a distro's own disk (#50): --manage --move and
/// --resize, --export --vhd, --import --vhd and --import-in-place. msl's disk
/// images are raw ext4 (not VHDX), with the distro's root at the filesystem
/// root as in WSL's ext4.vhdx.
extension Service {
    /// `--manage <distro> --move <folder>`: its ext4.img moves into `folder`. A
    /// distro still on the shared data.img is copied onto a new disk there.
    func move(_ d: DistroRecord, to folder: URL) throws {
        guard let disk = d.disk else {
            try migrate(d, to: folder)
            return
        }
        let src = URL(fileURLWithPath: disk.path).standardizedFileURL
        let dest = folder.appendingPathComponent(DistroDisk.fileName)
        if src.path == dest.path { return }
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw ServiceError("Failed to move distribution.\n\(dest.path) already exists.", code: ErrorCode.alreadyExists)
        }
        if vm.isRunning { try ownDisks.detach(d) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.moveImage(src, dest)
        } catch {
            throw ServiceError("Failed to move distribution.\n\(error.localizedDescription)", code: ErrorCode.service)
        }
        try registry.update(id: d.id) {
            $0.location = folder.path
            $0.disk?.path = dest.path
        }
        let old = URL(fileURLWithPath: d.location)
        if old.path != folder.path, (try? FileManager.default.contentsOfDirectory(atPath: old.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: old)
        }
        log("moved \(d.name): \(src.path) → \(dest.path)")
        if vm.isRunning, let rec = registry.find(id: d.id) { try? ownDisks.ensureAttached(rec) }
    }

    /// A distro on data.img moves onto its own new disk: the guest copies its files over.
    private func migrate(_ d: DistroRecord, to folder: URL) throws {
        var rec = d
        rec.location = folder.path
        rec.disk = try createDisk(in: folder, vhdSize: nil)
        ownDisks.prepare(rec)  // attached at boot if the VM isn't running yet
        var done = false
        defer {
            ownDisks.forget(rec.id)
            if !done {
                try? ownDisks.detach(rec)
                if let disk = rec.disk { removeDisk(disk, location: folder.path) }
            }
        }
        try bootVM()
        files.unmount(name: d.name)
        try ownDisks.ensureAttached(rec)
        let mini = try guest.miniInit
        let reply: Msl_V1_MigrateDistroReply
        do {
            reply = try blocking { try await mini.migrateDistro(.with { $0.id = d.id }) }
        } catch let e as RPCError {
            throw ServiceError("Failed to move distribution.\n\(e.message)", code: ErrorCode.service)
        }
        let disk = rec.disk
        try registry.update(id: d.id) {
            $0.location = folder.path
            $0.disk = disk
        }
        done = true
        files.syncLinks()
        log("moved \(d.name) from data.img onto \(disk?.path ?? ""): \(reply.entries) entries")
    }

    /// `--manage <distro> --resize <size>` for a distro on its own disk: the
    /// image grows while the distro is stopped; the guest grows the filesystem
    /// (offline) when it mounts the disk again. The disk attached at boot keeps
    /// its old size, so it comes back at the next boot, or at once if the VM
    /// can restart (DistroDisks).
    func resizeDisk(_ d: DistroRecord, _ requested: String) throws {
        guard let disk = d.disk else { return }
        let url = URL(fileURLWithPath: disk.path)
        let current = DiskImage.sizes(url)?.max ?? 0
        switch DistroDisk.checkGrow(current: current, requested: requested, volumeCapacity: VMHost.volumeCapacity(url.deletingLastPathComponent())) {
        case .unchanged:
            return
        case .refused(let why):
            throw ServiceError("Failed to resize disk.\n\(why)", code: ErrorCode.invalidArgument)
        case .grow(let size):
            try bootVM()
            if runningIds().contains(d.id) {
                throw ServiceError("Failed to resize disk.\nThe distribution is running. Stop it first with 'msl --terminate \(d.name)'.", code: ErrorCode.invalidArgument)
            }
            try ownDisks.detach(d)
            let fh = try FileHandle(forWritingTo: url)
            try fh.truncate(atOffset: size)  // sparse: nothing is written
            try fh.close()
            log("disk of \(d.name): \(StatusFormat.bytes(current)) → \(StatusFormat.bytes(size)); growing at attach")
            let result = try ownDisks.ensureAttached(d)
            guard result.contains("grew") else {
                throw ServiceError("Failed to resize disk.\nThe file is now \(StatusFormat.bytes(size)), but the filesystem wasn't grown: \(result.isEmpty ? "no result from the VM" : result)", code: ErrorCode.service)
            }
        }
    }

    /// `--export <distro> <file> --vhd`: a copy of its disk image (a clone on APFS).
    func exportDisk(_ d: DistroRecord, to dest: URL) throws {
        guard let disk = d.disk else {
            throw ServiceError("Failed to export distribution.\n'\(d.name)' is on the shared disk, so it has no disk image of its own.\nMove it to its own disk first: msl --manage \(d.name) --move <folder>", code: ErrorCode.unsupported)
        }
        let src = URL(fileURLWithPath: disk.path).standardizedFileURL
        guard src.path != dest.standardizedFileURL.path else {
            throw ServiceError("Failed to export distribution.\n\(dest.path) is the distribution's own disk.", code: ErrorCode.invalidArgument)
        }
        if vm.isRunning { try ownDisks.detach(d) }  // stopped, unmounted and flushed: a consistent image
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try Self.copyImage(src, dest)
        } catch {
            throw ServiceError("Failed to export distribution.\n\(error.localizedDescription)", code: ErrorCode.service)
        }
        log("exported the disk of \(d.name) to \(dest.path)")
    }

    /// `--import <distro> <folder> <image> --vhd` (copied into `<folder>/ext4.img`)
    /// and `--import-in-place <distro> <image>` (`copyTo` nil: used where it is).
    func importImage(name: String, image: URL, copyTo folder: URL?) throws -> DistroRecord {
        guard FileManager.default.fileExists(atPath: image.path) else {
            throw ServiceError("Failed to import distribution.\n\(image.path): No such file or directory", code: ErrorCode.fileNotFound)
        }
        let sb: DistroDisk.Superblock
        let fileSize: UInt64
        do {
            sb = try DistroDisk.readSuperblock(image)
            fileSize = DiskImage.sizes(image)?.max ?? 0
        } catch {
            throw ServiceError("Failed to import distribution.\n\(image.path) is not an ext4 disk image. msl imports raw ext4 images; convert a VHDX first, e.g. with qemu-img convert -O raw.", code: ErrorCode.importFailed)
        }
        guard sb.size <= fileSize else {
            throw ServiceError("Failed to import distribution.\n\(image.path) is smaller than the filesystem it holds (\(StatusFormat.bytes(fileSize)) < \(StatusFormat.bytes(sb.size))).", code: ErrorCode.importFailed)
        }
        if registry.all.contains(where: { $0.disk.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path } == image.standardizedFileURL.path }) {
            throw ServiceError("Failed to import distribution.\n\(image.path) is already a distribution's disk.", code: ErrorCode.alreadyExists)
        }
        let id = UUID().uuidString.lowercased()
        var path = image.path
        var created = false
        if let folder {
            let dest = folder.appendingPathComponent(DistroDisk.fileName)
            guard !FileManager.default.fileExists(atPath: dest.path) else {
                throw ServiceError("Failed to import distribution.\n\(dest.path) already exists.", code: ErrorCode.alreadyExists)
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Self.copyImage(image, dest)
            } catch {
                throw ServiceError("Failed to import distribution.\n\(error.localizedDescription)", code: ErrorCode.importFailed)
            }
            path = dest.path
            created = true
        }
        var rec = DistroRecord(id: id, name: name, location: folder?.path ?? image.deletingLastPathComponent().path)
        rec.disk = DistroDiskInfo(path: path, uuid: sb.uuid)
        var registered = false
        ownDisks.prepare(rec)  // attached at boot if the VM isn't running yet
        defer {
            ownDisks.forget(rec.id)
            if !registered {
                try? ownDisks.detach(rec)
                if created, let disk = rec.disk { removeDisk(disk, location: rec.location) }
            }
        }
        try bootVM()
        try ownDisks.ensureAttached(rec)
        let mini = try guest.miniInit
        let conf: Msl_V1_DistributionConf
        do {
            conf = try blocking { try await mini.distroConf(.with { $0.id = id }) }
        } catch let e as RPCError {
            throw ServiceError("Failed to import distribution.\n\(e.message)", code: ErrorCode.importFailed)
        }
        try register(&rec, name: name, conf: conf)
        registered = true
        log("imported \(name) (\(id)) from the disk image \(path)")
        return rec
    }

    // MARK: files

    /// Copy a sparse disk image: an APFS clone when possible, else a sparse copy.
    static func copyImage(_ src: URL, _ dest: URL) throws {
        let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_DATA_SPARSE | COPYFILE_EXCL)
        guard copyfile(src.path, dest.path, nil, flags) == 0 else {
            let e = errno
            try? FileManager.default.removeItem(at: dest)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO, userInfo: [NSLocalizedDescriptionKey: "Copying \(src.path) to \(dest.path): \(String(cString: strerror(e)))"])
        }
    }

    /// A rename on the same volume; across volumes a sparse copy, then the original is removed.
    static func moveImage(_ src: URL, _ dest: URL) throws {
        if rename(src.path, dest.path) == 0 { return }
        guard errno == EXDEV else {
            let e = errno
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO, userInfo: [NSLocalizedDescriptionKey: "Moving \(src.path) to \(dest.path): \(String(cString: strerror(e)))"])
        }
        try copyImage(src, dest)
        try FileManager.default.removeItem(at: src)
    }
}
