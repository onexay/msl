// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A distro's own disk (#50): a sparse ext4 image, `ext4.img` in the distro's
/// location folder (WSL's ext4.vhdx), attached through an NBD slot (NBDServer).
public enum DistroDisk {
    public static let fileName = "ext4.img"
    /// What each slot advertises. A slot's size can't change while the VM runs,
    /// so every slot is as large as any disk may grow.
    public static let slotSize: UInt64 = 4 << 40
    public static let defaultSlots = 16

    /// Slots in the VM: 16, or `MSL_DISK_SLOTS` (1-32, for tests).
    public static func slotCount(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        guard let v = env["MSL_DISK_SLOTS"].flatMap(Int.init), (1...32).contains(v) else { return defaultSlots }
        return v
    }

    /// Size of a new disk: `--vhd-size` if given, else `[msl2] defaultVhdSize`,
    /// else 256 GiB capped at the Mac volume (DataDisk's rules), never more than a slot.
    public static func initialSize(requested: UInt64?, configured: UInt64?, volumeCapacity: UInt64?) -> UInt64 {
        let size = DataDisk.initialSize(configured: requested ?? configured, volumeCapacity: volumeCapacity)
        return min(size, slotSize)
    }

    /// `msl --manage <distro> --resize <size>`: grow only, up to the Mac volume and the slot size.
    public static func checkGrow(current: UInt64, requested: String, volumeCapacity: UInt64?) -> DataDisk.GrowCheck {
        let check = DataDisk.checkGrow(current: current, requested: requested, volumeCapacity: volumeCapacity)
        if case .grow(let size) = check, size > slotSize {
            return .refused("A distribution's disk can be at most \(StatusFormat.bytes(slotSize)).")
        }
        return check
    }

    /// The ext4 superblock fields msld needs (the guest checks the same ones).
    public struct Superblock: Equatable, Sendable {
        public var size: UInt64    // filesystem size in bytes
        public var uuid: String    // lowercase, hyphenated
        public var clean: Bool     // EXT4_VALID_FS
    }

    /// Parse the 1024 bytes at offset 1024 of an ext4 image; nil if it isn't one.
    public static func parseSuperblock(_ sb: [UInt8]) -> Superblock? {
        guard sb.count >= 1024, sb[0x38] == 0x53, sb[0x39] == 0xEF else { return nil }
        func u32(_ o: Int) -> UInt64 { UInt64(sb[o]) | UInt64(sb[o + 1]) << 8 | UInt64(sb[o + 2]) << 16 | UInt64(sb[o + 3]) << 24 }
        let hi = u32(0x60) & 0x80 != 0 ? u32(0x150) : 0  // INCOMPAT_64BIT
        let logBlock = u32(0x18)
        guard logBlock <= 6 else { return nil }
        let hex = sb[0x68..<0x78].map { String(format: "%02x", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { r in
            String(hex[hex.index(hex.startIndex, offsetBy: r.lowerBound)..<hex.index(hex.startIndex, offsetBy: r.upperBound)])
        }
        return Superblock(size: ((hi << 32) | u32(0x04)) << (10 + logBlock),
                          uuid: parts.joined(separator: "-"),
                          clean: sb[0x3A] & 1 != 0)
    }

    /// The superblock of the ext4 image at `url`.
    public static func readSuperblock(_ url: URL) throws -> Superblock {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: 1024)
        guard let sb = parseSuperblock(Array(try h.read(upToCount: 1024) ?? Data())) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path,
                                                               NSLocalizedDescriptionKey: "\(url.path) is not an ext4 disk image."])
        }
        return sb
    }
}

/// Where a distro on its own disk keeps it (DistroRecord.disk).
public struct DistroDiskInfo: Codable, Equatable, Sendable {
    /// The image, normally `<location>/ext4.img`; for `--import-in-place`, wherever it was.
    public var path: String
    /// Its ext4 UUID: the guest mounts it only if the slot holds this filesystem.
    public var uuid: String

    public init(path: String, uuid: String) {
        self.path = path
        self.uuid = uuid
    }
}
