// SPDX-License-Identifier: Apache-2.0
// wsl.exe-compatible command line parsing.
//
// Mirrors `wsl.exe [Argument] [Options...] [CommandLine]`: a management
// argument must come first; otherwise the arguments are run options followed
// by the command line.

public enum ShellType: String, Codable, Sendable {
    case standard, login, none
}

public struct RunSpec: Codable, Equatable, Sendable {
    public var distribution: String?
    public var distributionId: String?
    public var user: String?
    /// Raw `--cd` value (`~` or an absolute Linux path), or `~` for `msl ~`.
    public var cd: String?
    public var shellType: ShellType = .standard
    /// Exec mode (`-e` / `--shell-type none`): the exact argv.
    public var argv: [String] = []
    /// Shell mode: the command line passed to `$SHELL -c`. nil = default shell.
    public var commandLine: String?

    public init() {}
}

public struct InstallSpec: Codable, Equatable, Sendable {
    public var distribution: String?
    public var fromFile: String?
    public var name: String?
    public var location: String?
    public var noLaunch = false
    public var version: Int?
    public init() {}
}

public enum ManageOp: Codable, Equatable, Sendable {
    case move(String)
    case setSparse(Bool)
    case setDefaultUser(String)
    case resize(String)
    case compact
}

public struct MountSpec: Codable, Equatable, Sendable {
    public var disk: String = ""
    public var vhd = false
    public var bare = false
    public var name: String?
    public var type: String?
    public var options: String?
    public var partition: Int?
    public init() {}
}

public struct ListSpec: Codable, Equatable, Sendable {
    public var all = false, running = false, quiet = false, verbose = false, online = false
    public init() {}
}

public enum CLICommand: Equatable, Sendable {
    case run(RunSpec)
    case help
    case version
    case status
    case list(ListSpec)
    case setDefault(String)
    case terminate(String)
    case shutdown(force: Bool)
    case unregister(String)
    case export(distribution: String, file: String, format: String?)
    case importTar(distribution: String, location: String, file: String, version: Int?, vhd: Bool)
    case install(InstallSpec)
    case setDefaultVersion(Int)
    case setVersion(distribution: String, version: Int)
    case manage(distribution: String, op: ManageOp)
    case debugShell
    case mount(MountSpec)
    case unmount(String?)
    case update(preRelease: Bool)
    case uninstall
    /// A valid wsl.exe argument that has no macOS equivalent.
    case unsupported(String)
    /// A valid wsl.exe argument planned for a later MSL milestone.
    case notImplemented(String)
}

public enum ArgumentError: Error, Equatable {
    case invalid(String)
    case missingValue(String)
}

