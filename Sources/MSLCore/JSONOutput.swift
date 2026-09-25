// SPDX-License-Identifier: Apache-2.0
import Foundation

/// `--json` output of the query commands (`--list`, `--list --online`,
/// `--status`, `--version`). Conventions (docs/json.md):
/// - one object on stdout with `"schema": 1`; bumped only for breaking changes,
///   new fields may appear at any time;
/// - camelCase fields; unknown values are omitted, never `null`;
/// - sizes in bytes, times in milliseconds;
/// - errors as `{"schema": 1, "error": {"message", "code"}}` on stderr, with
///   the same exit code as the text output (wsl.exe's).
public enum JSONOutput {
    public static let schema = 1

    public struct Distribution: Codable, Equatable, Sendable {
        public var name: String
        public var id: String
        public var state: String  // "Running" | "Stopped", as in `-l -v`
        public var version: Int
        public var `default`: Bool
    }

    public struct List: Codable, Equatable, Sendable {
        public var schema = JSONOutput.schema
        public var distributions: [Distribution]
    }

    public struct OnlineDistribution: Codable, Equatable, Sendable {
        public var name: String
        public var friendlyName: String
        public var architectures: [String]  // "arm64", "x86_64"
        /// Runs through Rosetta (x86_64-only image).
        public var emulated: Bool
        public var `default`: Bool
    }

    public struct OnlineList: Codable, Equatable, Sendable {
        public var schema = JSONOutput.schema
        public var distributions: [OnlineDistribution]
    }

    public struct Change: Codable, Equatable, Sendable {
        public var setting: String
        public var from: String
        public var to: String
    }

    public struct VM: Codable, Equatable, Sendable {
        public var running: Bool
        public var uptimeMs: Int?
        /// What the VM runs with now, or will start with when stopped.
        public var settings: VMSettings
        /// `.mslconfig` changes that apply after `msl --shutdown`.
        public var pendingChanges: [Change]
        public var settingsFile: String
        public var settingsFileExists: Bool
    }

    public struct Status: Codable, Equatable, Sendable {
        public var schema = JSONOutput.schema
        public var defaultDistribution: String
        public var defaultVersion = 2
        public var vm: VM
        /// `.mslconfig` warnings (printed to stderr in text mode).
        public var warnings: [String]
    }

    public struct Version: Codable, Equatable, Sendable {
        public var schema = JSONOutput.schema
        /// Plain x.y.z, comparable; the text output adds "+<commit>".
        public var msl: String
        /// Short git hash of the build (".dirty" with uncommitted changes); absent for a plain `swift build`.
        public var commit: String?
        public var kernel: String
        public var macOS: String
        /// Install prefix, when msl runs from an installed copy (not a development build).
        public var prefix: String?
        public init(msl: String, commit: String? = nil, kernel: String, macOS: String, prefix: String?) {
            self.msl = msl; self.commit = commit; self.kernel = kernel; self.macOS = macOS; self.prefix = prefix
        }
    }

    public struct Failure: Codable, Equatable, Sendable {
        public struct Body: Codable, Equatable, Sendable {
            public var message: String
            public var code: String
            public init(message: String, code: String) { self.message = message; self.code = code }
        }
        public var schema = JSONOutput.schema
        public var error: Body
        public init(error: Body) { self.error = error }
    }

    // MARK: - builders

    /// `--list [--all|--running|--quiet|--verbose] --json`. Returns nil when
    /// nothing is installed: that is an error, as in wsl.exe.
    public static func list(_ distros: [DistroSummary], _ spec: ListSpec) -> List? {
        if distros.isEmpty { return nil }
        let rows = spec.running ? distros.filter(\.running) : distros
        return List(distributions: rows.map {
            Distribution(name: $0.name, id: $0.id, state: $0.running ? "Running" : "Stopped", version: $0.version, default: $0.isDefault)
        })
    }

    public static func online(_ manifest: Manifest, rosetta: Bool) -> OnlineList {
        let def = manifest.resolve(nil)?.Name
        return OnlineList(distributions: manifest.installable(rosetta: rosetta).map { e in
            var arch: [String] = []
            if e.Arm64Url != nil { arch.append("arm64") }
            if e.Amd64Url != nil { arch.append("x86_64") }
            return OnlineDistribution(name: e.Name, friendlyName: e.FriendlyName, architectures: arch,
                                      emulated: e.Arm64Url == nil, default: e.Name == def)
        })
    }

    public static func status(defaultDistro: String, _ s: VMStatus, warnings: [String]) -> Status {
        let changes = s.effective.map { changesBetween($0, s.configured) } ?? []
        return Status(defaultDistribution: defaultDistro,
                      vm: VM(running: s.running,
                             uptimeMs: s.uptimeSeconds.map { Int($0 * 1000) },
                             settings: s.effective ?? s.configured,
                             pendingChanges: changes,
                             settingsFile: s.configPath,
                             settingsFileExists: s.configExists),
                      warnings: warnings)
    }

    /// Field-by-field differences, with raw values (not display strings).
    public static func changesBetween(_ a: VMSettings, _ b: VMSettings) -> [Change] {
        func fields(_ v: VMSettings) -> [String: String] {
            ["memoryBytes": "\(v.memoryBytes)", "processors": "\(v.processors)", "kernel": v.kernel,
             "kernelCommandLine": v.kernelCommandLine, "localhostForwarding": "\(v.localhostForwarding)",
             "dnsTunneling": "\(v.dnsTunneling)", "vmIdleTimeoutMs": "\(v.vmIdleTimeoutMs)",
             "instanceIdleTimeoutMs": "\(v.instanceIdleTimeoutMs)"]
        }
        let x = fields(a), y = fields(b)
        return x.keys.sorted().compactMap { k in
            x[k] == y[k] ? nil : Change(setting: k, from: x[k] ?? "", to: y[k] ?? "")
        }
    }

    // MARK: - encoding

    /// Pretty-printed for a terminal, one compact line otherwise; always ends in a newline.
    public static func encode<T: Encodable>(_ value: T, pretty: Bool) -> String {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? e.encode(value)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
