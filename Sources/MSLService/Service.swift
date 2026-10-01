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
    /// Set on SIGTERM/SIGINT (logout, restart, shutdown, launchctl bootout, #52):
    /// the VM is going down for good, so nothing may start it again.
    private var terminating = false
    private var signalSources: [DispatchSourceSignal] = []
    /// `msl --mount`: disk path -> (USB device, mount name). Cleared when the VM stops.
    private var disks: [String: (device: AnyObject, name: String)] = [:]
    private let diskLock = NSLock()
    private(set) lazy var forwarder = PortForwarder(vm: vm, guest: guest)
    private(set) lazy var files = FileView(vm: vm, paths: paths, registry: registry, guest: guest)
    /// The distros' own disks (#50).
    private(set) lazy var ownDisks = DistroDisks(vm: vm, guest: guest)

    public init(paths: Paths = Paths()) {
        self.paths = paths
        registry = Registry(url: paths.registry)
        vm = VMHost(paths: paths)
        guest = GuestClients(vm: vm)
        vm.onStop = { [weak self] in
            self?.diskLock.withLock { self?.disks.removeAll() }
            self?.ownDisks.reset()
            self?.forwarder.stopAll()
            self?.files.shutdown()
            self?.guest.reset()
            self?.idle.changed()
        }
        files.isViewable = { [weak self] d in d.disk == nil || self?.ownDisks.isAttached(d.id) == true }
        ownDisks.beforeDetach = { [weak self] id in
            if let d = self?.registry.find(id: id) { self?.files.unmount(name: d.name) }
        }
        ownDisks.onChange = { [weak self] in self?.files.syncLinks() }
        ownDisks.canRestartVM = { [weak self] in self?.vmIsIdle() ?? false }
        ownDisks.restartVM = { [weak self] in try self?.restartVM() }
    }

    public func serve() throws -> Never {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        // Started by launchd (the LaunchAgent, #52): it already listens on msld.sock.
        let launchd = launchdListener()
        let lfd = try launchd ?? listenUnix(paths.socket.path)
        _ = executableInode
        handleTermination()
        log("msld \(MSLBuild.displayVersion) listening on \(paths.socket.path)\(launchd != nil ? " (launchd)" : "")")
        serveConnect()
        startIdleMonitor()
        while true {
            let c = accept(lfd, nil, nil)
            if c < 0 { continue }
            Thread.detachNewThread { self.handle(IPCConnection(fd: c)) }
        }
    }

    /// Stops idle distros after [general] instanceIdleTimeout and the VM after
    /// [msl2] vmIdleTimeout (both in ms; -1 = never). Sleeps until the next of
    /// those deadlines or until requests, sessions or the VM change; no ticking.
    func startIdleMonitor() {
        Thread.detachNewThread {
            while true {
                guard self.vm.isRunning, self.idle.activeRequests == 0 else {
                    self.idle.resetVMIdle()
                    self.idle.waitForChange(until: nil)
                    continue
                }
                let now = Date()
                var next: Date?
                func due(inMs ms: Int) { next = min(next ?? .distantFuture, now.addingTimeInterval(Double(ms) / 1000)) }
                var stopped = false
                let running = self.runningIds()
                for id in running where self.config.instanceIdleTimeoutMs >= 0 {
                    let idleMs = self.idle.idleMs(distro: id)
                    if idleMs >= self.config.instanceIdleTimeoutMs, let mini = try? self.guest.miniInit {
                        log("instance idle timeout: stopping \(self.registry.find(id: id)?.name ?? id)")
                        _ = try? blocking { try await mini.stopDistro(.with { $0.id = id }) }
                        self.idle.forget(distro: id)
                        stopped = true
                    } else {
                        due(inMs: self.config.instanceIdleTimeoutMs - idleMs)
                    }
                }
                if stopped { continue }  // the VM's countdown may start now
                if ProcessInfo.processInfo.environment["MSL_DEBUG_IDLE"] != nil {
                    log("idle: requests=\(self.idle.activeRequests) running=\(running.count) vmIdleMs=\(self.idle.vmIdleMs()) limit=\(self.config.vmIdleTimeoutMs)")
                }
                if running.isEmpty {
                    if self.config.vmIdleTimeoutMs >= 0 {
                        let idleMs = self.idle.vmIdleMs()
                        if idleMs >= self.config.vmIdleTimeoutMs {
                            log("vm idle timeout: shutting down")
                            self.shutdown(force: false)
                            continue
                        }
                        due(inMs: self.config.vmIdleTimeoutMs - idleMs)
                    }
                } else {
                    self.idle.resetVMIdle()
                    // A distro can stop by itself (a shutdown inside it), which
                    // nothing announces: look again within a minute.
                    due(inMs: 60_000)
                }
                self.idle.waitForChange(until: next)
            }
        }
    }

    /// macOS sends SIGTERM at logout, restart and shutdown (and launchd waits
    /// ExitTimeOut for its jobs before SIGKILL): stop the distros quickly, unmount
    /// and flush their disks, then exit. Without this, the VM dies with msld.
    func handleTermination() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { [weak self] in self?.terminate(sig == SIGTERM ? "SIGTERM" : "SIGINT") }
            src.resume()
            signalSources.append(src)
        }
    }

    static let terminationGraceMs: UInt32 = 5000

    func terminate(_ why: String) {
        // Under bootLock: waits for a boot in progress, and no boot starts after.
        let first = bootLock.withLock { () -> Bool in
            defer { terminating = true }
            return !terminating
        }
        guard first else { return }
        log("\(why): shutting down")
        shutdown(force: false, graceMs: Self.terminationGraceMs)
        log("\(why): stopped; exiting")
        exit(0)
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
                                  configExists: FileManager.default.fileExists(atPath: url.path),
                                  disk: diskStatus(running: booted != nil), ownDisks: ownDisksStatus())
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
            try ownDisks.detach(d)
            let mini = try guest.miniInit
            _ = try blocking { try await mini.deleteDistro(.with { $0.id = d.id }) }
            try registry.mutate { $0.distros.removeAll { $0.id == d.id } }
            files.syncLinks()
            if let disk = d.disk { removeDisk(disk, location: d.location) }  // as WSL deletes ext4.vhdx
            return .ok
        case .export(let name, let format, let direct):
            let d = try find(name)
            try export(d, format: format, to: fds[0], direct: direct == true ? conn : nil)
            return .ok
        case .connect(let distro, let unix, let tcp):
            return try connectStream(distro: distro, unix: unix, tcp: tcp, conn: conn)
        case .importTar(let name, let location, let vhdSize, let direct):
            guard Registry.isValidName(name) else {
                throw ServiceError(Messages.invalidDistributionName(name), code: ErrorCode.invalidName)
            }
            guard registry.find(name: name) == nil else {
                throw ServiceError(Messages.distroNameAlreadyExists, code: ErrorCode.alreadyExists)
            }
            _ = try importDistro(name: name, location: location, vhdSize: vhdSize, from: fds[0], direct: direct == true ? conn : nil)
            return .ok
        case .installFromFile(let name, let location, _, let vhdSize, let direct):
            if let name {
                guard Registry.isValidName(name) else {
                    throw ServiceError(Messages.invalidDistributionName(name), code: ErrorCode.invalidName)
                }
                guard registry.find(name: name) == nil else {
                    throw ServiceError(Messages.distroNameAlreadyExists, code: ErrorCode.alreadyExists)
                }
            }
            let rec = try importDistro(name: name, location: location, vhdSize: vhdSize, from: fds[0], direct: direct == true ? conn : nil)
            return .installed(name: rec.name)
        case .exportDisk(let name, let path):
            try exportDisk(try find(name), to: URL(fileURLWithPath: path))
            return .ok
        case .importDisk(let name, let location, let image):
            try checkNewName(name)
            _ = try importImage(name: name, image: URL(fileURLWithPath: image), copyTo: URL(fileURLWithPath: location))
            return .ok
        case .importInPlace(let name, let image):
            try checkNewName(name)
            _ = try importImage(name: name, image: URL(fileURLWithPath: image), copyTo: nil)
            return .ok
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
            return .exited(try session(agent: agent, request: req, stdio: fds, events: events, direct: r.direct == true ? conn : nil))
        }
    }

    func directSession(agent: Msl_V1_Agent.Client<Transport>, request: Msl_V1_RunRequest, conn: IPCConnection, events: EventRouter) throws -> Int32 {
        defer { events.detach() }
        var token = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&token, token.count)
        let anyTTY = request.stdinTty || request.stdoutTty || request.stderrTty
        let wanted = (tty: anyTTY, stdin: !request.stdinTty, stdout: !request.stdoutTty, stderr: !request.stderrTty)
        let streams = [wanted.tty, wanted.stdin, wanted.stdout, wanted.stderr].map { $0 ? vm.acceptStream(token: token) : nil }
        var dial = request
        dial.dialBack = .with {
            $0.token = Data(token)
            $0.ttyPort = streams[0]?.port ?? 0
            $0.stdinPort = streams[1]?.port ?? 0
            $0.stdoutPort = streams[2]?.port ?? 0
            $0.stderrPort = streams[3]?.port ?? 0
        }
        let req = dial
        return try blocking {
            try await agent.run(req) { response in
                var exit: Int32 = 255
                for try await event in response.messages {
                    switch event.event {
                    case .started(let s):
                        events.attach(agent: agent, session: s.sessionID)
                        let fds = try streams.compactMap { try $0?.wait() }
                        defer { fds.forEach { close($0) } }
                        try conn.send(Reply.streams(tty: wanted.tty, stdin: wanted.stdin, stdout: wanted.stdout, stderr: wanted.stderr), fds: fds)
                    case .exited(let e):
                        exit = e.code
                    case .none:
                        break
                    }
                }
                return exit
            }
        }
    }

    /// A stream the guest dials back, handed to msl as `.stream` when it
    /// arrives: msl reads or writes the data itself (a `direct` request).
    func handOff(to conn: IPCConnection) -> Msl_V1_HostStream {
        var token = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&token, token.count)
        let s = vm.acceptStream(token: token)
        Thread.detachNewThread {
            guard let fd = try? s.wait() else { return }  // the guest failed first: its error is the reply
            try? conn.send(Reply.stream, fds: [fd])
            close(fd)
        }
        return .with { $0.token = Data(token); $0.port = s.port }
    }

    /// `msl --connect`: open the target in the distro, hand msl the stream, and
    /// count it as a session until msl disconnects (VS Code's managed pipes).
    func connectStream(distro: String, unix: String?, tcp: UInt16?, conn: IPCConnection) throws -> Reply {
        let d = try find(distro)
        _ = try startDistro(d)
        // One stream per direction (see OpenStreamRequest).
        var token = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&token, token.count)
        let out = vm.acceptStream(token: token)
        let inp = vm.acceptStream(token: token)
        let mini = try guest.miniInit
        let toHost = Msl_V1_HostStream.with { $0.token = Data(token); $0.port = out.port }
        let fromHost = Msl_V1_HostStream.with { $0.token = Data(token); $0.port = inp.port }
        do {
            _ = try blocking {
                try await mini.openStream(.with {
                    $0.stream = toHost
                    $0.fromHost = fromHost
                    $0.distroID = d.id
                    $0.uid = d.defaultUid
                    if let unix { $0.unixPath = unix }
                    if let tcp { $0.tcpPort = UInt32(tcp) }
                })
            }
        } catch let e as RPCError {
            vm.unlisten(port: out.port)
            vm.unlisten(port: inp.port)
            throw ServiceError(e.message, code: ErrorCode.service)
        }
        let fds = [try inp.wait(), try out.wait()]
        try conn.send(Reply.streams(tty: false, stdin: true, stdout: true, stderr: false), fds: fds)
        fds.forEach { close($0) }
        idle.beginSession(distro: d.id)
        defer { idle.endSession(distro: d.id) }
        // msl holds the connection open for as long as it uses the stream.
        while (try? conn.receive(ClientEvent.self)) != nil {}
        return .ok
    }

    // MARK: helpers

    func checkNewName(_ name: String) throws {
        guard Registry.isValidName(name) else {
            throw ServiceError(Messages.invalidDistributionName(name), code: ErrorCode.invalidName)
        }
        guard registry.find(name: name) == nil else {
            throw ServiceError(Messages.distroNameAlreadyExists, code: ErrorCode.alreadyExists)
        }
    }

    func find(_ name: String) throws -> DistroRecord {
        guard let d = registry.find(name: name) else {
            throw ServiceError(Messages.distroNotFound, code: ErrorCode.distroNotFound)
        }
        return d
    }

    func bootVM() throws {
        try bootLock.withLock {
            if terminating { throw ServiceError("msld is shutting down (macOS is logging out or restarting, or it was stopped). Try again in a few seconds.", code: ErrorCode.vm) }
            if vm.isRunning { return }
            vm.awaitTeardown()  // the previous VM's cleanup must not land on this boot
            config = MSLConfig.load()
            for w in config.warnings { log("msl: \(w)") }
            do {
                let plan = ownDisks.bootPlan(registry.all, defaultId: registry.defaultDistro?.id)
                ownDisks.booted(try vm.ensureRunning(config: config, disks: plan))
            } catch where executableReplaced {
                throw ServiceError("msld was updated on disk while running and can no longer start the virtual machine.\nRun 'msl --shutdown' to restart it.", code: ErrorCode.vm)
            }
            try guest.waitForMiniInit(timeout: 15)
            ownDisks.attachAll(registry.all)
            if config.localhostForwarding { forwarder.start() }
            if config.dnsTunneling { vm.listen(port: DNSProxy.vsockPort) { DNSProxy.handle($0) } }
            files.start(transport: config.fileViewTransport)
            idle.changed()
        }
    }

    /// Nothing depends on the running VM but this request: no distro runs, no
    /// other request is in progress, and no `--mount` disk is attached.
    func vmIsIdle() -> Bool {
        vm.isRunning && idle.activeRequests <= 1 && diskLock.withLock({ disks.isEmpty }) && runningIds().isEmpty
    }

    /// Stop the VM and boot it again (to attach a new distro disk at boot).
    func restartVM() throws {
        shutdown(force: false)
        guard !vm.isRunning else {
            throw ServiceError("The virtual machine didn't stop.", code: ErrorCode.vm)
        }
        try bootVM()
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

    /// `graceMs`: how long distros get to stop (0: the guest's default, 10 s).
    func shutdown(force: Bool, graceMs: UInt32 = 0) {
        guard vm.isRunning else { return }
        files.shutdown()  // unmount while the server is still up
        if !force, let mini = try? guest.miniInit, (try? blocking({ try await mini.shutdown(.with { $0.graceMs = graceMs }) })) != nil,
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

    /// The distros' own disks, added up (nil when there are none).
    func ownDisksStatus() -> OwnDisksStatus? {
        let sizes = registry.all.compactMap { $0.disk.flatMap { DiskImage.sizes(URL(fileURLWithPath: $0.path)) } }
        guard !sizes.isEmpty else { return nil }
        return OwnDisksStatus(count: sizes.count, maxBytes: sizes.reduce(0) { $0 + $1.max }, macUsedBytes: sizes.reduce(0) { $0 + $1.used },
                              macFreeBytes: VMHost.volumeAvailable(paths.root))
    }

    /// data.img, while some distro is still kept on it.
    func diskStatus(running: Bool) -> DiskStatus? {
        guard registry.all.contains(where: { $0.disk == nil }) else { return nil }
        let url = paths.dataDisk
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]), let size = v.fileSize else { return nil }
        var inVM: UInt64?
        if running, let mini = try? guest.miniInit, let ping = try? blocking({ try await mini.ping(Msl_V1_Empty()) }), ping.dataTotalBytes > 0 {
            inVM = ping.dataFreeBytes
        }
        return DiskStatus(maxBytes: UInt64(size), macUsedBytes: UInt64(v.totalFileAllocatedSize ?? 0),
                          macFreeBytes: VMHost.volumeAvailable(paths.root), distroFreeBytes: inVM)
    }

    /// Grow data.img, which every distro shares. The formatter's sparse_super2
    /// rules out online ext4 resizing, so: stop the VM, make the file larger,
    /// and boot; mini-init runs e2fsck and resize2fs before mounting it.
    func resizeDataDisk(_ requested: String) throws {
        let url = paths.dataDisk
        let current = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        switch DataDisk.checkGrow(current: current, requested: requested, volumeCapacity: VMHost.volumeCapacity(paths.root)) {
        case .unchanged:
            return
        case .refused(let why):
            throw ServiceError("Failed to resize disk.\n\(why)", code: ErrorCode.invalidArgument)
        case .grow(let size):
            if summaries().contains(where: \.running) {
                throw ServiceError("Failed to resize disk.\nAll distributions share the disk, so they must all be stopped first: run 'msl --shutdown'.", code: ErrorCode.invalidArgument)
            }
            shutdown(force: false)
            guard !vm.isRunning else {
                throw ServiceError("Failed to resize disk.\nThe virtual machine didn't stop.", code: ErrorCode.vm)
            }
            let fh = try FileHandle(forWritingTo: url)
            defer { try? fh.close() }
            try fh.truncate(atOffset: size)  // sparse: nothing is written
            log("data disk: \(StatusFormat.bytes(current)) → \(StatusFormat.bytes(size)); growing at boot")
            try bootVM()
            let mini = try guest.miniInit
            let ping = try blocking { try await mini.ping(Msl_V1_Empty()) }
            guard ping.dataGrow.hasPrefix("grew") else {
                throw ServiceError("Failed to resize disk.\nThe file is now \(StatusFormat.bytes(size)), but the filesystem wasn't grown: \(ping.dataGrow.isEmpty ? "no result from the VM" : ping.dataGrow)", code: ErrorCode.service)
            }
            log("data disk: \(ping.dataGrow)")
        }
    }

    func manage(_ d: DistroRecord, _ op: ManageOp) throws {
        switch op {
        case .setDefaultUser(let user):
            let agent = try startDistro(d)
            let reply = try blocking { try await agent.lookupUser(.with { $0.name = user }) }
            guard reply.found else { throw ServiceError(Messages.userNotFound, code: ErrorCode.userNotFound) }
            try registry.update(id: d.id) { $0.defaultUid = reply.uid }
        case .move(let dir):
            try move(d, to: URL(fileURLWithPath: dir).standardizedFileURL)
        case .setSparse:
            break  // disks are always sparse
        case .resize(let requested):
            if d.disk == nil {
                try resizeDataDisk(requested)
            } else {
                try resizeDisk(d, requested)
            }
        case .compact:
            try bootVM()
            let mini = try guest.miniInit
            let reply = try blocking { try await mini.compactDisk(Msl_V1_Empty()) }
            log("compact: trimmed \(reply.trimmedBytes >> 20) MiB")
        }
    }

    // MARK: import / export

    /// Import a rootfs tar as a new distro on its own disk: `<location>/ext4.img`
    /// (the location defaults to msl's `distros/<id>`). With MSL_LEGACY_STORE
    /// set (tests), it goes to the shared data.img instead, as before #50.
    func importDistro(name: String?, location: String?, vhdSize: UInt64?, from input: Int32, direct: IPCConnection? = nil) throws -> DistroRecord {
        let id = UUID().uuidString.lowercased()
        let folder = URL(fileURLWithPath: location ?? paths.root.appendingPathComponent("distros/\(id)").path).standardizedFileURL
        var rec = DistroRecord(id: id, name: name ?? "", location: folder.path)
        if ProcessInfo.processInfo.environment["MSL_LEGACY_STORE"] == nil {
            // Created before the VM boots, it's attached at boot.
            rec.disk = try createDisk(in: folder, vhdSize: vhdSize)
            ownDisks.prepare(rec)
        }
        // Undo everything if the import doesn't end up registered.
        var registered = false
        defer {
            ownDisks.forget(id)
            if !registered {
                if rec.disk != nil { try? ownDisks.detach(rec) }
                if let mini = try? guest.miniInit { _ = try? blocking { try await mini.deleteDistro(.with { $0.id = id }) } }
                if let disk = rec.disk { removeDisk(disk, location: rec.location) }
            }
        }
        try bootVM()
        try ownDisks.ensureAttached(rec)
        let mini = try guest.miniInit
        let vm = self.vm
        let done: Msl_V1_ImportDistroDone
        let stream = direct.map { handOff(to: $0) }
        do {
            done = try blocking {
                try await mini.importDistro(.with { $0.id = id; if let s = stream { $0.stream = s } }) { response in
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
        try register(&rec, name: name, conf: done.distributionConf)
        registered = true
        log("imported \(rec.name) (\(id)): \(done.entries) entries\(rec.disk.map { " on \($0.path)" } ?? "")")
        return rec
    }

    /// Name the new distro (from the request or its wsl-distribution.conf) and add it to the registry.
    func register(_ rec: inout DistroRecord, name: String?, conf: Msl_V1_DistributionConf) throws {
        guard let finalName = name ?? (conf.oobeDefaultName.isEmpty ? nil : conf.oobeDefaultName) else {
            throw ServiceError(Messages.distributionNameNeeded, code: ErrorCode.nameNeeded)
        }
        rec.name = finalName
        rec.oobeCommand = conf.oobeCommand
        rec.oobeDefaultUid = conf.hasOobeDefaultUid ? conf.oobeDefaultUid : nil
        rec.oobePending = !conf.oobeCommand.isEmpty
        let new = rec
        try registry.mutate {
            guard !$0.distros.contains(where: { $0.name.caseInsensitiveCompare(finalName) == .orderedSame }) else {
                throw ServiceError(Messages.distroNameAlreadyExists, code: ErrorCode.alreadyExists)
            }
            $0.distros.append(new)
        }
        files.syncLinks()
    }

    /// A new, empty own disk: `<folder>/ext4.img`.
    func createDisk(in folder: URL, vhdSize: UInt64?) throws -> DistroDiskInfo {
        let image = folder.appendingPathComponent(DistroDisk.fileName)
        guard !FileManager.default.fileExists(atPath: image.path) else {
            throw ServiceError("A distribution's disk already exists at \(image.path).\nChoose another location.", code: ErrorCode.alreadyExists)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let configured = (vm.isRunning ? config : MSLConfig.load()).defaultVhdSize
            let size = DistroDisk.initialSize(requested: vhdSize, configured: configured, volumeCapacity: VMHost.volumeCapacity(folder))
            let disk = try DiskImage.create(at: image, size: size)
            log("created disk \(image.path) (\(StatusFormat.bytes(size)))")
            return disk
        } catch {
            try? FileManager.default.removeItem(at: image)
            throw ServiceError("Failed to create the distribution's disk at \(image.path).\n\(error.localizedDescription)", code: ErrorCode.service)
        }
    }

    /// Delete an own disk, and its folder if nothing else is left in it.
    func removeDisk(_ disk: DistroDiskInfo, location: String) {
        do {
            try FileManager.default.removeItem(atPath: disk.path)
            log("deleted disk \(disk.path)")
        } catch {
            log("could not delete disk \(disk.path): \(error.localizedDescription)")
        }
        let folder = URL(fileURLWithPath: location)
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    func export(_ d: DistroRecord, format: String, to output: Int32, direct: IPCConnection? = nil) throws {
        let fmt: Msl_V1_ExportFormat
        switch format {
        case "", "tar": fmt = .tar
        case "tar.gz", "tgz": fmt = .tarGz
        case "tar.xz": fmt = .tarXz
        default: throw ServiceError(Messages.unsupportedOnMacOS("--format \(format)"), code: ErrorCode.unsupported)
        }
        try bootVM()
        try ownDisks.ensureAttached(d)
        let mini = try guest.miniInit
        let vm = self.vm
        let stream = direct.map { handOff(to: $0) }
        _ = try blocking {
            try await mini.exportDistro(.with { $0.id = d.id; $0.format = fmt; if let s = stream { $0.stream = s } }) { response in
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
        try ownDisks.ensureAttached(d)
        let mini = try guest.miniInit
        let host = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "msl"
        let dns = config.dnsTunneling
        let own = d.disk != nil
        let reply = try blocking {
            try await mini.startDistro(.with { $0.id = d.id; $0.name = d.name; $0.hostname = host; $0.dnsTunneling = dns; $0.ownDisk = own })
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
            oobe.env = r.env.merging(["WSL_DISTRO_NAME": d.name, "MSL_MACOS_USER": NSUserName()]) { $1 }
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
        req.env = r.env.merging(["MSL_MACOS_VIEW": FileView.viewDir.path]) { $1 }
        req.mslenv = r.mslenv
        req.mslenvValues = r.mslenvValues
        req.macHome = r.macHome
        apply(r, to: &req)
        return try session(agent: agent, request: req, stdio: stdio, events: events, direct: r.direct == true ? conn : nil)
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
    /// Run one process. With `direct` (the msl connection of a RunRequest.direct),
    /// the guest dials its streams back to one-shot host ports and msl gets their
    /// fds: msld only sets up and reports the exit. Otherwise msld relays msl's
    /// `stdio` through framed bridges.
    func session(agent: Msl_V1_Agent.Client<Transport>, request: Msl_V1_RunRequest, stdio: [Int32], events: EventRouter, direct: IPCConnection? = nil) throws -> Int32 {
        if let direct { return try directSession(agent: agent, request: request, conn: direct, events: events) }
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

    private let cond = NSCondition()
    private var pending = false

    var activeRequests: Int { lock.withLock { requests } }
    func beginRequest() { lock.withLock { requests += 1 }; changed() }
    func endRequest() { lock.withLock { requests -= 1; vmIdleSince = Date() }; changed() }

    func beginSession(distro: String) { lock.withLock { sessions[distro, default: 0] += 1 }; changed() }
    func endSession(distro: String) {
        lock.withLock {
            sessions[distro, default: 1] -= 1
            if sessions[distro] == 0 { idleSince[distro] = Date() }
        }
        changed()
    }

    /// Wake the idle monitor: something its deadlines depend on changed.
    func changed() {
        cond.lock(); pending = true; cond.signal(); cond.unlock()
    }

    /// Sleep until `changed()` or `deadline` (nil: no deadline).
    func waitForChange(until deadline: Date?) {
        cond.lock()
        defer { pending = false; cond.unlock() }
        while !pending {
            if let deadline {
                if !cond.wait(until: deadline) { return }
            } else {
                cond.wait()
            }
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
