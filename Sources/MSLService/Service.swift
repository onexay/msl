// SPDX-License-Identifier: Apache-2.0
import Foundation
import GRPCCore
import MSLCore
import MSLProtocol
import Security

/// msld: serves msl clients on a Unix socket and drives the utility VM.
public final class Service: @unchecked Sendable {
    let paths: Paths
    let registry: Registry
    let vm: VMHost
    let guest: GuestClients
    private let bootLock = NSLock()
    /// Identity of our executable at startup, to notice it being replaced on disk
    /// (an updated build): a replaced, running msld can no longer start VMs.
    private let executablePath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    private lazy var executableInode: UInt64 = Self.inode(executablePath)

    static func inode(_ path: String) -> UInt64 {
        var st = stat()
        return stat(path, &st) == 0 ? UInt64(st.st_ino) : 0
    }

    /// Replaced (new inode) or modified in place (on-disk signature no longer valid).
    var executableReplaced: Bool {
        if Self.inode(executablePath) != executableInode { return true }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: executablePath) as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) != errSecSuccess
    }
    /// Settings read at the last VM boot (like WSL, .mslconfig applies on the next start).
    private(set) var config = MSLConfig()
    let idle = IdleTracker()
    /// `msl --mount`: disk path -> (USB device, mount name). Cleared when the VM stops.
    private var disks: [String: (device: AnyObject, name: String)] = [:]
    private let diskLock = NSLock()
    private(set) lazy var forwarder = PortForwarder(vm: vm, guest: guest)
    private(set) lazy var files = FileView(vm: vm, paths: paths, registry: registry, guest: guest)

    public init(paths: Paths = Paths()) {
        self.paths = paths
        registry = Registry(url: paths.registry)
        vm = VMHost(paths: paths)
        guest = GuestClients(vm: vm)
        vm.onStop = { [weak self] in
            self?.diskLock.withLock { self?.disks.removeAll() }
            self?.forwarder.stopAll()
            self?.files.shutdown()
            self?.guest.reset()
        }
    }

    public func serve() throws -> Never {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let lfd = try listenUnix(paths.socket.path)
        _ = executableInode
        log("msld listening on \(paths.socket.path)")
        serveConnect()
        startIdleMonitor()
        while true {
            let c = accept(lfd, nil, nil)
            if c < 0 { continue }
            Thread.detachNewThread { self.handle(IPCConnection(fd: c)) }
        }
    }

    /// Stops idle distros after [general] instanceIdleTimeout and the VM after
    /// [msl2] vmIdleTimeout (both in ms; -1 = never).
    func startIdleMonitor() {
        Thread.detachNewThread {
            while true {
                sleep(1)
                guard self.vm.isRunning, self.idle.activeRequests == 0 else {
                    self.idle.resetVMIdle()
                    continue
                }
                let running = self.runningIds()
                for id in running where self.config.instanceIdleTimeoutMs >= 0 {
                    if self.idle.idleMs(distro: id) >= self.config.instanceIdleTimeoutMs,
                       let mini = try? self.guest.miniInit {
                        log("instance idle timeout: stopping \(self.registry.find(id: id)?.name ?? id)")
                        _ = try? blocking { try await mini.stopDistro(.with { $0.id = id }) }
                        self.idle.forget(distro: id)
                    }
                }
                if ProcessInfo.processInfo.environment["MSL_DEBUG_IDLE"] != nil {
                    log("idle: requests=\(self.idle.activeRequests) running=\(self.runningIds().count) vmIdleMs=\(self.idle.vmIdleMs()) limit=\(self.config.vmIdleTimeoutMs)")
                }
                if self.runningIds().isEmpty {
                    if self.config.vmIdleTimeoutMs >= 0, self.idle.vmIdleMs() >= self.config.vmIdleTimeoutMs {
                        log("vm idle timeout: shutting down")
                        self.shutdown(force: false)
                    }
                } else {
                    self.idle.resetVMIdle()
                }
            }
        }
    }

    func runningIds() -> [String] {
        guard vm.isRunning, let mini = try? guest.miniInit,
              let reply = try? blocking({ try await mini.listRunning(Msl_V1_Empty()) }) else { return [] }
        return reply.ids
    }

    // MARK: dispatch

    func handle(_ conn: IPCConnection) {
        guard let (req, fds) = try? conn.receive(Request.self) else { return }
        defer { fds.forEach { close($0) } }
        idle.beginRequest()
        defer { idle.endRequest() }
        let reply: Reply
        do {
            reply = try dispatch(req, fds: fds, conn: conn)
        } catch let e as ServiceError {
            reply = .failure(message: e.message, code: e.code)
        } catch let e as RPCError {
            reply = .failure(message: e.message, code: e.code == .notFound && e.message == Messages.userNotFound ? ErrorCode.userNotFound : ErrorCode.service)
        } catch {
            reply = .failure(message: "\(error)", code: ErrorCode.service)
        }
        try? conn.send(reply)
        // After a shutdown, a replaced (updated) msld exits so the next msl starts the new one.
        if case .shutdown = req, executableReplaced, !vm.isRunning {
            log("executable was replaced on disk; exiting so the new build takes over")
            exit(0)
        }
    }

    func dispatch(_ req: Request, fds: [Int32], conn: IPCConnection) throws -> Reply {
        switch req {
        case .list:
            return .distros(summaries())
        case .status:
            let now = MSLConfig.load()
            let booted = vm.isRunning ? vm.queue.sync { vm.booted } : nil
            let url = MSLConfig.defaultURL
            let status = VMStatus(running: booted != nil,
                                  uptimeSeconds: booted.map { Date().timeIntervalSince($0.at) },
                                  effective: booted?.settings,
                                  configured: VMHost.resolve(now),
                                  configPath: url.path,
                                  configExists: FileManager.default.fileExists(atPath: url.path))
            return .status(distros: summaries(), vm: status)
        case .versionInfo:
            return .versionInfo(kernel: (try? Resources.locate().kernelVersion) ?? "unknown")
        case .setDefault(let name):
            let d = try find(name)
            try registry.mutate { $0.defaultId = d.id }
            return .ok
        case .terminate(let name):
            let d = try find(name)
            if vm.isRunning {
                let mini = try guest.miniInit
                _ = try blocking { try await mini.stopDistro(.with { $0.id = d.id }) }
            }
            return .ok
        case .shutdown(let force):
            shutdown(force: force)
            return .ok
        case .unregister(let name):
            let d = try find(name)
            files.unmount(name: d.name)  // before the guest drops its export
            try bootVM()
            let mini = try guest.miniInit
            _ = try blocking { try await mini.deleteDistro(.with { $0.id = d.id }) }
            try registry.mutate { $0.distros.removeAll { $0.id == d.id } }
            files.syncLinks()
            return .ok
        case .export(let name, let format):
            let d = try find(name)
            try export(d, format: format, to: fds[0])
            return .ok
        case .importTar(let name, let location):
            guard Registry.isValidName(name) else {
                throw ServiceError(Messages.invalidDistributionName(name), code: ErrorCode.invalidName)
            }
            guard registry.find(name: name) == nil else {
                throw ServiceError(Messages.distroNameAlreadyExists, code: ErrorCode.alreadyExists)
            }
            _ = try importDistro(name: name, location: location, from: fds[0])
            return .ok
        case .installFromFile(let name, let location, _):
            if let name {
                guard Registry.isValidName(name) else {
                    throw ServiceError(Messages.invalidDistributionName(name), code: ErrorCode.invalidName)
                }
                guard registry.find(name: name) == nil else {
                    throw ServiceError(Messages.distroNameAlreadyExists, code: ErrorCode.alreadyExists)
                }
            }
            let rec = try importDistro(name: name, location: location, from: fds[0])
            return .installed(name: rec.name)
        case .mount(let m):
            return try mount(m)
        case .unmount(let disk):
            try unmount(disk)
            return .ok
        case .manage(let name, let op):
            try manage(try find(name), op)
            return .ok
        case .run(let r):
            guard fds.count == 3 else { throw ServiceError("missing stdio", code: ErrorCode.invalidArgument) }
            return .exited(try run(r, stdio: fds, conn: conn))
        case .debugShell(let r):
            guard fds.count == 3 else { throw ServiceError("missing stdio", code: ErrorCode.invalidArgument) }
            try bootVM()
            let agent = try guest.agent(port: VMHost.controlPort)  // mini-init also serves Agent
            var req = Msl_V1_RunRequest()
            req.cwd = "/"
            req.env = r.env
            apply(r, to: &req)
            let events = EventRouter(conn: conn)
            defer { events.finish() }
            return .exited(try session(agent: agent, request: req, stdio: fds, events: events))
        }
    }

    // MARK: helpers

    func find(_ name: String) throws -> DistroRecord {
        guard let d = registry.find(name: name) else {
            throw ServiceError(Messages.distroNotFound, code: ErrorCode.distroNotFound)
        }
        return d
    }

    func bootVM() throws {
        try bootLock.withLock {
            if vm.isRunning { return }
            config = MSLConfig.load()
            for w in config.warnings { log("msl: \(w)") }
            do {
                try vm.ensureRunning(config: config)
            } catch where executableReplaced {
                throw ServiceError("msld was updated on disk while running and can no longer start the virtual machine.\nRun 'msl --shutdown' to restart it.", code: ErrorCode.vm)
            }
            try guest.waitForMiniInit(timeout: 15)
            if config.localhostForwarding { forwarder.start() }
            if config.dnsTunneling { vm.listen(port: DNSProxy.vsockPort) { DNSProxy.handle($0) } }
            files.start()
        }
    }

    func summaries() -> [DistroSummary] {
        var running = Set<String>()
        if vm.isRunning, let mini = try? guest.miniInit,
           let reply = try? blocking({ try await mini.listRunning(Msl_V1_Empty()) }) {
            running = Set(reply.ids)
        }
        let def = registry.defaultDistro?.id
        return registry.all.map {
            DistroSummary(name: $0.name, id: $0.id, running: running.contains($0.id), version: $0.version, isDefault: $0.id == def)
        }
    }

    func shutdown(force: Bool) {
        guard vm.isRunning else { return }
        files.shutdown()  // unmount while the server is still up
        if !force, let mini = try? guest.miniInit, (try? blocking({ try await mini.shutdown(Msl_V1_Empty()) })) != nil,
           vm.waitForStop(timeout: 10) {
            return
        }
        vm.stop()
    }

    // MARK: mount

    func mount(_ m: MountSpec) throws -> Reply {
        let path = (m.disk as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw ServiceError("Failed to attach disk '\(m.disk)' to the VM: no such file or device.", code: ErrorCode.fileNotFound)
        }
        if diskLock.withLock({ disks[path] }) != nil {
            throw ServiceError("The disk '\(m.disk)' is already attached.", code: ErrorCode.alreadyExists)
        }
        var mountName = m.name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        if m.name == nil, let p = m.partition { mountName += "p\(p)" }
        let name = mountName
        try bootVM()
        let mini = try guest.miniInit
        let before = try blocking { try await mini.listDisks(Msl_V1_Empty()) }.names
        let device = try vm.attachDisk(path: path, readOnly: false)
        do {
            let reply = try blocking {
                try await mini.mountDisk(.with {
                    $0.before = before
                    $0.name = name
                    $0.fstype = m.type ?? ""
                    $0.options = m.options ?? ""
                    $0.partition = UInt32(m.partition ?? 0)
                    $0.bare = m.bare
                })
            }
            diskLock.withLock { disks[path] = (device, m.bare ? "" : name) }
            return .mounted(device: reply.device, mountPoint: reply.mountPoint)
        } catch let e as RPCError {
            if m.bare || e.code == .invalidArgument || e.code == .alreadyExists || e.code == .deadlineExceeded {
                vm.detachDisk(device)
                throw ServiceError(e.message, code: ErrorCode.invalidArgument)
            }
            // WSL keeps the disk attached when only the mount failed.
            diskLock.withLock { disks[path] = (device, "") }
            throw ServiceError("The disk was attached but failed to mount: \(e.message).\nFor more details, run 'dmesg' in `msl --debug-shell`.\nTo detach the disk, run 'msl --unmount \(m.disk)'.", code: ErrorCode.service)
        }
    }

    func unmount(_ disk: String?) throws {
        let targets: [(String, (device: AnyObject, name: String))] = try diskLock.withLock {
            if let disk {
                let path = (disk as NSString).standardizingPath
                guard let d = disks[path] else {
                    throw ServiceError("The disk '\(disk)' is not attached.", code: ErrorCode.fileNotFound)
                }
                return [(path, d)]
            }
            return Array(disks)
        }
        for (path, d) in targets {
            if !d.name.isEmpty, let mini = try? guest.miniInit {
                _ = try? blocking { try await mini.unmountDisk(.with { $0.name = d.name }) }
            }
            vm.detachDisk(d.device)
            _ = diskLock.withLock { disks.removeValue(forKey: path) }
        }
    }

    // MARK: manage

    func manage(_ d: DistroRecord, _ op: ManageOp) throws {
        switch op {
        case .setDefaultUser(let user):
            let agent = try startDistro(d)
            let reply = try blocking { try await agent.lookupUser(.with { $0.name = user }) }
            guard reply.found else { throw ServiceError(Messages.userNotFound, code: ErrorCode.userNotFound) }
            try registry.update(id: d.id) { $0.defaultUid = reply.uid }
        case .move:
            // All distros are directories on the shared data disk, so there's no
            // per-distro file to move. Refuse rather than pretend.
            throw ServiceError("Failed to move distribution.\nAll distributions share one disk, so a single distribution can't be moved.", code: ErrorCode.unsupported)
        case .setSparse:
            break  // the data disk is always sparse
        case .resize:
            // All distros share one sparse data disk (256 GiB). Growing it needs an
            // offline resize2fs: the formatter uses sparse_super2, which rules out
            // online ext4 resizing (see issue #3).
            throw ServiceError("Failed to resize disk.\nAll distributions share one sparse 256 GiB disk, which can't be resized yet.", code: ErrorCode.unsupported)
        case .compact:
            try bootVM()
            let mini = try guest.miniInit
            let reply = try blocking { try await mini.compactDisk(Msl_V1_Empty()) }
            log("compact: trimmed \(reply.trimmedBytes >> 20) MiB")
        }
    }

    // MARK: import / export

    func importDistro(name: String?, location: String?, from input: Int32) throws -> DistroRecord {
        try bootVM()
        let id = UUID().uuidString.lowercased()
        let mini = try guest.miniInit
        let vm = self.vm
        let done: Msl_V1_ImportDistroDone
        do {
            done = try blocking {
                try await mini.importDistro(.with { $0.id = id }) { response in
                    var pumping = false
                    let finished = Completion()
                    for try await event in response.messages {
                        switch event.event {
                        case .dataPort(let port):
                            let v = try vm.connect(port: port)
                            pumping = true
                            let b = FramedBridge(vsock: v, localIn: input, localOut: nil)
                            Task { await b.sent.wait(); finished.signal() }
                        case .done(let d):
                            if pumping { await finished.wait() }
                            return d
                        case .none: break
                        }
                    }
                    throw ServiceError(Messages.importFailed, code: ErrorCode.importFailed)
                }
            }
        } catch let e as RPCError {
            throw ServiceError(Messages.importFailed + "\n\(e.message)", code: ErrorCode.importFailed)
        }

        let conf = done.distributionConf
        let finalName = name ?? (conf.oobeDefaultName.isEmpty ? nil : conf.oobeDefaultName)
        func discard() { _ = try? blocking { try await mini.deleteDistro(.with { $0.id = id }) } }
        guard let finalName else {
            discard()
            throw ServiceError(Messages.distributionNameNeeded, code: ErrorCode.nameNeeded)
        }
        guard registry.find(name: finalName) == nil else {
            discard()
            throw ServiceError(Messages.distroNameAlreadyExists, code: ErrorCode.alreadyExists)
        }
        var rec = DistroRecord(id: id, name: finalName, location: location ?? paths.root.appendingPathComponent("distros/\(id)").path)
        rec.oobeCommand = conf.oobeCommand
        rec.oobeDefaultUid = conf.hasOobeDefaultUid ? conf.oobeDefaultUid : nil
        rec.oobePending = !conf.oobeCommand.isEmpty
        try registry.mutate { $0.distros.append(rec) }
        files.syncLinks()
        log("imported \(finalName) (\(id)): \(done.entries) entries")
        return rec
    }

    func export(_ d: DistroRecord, format: String, to output: Int32) throws {
        let fmt: Msl_V1_ExportFormat
        switch format {
        case "", "tar": fmt = .tar
        case "tar.gz", "tgz": fmt = .tarGz
        case "tar.xz": fmt = .tarXz
        default: throw ServiceError(Messages.unsupportedOnMacOS("--format \(format)"), code: ErrorCode.unsupported)
        }
        try bootVM()
        let mini = try guest.miniInit
        let vm = self.vm
        _ = try blocking {
            try await mini.exportDistro(.with { $0.id = d.id; $0.format = fmt }) { response in
                var pumping = false
                let finished = Completion()
                for try await event in response.messages {
                    switch event.event {
                    case .dataPort(let port):
                        let v = try vm.connect(port: port)
                        pumping = true
                        let b = FramedBridge(vsock: v, localIn: nil, localOut: output)
                        Task { await b.delivered.wait(); finished.signal() }
                    case .done:
                        if pumping { await finished.wait() }
                        return true
                    case .none: break
                    }
                }
                return false
            }
        }
    }

    // MARK: run

    func resolveDistro(_ spec: RunSpec) throws -> DistroRecord {
        if let id = spec.distributionId {
            guard let d = registry.find(id: id) else { throw ServiceError(Messages.distroNotFound, code: ErrorCode.distroNotFound) }
            return d
        }
        if let name = spec.distribution { return try find(name) }
        guard let d = registry.defaultDistro else {
            throw ServiceError(Messages.noDefaultDistro, code: ErrorCode.noDistros)
        }
        return d
    }

    func startDistro(_ d: DistroRecord) throws -> Msl_V1_Agent.Client<Transport> {
        try bootVM()
        let mini = try guest.miniInit
        let host = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "msl"
        let dns = config.dnsTunneling
        let reply = try blocking {
            try await mini.startDistro(.with { $0.id = d.id; $0.name = d.name; $0.hostname = host; $0.dnsTunneling = dns })
        }
        return try guest.agent(port: reply.agentPort)
    }

    func run(_ r: RunRequest, stdio: [Int32], conn: IPCConnection) throws -> Int32 {
        var d = try resolveDistro(r.spec)
        let agent = try startDistro(d)
        let events = EventRouter(conn: conn)
        defer { events.finish() }
        idle.beginSession(distro: d.id)
        defer { idle.endSession(distro: d.id) }
        let interactiveShell = r.spec.commandLine == nil && r.spec.argv.isEmpty && r.stdinTTY

        if d.oobePending && interactiveShell {
            var oobe = Msl_V1_RunRequest()
            oobe.argv = ["/bin/sh", "-c", d.oobeCommand]
            oobe.shellType = .none
            oobe.user = "root"
            oobe.cwd = "/"
            // WSL_DISTRO_NAME only here: Ubuntu's wsl-setup uses `set -u`.
            oobe.env = r.env.merging(["WSL_DISTRO_NAME": d.name, "MSL_MAC_USER": NSUserName()]) { $1 }
            apply(r, to: &oobe)
            let code = try session(agent: agent, request: oobe, stdio: stdio, events: events)
            guard code == 0 else { return code }
            try registry.update(id: d.id) {
                $0.oobePending = false
                if let uid = $0.oobeDefaultUid { $0.defaultUid = uid }
            }
            d = registry.find(id: d.id) ?? d
        }

        var req = Msl_V1_RunRequest()
        req.user = r.spec.user ?? ""
        req.defaultUid = d.defaultUid
        switch r.spec.shellType {
        case .none: req.shellType = .none; req.argv = r.spec.argv
        case .login: req.shellType = .login
        case .standard: req.shellType = .standard
        }
        req.commandLine = r.spec.commandLine ?? ""
        if req.shellType == .none && req.argv.isEmpty { req.shellType = .standard }  // `msl --shell-type none` alone: default shell
        // With no --cd, the guest maps the Mac cwd under the distro's [automount] root.
        req.cwd = r.spec.cd ?? ""
        req.macCwd = r.macCwd
        req.env = r.env.merging(["MSL_MAC_VIEW": FileView.viewDir.path]) { $1 }
        req.mslenv = r.mslenv
        req.mslenvValues = r.mslenvValues
        req.macHome = r.macHome
        apply(r, to: &req)
        return try session(agent: agent, request: req, stdio: stdio, events: events)
    }

    private func apply(_ r: RunRequest, to req: inout Msl_V1_RunRequest) {
        req.stdinTty = r.stdinTTY
        req.stdoutTty = r.stdoutTTY
        req.stderrTty = r.stderrTTY
        req.rows = UInt32(r.rows)
        req.cols = UInt32(r.cols)
    }

    /// Run one process: bridge msl's stdio to the guest streams, forward
    /// resize/signal events, return the exit code.
    func session(agent: Msl_V1_Agent.Client<Transport>, request: Msl_V1_RunRequest, stdio: [Int32], events: EventRouter) throws -> Int32 {
        let vm = self.vm
        let stop = StopFlag()
        let bridges = BridgeSet()
        defer { events.detach() }

        let code: Int32 = try blocking {
            try await agent.run(request) { response in
                var exit: Int32 = 255
                for try await event in response.messages {
                    switch event.event {
                    case .started(let s):
                        events.attach(agent: agent, session: s.sessionID)
                        func open(_ port: UInt32) throws -> Int32? { port == 0 ? nil : try vm.connect(port: port) }
                        if let tty = try open(s.ttyPort) {
                            let sink = request.stdoutTty ? stdio[1] : request.stderrTty ? stdio[2] : stdio[1]
                            bridges.add(FramedBridge(vsock: tty, localIn: request.stdinTty ? stdio[0] : nil, localOut: sink, stop: stop), output: true)
                        }
                        if let sin = try open(s.stdinPort) {
                            bridges.add(FramedBridge(vsock: sin, localIn: stdio[0], localOut: nil, stop: stop), output: false)
                        }
                        if let sout = try open(s.stdoutPort) {
                            bridges.add(FramedBridge(vsock: sout, localIn: nil, localOut: stdio[1]), output: true)
                        }
                        if let serr = try open(s.stderrPort) {
                            bridges.add(FramedBridge(vsock: serr, localIn: nil, localOut: stdio[2]), output: true)
                        }
                    case .exited(let e):
                        exit = e.code
                    case .none:
                        break
                    }
                }
                return exit
            }
        }
        // Deliver all output (however slow the reader); stop only waiting on a
        // stream the guest gave up on (a background process keeps it open).
        for b in bridges.outputs {
            while !b.delivered.isSignaled && !b.quiet(for: 2) { usleep(20_000) }
        }
        stop.set()
        bridges.all.forEach { $0.abort() }
        return code
    }
}

