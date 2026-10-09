// SPDX-License-Identifier: Apache-2.0
import Foundation
import MSLCore

/// `msl --update` and `msl --uninstall` for an installed msl:
/// <prefix>/bin/msl, <prefix>/libexec/msl/msld, <prefix>/share/msl, <prefix>/share/doc/msl.
enum Installation {
    /// The install prefix, or nil for a development build (build/bin/{msl,msld}).
    static var prefix: URL? {
        let prefix = selfExecutable.deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: prefix.appendingPathComponent("libexec/msl/msld").path) ? prefix : nil
    }

    static let managedPaths = ["bin/msl", "libexec/msl", "share/msl", "share/doc/msl"]

    /// Stop the VM; a replaced/removed msld then exits by itself (see Service.handle).
    static func stopService(paths: Paths = Paths()) {
        guard let c = try? IPCConnection.connect(path: paths.socket.path) else { return }
        try? c.send(Request.shutdown(force: false))
        _ = try? c.receive(Reply.self)
    }

    /// `sudo msl --update` must reach the daemon owned by the invoking user.
    static func servicePaths() -> Paths {
        var environment = ProcessInfo.processInfo.environment
        if (environment["MSL_HOME"] ?? "").isEmpty,
           getuid() == 0,
           let value = environment["SUDO_UID"],
           let uid = uid_t(value),
           let user = getpwuid(uid) {
            environment["MSL_HOME"] = URL(fileURLWithPath: String(cString: user.pointee.pw_dir))
                .appendingPathComponent("Library/Application Support/msl", isDirectory: true).path
        }
        return Paths(environment: environment)
    }

    struct Channel: Decodable { var version: String; var url: String; var sha256: String; var minimumMacOS: Int }
    struct UpdateManifest: Decodable { var channels: [String: Channel] }

    static func update(prerelease: Bool) -> Never {
        out("Checking for updates.")
        let source = ProcessInfo.processInfo.environment["MSL_UPDATE_URL"] ?? MSLBuild.updateURL
        guard !source.isEmpty, let url = URL(string: source) else {
            out("Updates are not configured for this build of \(Messages.exe) (no release channel).")
            exit(0)
        }
        guard let prefix else {
            fail("This is a development build; update it by rebuilding (scripts/build.sh).", ErrorCode.unsupported)
        }
        let manifest: UpdateManifest
        do {
            let data = url.isFileURL ? try Data(contentsOf: url) : try Online.fetch(url)
            manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch {
            fail("Update failed: could not read '\(source)': \(error.localizedDescription)", ErrorCode.service)
        }
        guard let ch = (prerelease ? manifest.channels["pre-release"] : nil) ?? manifest.channels["stable"] else {
            fail("Update failed: the release channel has no stable version.", ErrorCode.service)
        }
        guard versionIsNewer(ch.version, than: MSLBuild.version) else {
            out("The most recent version of \(Messages.product) is already installed.")
            exit(0)
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard os.majorVersion >= ch.minimumMacOS else {
            fail("Update failed: \(Messages.product) \(ch.version) needs macOS \(ch.minimumMacOS) or later (this is macOS \(os.majorVersion).\(os.minorVersion)).", ErrorCode.unsupported)
        }
        guard FileManager.default.isWritableFile(atPath: prefix.appendingPathComponent("bin").path) else {
            fail("Updating requires write access to \(prefix.path); run 'sudo \(Messages.exe) --update'.", ErrorCode.unsupported)
        }
        out("Updating \(Messages.product) to version \(ch.version).")
        let tarball = Online.downloadVerified(URL(string: ch.url)!, sha256: ch.sha256, label: "msl \(ch.version)")
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("msl-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        guard shell("/usr/bin/tar", ["-xzf", tarball.path, "-C", staging.path]) == 0,
              let root = try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).first,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("libexec/msl/msld").path) else {
            fail("Update failed: the downloaded archive is not an msl release.", ErrorCode.service)
        }
        let paths = servicePaths()
        stopService(paths: paths)
        let launchAgentUnloaded = LaunchAgent.unload(paths: paths)
        do {
            try replaceTree(from: root, to: prefix)
        } catch {
            fail("Update failed: \(error.localizedDescription)", ErrorCode.service)
        }
        if !launchAgentUnloaded {
            stopService(paths: paths)  // the old, directly-started msld notices its executable was replaced
        }
        ManageIDE.refreshInstalled()
        out(Messages.operationCompleted)
        exit(0)
    }

    /// Move every file of `src` into `dst` (atomically per file: new inodes, so a
    /// running msld keeps a valid signature until it exits).
    static func replaceTree(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let f as URL in e {
            let rel = String(f.path.dropFirst(src.path.count + 1))
            let target = dst.appendingPathComponent(rel)
            if (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            let tmp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).new")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: f, to: tmp)
            if rename(tmp.path, target.path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    static func uninstall() -> Never {
        guard let prefix else {
            fail("This is a development build; there is nothing to uninstall (delete the build/ folder instead).", ErrorCode.unsupported)
        }
        guard FileManager.default.isWritableFile(atPath: prefix.appendingPathComponent("bin").path) else {
            fail("Uninstalling requires write access to \(prefix.path); run 'sudo \(Messages.exe) --uninstall'.", ErrorCode.unsupported)
        }
        ManageIDE.uninstallEverywhere()
        LaunchAgent.remove(paths: Paths())  // launchd stops msld (SIGTERM: a clean VM shutdown)
        stopService()
        for p in managedPaths { try? FileManager.default.removeItem(at: prefix.appendingPathComponent(p)) }
        stopService()
        out("\(Messages.product) was uninstalled from \(prefix.path).")
        out("Distributions and settings were kept in \(Paths().root.path); delete that folder to remove them.")
        if shell("/usr/sbin/pkgutil", ["--pkg-info", "dev.msl.msl"]) == 0 {
            out("To remove the installer receipt, run: sudo pkgutil --forget dev.msl.msl")
        }
        exit(0)
    }

    @discardableResult
    static func shell(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
