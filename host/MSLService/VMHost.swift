// SPDX-License-Identifier: Apache-2.0
import ContainerizationEXT4
import Foundation
import MSLCore
import SystemPackage
import Virtualization
import vmnet

/// Locates the kernel and initrd: $MSL_KERNEL / $MSL_INITRD, else
/// `<dir of msld>/../share/msl/{Image,initrd.gz}`.
public struct Resources: Sendable {
    public let kernel: URL
    public let initrd: URL
    public let kernelVersion: String

    public static func locate() throws -> Resources {
        let env = ProcessInfo.processInfo.environment
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // build/bin/msld -> build/share/msl; <prefix>/libexec/msl/msld -> <prefix>/share/msl
        let dir = exe.deletingLastPathComponent()
        let share = [dir.appendingPathComponent("../share/msl"), dir.appendingPathComponent("../../share/msl")]
            .map(\.standardizedFileURL)
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("initrd.gz").path) }
            ?? dir.appendingPathComponent("../share/msl").standardizedFileURL
        let kernel = env["MSL_KERNEL"].map(URL.init(fileURLWithPath:)) ?? share.appendingPathComponent("Image")
        let initrd = env["MSL_INITRD"].map(URL.init(fileURLWithPath:)) ?? share.appendingPathComponent("initrd.gz")
        for f in [kernel, initrd] where !FileManager.default.fileExists(atPath: f.path) {
            throw ServiceError("Missing \(f.path)", code: ErrorCode.fileNotFound)
        }
        let version = (try? String(contentsOf: share.appendingPathComponent("kernel.version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        return Resources(kernel: kernel, initrd: initrd, kernelVersion: version)
    }
}

public struct ServiceError: Error {
    public let message: String
    public let code: String
    public init(_ message: String, code: String) {
        self.message = message
        self.code = code
    }
}

/// Owns the utility VM. All Virtualization.framework calls happen on `queue`.
public final class VMHost: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    public static let controlPort: UInt32 = 1024

    let paths: Paths
    let queue = DispatchQueue(label: "msl.vm")
    private var vm: VZVirtualMachine?
    private var bridges: [UInt32: Int32] = [:]  // guest port -> listening fd
    private let lock = NSLock()
    public var onStop: (() -> Void)?

    public init(paths: Paths) {
        self.paths = paths
    }

    public var isRunning: Bool {
        queue.sync { vm?.state == .running }
    }

    // MARK: boot

    static let baseCommandLine = "console=hvc0 ip=dhcp net.ifnames=0 loglevel=4"

    /// .mslconfig with defaults applied: the single source for booting the VM
    /// and for `msl --status`.
    public static func resolve(_ cfg: MSLConfig) -> VMSettings {
        let cpus = max(1, min(cfg.processors ?? ProcessInfo.processInfo.activeProcessorCount,
                              VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        let mem = cfg.memoryBytes ?? ProcessInfo.processInfo.physicalMemory / 2  // .wslconfig default: 50%
        let memory = min(max(mem & ~(UInt64(1 << 20) - 1), VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                         VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        let kernel: String
        if let k = cfg.kernel {
            kernel = "\(k) (custom)"
        } else {
            kernel = ((try? Resources.locate().kernelVersion) ?? "missing") + " (bundled)"
        }
        return VMSettings(memoryBytes: memory, processors: cpus, kernel: kernel,
                          kernelCommandLine: [baseCommandLine, cfg.kernelCommandLine].filter { !$0.isEmpty }.joined(separator: " "),
                          localhostForwarding: cfg.localhostForwarding, autoProxy: cfg.autoProxy,
                          dnsProxy: cfg.dnsProxy, dnsTunneling: cfg.dnsTunneling,
                          vmIdleTimeoutMs: cfg.vmIdleTimeoutMs, instanceIdleTimeoutMs: cfg.instanceIdleTimeoutMs,
                          nestedVirtualization: cfg.nestedVirtualization && VZGenericPlatformConfiguration.isNestedVirtualizationSupported)
    }

    /// Settings and start time of the running VM (nil when stopped).
    public private(set) var booted: (settings: VMSettings, at: Date)?

    /// A distro's own disk to attach at boot: its image, found in the VM by `serial`.
    public struct BootDisk: Equatable, Sendable {
        public var serial: String
        public var path: String
    }

    /// Boot the VM with `disks` attached as virtio-blk. Returns the ones that
    /// were (an image that can't be opened is left out and logged).
    @discardableResult
    public func ensureRunning(config: MSLConfig, disks: [BootDisk] = []) throws -> [BootDisk] {
        if isRunning { return [] }
        var res = try Resources.locate()
        if let k = config.kernel {
            guard FileManager.default.fileExists(atPath: k) else {
                throw ServiceError("The custom kernel was not found: \(k)", code: ErrorCode.fileNotFound)
            }
            res = Resources(kernel: URL(fileURLWithPath: k), initrd: res.initrd, kernelVersion: "custom")
        }
        let settings = Self.resolve(config)
        try ensureDataDisk(config)
        try FileManager.default.createDirectory(at: paths.runDir, withIntermediateDirectories: true)
        try Self.waitUntilFree([paths.dataDisk.path] + disks.map(\.path))
        let (vmConfig, attached) = try makeConfig(res, settings, disks: disks)
        let sem = DispatchSemaphore(value: 0)
        var startError: Error?
        queue.sync {
            let vm = VZVirtualMachine(configuration: vmConfig, queue: queue)
            vm.delegate = self
            self.vm = vm
            vm.start { result in
                if case .failure(let e) = result { startError = e }
                sem.signal()
            }
        }
        sem.wait()
        if let startError {
            queue.sync { vm = nil }
            let e = startError as NSError
            log("vm start failed: \(e.domain) \(e.code) \(e.userInfo); disks: \(attached.map(\.path))")
            throw ServiceError("The virtual machine could not be started: \(startError.localizedDescription)", code: ErrorCode.vm)
        }
        queue.sync { booted = (settings, Date()) }
        log("vm started (\(settings.processors) CPUs, \(settings.memoryBytes >> 20) MiB, \(attached.count) distro disks)")
        return attached
    }

    func ensureDataDisk(_ config: MSLConfig) throws {
        let url = paths.dataDisk
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let size = DataDisk.initialSize(configured: config.defaultVhdSize, volumeCapacity: Self.volumeCapacity(paths.root))
        let fmt = try EXT4.Formatter(FilePath(url.path), minDiskSize: size, journal: .init(defaultMode: .ordered))
        try fmt.close()
        log("created data disk \(url.path) (\(StatusFormat.bytes(size)))")
    }

    /// VZ holds an exclusive flock on each disk image while a VM uses it, and
    /// releases it a little after the VM reports it has stopped. Booting before
    /// then fails with "The storage device attachment is invalid", so wait (up
    /// to `timeout`) until every image can be locked.
    static func waitUntilFree(_ images: [String], timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        for path in images {
            let fd = open(path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { continue }  // missing: makeConfig reports it
            defer { close(fd) }
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK, Date() < deadline else {
                    throw ServiceError("The disk \(path) is in use by another virtual machine.", code: ErrorCode.vm)
                }
                usleep(50_000)
            }
            flock(fd, LOCK_UN)
        }
    }

    /// The persisted machine identifier, created at the first start. A new one
    /// replaces a file VZ can't read.
    func machineIdentifier() throws -> VZGenericMachineIdentifier {
        let url = paths.machineIdentifier
        if let data = try? Data(contentsOf: url), let id = VZGenericMachineIdentifier(dataRepresentation: data) { return id }
        let id = VZGenericMachineIdentifier()
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try id.dataRepresentation.write(to: url, options: .atomic)
        log("created machine identifier \(url.path)")
        return id
    }

    /// `msl.machine_id=<32 hex>`: the identifier's UUID, which mini-init writes to
    /// /etc/machine-id. VZ keeps it in dataRepresentation, a plist {UUID: 16 bytes}.
    static func machineIDArgument(_ id: VZGenericMachineIdentifier) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: id.dataRepresentation, format: nil) as? [String: Any],
              let uuid = plist["UUID"] as? Data, uuid.count == 16 else {
            log("machine identifier: no UUID in its data representation")
            return nil
        }
        return "msl.machine_id=" + uuid.map { String(format: "%02x", $0) }.joined()
    }

    /// Total capacity of the Mac volume holding `url`.
    static func volumeCapacity(_ url: URL) -> UInt64? {
        (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity).flatMap { $0.map(UInt64.init) }
    }

    /// Free space for important data on that volume (what Finder shows as available).
    static func volumeAvailable(_ url: URL) -> UInt64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage)
            .flatMap { $0.map { UInt64(max(0, $0)) } }
    }

    func makeNetwork() -> VZNetworkDeviceAttachment {
        var status: vmnet_return_t = .VMNET_SUCCESS
        // Note: pinning the subnet (vmnet_network_configuration_set_ipv4_subnet) stops
        // vmnet's DHCP from answering the kernel's `ip=dhcp` (M1 finding); pinning
        // needs static guest addressing.
        if let cfg = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) {
            if let net = vmnet_network_create(cfg, &status) {
                return VZVmnetNetworkDeviceAttachment(network: net)
            }
        }
        log("vmnet unavailable (status \(status.rawValue)); using NAT attachment")
        return VZNATNetworkDeviceAttachment()
    }

    func makeConfig(_ res: Resources, _ s: VMSettings, disks: [BootDisk]) throws -> (VZVirtualMachineConfiguration, [BootDisk]) {
        let c = VZVirtualMachineConfiguration()
        let boot = VZLinuxBootLoader(kernelURL: res.kernel)
        boot.initialRamdiskURL = res.initrd
        let machineID = try machineIdentifier()
        boot.commandLine = s.kernelCommandLine + (Self.machineIDArgument(machineID).map { " " + $0 } ?? "")
        c.bootLoader = boot
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = machineID
        platform.isNestedVirtualizationEnabled = s.nestedVirtualization
        c.platform = platform
        c.cpuCount = s.processors
        c.memorySize = s.memoryBytes

        FileManager.default.createFile(atPath: paths.consoleLog.path, contents: nil)
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil, fileHandleForWriting: FileHandle(forWritingAtPath: paths.consoleLog.path))
        c.serialPorts = [console]

        let disk = try VZDiskImageStorageDeviceAttachment(url: paths.dataDisk, readOnly: false, cachingMode: .automatic, synchronizationMode: .full)
        let data = VZVirtioBlockDeviceConfiguration(attachment: disk)
        data.blockDeviceIdentifier = "data"  // how mini-init finds it
        c.storageDevices = [data]
        // The distros' own disks (#50), served by VZ like data.img: guest
        // flushes become F_FULLFSYNC (.full).
        var attached: [BootDisk] = []
        for d in disks.prefix(DistroDisk.maxBootDisks) {
            do {
                let a = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: d.path), readOnly: false,
                                                               cachingMode: .automatic, synchronizationMode: .full)
                let dev = VZVirtioBlockDeviceConfiguration(attachment: a)
                dev.blockDeviceIdentifier = d.serial
                c.storageDevices.append(dev)
                attached.append(d)
            } catch {
                log("disk \(d.path) not attached: \(error.localizedDescription)")
            }
        }

        let nic = VZVirtioNetworkDeviceConfiguration()
        nic.attachment = makeNetwork()
        c.networkDevices = [nic]

        let mac = VZVirtioFileSystemDeviceConfiguration(tag: "mac")
        mac.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(fileURLWithPath: "/"), readOnly: false))
        var shares: [VZDirectorySharingDeviceConfiguration] = [mac]
        if VZLinuxRosettaDirectoryShare.availability == .installed {
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
            fs.share = try VZLinuxRosettaDirectoryShare()
            shares.append(fs)
        }
        c.directorySharingDevices = shares
        c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        c.usbControllers = [VZXHCIControllerConfiguration()]
        try c.validate()
        return (c, attached)
    }

    // MARK: stop

    public func stop() {
        let sem = DispatchSemaphore(value: 0)
        let current = queue.sync { vm }
        queue.async {
            guard let vm = current, vm.canStop else { sem.signal(); return }
            vm.stop { _ in sem.signal() }
        }
        _ = sem.wait(timeout: .now() + 10)
        if let current { stopped(current) }
    }

    /// Wait for the guest to power itself off (after MiniInit.Shutdown).
    public func waitForStop(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = queue.sync { vm }
            guard let current else {
                awaitTeardown()  // another path (the delegate) is still tearing it down
                return true
            }
            if queue.sync(execute: { current.state == .stopped }) {
                stopped(current)
                return true
            }
            usleep(50_000)
        }
        return false
    }

    /// Teardowns of a stopped VM still running (`stopped`). A boot must wait for
    /// them: `vm` is cleared first, and a teardown finishing after the next boot
    /// would wipe that boot's state (DistroDisks' boot disks, the vsock bridges).
    private let teardown = NSCondition()
    private var tearingDown = 0

    /// Wait (up to `timeout`) until no stopped VM is still being torn down.
    public func awaitTeardown(timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        teardown.lock()
        defer { teardown.unlock() }
        while tearingDown > 0 && teardown.wait(until: deadline) {}
    }

    /// `which` stopped. Runs once per VM (the stop paths and the delegate all
    /// report it), and never for a VM started since: a late report must not
    /// tear down the next boot.
    private func stopped(_ which: VZVirtualMachine) {
        let current = queue.sync { () -> Bool in
            guard vm === which else { return false }
            vm = nil
            booted = nil
            teardown.withLock { tearingDown += 1 }
            return true
        }
        guard current else { return }
        defer {
            teardown.lock()
            tearingDown -= 1
            teardown.broadcast()
            teardown.unlock()
        }
        lock.withLock {
            for (port, fd) in bridges {
                close(fd)
                unlink(paths.runDir.appendingPathComponent("vsock-\(port).sock").path)
            }
            bridges.removeAll()
        }
        onStop?()
    }

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        log("guest powered off")
        DispatchQueue.global().async { self.stopped(virtualMachine) }
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        log("vm stopped with error: \(error)")
        DispatchQueue.global().async { self.stopped(virtualMachine) }
    }

    // MARK: USB mass storage (msl --mount)

    /// Hot-attach a disk image file or a /dev/diskN block device.
    public func attachDisk(path: String, readOnly: Bool) throws -> AnyObject {
        let attachment: VZStorageDeviceAttachment
        var isBlock = false
        var st = stat()
        if stat(path, &st) == 0 { isBlock = (st.st_mode & S_IFMT) == S_IFBLK || (st.st_mode & S_IFMT) == S_IFCHR }
        if isBlock {
            let raw = path.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
            guard let fh = FileHandle(forUpdatingAtPath: raw) ?? (readOnly ? FileHandle(forReadingAtPath: raw) : nil) else {
                throw ServiceError("Administrator access is needed to mount a disk.", code: ErrorCode.unsupported)
            }
            attachment = try VZDiskBlockDeviceStorageDeviceAttachment(fileHandle: fh, readOnly: readOnly, synchronizationMode: .full)
        } else {
            attachment = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: path), readOnly: readOnly,
                                                                cachingMode: .automatic, synchronizationMode: .full)
        }
        let dev = VZUSBMassStorageDevice(configuration: VZUSBMassStorageDeviceConfiguration(attachment: attachment))
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        queue.async {
            guard let usb = self.vm?.usbControllers.first else {
                failure = ServiceError("vm not running", code: ErrorCode.vm)
                sem.signal()
                return
            }
            usb.attach(device: dev) { err in
                failure = err
                sem.signal()
            }
        }
        sem.wait()
        if let failure { throw ServiceError("Failed to attach disk '\(path)' to the VM: \(failure.localizedDescription)", code: ErrorCode.vm) }
        return dev
    }

    public func detachDisk(_ device: AnyObject) {
        guard let dev = device as? VZUSBMassStorageDevice else { return }
        let sem = DispatchSemaphore(value: 0)
        queue.async {
            guard let usb = self.vm?.usbControllers.first else { sem.signal(); return }
            usb.detach(device: dev) { _ in sem.signal() }
        }
        _ = sem.wait(timeout: .now() + 10)
    }

    // MARK: vsock

    private var listeners: [UInt32: VZVirtioSocketListener] = [:]  // on `queue`

    /// Accept guest-initiated vsock connections on `port`; `handler` gets a dup'd
    /// fd it owns, on a background thread.
    public func listen(port: UInt32, handler: @escaping @Sendable (Int32) -> Void) {
        queue.async {
            guard let dev = self.vm?.socketDevices.first as? VZVirtioSocketDevice else { return }
            let l = VZVirtioSocketListener()
            let d = ListenerDelegate(handler: handler)
            objc_setAssociatedObject(l, &ListenerDelegate.key, d, .OBJC_ASSOCIATION_RETAIN)
            l.delegate = d
            dev.setSocketListener(l, forPort: port)
            self.listeners[port] = l
        }
    }

    /// Stop accepting guest connections on `port`.
    public func unlisten(port: UInt32) {
        queue.async {
            (self.vm?.socketDevices.first as? VZVirtioSocketDevice)?.removeSocketListener(forPort: port)
            self.listeners[port] = nil
        }
    }

    /// A one-shot port for a guest-initiated stream (RunRequest.dial_back): a
    /// random host port whose first connection that starts with `token` is the
    /// stream (any other is dropped; a process in the VM could guess the port).
    /// `wait` returns the stream's fd, which the caller owns.
    public func acceptStream(token: [UInt8], timeout: TimeInterval = 15) -> (port: UInt32, wait: () throws -> Int32) {
        let port = UInt32.random(in: 0x4000_0000...0x7fff_ffff)
        let sem = DispatchSemaphore(value: 0)
        let box = FDBox()
        let remove = { [weak self] in self?.unlisten(port: port) }
        listen(port: port) { fd in
            // The token comes first; a connection that doesn't send it in 5 s isn't ours.
            var got = [UInt8]()
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let deadline = Date().addingTimeInterval(5)
            while got.count < token.count {
                let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
                guard poll(&p, 1, left) > 0 else { break }
                var buf = [UInt8](repeating: 0, count: token.count - got.count)
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                got += buf[0..<n]
            }
            guard got == token, box.claim(fd) else { close(fd); return }
            remove()
            sem.signal()
        }
        return (port, {
            guard sem.wait(timeout: .now() + timeout) == .success else {
                remove()
                throw ServiceError("The distribution didn't open its session stream.", code: ErrorCode.service)
            }
            return box.fd
        })
    }

    /// Connect to a guest vsock port. The returned fd is a dup the caller owns.
    public func connect(port: UInt32) throws -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        var out: Result<Int32, Error> = .failure(ServiceError("vm not running", code: ErrorCode.vm))
        queue.async {
            guard let dev = self.vm?.socketDevices.first as? VZVirtioSocketDevice else { sem.signal(); return }
            dev.connect(toPort: port) { result in
                out = result.map { conn in
                    let fd = dup(conn.fileDescriptor)
                    conn.close()
                    return fd
                }
                sem.signal()
            }
        }
        sem.wait()
        return try out.get()
    }

    /// A Unix socket path whose connections are bridged to the guest vsock
    /// `port` (gRPC clients connect here).
    public func bridgePath(port: UInt32) throws -> String {
        try FileManager.default.createDirectory(at: paths.runDir, withIntermediateDirectories: true)
        let path = paths.runDir.appendingPathComponent("vsock-\(port).sock").path
        try lock.withLock {
            if bridges[port] != nil { return }
            let lfd = try listenUnix(path)
            bridges[port] = lfd
            Thread.detachNewThread { [weak self] in
                while true {
                    let c = accept(lfd, nil, nil)
                    if c < 0 { return }  // listener closed on VM stop
                    guard let self, let v = try? self.connect(port: port) else { close(c); continue }
                    Pump.bidirectional(c, v)
                }
            }
        }
        return path
    }
}

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

final class ListenerDelegate: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    nonisolated(unsafe) static var key = 0
    let handler: @Sendable (Int32) -> Void
    init(handler: @escaping @Sendable (Int32) -> Void) { self.handler = handler }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        let fd = dup(connection.fileDescriptor)
        connection.close()
        guard fd >= 0 else { return false }
        let h = handler
        Thread.detachNewThread { h(fd) }
        return true
    }
}


/// Holds the first fd handed to it.
final class FDBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var fd: Int32 = -1
    func claim(_ fd: Int32) -> Bool {
        lock.withLock {
            guard self.fd < 0 else { return false }
            self.fd = fd
            return true
        }
    }
}
