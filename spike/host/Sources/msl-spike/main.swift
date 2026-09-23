// msl-spike: milestone 0 VM runner (throwaway; the real host is msld).
//
// Boots the utility VM (kernel + initrd with msl-guest as /init) and exposes:
//   <run>/vsock-<port>.sock  Unix sockets bridged to guest vsock ports
//   <run>/control.sock       line commands: usb-attach <img> | usb-detach <img> |
//                            balloon <MiB> | state | stop
//   <run>/console.log        guest hvc0 console

import ContainerizationEXT4
import Foundation
import SystemPackage
import Virtualization
import vmnet

// MARK: - Options

struct Options {
    var kernel = ""
    var initrd = ""
    var disk = ""
    var diskGiB: UInt64 = 32
    var share = ""
    var mac = "/"
    var run = ""
    var cpus = 4
    var memGiB: UInt64 = 4
    var net = "vmnet"
    var cmdline = "console=hvc0 ip=dhcp loglevel=4"

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let k = it.next() {
            guard let v = it.next() else { fatal("missing value for \(k)") }
            switch k {
            case "--kernel": kernel = v
            case "--initrd": initrd = v
            case "--disk": disk = v
            case "--disk-gib": diskGiB = UInt64(v)!
            case "--share": share = v
            case "--mac": mac = v
            case "--run": run = v
            case "--cpus": cpus = Int(v)!
            case "--mem-gib": memGiB = UInt64(v)!
            case "--net": net = v
            case "--cmdline-extra": cmdline += " " + v
            default: fatal("unknown option \(k)")
            }
        }
        for (name, val) in [("--kernel", kernel), ("--initrd", initrd), ("--disk", disk), ("--share", share), ("--run", run)]
        where val.isEmpty {
            fatal("\(name) is required")
        }
    }
}

func log(_ s: String) {
    FileHandle.standardError.write("[msl-spike] \(s)\n".data(using: .utf8)!)
}

func fatal(_ s: String) -> Never {
    log("fatal: \(s)")
    exit(1)
}

let opts = Options(CommandLine.arguments)
let vmQueue = DispatchQueue(label: "msl.vm")
try? FileManager.default.createDirectory(atPath: opts.run, withIntermediateDirectories: true)

// MARK: - Data disk (ext4 formatted on the host, no mkfs needed)

func ensureDataDisk() throws {
    guard !FileManager.default.fileExists(atPath: opts.disk) else { return }
    let t0 = Date()
    let fmt = try EXT4.Formatter(FilePath(opts.disk), minDiskSize: opts.diskGiB << 30,
                                 journal: .init(defaultMode: .ordered))
    try fmt.close()
    let attrs = try FileManager.default.attributesOfItem(atPath: opts.disk)
    log("formatted ext4 data disk \(opts.disk) (\(opts.diskGiB) GiB logical, \(attrs[.size] ?? 0) bytes) in \(Date().timeIntervalSince(t0))s")
}

// MARK: - VM configuration

func makeNetwork() -> VZNetworkDeviceAttachment {
    if opts.net == "vmnet" {
        var status: vmnet_return_t = .VMNET_SUCCESS
        if let cfg = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status),
           let net = vmnet_network_create(cfg, &status) {
            log("network: vmnet shared (VZVmnetNetworkDeviceAttachment)")
            return VZVmnetNetworkDeviceAttachment(network: net)
        }
        log("network: vmnet_network_create failed (status \(status.rawValue)); falling back to NAT")
    }
    log("network: VZNATNetworkDeviceAttachment")
    return VZNATNetworkDeviceAttachment()
}

func makeConfig() throws -> VZVirtualMachineConfiguration {
    let c = VZVirtualMachineConfiguration()
    let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: opts.kernel))
    boot.initialRamdiskURL = URL(fileURLWithPath: opts.initrd)
    boot.commandLine = opts.cmdline
    c.bootLoader = boot
    c.cpuCount = opts.cpus
    c.memorySize = opts.memGiB << 30

    let consolePath = "\(opts.run)/console.log"
    FileManager.default.createFile(atPath: consolePath, contents: nil)
    let console = VZVirtioConsoleDeviceSerialPortConfiguration()
    console.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: nil, fileHandleForWriting: FileHandle(forWritingAtPath: consolePath))
    c.serialPorts = [console]

    let disk = try VZDiskImageStorageDeviceAttachment(
        url: URL(fileURLWithPath: opts.disk), readOnly: false, cachingMode: .automatic, synchronizationMode: .full)
    c.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

    let nic = VZVirtioNetworkDeviceConfiguration()
    nic.attachment = makeNetwork()
    c.networkDevices = [nic]

    var shares: [VZDirectorySharingDeviceConfiguration] = []
    for (tag, path) in [("share", opts.share), ("mac", opts.mac)] {
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(fileURLWithPath: path), readOnly: false))
        shares.append(fs)
    }
    switch VZLinuxRosettaDirectoryShare.availability {
    case .installed:
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
        fs.share = try VZLinuxRosettaDirectoryShare()
        shares.append(fs)
        log("rosetta: installed, shared as tag 'rosetta'")
    case .notInstalled: log("rosetta: not installed (softwareupdate --install-rosetta)")
    default: log("rosetta: not supported")
    }
    c.directorySharingDevices = shares

    c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    c.usbControllers = [VZXHCIControllerConfiguration()]
    try c.validate()
    return c
}

// MARK: - Unix socket helpers

