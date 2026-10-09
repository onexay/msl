// SPDX-License-Identifier: Apache-2.0
import Foundation
import MSLCore

/// msld as a LaunchAgent (#52). launchd holds msld.sock and starts msld on the
/// first connection (so it still runs only on demand), and at logout, restart
/// or shutdown sends it SIGTERM and waits ExitTimeOut for it to shut the VM
/// down cleanly. Used by an installed msl with the default home; a development
/// build, a test home (MSL_HOME), or a session without a GUI login (SSH), where
/// launchd can't load it, starts msld directly as before.
enum LaunchAgent {
    static let baseLabel = "dev.msl.msld"
    static let exitTimeOut = 30

    static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// MSL_LAUNCHD=1 forces the agent (tests), =0 turns it off.
    static var wanted: Bool {
        switch env["MSL_LAUNCHD"] {
        case "1": return true
        case "0": return false
        default: return Installation.prefix != nil && (env["MSL_HOME"] ?? "").isEmpty
        }
    }

    /// dev.msl.msld, or dev.msl.msld.<hash of the home> for another MSL_HOME.
    static func label(_ paths: Paths) -> String {
        guard let home = env["MSL_HOME"], !home.isEmpty else { return baseLabel }
        let h = paths.root.path.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }  // FNV-1a
        return baseLabel + "." + String(format: "%08x", h)
    }

    static func plistURL(_ label: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func plist(label: String, msld: String, paths: Paths) -> [String: Any] {
        // A test home's MSL_* settings reach msld through launchd.
        let vars = env.filter { $0.key.hasPrefix("MSL_") && $0.key != "MSL_LAUNCHD" }
        var p: [String: Any] = [
            "Label": label,
            "ProgramArguments": [msld],
            "Sockets": ["Listeners": ["SockPathName": paths.socket.path, "SockPathMode": 0o600]],
            "StandardOutPath": paths.log.path,
            "StandardErrorPath": paths.log.path,
            "ExitTimeOut": exitTimeOut,
            // Not throttled like a background job: it runs the VM for interactive use.
            "ProcessType": "Interactive",
        ]
        if !vars.isEmpty { p["EnvironmentVariables"] = vars }
        return p
    }

    /// Write the agent and load it in this user's GUI domain. False when launchd
    /// can't run it here (e.g. no GUI login), so the caller starts msld itself.
    static func install(msld: String, paths: Paths) -> Bool {
        let label = label(paths)
        let url = plistURL(label)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist(label: label, msld: msld, paths: paths), format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
        } catch {
            return false
        }
        // Reload: it may be loaded with an old plist, or without its socket
        // (msld.sock deleted), which is why the connection failed.
        Installation.shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        return Installation.shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", url.path]) == 0
    }

    /// Stop the installed agent without removing its plist. Keeping the job
    /// unloaded lets an update replace msld without a socket connection
    /// activating the new binary just to shut it down again.
    static func unload(paths: Paths) -> Bool {
        guard wanted else { return false }
        let uid: uid_t
        if getuid() == 0, let value = ProcessInfo.processInfo.environment["SUDO_UID"], let invokingUser = uid_t(value) {
            uid = invokingUser
        } else {
            uid = getuid()
        }
        return Installation.shell("/bin/launchctl", ["bootout", "gui/\(uid)/\(label(paths))"]) == 0
    }

    /// `msl --uninstall`: unload and delete the agent (also under sudo, for the invoking user).
    static func remove(paths: Paths) {
        var uid = getuid()
        var home = FileManager.default.homeDirectoryForCurrentUser
        if uid == 0, let s = env["SUDO_UID"], let u = uid_t(s), let pw = getpwuid(u) {
            uid = u
            home = URL(fileURLWithPath: String(cString: pw.pointee.pw_dir))
        }
        let label = label(paths)
        Installation.shell("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL(label, home: home))
    }
}
