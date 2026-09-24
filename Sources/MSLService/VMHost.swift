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
    static let dataDiskBytes: UInt64 = 256 << 30

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
                          localhostForwarding: cfg.localhostForwarding, dnsTunneling: cfg.dnsTunneling,
                          vmIdleTimeoutMs: cfg.vmIdleTimeoutMs, instanceIdleTimeoutMs: cfg.instanceIdleTimeoutMs)
    }

    /// Settings and start time of the running VM (nil when stopped).
    public private(set) var booted: (settings: VMSettings, at: Date)?

    public func ensureRunning(config: MSLConfig) throws {
        if isRunning { return }
        var res = try Resources.locate()
        if let k = config.kernel {
            guard FileManager.default.fileExists(atPath: k) else {
                throw ServiceError("The custom kernel was not found: \(k)", code: ErrorCode.fileNotFound)
            }
            res = Resources(kernel: URL(fileURLWithPath: k), initrd: res.initrd, kernelVersion: "custom")
        }
        let settings = Self.resolve(config)
        try ensureDataDisk()
        let vmConfig = try makeConfig(res, settings)
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
            throw ServiceError("The virtual machine could not be started: \(startError.localizedDescription)", code: ErrorCode.vm)
        }
        queue.sync { booted = (settings, Date()) }
        log("vm started (\(settings.processors) CPUs, \(settings.memoryBytes >> 20) MiB)")
    }

    func ensureDataDisk() throws {
        let url = paths.dataDisk
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let fmt = try EXT4.Formatter(FilePath(url.path), minDiskSize: Self.dataDiskBytes, journal: .init(defaultMode: .ordered))
        try fmt.close()
        log("created data disk \(url.path)")
    }

    func makeNetwork() -> VZNetworkDeviceAttachment {
        var status: vmnet_return_t = .VMNET_SUCCESS
        // Note: pinning the subnet (vmnet_network_configuration_set_ipv4_subnet) stops
        // vmnet's DHCP from answering the kernel's `ip=dhcp` (M1 finding); pinning
        // needs static guest addressing (milestone 4).
        if let cfg = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) {
            if let net = vmnet_network_create(cfg, &status) {
                return VZVmnetNetworkDeviceAttachment(network: net)
            }
        }
        log("vmnet unavailable (status \(status.rawValue)); using NAT attachment")
        return VZNATNetworkDeviceAttachment()
    }

    func makeConfig(_ res: Resources, _ s: VMSettings) throws -> VZVirtualMachineConfiguration {
        let c = VZVirtualMachineConfiguration()
        let boot = VZLinuxBootLoader(kernelURL: res.kernel)
        boot.initialRamdiskURL = res.initrd
        boot.commandLine = s.kernelCommandLine
        c.bootLoader = boot
        c.cpuCount = s.processors
        c.memorySize = s.memoryBytes

        FileManager.default.createFile(atPath: paths.consoleLog.path, contents: nil)
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil, fileHandleForWriting: FileHandle(forWritingAtPath: paths.consoleLog.path))
        c.serialPorts = [console]

        let disk = try VZDiskImageStorageDeviceAttachment(url: paths.dataDisk, readOnly: false, cachingMode: .automatic, synchronizationMode: .full)
        c.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

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
        return c
    }

    // MARK: stop

    public func stop() {
        let sem = DispatchSemaphore(value: 0)
        queue.async {
            guard let vm = self.vm, vm.canStop else { sem.signal(); return }
            vm.stop { _ in sem.signal() }
        }
        _ = sem.wait(timeout: .now() + 10)
        stopped()
    }

    /// Wait for the guest to power itself off (after MiniInit.Shutdown).
    public func waitForStop(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if queue.sync(execute: { vm == nil || vm?.state == .stopped }) {
                stopped()
                return true
            }
            usleep(50_000)
        }
        return false
    }

    private func stopped() {
        queue.sync { vm = nil; booted = nil }
        lock.withLock {
            for (_, fd) in bridges { close(fd) }
            bridges.removeAll()
        }
        onStop?()
    }

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        log("guest powered off")
        DispatchQueue.global().async { self.stopped() }
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        log("vm stopped with error: \(error)")
        DispatchQueue.global().async { self.stopped() }
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

    private var listeners: [VZVirtioSocketListener] = []

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
            self.listeners.append(l)
        }
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
