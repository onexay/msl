// SPDX-License-Identifier: Apache-2.0
// msl: the wsl.exe-compatible command line.
import Darwin
import Foundation
import MSLCore

let mslVersion = MSLBuild.displayVersion
let failureExit: Int32 = 255  // wsl.exe returns -1 on failure

func out(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!) }
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

/// `--json`: query results as JSON on stdout, errors as JSON on stderr.
nonisolated(unsafe) var jsonMode = false

func fail(_ message: String, _ code: String) -> Never {
    TTY.restore()
    if jsonMode {
        FileHandle.standardError.write(Data(JSONOutput.encode(JSONOutput.Failure(error: .init(message: message, code: code)), pretty: isatty(2) != 0).utf8 + [0x0a]))
    } else {
        out(Messages.failure(message, code))
    }
    exit(failureExit)
}

func outJSON<T: Encodable>(_ value: T) {
    out(JSONOutput.encode(value, pretty: isatty(1) != 0))
}

// MARK: - terminal

enum TTY {
    nonisolated(unsafe) static var saved: termios?

    static func makeRaw() {
        var t = termios()
        guard tcgetattr(0, &t) == 0 else { return }
        saved = t
        cfmakeraw(&t)
        tcsetattr(0, TCSANOW, &t)
    }

    static func restore() {
        if var t = saved {
            tcsetattr(0, TCSANOW, &t)
            saved = nil
        }
    }

    static func size() -> (UInt16, UInt16) {
        var ws = winsize()
        for fd: Int32 in [0, 1, 2] where isatty(fd) != 0 {
            if ioctl(fd, TIOCGWINSZ, &ws) == 0 { return (ws.ws_row, ws.ws_col) }
        }
        return (24, 80)
    }
}

// MARK: - connection to msld

func connect() -> IPCConnection {
    let paths = Paths()
    if let c = try? IPCConnection.connect(path: paths.socket.path) { return c }
    startDaemon(paths)
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if let c = try? IPCConnection.connect(path: paths.socket.path) { return c }
        usleep(20_000)
    }
    fail("Could not connect to msld (see \(paths.log.path)).", ErrorCode.service)
}

/// Start msld (next to this binary) detached, logging to msld.log.
func startDaemon(_ paths: Paths) {
    try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let dir = exe.deletingLastPathComponent()
    // build/bin/{msl,msld}, or an installed <prefix>/bin/msl + <prefix>/libexec/msl/msld
    let msld = [dir.appendingPathComponent("msld"), dir.appendingPathComponent("../libexec/msl/msld").standardizedFileURL]
        .map(\.path).first { FileManager.default.isExecutableFile(atPath: $0) } ?? dir.appendingPathComponent("msld").path
    var attr = posix_spawnattr_t(nil as OpaquePointer?)
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, paths.log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(msld), nil]
    let rc = posix_spawn(&pid, msld, &actions, &attr, argv, environ)
    if rc != 0 { err("msl: could not start \(msld): \(String(cString: strerror(rc)))") }
}

func request(_ r: Request, fds: [Int32] = []) -> Reply {
    let c = connect()
    do {
        try c.send(r, fds: fds)
        return try c.receive(Reply.self).0
    } catch {
        fail("Lost connection to msld: \(error)", ErrorCode.service)
    }
}

func expectOK(_ reply: Reply) {
    switch reply {
    case .ok, .installed, .distros, .versionInfo, .exited, .mounted, .status: return
    case .failure(let m, let c): fail(m, c)
    }
}

func distros() -> [DistroSummary] {
    switch request(.list) {
    case .distros(let d): return d
    case .failure(let m, let c): fail(m, c)
    default: return []
    }
}

// MARK: - run

