// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Microsoft's WSL distribution manifest (`distributions/DistributionInfo.json`).
/// msl installs the same `.wsl` images, using the entries' Arm64Url.
public struct Manifest: Decodable, Sendable {
    public struct Download: Decodable, Sendable, Equatable {
        public var Url: String
        public var Sha256: String
    }

    public struct Entry: Decodable, Sendable, Equatable {
        public var Name: String
        public var FriendlyName: String
        public var Default: Bool?
        public var Amd64Url: Download?
        public var Arm64Url: Download?
    }

    public var ModernDistributions: [String: [Entry]]
    public var Default: String?
    /// Flavor order as it appears in the file (JSON objects are unordered once decoded).
    public var flavorOrder: [String] = []

    enum CodingKeys: String, CodingKey { case ModernDistributions, Default }

    public static let defaultURL = "https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json"

    public static var url: URL {
        URL(string: ProcessInfo.processInfo.environment["MSL_DISTRIBUTION_LIST_URL"] ?? defaultURL)!
    }

    public static func parse(_ data: Data) throws -> Manifest {
        var m = try JSONDecoder().decode(Manifest.self, from: data)
        // Recover the flavor order from the raw text.
        let text = String(decoding: data, as: UTF8.self)
        m.flavorOrder = m.ModernDistributions.keys.sorted {
            (text.range(of: "\"\($0)\"")?.lowerBound ?? text.endIndex) < (text.range(of: "\"\($1)\"")?.lowerBound ?? text.endIndex)
        }
        return m
    }

    /// Entries installable on this Mac, in manifest order: arm64 images, plus
    /// x86_64-only images when Rosetta can run them.
    public func installable(rosetta: Bool) -> [Entry] {
        flavorOrder.flatMap { ModernDistributions[$0] ?? [] }.filter { $0.Arm64Url != nil || (rosetta && $0.Amd64Url != nil) }
    }

    public var installable: [Entry] { installable(rosetta: false) }

    /// x86_64-only distributions are deferred (Nitrogen, #40): hidden from
    /// `--list --online` and refused by `--install`. `--from-file` still works.
    public static let x86Supported = false

    /// Whether x86_64-only entries can be offered on this Mac.
    public static func x86Available(rosetta: Bool, supported: Bool = x86Supported) -> Bool {
        supported && rosetta
    }

    /// Why `--install` can't install `entry` on this Mac, or nil if it can.
    public static func installRefusal(_ entry: Entry, rosetta: Bool, supported: Bool = x86Supported) -> String? {
        if entry.Arm64Url != nil { return nil }
        guard entry.Amd64Url != nil else { return "'\(entry.Name)' has no image for this Mac." }
        guard supported else { return "'\(entry.Name)' is only available for x86_64, which msl doesn't support yet." }
        guard rosetta else {
            return "'\(entry.Name)' is only available for x86_64, which needs Rosetta. Install it with: softwareupdate --install-rosetta"
        }
        return nil
    }

    /// WSL's resolution: a flavor name picks that flavor's default entry;
    /// otherwise an exact (case-insensitive) entry name.
    public func resolve(_ name: String?) -> Entry? {
        let wanted = name ?? Default ?? "Ubuntu"
        if let flavor = ModernDistributions.first(where: { $0.key.caseInsensitiveCompare(wanted) == .orderedSame })?.value {
            return flavor.first(where: { $0.Default == true }) ?? flavor.first
        }
        return ModernDistributions.values.joined().first { $0.Name.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// `msl --list --online` text. x86_64-only entries (run through Rosetta) are marked.
    public func onlineListing(rosetta: Bool = false) -> String {
        let rows = installable(rosetta: rosetta)
        let width = max(rows.map(\.Name.count).max() ?? 0, 4) + 4
        var lines = [
            "The following is a list of valid distributions that can be installed.",
            "Install using '\(Messages.exe) --install <Distro>'.",
            "",
            "NAME".padding(toLength: width, withPad: " ", startingAt: 0) + "FRIENDLY NAME",
        ]
        for e in rows {
            let note = e.Arm64Url == nil ? " (x86_64, runs with Rosetta)" : ""
            lines.append(e.Name.padding(toLength: width, withPad: " ", startingAt: 0) + e.FriendlyName + note)
        }
        return lines.joined(separator: "\n")
    }
}
