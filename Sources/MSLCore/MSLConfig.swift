import Foundation

/// `~/.mslconfig`, the `.wslconfig` equivalent (same INI sections and keys).
/// Unknown keys are ignored; malformed values produce a warning and fall back to
/// the default, and a malformed file never blocks startup (as in WSL).
public struct MSLConfig: Equatable, Sendable {
    // [wsl2]
    public var memoryBytes: UInt64?          // default: 50% of host RAM
    public var processors: Int?              // default: all
    public var kernel: String?               // custom kernel image path
    public var kernelCommandLine: String = ""
    public var localhostForwarding = true
    public var dnsTunneling = true
    public var vmIdleTimeoutMs: Int = 60_000
    // [general]
    public var instanceIdleTimeoutMs: Int = 15_000
    // [experimental]
    /// Accepted for .wslconfig compatibility; has no effect on macOS: the
    /// Virtualization.framework balloon doesn't return pages to the host, so memory
    /// comes back when the VM exits (vmIdleTimeout). See docs/design/memory-reclaim.md.
    public enum MemoryReclaim: String, Sendable { case disabled, gradual, dropCache }
    public var autoMemoryReclaim: MemoryReclaim = .dropCache

    public var warnings: [String] = []

    public init() {}

    public static var defaultURL: URL {
        if let p = ProcessInfo.processInfo.environment["MSL_CONFIG"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mslconfig")
    }

    public static func load(_ url: URL = defaultURL) -> MSLConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return MSLConfig() }
        return parse(text, path: url.path)
    }

    public static func parse(_ text: String, path: String = "~/.mslconfig") -> MSLConfig {
        var c = MSLConfig()
        var section = ""
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard let eq = line.firstIndex(of: "=") else {
                c.warnings.append("Expected ' = ' in \(path):\(i + 1)")
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            let entry = "\(section).\(key)"
            let at = "\(path):\(i + 1)"
            switch entry {
            case "wsl2.memory":
                if let v = parseSize(value) { c.memoryBytes = v } else { c.warnings.append("Invalid memory string '\(value)' for .mslconfig entry '\(entry)' in \(at)") }
            case "wsl2.processors":
                if let v = Int(value), v > 0 { c.processors = v } else { c.warnings.append("Invalid integer '\(value)' for .mslconfig entry '\(entry)' in \(at)") }
            case "wsl2.kernel":
                c.kernel = (value as NSString).expandingTildeInPath
            case "wsl2.kernelcommandline":
                c.kernelCommandLine = value
            case "wsl2.localhostforwarding":
                if let b = parseBool(value) { c.localhostForwarding = b } else { c.warnings.append("Invalid boolean '\(value)' for .mslconfig entry '\(entry)' in \(at)") }
            case "wsl2.dnstunneling":
                if let b = parseBool(value) { c.dnsTunneling = b } else { c.warnings.append("Invalid boolean '\(value)' for .mslconfig entry '\(entry)' in \(at)") }
            case "wsl2.vmidletimeout":
                if let v = Int(value) { c.vmIdleTimeoutMs = v } else { c.warnings.append("Invalid integer '\(value)' for .mslconfig entry '\(entry)' in \(at)") }
            case "experimental.automemoryreclaim":
                switch value.lowercased() {
                case "disabled": c.autoMemoryReclaim = .disabled
                case "gradual": c.autoMemoryReclaim = .gradual
                case "dropcache": c.autoMemoryReclaim = .dropCache
                default: c.warnings.append("Invalid value '\(value)' for .mslconfig entry '\(entry)' in \(at)")
                }
            case "general.instanceidletimeout":
                if let v = Int(value) { c.instanceIdleTimeoutMs = v } else { c.warnings.append("Invalid integer '\(value)' for .mslconfig entry '\(entry)' in \(at)") }
            default:
                break  // other .wslconfig keys: accepted, not (yet) meaningful on macOS
            }
        }
        return c
    }

    /// Bytes, or a number with KB/MB/GB/TB (also K/M/G/T), as in .wslconfig.
    public static func parseSize(_ s: String) -> UInt64? {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        let units: [(String, UInt64)] = [("TB", 1 << 40), ("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10),
                                         ("T", 1 << 40), ("G", 1 << 30), ("M", 1 << 20), ("K", 1 << 10), ("B", 1)]
        for (suffix, mult) in units where t.hasSuffix(suffix) {
            guard let n = UInt64(t.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) else { return nil }
            return n * mult
        }
        return UInt64(t)
    }

    static func parseBool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true", "1", "yes": true
        case "false", "0", "no": false
        default: nil
        }
    }
}