func listenUnix(_ path: String) -> Int32 {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8.prefix(Int(MemoryLayout.size(ofValue: addr.sun_path)) - 1))
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (i, b) in bytes.enumerated() { buf[i] = b }
    }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0, listen(fd, 16) == 0 else { fatal("listen \(path): \(String(cString: strerror(errno)))") }
    return fd
}

func acceptLoop(_ listenFD: Int32, _ onClient: @escaping (Int32) -> Void) {
    Thread.detachNewThread {
        while true {
            let c = accept(listenFD, nil, nil)
            if c >= 0 { onClient(c) }
        }
    }
}

/// Copy bytes both ways until either side closes.
func pump(_ a: Int32, _ b: Int32, onDone: @escaping () -> Void) {
    let group = DispatchGroup()
    for (src, dst) in [(a, b), (b, a)] {
        group.enter()
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(src, &buf, buf.count)
                if n <= 0 { break }
                var off = 0
                while off < n {
                    let w = buf.withUnsafeBytes { write(dst, $0.baseAddress! + off, n - off) }
                    if w <= 0 { break }
                    off += w
                }
            }
            shutdown(dst, SHUT_WR)
            group.leave()
        }
    }
    group.notify(queue: .global()) { onDone() }
}

// MARK: - VM lifecycle

final class Delegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ vm: VZVirtualMachine) {
        log("guest stopped")
        exit(0)
    }

    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
        log("vm stopped with error: \(error)")
        exit(1)
    }
}

do { try ensureDataDisk() } catch { fatal("data disk: \(error)") }
let config: VZVirtualMachineConfiguration
do { config = try makeConfig() } catch { fatal("config: \(error)") }
let vm = VZVirtualMachine(configuration: config, queue: vmQueue)
let delegate = Delegate()
var usbDevices: [String: VZUSBMassStorageDevice] = [:]

func bridgeVsock(port: UInt32) {
    let path = "\(opts.run)/vsock-\(port).sock"
    acceptLoop(listenUnix(path)) { client in
        vmQueue.async {
            guard let dev = vm.socketDevices.first as? VZVirtioSocketDevice else { close(client); return }
            dev.connect(toPort: port) { result in
                switch result {
                case .success(let conn):
                    pump(client, conn.fileDescriptor) {
                        close(client)
                        conn.close()
                    }
                case .failure(let err):
                    let msg = "{\"ok\":false,\"error\":\"vsock connect \(port): \(err.localizedDescription)\"}\n"
                    _ = msg.withCString { write(client, $0, strlen($0)) }
                    close(client)
                }
            }
        }
    }
}

/// Runs `body` on the VM queue and waits for its reply.
func onVM(_ body: @escaping (@escaping (String) -> Void) -> Void) -> String {
    let sem = DispatchSemaphore(value: 0)
    var out = ""
    vmQueue.async { body { out = $0; sem.signal() } }
    sem.wait()
    return out
}

func control(_ line: String) -> String {
    let parts = line.split(separator: " ").map(String.init)
    switch parts.first ?? "" {
    case "state":
        return onVM { $0("state \(vm.state.rawValue)") }
    case "stop":
        return onVM { reply in
            vm.stop { err in
                reply(err.map { "error \($0)" } ?? "ok")
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) }
            }
        }
    case "balloon" where parts.count == 2:
        return onVM { reply in
            guard let b = vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice else {
                return reply("error no balloon")
            }
            b.targetVirtualMachineMemorySize = UInt64(parts[1])! << 20
            reply("ok target=\(b.targetVirtualMachineMemorySize >> 20)MiB")
        }
    case "usb-attach" where parts.count >= 2:
        let path = parts[1]
        return onVM { reply in
            do {
                let att = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: path), readOnly: parts.count > 2)
                let dev = VZUSBMassStorageDevice(configuration: VZUSBMassStorageDeviceConfiguration(attachment: att))
                guard let usb = vm.usbControllers.first else { return reply("error no usb controller") }
                usb.attach(device: dev) { err in
                    if let err { return reply("error \(err)") }
                    usbDevices[path] = dev
                    reply("ok attached")
                }
            } catch { reply("error \(error)") }
        }
    case "usb-detach" where parts.count == 2:
        return onVM { reply in
            guard let dev = usbDevices[parts[1]], let usb = vm.usbControllers.first else { return reply("error unknown device") }
            usb.detach(device: dev) { err in
                usbDevices[parts[1]] = nil
                reply(err.map { "error \($0)" } ?? "ok detached")
            }
        }
    default:
        return "error unknown command"
    }
}

acceptLoop(listenUnix("\(opts.run)/control.sock")) { client in
    Thread.detachNewThread {
        let fh = FileHandle(fileDescriptor: client, closeOnDealloc: true)
        var pending = Data()
        while true {
            let chunk = fh.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                pending.removeSubrange(...nl)
                fh.write((control(line) + "\n").data(using: .utf8)!)
            }
        }
    }
}

for port in [UInt32(1024)] + (2000..<2010).map(UInt32.init) {
    bridgeVsock(port: port)
}

vmQueue.async {
    vm.delegate = delegate
    let t0 = Date()
    vm.start { result in
        switch result {
        case .success: log("vm started in \(String(format: "%.3f", Date().timeIntervalSince(t0)))s; run dir \(opts.run)")
        case .failure(let e): fatal("start: \(e)")
        }
    }
}
dispatchMain()
