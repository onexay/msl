// SPDX-License-Identifier: Apache-2.0
import Foundation
import MSLCore

/// `msl --manage-ide`: install or uninstall the MSL extension in VS Code and
/// similar IDEs, and add it to (or remove it from) `enable-proposed-api` in
/// their argv.json, which the extension's remote resolver needs.
enum ManageIDE {
    struct Found {
        let ide: IDE
        let cli: String?
        let config: URL
        var argv: URL { config.appendingPathComponent("argv.json") }
        /// From extensions/extensions.json, the IDE's list: an uninstalled
        /// extension's folder stays until the IDE cleans it up.
        var extensionInstalled: Bool {
            let list = config.appendingPathComponent("extensions/extensions.json")
            guard let data = try? Data(contentsOf: list),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
            return items.contains { (($0["identifier"] as? [String: Any])?["id"] as? String)?.lowercased() == IDE.extensionID }
        }
        var argvEnabled: Bool { ArgvJSON.isEnabled(IDE.extensionID, in: try? String(contentsOf: argv, encoding: .utf8)) }
        var status: String {
            switch (extensionInstalled, argvEnabled) {
            case (true, true): return "set up"
            case (false, false): return "not set up"
            case (true, false): return "extension installed, argv.json not enabled"
            case (false, true): return "argv.json enabled, extension not installed"
            }
        }
    }