final class BridgeSet: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(FramedBridge, Bool)] = []
    func add(_ b: FramedBridge, output: Bool) { lock.withLock { items.append((b, output)) } }
    var outputs: [FramedBridge] { lock.withLock { items.filter(\.1).map(\.0) } }
    var all: [FramedBridge] { lock.withLock { items.map(\.0) } }
}

/// Reads resize/signal events from one msl connection (a single reader for the
/// connection's lifetime) and routes them to the session currently running on it.
final class EventRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var target: (Msl_V1_Agent.Client<Transport>, UInt64)?
    private var finished = false

    init(conn: IPCConnection) {
        Thread.detachNewThread { [self] in
            while true {
                guard let (ev, extra) = try? conn.receive(ClientEvent.self) else {
                    // msl went away (or the run completed and msld closed the socket).
                    if let (agent, id) = current(), !isFinished {
                        _ = try? blocking { try await agent.signal(.with { $0.sessionID = id; $0.signal = SIGHUP }) }
                    }
                    return
                }
                extra.forEach { close($0) }
                guard let (agent, id) = current() else { continue }
                switch ev {
                case .resize(let rows, let cols):
                    _ = try? blocking { try await agent.resize(.with { $0.sessionID = id; $0.rows = UInt32(rows); $0.cols = UInt32(cols) }) }
                case .signal(let sig):
                    _ = try? blocking { try await agent.signal(.with { $0.sessionID = id; $0.signal = sig }) }
                }
            }
        }
    }

    private func current() -> (Msl_V1_Agent.Client<Transport>, UInt64)? { lock.withLock { target } }
    private var isFinished: Bool { lock.withLock { finished } }
    func attach(agent: Msl_V1_Agent.Client<Transport>, session: UInt64) { lock.withLock { target = (agent, session) } }
    func detach() { lock.withLock { target = nil } }
    func finish() { lock.withLock { finished = true; target = nil } }
}

