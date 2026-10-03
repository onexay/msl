// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Build identity. `scripts/package.sh` stamps the release version and update
/// channel; `scripts/build.sh` stamps the commit for JSON diagnostics.
public enum MSLBuild {
    public static let version = "0.3.0"
    /// Short git hash of the build (".dirty" with uncommitted changes); empty for a plain `swift build`.
    public static let commit = ""
    /// What `msl --version` shows. Commit identity remains available in JSON output.
    public static var displayVersion: String { version }
    /// Release manifest URL for `msl --update` (empty for local builds; MSL_UPDATE_URL overrides).
    public static let updateURL = ""
    /// The oldest macOS msl runs on: Package.swift's platform, and what install.sh checks.
    public static let minimumMacOS = 27

    /// Why msl can't run on this macOS, or nil. dyld starts a command-line binary
    /// built for a newer macOS anyway, so msl and msld check for themselves.
    public static func unsupportedMacOS(_ v: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String? {
        v.majorVersion >= minimumMacOS ? nil : "msl needs macOS \(minimumMacOS) or later (this is macOS \(v.majorVersion).\(v.minorVersion))."
    }
}

/// Dotted version comparison ("0.10.0" > "0.9.3").
public func versionIsNewer(_ a: String, than b: String) -> Bool {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}