    /// $HOME (the IDE CLIs we run use it too), so tests can use a throwaway one.
    static var home: URL {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The .vsix shipped next to the VM images: <prefix>/share/msl (or build/share/msl).
    static var vsix: URL {
        if let p = ProcessInfo.processInfo.environment["MSL_VSIX"], !p.isEmpty { return URL(fileURLWithPath: p) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        return exe.deletingLastPathComponent().appendingPathComponent("../share/msl/msl.vsix").standardizedFileURL
    }

    /// IDEs with a command-line tool or a per-user data folder.
    static func detect() -> [Found] {
        let fm = FileManager.default
        let appDirs = ["/Applications", home.appendingPathComponent("Applications").path]
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return IDE.all.compactMap { ide in
            let bundled = ide.apps.flatMap { app in appDirs.map { "\($0)/\(app)/\(ide.bundleCLI)" } }
            let onPath = ide.commands.flatMap { c in path.map { "\($0)/\(c)" } }
            let cli = (bundled + onPath).first { fm.isExecutableFile(atPath: $0) }
            let config = home.appendingPathComponent(ide.configDir, isDirectory: true)
            guard cli != nil || fm.fileExists(atPath: config.path) else { return nil }
            return Found(ide: ide, cli: cli, config: config)
        }
    }

    static func run(_ spec: ManageIDESpec) -> Never {
        if getuid() == 0 {
            fail("Run '\(Messages.exe) --manage-ide' as yourself, not as root: it changes your IDE settings.", ErrorCode.unsupported)
        }
        let found = detect()
        let names = IDE.all.map(\.name).joined(separator: ", ")
        if found.isEmpty {
            out("No supported IDE found (\(names)).")
            exit(0)
        }
        var targets: [Found]
        let action: ManageIDESpec.Action
        if let a = spec.action, let which = spec.ide {
            action = a
            if which == "all" {
                targets = found
            } else if let f = found.first(where: { $0.ide.id == which }) {
                targets = [f]
            } else {
                fail("\(IDE.named(which)?.name ?? which) was not found.", ErrorCode.fileNotFound)
            }
        } else {
            guard isatty(0) != 0 else {
                fail("Use '\(Messages.exe) --manage-ide --ide <ide|all> --install|--uninstall' when not in a terminal.", ErrorCode.invalidArgument)
            }
            let shown = spec.ide.flatMap { id in id == "all" ? nil : found.filter { $0.ide.id == id } } ?? found
            guard !shown.isEmpty else { fail("\(IDE.named(spec.ide ?? "")?.name ?? "That IDE") was not found.", ErrorCode.fileNotFound) }
            out("IDEs found:")
            for (i, f) in shown.enumerated() {
                out("  \(i + 1)  \(f.ide.name.padding(toLength: 30, withPad: " ", startingAt: 0))\(f.status)")
            }
            guard let a = ask("Install or uninstall the MSL extension? [i]nstall, [u]ninstall, [q]uit", default: "i") else { exit(0) }
            switch a.lowercased() {
            case "i", "install": action = .install
            case "u", "uninstall": action = .uninstall
            default: exit(0)
            }
            if shown.count == 1 {
                targets = shown
            } else {
                let pick = ask("Which? [1-\(shown.count), a=all]", default: "a") ?? "a"
                if pick.lowercased() == "a" || pick.lowercased() == "all" {
                    targets = shown
                } else if let n = Int(pick), (1...shown.count).contains(n) {
                    targets = [shown[n - 1]]
                } else {
                    exit(0)
                }
            }
        }

        if action == .install && !FileManager.default.fileExists(atPath: vsix.path) {
            fail("The MSL extension package is missing (\(vsix.path)).", ErrorCode.fileNotFound)
        }
        var changed: [String] = []
        var failed = false
        for f in targets {
            out("\(f.ide.name):")
            let ok = action == .install ? install(f) : uninstall(f)
            if ok.changed { changed.append(f.ide.name) }
            if !ok.success { failed = true }
        }
        if !changed.isEmpty {
            out("Quit and reopen \(changed.joined(separator: " and ")) (⌘Q) for the change to take effect.")
        }
        exit(failed ? 1 : 0)
    }

    /// For `msl --uninstall` (before its files are removed): undo the setup in
    /// every IDE that has it. Under sudo, as the invoking user with their home.
    static func uninstallEverywhere() {
        if getuid() == 0 {
            guard let user = ProcessInfo.processInfo.environment["SUDO_USER"], !user.isEmpty, user != "root" else { return }
            let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
            let (_, output) = capture("/usr/bin/sudo", ["-u", user, "-H", exe, "--manage-ide", "--ide", "all", "--uninstall"])
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && !text.hasPrefix("No supported IDE") { out(text) }
            return
        }
        let setUp = detect().filter { $0.extensionInstalled || $0.argvEnabled }
        for f in setUp {
            out("\(f.ide.name):")
            _ = uninstall(f)
        }
        if !setUp.isEmpty { out("Quit and reopen \(setUp.map(\.ide.name).joined(separator: " and ")) (⌘Q) for the change to take effect.") }
    }

    static func install(_ f: Found) -> (success: Bool, changed: Bool) {
        var changed = false
        guard let cli = f.cli else {
            out("  ✘ its command-line tool wasn't found; install the extension from \(vsix.path) by hand")
            return (false, false)
        }
        let (code, output) = capture(cli, ["--install-extension", vsix.path, "--force"])
        if code == 0 {
            out("  ✔ installed the MSL extension")
            changed = true
        } else {
            out("  ✘ installing the extension failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            return (false, false)
        }
        switch editArgv(f, { try ArgvJSON.enabling(IDE.extensionID, in: $0) }) {
        case .changed: out("  ✔ added \(IDE.extensionID) to enable-proposed-api in \(tilde(f.argv))")
        case .unchanged: out("  ✔ \(tilde(f.argv)) already enables \(IDE.extensionID)")
        case .failed(let e):
            out("  ✘ couldn't edit \(tilde(f.argv)) (\(e)); add \"enable-proposed-api\": [\"\(IDE.extensionID)\"] by hand")
            return (false, changed)
        }
        return (true, changed)
    }

    static func uninstall(_ f: Found) -> (success: Bool, changed: Bool) {
        var changed = false
        var success = true
        if f.extensionInstalled {
            if let cli = f.cli, capture(cli, ["--uninstall-extension", IDE.extensionID]).0 == 0 {
                out("  ✔ uninstalled the MSL extension")
                changed = true
            } else {
                out("  ✘ uninstalling the extension failed; remove it from the Extensions view")
                success = false
            }
        } else {
            out("  ✔ the MSL extension isn't installed")
        }
        switch editArgv(f, { try ArgvJSON.disabling(IDE.extensionID, in: $0) ?? "" }) {
        case .changed:
            out("  ✔ removed \(IDE.extensionID) from \(tilde(f.argv))")
            changed = true
        case .unchanged: break
        case .failed(let e):
            out("  ✘ couldn't edit \(tilde(f.argv)) (\(e))")
            success = false
        }
        return (success, changed)
    }

    enum EditResult { case changed, unchanged, failed(String) }

    /// Apply `edit` to argv.json: keep a one-time backup, write atomically.
    static func editArgv(_ f: Found, _ edit: (String?) throws -> String) -> EditResult {
        let fm = FileManager.default
        let old = try? String(contentsOf: f.argv, encoding: .utf8)
        let new: String
        do { new = try edit(old) } catch { return .failed("\(error)") }
        if new == (old ?? "") || (old == nil && new.isEmpty) { return .unchanged }
        do {
            try fm.createDirectory(at: f.config, withIntermediateDirectories: true)
            let backup = f.argv.appendingPathExtension("msl-backup")
            if let old, !fm.fileExists(atPath: backup.path) { try old.write(to: backup, atomically: true, encoding: .utf8) }
            try new.write(to: f.argv, atomically: true, encoding: .utf8)
        } catch {
            return .failed(error.localizedDescription)
        }
        return .changed
    }

    static func tilde(_ u: URL) -> String {
        u.path.hasPrefix(home.path + "/") ? "~" + u.path.dropFirst(home.path.count) : u.path
    }

    static func ask(_ question: String, default d: String) -> String? {
        FileHandle.standardOutput.write("\(question) (\(d)): ".data(using: .utf8)!)
        guard let line = readLine() else { return nil }
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? d : t
    }

    /// Run a tool, returning its exit status and combined output.
    static func capture(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
