// SPDX-License-Identifier: Apache-2.0
import ContainerizationEXT4
import Foundation
import MSLCore
import SystemPackage

/// Creating a distro's own disk (#50): a sparse ext4 image.
enum DiskImage {
    /// Format a new sparse ext4 image of about `size` bytes at `url` and
    /// return its UUID (the formatter picks one; it can't be set).
    static func create(at url: URL, size: UInt64) throws -> DistroDiskInfo {
        let fmt = try EXT4.Formatter(FilePath(url.path), minDiskSize: size, journal: .init(defaultMode: .ordered))
        try fmt.close()
        return DistroDiskInfo(path: url.path, uuid: try DistroDisk.readSuperblock(url).uuid)
    }

    /// Apparent (maximum) and allocated size of an image.
    static func sizes(_ url: URL) -> (max: UInt64, used: UInt64)? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]),
              let size = v.fileSize else { return nil }
        return (UInt64(size), UInt64(v.totalFileAllocatedSize ?? 0))
    }
}
