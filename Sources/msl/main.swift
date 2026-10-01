// SPDX-License-Identifier: Apache-2.0
// msl: the wsl.exe-compatible command line.
import Darwin
import Foundation
import MSLCore

let mslVersion = MSLBuild.displayVersion
let failureExit: Int32 = 255  // wsl.exe returns -1 on failure

func out(_ s: String) { write(1, s + "\n") }
func err(_ s: String) { write(2, s + "\n") }

/// Write to stdout or stderr with write(2). FileHandle.write raises an
/// Objective-C exception when the reader is gone (EPIPE with SIGPIPE ignored,
/// as during a tar stream), which aborts msl; here the text is just dropped.
func write(_ fd: Int32, _ s: String) {
    var bytes = Array(s.utf8)[...]
    while !bytes.isEmpty {
        let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return }
        bytes = bytes.dropFirst(n)
    }
}

/// `--json`: query results as JSON on stdout, errors as JSON on stderr.
nonisolated(unsafe) var jsonMode = false

func fail(_ message: String, _ code: String) -> Never {
    TTY.restore()
    if jsonMode {
        write(2, JSONOutput.encode(JSONOutput.Failure(error: .init(message: message, code: code)), pretty: isatty(2) != 0) + "\n")
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
    if !(LaunchAgent.wanted && LaunchAgent.install(msld: msldPath(), paths: paths)) {
        startDaemon(paths)
    }
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if let c = try? IPCConnection.connect(path: paths.socket.path) { return c }
        usleep(20_000)
    }
    fail("Could not connect to msld (see \(paths.log.path)).", ErrorCode.service)
}

/// This binary's absolute path, symlinks resolved. Not argv[0]: run from PATH,
/// that's just "msl", which would resolve against the current directory.
let selfExecutable: URL = {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size) + 1)
    let path = _NSGetExecutablePath(&buf, &size) == 0 ? String(cString: buf) : CommandLine.arguments[0]
    return URL(fileURLWithPath: path).resolvingSymlinksInPath()
}()

/// msld next to this binary: build/bin/{msl,msld}, or an installed
/// <prefix>/bin/msl + <prefix>/libexec/msl/msld.
func msldPath() -> String {
    let dir = selfExecutable.deletingLastPathComponent()
    return [dir.appendingPathComponent("msld"), dir.appendingPathComponent("../libexec/msl/msld").standardizedFileURL]
        .map(\.path).first { FileManager.default.isExecutableFile(atPath: $0) } ?? dir.appendingPathComponent("msld").path
}