func run(_ spec: RunSpec, debugShell: Bool = false) -> Never {
    let tty = (isatty(0) != 0, isatty(1) != 0, isatty(2) != 0)
    var env: [String: String] = [:]
    let host = ProcessInfo.processInfo.environment
    for k in ["TERM", "COLORTERM", "TERM_PROGRAM"] { env[k] = host[k] }
    let (rows, cols) = TTY.size()
    var req = RunRequest(spec: spec, macCwd: FileManager.default.currentDirectoryPath, env: env,
                         stdinTTY: tty.0, stdoutTTY: tty.1, stderrTTY: tty.2, rows: rows, cols: cols)
    req.macHome = NSHomeDirectory()
    if let spec = host["MSLENV"], !spec.isEmpty {
        req.mslenv = spec
        for item in spec.split(separator: ":") {
            let name = String(item.split(separator: "/", maxSplits: 1).first ?? "")
            if let v = host[name] { req.mslenvValues[name] = v }
        }
    }
    let c = connect()
    do {
        try c.send(debugShell ? Request.debugShell(req) : Request.run(req), fds: [0, 1, 2])
    } catch {
        fail("Lost connection to msld: \(error)", ErrorCode.service)
    }
    if tty.0 { TTY.makeRaw() }

    // Forward window size changes and (in pipe mode) signals.
    let q = DispatchQueue(label: "msl.signals")
    var sources: [DispatchSourceSignal] = []
    func on(_ sig: Int32, _ handler: @escaping () -> Void) {
        signal(sig, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: sig, queue: q)
        s.setEventHandler(handler: handler)
        s.resume()
        sources.append(s)
    }
    on(SIGWINCH) {
        let (r, cl) = TTY.size()
        try? c.send(ClientEvent.resize(rows: r, cols: cl))
    }
    for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
        on(sig) { try? c.send(ClientEvent.signal(sig)) }
    }

    let reply = (try? c.receive(Reply.self).0) ?? .failure(message: "Lost connection to msld.", code: ErrorCode.service)
    TTY.restore()
    switch reply {
    case .exited(let code): exit(code)
    case .failure(let m, let code): fail(m, code)
    default: exit(failureExit)
    }
}

// MARK: - files for import/export

func openInput(_ file: String) -> Int32 {
    if file == "-" { return 0 }
    let fd = open(file, O_RDONLY)
    if fd < 0 { fail(String(cString: strerror(errno)) + ": \(file)", ErrorCode.fileNotFound) }
    return fd
}

