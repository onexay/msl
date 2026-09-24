// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The VM's settings after defaults are applied (what `.mslconfig` resolves to).
public struct VMSettings: Codable, Equatable, Sendable {
    public var memoryBytes: UInt64
    public var processors: Int
    public var kernel: String
    public var kernelCommandLine: String
    public var localhostForwarding: Bool
    public var dnsTunneling: Bool
    public var vmIdleTimeoutMs: Int
    public var instanceIdleTimeoutMs: Int

    public init(memoryBytes: UInt64, processors: Int, kernel: String, kernelCommandLine: String,
                localhostForwarding: Bool, dnsTunneling: Bool, vmIdleTimeoutMs: Int, instanceIdleTimeoutMs: Int) {
        self.memoryBytes = memoryBytes; self.processors = processors; self.kernel = kernel
        self.kernelCommandLine = kernelCommandLine; self.localhostForwarding = localhostForwarding
        self.dnsTunneling = dnsTunneling; self.vmIdleTimeoutMs = vmIdleTimeoutMs; self.instanceIdleTimeoutMs = instanceIdleTimeoutMs
    }
}

public struct VMStatus: Codable, Sendable {
    public var running: Bool
    public var uptimeSeconds: Double?
    /// What the running VM booted with (nil when stopped).
    public var effective: VMSettings?
    /// What ~/.mslconfig resolves to now (used at the next start).
    public var configured: VMSettings
    public var configPath: String
    public var configExists: Bool

    public init(running: Bool, uptimeSeconds: Double?, effective: VMSettings?, configured: VMSettings, configPath: String, configExists: Bool) {
        self.running = running; self.uptimeSeconds = uptimeSeconds; self.effective = effective
        self.configured = configured; self.configPath = configPath; self.configExists = configExists
    }
}

/// `msl --status` output: wsl.exe's two lines, then the VM section.
public enum StatusFormat {
    public static func render(defaultDistro: String, _ s: VMStatus, home: String = NSHomeDirectory()) -> String {
        var lines = [Messages.statusDefaultDistro(defaultDistro), Messages.statusDefaultVersion(2), ""]
        let shown = s.effective ?? s.configured
        let path = s.configPath.hasPrefix(home + "/") ? "~" + s.configPath.dropFirst(home.count) : s.configPath
        if s.running {
            lines.append("Virtual machine: Running" + (s.uptimeSeconds.map { " (up \(duration($0)))" } ?? ""))
        } else {
            lines.append("Virtual machine: Stopped (the next msl command starts it with these settings)")
        }
        let rows: [(String, String)] = [
            ("Memory", bytes(shown.memoryBytes)),
            ("Processors", "\(shown.processors)"),
            ("Kernel", shown.kernel),
            ("Kernel command line", shown.kernelCommandLine),
            ("Localhost forwarding", onOff(shown.localhostForwarding)),
            ("DNS tunneling", onOff(shown.dnsTunneling)),
            ("VM idle timeout", timeout(shown.vmIdleTimeoutMs)),
            ("Distribution idle timeout", timeout(shown.instanceIdleTimeoutMs)),
            ("Settings file", s.configExists ? path : "\(path) (not present; defaults)"),
        ]
        let width = rows.map(\.0.count).max()! + 1
        for (k, v) in rows { lines.append("  " + (k + ":").padding(toLength: width + 1, withPad: " ", startingAt: 0) + v) }

        if let e = s.effective {
            let changes = diff(e, s.configured)
            if !changes.isEmpty {
                lines.append("")
                lines.append("Pending changes in \(path) (applied after 'msl --shutdown'):")
                for c in changes { lines.append("  " + c) }
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func diff(_ a: VMSettings, _ b: VMSettings) -> [String] {
        var out: [String] = []
        func add(_ name: String, _ x: String, _ y: String) { if x != y { out.append("\(name): \(x) → \(y)") } }
        add("Memory", bytes(a.memoryBytes), bytes(b.memoryBytes))
        add("Processors", "\(a.processors)", "\(b.processors)")
        add("Kernel", a.kernel, b.kernel)
        add("Kernel command line", a.kernelCommandLine, b.kernelCommandLine)
        add("Localhost forwarding", onOff(a.localhostForwarding), onOff(b.localhostForwarding))
        add("DNS tunneling", onOff(a.dnsTunneling), onOff(b.dnsTunneling))
        add("VM idle timeout", timeout(a.vmIdleTimeoutMs), timeout(b.vmIdleTimeoutMs))
        add("Distribution idle timeout", timeout(a.instanceIdleTimeoutMs), timeout(b.instanceIdleTimeoutMs))
        return out
    }

    public static func bytes(_ b: UInt64) -> String {
        if b % (1 << 30) == 0 { return "\(b >> 30) GB" }
        if b >= 1 << 30 { return String(format: "%.1f GB", Double(b) / Double(1 << 30)) }
        return "\(b >> 20) MB"
    }

    public static func timeout(_ ms: Int) -> String {
        if ms < 0 { return "never" }
        if ms % 1000 == 0 { return "\(ms / 1000) s" }
        return "\(ms) ms"
    }

    static func onOff(_ b: Bool) -> String { b ? "on" : "off" }

    static func duration(_ s: Double) -> String {
        let t = Int(s)
        if t < 60 { return "\(t)s" }
        if t < 3600 { return "\(t / 60)m \(t % 60)s" }
        return "\(t / 3600)h \((t % 3600) / 60)m"
    }
}
