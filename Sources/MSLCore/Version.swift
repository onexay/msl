// SPDX-License-Identifier: Apache-2.0
/// Build identity. `scripts/package.sh` stamps the release version and update
/// channel; `scripts/build.sh` stamps the commit.
public enum MSLBuild {
    public static let version = "0.1.7"
    /// Short git hash of the build (".dirty" with uncommitted changes); empty for a plain `swift build`.
    public static let commit = ""
    /// What `msl --version` shows: semver build metadata, e.g. "0.1.7+3af5916".
    /// Update checks compare `version` only.
    public static var displayVersion: String { commit.isEmpty ? version : "\(version)+\(commit)" }
    /// Release manifest URL for `msl --update` (empty for local builds; MSL_UPDATE_URL overrides).
    public static let updateURL = ""
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