func openOutput(_ file: String) -> Int32 {
    if file == "-" { return 1 }
    let fd = open(file, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd < 0 { fail(String(cString: strerror(errno)) + ": \(file)", ErrorCode.fileNotFound) }
    return fd
}

// MARK: - main

let command: CLICommand
do {
    let invocation = try Arguments.parseInvocation(Array(CommandLine.arguments.dropFirst()))
    command = invocation.command
    jsonMode = invocation.json
} catch ArgumentError.jsonUnsupported {
    jsonMode = true
    fail(Messages.jsonUnsupported, ErrorCode.invalidArgument)
} catch ArgumentError.invalid(let a) {
    fail(Messages.invalidCommandLine(a), ErrorCode.invalidArgument)
} catch ArgumentError.missingValue(let a) {
    fail(Messages.missingArgument(a), ErrorCode.invalidArgument)
} catch {
    fail("\(error)", ErrorCode.invalidArgument)
}

switch command {
case .help:
    out(Messages.usage)

case .version:
    let reply = request(.versionInfo)
    expectOK(reply)
    guard case .versionInfo(let kernel) = reply else { exit(failureExit) }
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let macOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    if jsonMode {
        outJSON(JSONOutput.Version(msl: MSLBuild.version, commit: MSLBuild.commit.isEmpty ? nil : MSLBuild.commit, kernel: kernel, macOS: macOS, prefix: Installation.prefix?.path))
    } else {
        out(Messages.versions(msl: mslVersion, kernel: kernel, macOS: macOS))
    }

case .status:
    let warnings = MSLConfig.load().warnings
    if !jsonMode { printConfigWarnings() }
    let reply = request(.status)
    expectOK(reply)
    guard case .status(let ds, let vm) = reply else { exit(failureExit) }
    guard let def = ds.first(where: \.isDefault) else { fail(Messages.noDefaultDistro, ErrorCode.noDistros) }
    if jsonMode {
        outJSON(JSONOutput.status(defaultDistro: def.name, vm, warnings: warnings))
    } else {
        out(StatusFormat.render(defaultDistro: def.name, vm))
    }

case .list(let spec):
    if spec.online {
        let manifest = Online.manifest()
        if jsonMode {
            outJSON(JSONOutput.online(manifest, rosetta: Manifest.x86Available(rosetta: Online.rosettaInstalled)))
        } else {
            out(manifest.onlineListing(rosetta: Manifest.x86Available(rosetta: Online.rosettaInstalled)))
        }
        exit(0)
    }
    if jsonMode {
        guard let list = JSONOutput.list(distros(), spec) else { fail(Messages.noDefaultDistro, ErrorCode.noDistros) }
        outJSON(list)
        exit(0)
    }
    let (text, isError) = ListFormat.render(distros(), spec)
    if isError { fail(text, ErrorCode.noDistros) }
    out(text)

case .setDefault(let name):
    expectOK(request(.setDefault(name: name)))
    out(Messages.operationCompleted)

case .terminate(let name):
    expectOK(request(.terminate(name: name)))
    out(Messages.operationCompleted)

case .shutdown(let force):
    expectOK(request(.shutdown(force: force)))

case .unregister(let name):
    out(Messages.unregistering)
    expectOK(request(.unregister(name: name)))
    out(Messages.operationCompleted)

case .export(let name, let file, let format):
    if format == "vhd" { fail(Messages.notImplemented("--format vhd"), ErrorCode.unsupported) }
    let fd = openOutput(file)
    if file != "-" { out(Messages.exportProgress) }
    expectOK(request(.export(name: name, format: format ?? "tar"), fds: [fd]))
    if file != "-" { out(Messages.operationCompleted) }

case .importTar(let name, let location, let file, let version, let vhd):
    if vhd { fail(Messages.notImplemented("--vhd"), ErrorCode.unsupported) }
    if let version, version != 2 { fail(Messages.wsl1NotSupported, ErrorCode.unsupported) }
    let fd = openInput(file)
    out(Messages.importProgress)
    expectOK(request(.importTar(name: name, location: location), fds: [fd]))
    out(Messages.operationCompleted)

case .install(let spec):
    if let version = spec.version, version != 2 { fail(Messages.wsl1NotSupported, ErrorCode.unsupported) }
    printConfigWarnings()
    let file: String
    var name = spec.name
    if let f = spec.fromFile {
        file = f
        out(Messages.installing(f))
    } else {
        let manifest = Online.manifest()
        guard let entry = manifest.resolve(spec.distribution) else {
            fail("Invalid distribution name: '\(spec.distribution ?? "")'.\nTo get a list of valid distributions, use '\(Messages.exe) --list --online'.", ErrorCode.invalidName)
        }
        if name == nil { name = entry.Name }
        if distros().contains(where: { $0.name.caseInsensitiveCompare(name!) == .orderedSame }) {
            fail(Messages.distroNameAlreadyExists, ErrorCode.alreadyExists)
        }
        file = Online.download(entry).path
        out(Messages.installing(entry.FriendlyName))
    }
    let fd = openInput(file)
    let reply = request(.installFromFile(name: name, location: spec.location, sourceDescription: file), fds: [fd])
    expectOK(reply)
    guard case .installed(let name) = reply else { exit(failureExit) }
    out(Messages.distributionInstalled(name))
    if !spec.noLaunch {
        out(Messages.launching(name))
        var run = RunSpec()
        run.distribution = name
        run.cd = "~"
        msl_run(run)
    }

case .setDefaultVersion(let v):
    if v != 2 { fail(Messages.wsl1NotSupported, ErrorCode.unsupported) }
    out(Messages.operationCompleted)

case .setVersion(let name, let v):
    guard distros().contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
        fail(Messages.distroNotFound, ErrorCode.distroNotFound)
    }
    if v != 2 { fail(Messages.wsl1NotSupported, ErrorCode.unsupported) }
    out(Messages.operationCompleted)

case .manage(let name, let op):
    printConfigWarnings()
    expectOK(request(.manage(name: name, op: op)))
    out(Messages.operationCompleted)

case .debugShell:
    run(RunSpec(), debugShell: true)

case .mount(let m):
    let reply = request(.mount(m))
    expectOK(reply)
    if case .mounted(let device, let mountPoint) = reply {
        if mountPoint.isEmpty {
            out("The disk was successfully attached as '\(device)'.\nTo detach the disk, run '\(Messages.exe) --unmount \(m.disk)'.")
        } else {
            out("The disk was successfully mounted as '\(mountPoint)'.\nTo unmount and detach the disk, run '\(Messages.exe) --unmount \(m.disk)'.")
        }
    }

case .unmount(let disk):
    expectOK(request(.unmount(disk: disk)))

case .update(let pre):
    Installation.update(prerelease: pre)

case .uninstall:
    Installation.uninstall()

case .manageIDE(let spec):
    ManageIDE.run(spec)

case .unsupported(let a):
    fail(Messages.unsupportedOnMacOS(a), ErrorCode.unsupported)

case .notImplemented(let a):
    fail(Messages.notImplemented(a), ErrorCode.unsupported)

case .run(let spec):
    printConfigWarnings()
    msl_run(spec)
}

func msl_run(_ spec: RunSpec) -> Never { run(spec) }

/// Like wsl.exe, report .mslconfig problems (they never block startup).
func printConfigWarnings() {
    for w in MSLConfig.load().warnings { err("\(Messages.exe): \(w)") }
}