/// Session and request bookkeeping for the idle timeouts.
final class IdleTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: Int] = [:]
    private var idleSince: [String: Date] = [:]
    private var vmIdleSince = Date()
    private var requests = 0

    var activeRequests: Int { lock.withLock { requests } }
    func beginRequest() { lock.withLock { requests += 1 } }
    func endRequest() { lock.withLock { requests -= 1; vmIdleSince = Date() } }

    func beginSession(distro: String) { lock.withLock { sessions[distro, default: 0] += 1 } }
    func endSession(distro: String) {
        lock.withLock {
            sessions[distro, default: 1] -= 1
            if sessions[distro] == 0 { idleSince[distro] = Date() }
        }
    }

    /// How long a running distro has had no sessions (a distro started without a
    /// session, e.g. by import, counts from the first time it is seen).
    func idleMs(distro: String) -> Int {
        lock.withLock {
            if sessions[distro, default: 0] > 0 { return 0 }
            let since = idleSince[distro] ?? { idleSince[distro] = Date(); return Date() }()
            return Int(Date().timeIntervalSince(since) * 1000)
        }
    }

    func forget(distro: String) { lock.withLock { idleSince[distro] = nil } }
    func vmIdleMs() -> Int { lock.withLock { Int(Date().timeIntervalSince(vmIdleSince) * 1000) } }
    func resetVMIdle() { lock.withLock { vmIdleSince = Date() } }
}