public enum Arguments {
    public static func parse(_ args: [String]) throws -> CLICommand {
        guard let first = args.first else { return .run(RunSpec()) }
        var rest = Array(args.dropFirst())

        func value(_ option: String) throws -> String {
            guard !rest.isEmpty else { throw ArgumentError.missingValue(option) }
            return rest.removeFirst()
        }
        func noMore() throws {
            if let extra = rest.first { throw ArgumentError.invalid(extra) }
        }

        switch first {
        case "--help":
            return .help
        case "--version", "-v":
            try noMore()
            return .version
        case "--status":
            try noMore()
            return .status
        case "--list", "-l":
            var spec = ListSpec()
            for a in rest {
                switch a {
                case "--all": spec.all = true
                case "--running": spec.running = true
                case "--quiet", "-q": spec.quiet = true
                case "--verbose", "-v": spec.verbose = true
                case "--online", "-o": spec.online = true
                default: throw ArgumentError.invalid(a)
                }
            }
            return .list(spec)
        case "--set-default", "-s":
            let d = try value(first)
            try noMore()
            return .setDefault(d)
        case "--terminate", "-t":
            let d = try value(first)
            try noMore()
            return .terminate(d)
        case "--shutdown":
            var force = false
            for a in rest {
                guard a == "--force" else { throw ArgumentError.invalid(a) }
                force = true
            }
            return .shutdown(force: force)
        case "--unregister":
            let d = try value(first)
            try noMore()
            return .unregister(d)
        case "--export":
            let d = try value(first)
            let f = try value(first)
            var format: String?
            while let a = rest.first {
                rest.removeFirst()
                switch a {
                case "--format": format = try value(a)
                case "--vhd": format = "vhd"
                default: throw ArgumentError.invalid(a)
                }
            }
            return .export(distribution: d, file: f, format: format)
        case "--import":
            let d = try value(first)
            let loc = try value(first)
            let f = try value(first)
            var version: Int?
            var vhd = false
            while let a = rest.first {
                rest.removeFirst()
                switch a {
                case "--version": version = try int(value(a), a)
                case "--vhd": vhd = true
                default: throw ArgumentError.invalid(a)
                }
            }
            return .importTar(distribution: d, location: loc, file: f, version: version, vhd: vhd)
        case "--install":
            var spec = InstallSpec()
            while let a = rest.first {
                rest.removeFirst()
                switch a {
                case "--from-file": spec.fromFile = try value(a)
                case "--name": spec.name = try value(a)
                case "--location": spec.location = try value(a)
                case "--no-launch", "-n": spec.noLaunch = true
                case "--version": spec.version = try int(value(a), a)
                case "--distribution", "-d": spec.distribution = try value(a)
                case "--web-download", "--fixed-vhd", "--legacy", "--no-distribution": break  // no effect on macOS
                case "--vhd-size": _ = try value(a)
                case "--enable-wsl1", "--inbox": return .unsupported(a)
                default:
                    if a.hasPrefix("-") || spec.distribution != nil { throw ArgumentError.invalid(a) }
                    spec.distribution = a
                }
            }
            return .install(spec)
        case "--set-default-version":
            let v = try int(value(first), first)
            try noMore()
            return .setDefaultVersion(v)
        case "--set-version":
            let d = try value(first)
            let v = try int(value(first), first)
            try noMore()
            return .setVersion(distribution: d, version: v)
        case "--system", "--inbox", "--enable-wsl1":
            return .unsupported(first)
        case "--manage":
            let d = try value(first)
            guard let opt = rest.first else { throw ArgumentError.missingValue(first) }
            rest.removeFirst()
            let op: ManageOp
            switch opt {
            case "--move": op = .move(try value(opt))
            case "--set-sparse", "-s":
                let v = try value(opt).lowercased()
                guard v == "true" || v == "false" else { throw ArgumentError.invalid(v) }
                op = .setSparse(v == "true")
            case "--set-default-user": op = .setDefaultUser(try value(opt))
            case "--resize": op = .resize(try value(opt))
            case "--compact": op = .compact
            default: throw ArgumentError.invalid(opt)
            }
            try noMore()
            return .manage(distribution: d, op: op)
        case "--debug-shell":
            try noMore()
            return .debugShell
        case "--mount":
            var m = MountSpec()
            m.disk = try value(first)
            while let a = rest.first {
                rest.removeFirst()
                switch a {
                case "--vhd": m.vhd = true
                case "--bare": m.bare = true
                case "--name": m.name = try value(a)
                case "--type", "-t": m.type = try value(a)
                case "--options", "-o": m.options = try value(a)
                case "--partition": m.partition = try int(value(a), a)
                default: throw ArgumentError.invalid(a)
                }
            }
            return .mount(m)
        case "--unmount":
            let disk = rest.isEmpty ? nil : rest.removeFirst()
            try noMore()
            return .unmount(disk)
        case "--update":
            var pre = false
            for a in rest {
                switch a {
                case "--pre-release": pre = true
                case "--web-download": break
                default: throw ArgumentError.invalid(a)
                }
            }
            return .update(preRelease: pre)
        case "--uninstall":
            try noMore()
            return .uninstall
        case "--import-in-place":
            return .notImplemented(first)
        default:
            return .run(try parseRun(args))
        }
    }

    static func int(_ s: String, _ option: String) throws -> Int {
        guard let v = Int(s) else { throw ArgumentError.invalid(s) }
        return v
    }

    static func parseRun(_ args: [String]) throws -> RunSpec {
        var spec = RunSpec()
        var i = 0
        func value(_ option: String) throws -> String {
            guard i + 1 < args.count else { throw ArgumentError.missingValue(option) }
            i += 1
            return args[i]
        }
        var command: [String]?
        var exec = false
        loop: while i < args.count {
            let a = args[i]
            switch a {
            case "-d", "--distribution": spec.distribution = try value(a)
            case "--distribution-id": spec.distributionId = try value(a)
            case "-u", "--user": spec.user = try value(a)
            case "--cd": spec.cd = try value(a)
            case "--shell-type":
                let v = try value(a)
                guard let t = ShellType(rawValue: v) else { throw ArgumentError.invalid(v) }
                spec.shellType = t
            case "~" where i == 0:
                spec.cd = "~"
            case "-e", "--exec":
                guard i + 1 < args.count else { throw ArgumentError.missingValue(a) }
                command = Array(args[(i + 1)...])
                exec = true
                break loop
            case "--":
                command = Array(args[(i + 1)...])
                break loop
            case "--system":
                throw ArgumentError.invalid(a)
            default:
                if a.hasPrefix("-") { throw ArgumentError.invalid(a) }
                command = Array(args[i...])
                break loop
            }
            i += 1
        }
        if exec || spec.shellType == .none {
            spec.shellType = .none
            spec.argv = command ?? []
        } else if let command, !command.isEmpty {
            spec.commandLine = joinCommandLine(command)
        }
        return spec
    }

    /// Rebuild a command line from argv the way it would have been typed:
    /// arguments with whitespace (or empty) are single-quoted, everything else
    /// is passed through so the Linux shell expands it (like `wsl echo $HOME`).
    public static func joinCommandLine(_ argv: [String]) -> String {
        argv.map { a in
            if a.isEmpty || a.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
                return "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            return a
        }.joined(separator: " ")
    }
}
