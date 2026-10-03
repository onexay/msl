// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Sizing rules for data.img, the sparse ext4 disk every distro shares.
/// The size is its apparent (maximum) size; the Mac only stores what's written.
public enum DataDisk {
    public static let defaultMax: UInt64 = 256 << 30
    public static let minimum: UInt64 = 4 << 30

    /// Size of a new data.img: `[msl2] defaultVhdSize` if set, else 256 GiB,
    /// but never more than the Mac volume holds, so distros aren't promised
    /// space the Mac doesn't have.
    public static func initialSize(configured: UInt64?, volumeCapacity: UInt64?) -> UInt64 {
        var size = configured ?? defaultMax
        if configured == nil, let cap = volumeCapacity { size = min(size, cap) }
        size = max(size, minimum)
        return size & ~((1 << 20) - 1)  // whole MiB
    }

    public enum GrowCheck: Equatable {
        case unchanged
        case grow(UInt64)
        case refused(String)
    }

    /// `msl --manage <distro> --resize <size>`: grow only, up to the Mac volume's capacity.
    public static func checkGrow(current: UInt64, requested: String, volumeCapacity: UInt64?) -> GrowCheck {
        guard let want = MSLConfig.parseSize(requested), want > 0 else {
            return .refused("Invalid size: \(requested). Use a number with KB, MB, GB or TB, e.g. 512GB.")
        }
        let size = want & ~((1 << 20) - 1)
        if size == current { return .unchanged }
        if size < current {
            return .refused("The disk can only grow. It's \(StatusFormat.bytes(current)) now, and shrinking an ext4 filesystem in place isn't safe.")
        }
        if let cap = volumeCapacity, size > cap {
            return .refused("\(StatusFormat.bytes(size)) is more than the macOS disk holds (\(StatusFormat.bytes(cap))).")
        }
        return .grow(size)
    }
}
