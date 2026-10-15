// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Finds the Linux kernel's panic banner in a console stream that arrives in
/// arbitrary chunks. It's the host's only sign of a guest panic: the guest
/// doesn't stop by itself (its vCPUs spin), and Virtualization.framework has
/// no panic callback.
public struct PanicScanner {
    static let banner = Data("Kernel panic - not syncing".utf8)
    /// Longest banner line kept while waiting for its newline.
    static let maxLine = 4096

    private var pending = Data()

    public init() {}

    /// The banner's line once `chunk` completes one, else nil.
    public mutating func feed(_ chunk: Data) -> String? {
        pending.append(chunk)
        guard let at = pending.range(of: Self.banner) else {
            // A banner may straddle two chunks: keep what could start one.
            pending = Data(pending.suffix(Self.banner.count - 1))
            return nil
        }
        let line = pending[at.lowerBound...]
        guard let end = line.firstIndex(of: 0x0A) else {
            pending = Data(line.prefix(Self.maxLine))
            return nil
        }
        pending = Data()
        return String(decoding: line[..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