/// Start msld detached, logging to msld.log (when it isn't a LaunchAgent).
func startDaemon(_ paths: Paths) {
    try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
    let msld = msldPath()
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

/// A tar-stream request: msld hands over the guest's stream (`.stream`) and msl
/// moves the data itself, writing `file` to it (`sending`) or reading it into
/// `file`, then gets the final reply.
func streamRequest(_ r: Request, file: Int32, sending: Bool) -> Reply {
    signal(SIGPIPE, SIG_IGN)
    let c = connect()
    do { try c.send(r) } catch { fail("Lost connection to msld: \(error)", ErrorCode.service) }
    let done = DispatchGroup()
    let end = Streams.Expect()
    while true {
        let reply: Reply
        let fds: [Int32]
        do { (reply, fds) = try c.receive(Reply.self) } catch { fail("Lost connection to msld.", ErrorCode.service) }
        switch reply {
        case .stream:
            guard let s = fds.first else { continue }
            if sending {
                Streams.copy(from: file, to: s, endWrite: true, group: done)
            } else {
                Streams.copy(from: s, to: file, group: done, expect: end)
            }
        case .streamEnd(let bytes):
            end.set(bytes)
        default:
            done.wait()
            return reply
        }
    }
}

func expectOK(_ reply: Reply) {
    switch reply {
    case .ok, .installed, .distros, .versionInfo, .exited, .mounted, .status, .streams, .stream, .ended, .streamEnd: return
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
        try c.send(debugShell ? Request.debugShell(req) : Request.run(req))
    } catch {
        fail("Lost connection to msld: \(error)", ErrorCode.service)
    }
    if tty.0 { TTY.makeRaw() }
    // We write to the streams ourselves now: a closed stdout must not kill msl.
    signal(SIGPIPE, SIG_IGN)

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

    // msld hands over each process's streams (the distro's first-run setup, then
    // the command), then reports the exit; msl moves the bytes itself.
    var current: (done: DispatchGroup, stop: Streams.Stop, ends: [Streams.Expect?])?
    while true {
        let reply: Reply
        let fds: [Int32]
        do { (reply, fds) = try c.receive(Reply.self) } catch {
            TTY.restore()
            fail("Lost connection to msld.", ErrorCode.service)
        }
        switch reply {
        case .streams(let ttyStream, let stdin, let stdout, let stderr):
            let done = DispatchGroup(), stop = Streams.Stop()
            var ends: [Streams.Expect?] = [nil, nil, nil]  // tty, stdout, stderr
            var it = fds.makeIterator()
            if ttyStream, let s = it.next() {
                // Not half-closed at our eof: it also carries the output.
                if tty.0 { Streams.copy(from: 0, to: s, stop: stop) }
                ends[0] = Streams.Expect()
                Streams.copy(from: s, to: tty.1 ? 1 : 2, group: done, expect: ends[0])
            }
            if stdin, let s = it.next() { Streams.copy(from: 0, to: s, endWrite: true, stop: stop) }
            if stdout, let s = it.next() {
                ends[1] = Streams.Expect()
                Streams.copy(from: s, to: 1, group: done, expect: ends[1])
            }
            if stderr, let s = it.next() {
                ends[2] = Streams.Expect()
                Streams.copy(from: s, to: 2, group: done, expect: ends[2])
            }
            current = (done, stop, ends)
        case .ended(let ttyBytes, let stdoutBytes, let stderrBytes):
            // The process has exited: stop reading our stdin for it, take
            // exactly the output it wrote, then the next process (or the exit).
            if let cur = current {
                cur.stop.set()
                for (e, n) in zip(cur.ends, [ttyBytes, stdoutBytes, stderrBytes]) { e?.set(n) }
                cur.done.wait()
            }
            current = nil
        case .exited(let code):
            TTY.restore()
            exit(code)
        case .failure(let m, let code):
            TTY.restore()
            fail(m, code)
        default:
            TTY.restore()
            exit(failureExit)
        }
    }
}

/// Copying between msl's stdio and a process's streams (vsock fds from msld).
enum Streams {
    /// Ends a copy blocked reading its source (a session's stdin, when the next
    /// session starts): setting it closes the write end of a pipe the copy polls.
    final class Stop: @unchecked Sendable {
        private var fds: [Int32] = [-1, -1]
        init() { _ = pipe(&fds) }
        var fd: Int32 { fds[0] }
        func set() { if fds[1] >= 0 { close(fds[1]); fds[1] = -1 } }
    }

    /// How many bytes an output stream carries, which the guest reports over
    /// msld (Reply.ended / .streamEnd) once it has written them all. The vsock's
    /// own end isn't reliable on VZ: a guest close can drop the tail, and a
    /// half-close can go missing. The copy reads with plain blocking reads; if
    /// it already has everything when the count arrives, `set` shuts down the
    /// source's read side, which ends the blocked read.
    final class Expect: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: UInt64?
        private var got: UInt64 = 0
        private var source: Int32 = -1
        /// The copy is reading `fd`.
        fileprivate func start(_ fd: Int32) { lock.withLock { source = fd } }
        /// `n` more bytes copied; true once that's everything.
        fileprivate func add(_ n: Int) -> Bool { lock.withLock { got += UInt64(n); return complete } }
        fileprivate var isComplete: Bool { lock.withLock { complete } }
        /// The copy has closed its source.
        fileprivate func finish() { lock.withLock { source = -1 } }
        private var complete: Bool { bytes.map { got >= $0 } ?? false }
        func set(_ n: UInt64) {
            lock.withLock {
                bytes = n
                if complete && source >= 0 { shutdown(source, SHUT_RD) }
            }
        }
    }

    /// Copy `from` -> `to` on a thread. An input copy (`stop`) runs until eof
    /// or `stop`, and with `endWrite` shuts down the write side of `to` at eof
    /// (stdin's eof for the process). An output copy (`expect`) runs until it
    /// has the expected bytes (or eof), then closes `from`: the guest closes its
    /// end only after that. An output whose destination is gone (`msl … | head`)
    /// is closed too, so the process gets SIGPIPE as it would locally. `group`
    /// is left when the copy ends.
    @discardableResult
    static func copy(from: Int32, to: Int32, endWrite: Bool = false, group: DispatchGroup? = nil, stop: Stop? = nil, expect: Expect? = nil) -> Thread {
        group?.enter()
        expect?.start(from)
        let t = Thread {
            var buf = [UInt8](repeating: 0, count: 256 * 1024)
            outer: while expect?.isComplete != true {
                if let stop {
                    var p = [pollfd(fd: from, events: Int16(POLLIN), revents: 0), pollfd(fd: stop.fd, events: Int16(POLLIN), revents: 0)]
                    if poll(&p, 2, -1) < 0 && errno == EINTR { continue }
                    if p[1].revents != 0 && p[0].revents == 0 { group?.leave(); return }  // stopped: no eof for the stream
                }
                let n = read(from, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                var off = 0
                while off < n {
                    let w = buf.withUnsafeBytes { write(to, $0.baseAddress! + off, n - off) }
                    if w < 0 && errno == EINTR { continue }
                    if w <= 0 { break outer }
                    off += w
                }
                if expect?.add(n) == true { break }
            }
            if endWrite { shutdown(to, SHUT_WR) }
            if let expect { expect.finish(); close(from) }
            group?.leave()
        }
        t.start()
        return t
    }
}

// MARK: - files for import/export

func openInput(_ file: String) -> Int32 {
    if file == "-" { return 0 }
    let fd = open(file, O_RDONLY)
    if fd < 0 { fail(String(cString: strerror(errno)) + ": \(file)", ErrorCode.fileNotFound) }
    return fd
}

/// A path as msld needs it: absolute, from this process's cwd, `~` expanded.
func absolutePath(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
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
        outJSON(JSONOutput.Version(msl: MSLBuild.version, commit: MSLBuild.commit.isEmpty ? nil : MSLBuild.commit, kernel: kernel, macos: macOS, prefix: Installation.prefix?.path))
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
    if format == "vhd" {
        if file == "-" { fail(Messages.diskImageNotToStdout, ErrorCode.invalidArgument) }
        out(Messages.exportProgress)
        expectOK(request(.exportDisk(name: name, path: absolutePath(file))))
        out(Messages.operationCompleted)
        exit(0)
    }
    let fd = openOutput(file)
    if file != "-" { out(Messages.exportProgress) }
    expectOK(streamRequest(.export(name: name, format: format ?? "tar"), file: fd, sending: false))
    if file != "-" { out(Messages.operationCompleted) }

case .importTar(let name, let location, let file, let version, let vhd):
    if let version, version != 2 { fail(Messages.wsl1NotSupported, ErrorCode.unsupported) }
    if vhd {
        if file == "-" { fail(Messages.diskImageNotFromStdin, ErrorCode.invalidArgument) }
        out(Messages.importProgress)
        expectOK(request(.importDisk(name: name, location: absolutePath(location), image: absolutePath(file))))
        out(Messages.operationCompleted)
        exit(0)
    }
    let fd = openInput(file)
    out(Messages.importProgress)
    expectOK(streamRequest(.importTar(name: name, location: absolutePath(location)), file: fd, sending: true))
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
    let reply = streamRequest(.installFromFile(name: name, location: spec.location.map(absolutePath), sourceDescription: file, vhdSize: spec.vhdSize),
                              file: fd, sending: true)
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

case .importInPlace(let name, let file):
    out(Messages.importProgress)
    expectOK(request(.importInPlace(name: name, image: absolutePath(file))))
    out(Messages.operationCompleted)

case .manage(let name, let op):
    printConfigWarnings()
    var op = op
    if case .move(let dir) = op { op = .move(absolutePath(dir)) }
    expectOK(request(.manage(name: name, op: op)))
    out(Messages.operationCompleted)

case .debugShell:
    run(RunSpec(), debugShell: true)

case .connect(let req):
    // stdin/stdout <-> the target; msld keeps the distro up while we're connected.
    signal(SIGPIPE, SIG_IGN)
    let c = connect()
    var unix: String?, tcp: UInt16?
    switch req.target {
    case .unix(let p): unix = p
    case .tcp(let p): tcp = p
    }
    let reply: Reply
    let fds: [Int32]
    do {
        try c.send(Request.connect(distro: req.distro, unix: unix, tcp: tcp))
        (reply, fds) = try c.receive(Reply.self)
    } catch {
        fail("Lost connection to msld: \(error)", ErrorCode.service)
    }
    guard case .streams = reply, fds.count == 2 else {
        expectOK(reply)
        exit(failureExit)
    }
    // One stream each way: ending ours never cuts the target's reply short.
    // The target's output ends with the byte count msld relays (.streamEnd).
    let done = DispatchGroup(), end = Streams.Expect()
    Streams.copy(from: 0, to: fds[0], endWrite: true)
    Streams.copy(from: fds[1], to: 1, group: done, expect: end)
    while case .streamEnd(let bytes)? = try? c.receive(Reply.self).0 {
        end.set(bytes)
        break
    }
    done.wait()
    exit(0)

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
